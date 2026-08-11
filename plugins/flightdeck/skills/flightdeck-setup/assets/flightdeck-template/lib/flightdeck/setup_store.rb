# frozen_string_literal: true

require "find"
require "uri"
require_relative "bridge_bulk_store"

module Flightdeck
  class SetupStore
    FAILURE_POLICIES = %w[stop continue].freeze
    WORKLOAD_PROFILES = {
      "charts" => "charts",
      "patching" => "patching",
      "environments" => "environments"
    }.freeze
    HOSTED_LOCATOR = /\A[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)+\z/

    attr_reader :config

    def initialize(config)
      @config = config
    end

    def plan(repositories_root:, failure_policy: "continue")
      validate_failure_policy!(failure_policy)
      root = normalize_discovery_root(repositories_root)
      repositories = discover_git_roots(root).map { |path| inspect_repository(path, root) }
      mark_identifier_collisions!(repositories)
      {
        "schema_version" => "flightdeck.setup-plan/v1",
        "read_only" => true,
        "repositories_root" => root,
        "failure_policy" => failure_policy,
        "declarations" => Support.relative_path(config.root, config.repository_declarations_path),
        "local_state" => Support.relative_path(config.root, config.local_registry_path),
        "default_bridge" => {
          "mode" => "reference",
          "tracked_repository_files_changed" => false,
          "git_local_exclude_changed_on_connect" => true
        },
        "repositories" => repositories,
        "summary" => summary_for(repositories),
        "next" => repositories.empty? ?
          "Choose a narrower root that contains Git repositories." :
          "Run setup connect to record portable declarations, attach exact local paths, and install safe reference bridges."
      }
    end

    def connect(repositories_root:, failure_policy: "continue")
      plan_value = plan(
        repositories_root: repositories_root,
        failure_policy: failure_policy
      )
      blocked = plan_value.fetch("repositories").select { |item| item.fetch("blockers").any? }
      if failure_policy == "stop" && blocked.any?
        return connection_result(
          plan_value,
          bridge_receipt: nil,
          changed: false,
          stopped: true
        )
      end

      eligible = plan_value.fetch("repositories").reject { |item| item.fetch("blockers").any? }
      if eligible.empty?
        return connection_result(
          plan_value,
          bridge_receipt: nil,
          changed: false,
          stopped: false
        )
      end
      before_declarations = File.read(config.repository_declarations_path, encoding: "UTF-8")
      before_registry = File.file?(config.local_registry_path) ?
        File.read(config.local_registry_path, encoding: "UTF-8") : nil
      write_connection_state(eligible)
      refreshed = Config.new(root: config.root)
      bridge_receipt = install_selected(refreshed, eligible, failure_policy)
      connection_result(
        plan_value,
        bridge_receipt: bridge_receipt,
        changed: before_declarations != File.read(config.repository_declarations_path, encoding: "UTF-8") ||
          before_registry != File.read(config.local_registry_path, encoding: "UTF-8"),
        stopped: false
      )
    rescue StandardError
      Support.atomic_write(config.repository_declarations_path, before_declarations) if before_declarations
      if defined?(before_registry)
        if before_registry
          Support.atomic_write(config.local_registry_path, before_registry)
        else
          FileUtils.rm_f(config.local_registry_path)
        end
      end
      raise
    end

    private

    def validate_failure_policy!(value)
      return if FAILURE_POLICIES.include?(value.to_s)

      raise UsageError, "failure policy must be one of: #{FAILURE_POLICIES.join(', ')}"
    end

    def normalize_discovery_root(value)
      requested = value.to_s
      raise UsageError, "--repositories-root must be an absolute directory" unless Pathname.new(requested).absolute?

      expanded = File.expand_path(requested)
      raise ValidationError, "repository root must not be a symlink" if File.symlink?(expanded)
      raise ValidationError, "repository root does not exist: #{expanded}" unless Dir.exist?(expanded)

      root = File.realpath(expanded)
      if root == File::SEPARATOR || root == File.realpath(Dir.home)
        raise ValidationError, "repository root is too broad: #{root}"
      end
      root
    rescue Errno::ENOENT, Errno::ELOOP => e
      raise ValidationError, "repository root cannot be resolved safely: #{e.message}"
    end

    def discover_git_roots(root)
      repositories = []
      Find.find(root) do |path|
        next unless File.basename(path) == ".git"

        candidate = File.dirname(path)
        repositories << File.realpath(candidate) if git_root?(candidate)
        Find.prune if File.directory?(path)
      rescue Errno::EACCES, Errno::ENOENT, Errno::ELOOP
        Find.prune if File.directory?(path)
      end
      repositories.uniq.reject { |path| path == File.realpath(config.root) }.sort
    end

    def git_root?(path)
      output, _error, status = Support.capture("git", "rev-parse", "--show-toplevel", chdir: path)
      status.zero? && File.realpath(output) == File.realpath(path)
    rescue Errno::ENOENT, Errno::ELOOP
      false
    end

    def inspect_repository(path, discovery_root)
      relative = Support.relative_path(discovery_root, path)
      identifier = repository_identifier(path)
      branch, _branch_error, branch_status = git(path, "symbolic-ref", "--quiet", "--short", "HEAD")
      sha, sha_error, sha_status = git(path, "rev-parse", "HEAD")
      changes, changes_error, changes_status = git(path, "status", "--porcelain=v1", "--untracked-files=normal")
      origin, _origin_error, origin_status = git(path, "remote", "get-url", "origin")
      remote = origin_status.zero? && Support.present?(origin) ?
        remote_identity(origin, identifier) :
        local_identity(identifier)
      workload = classify_workload(path, relative)
      default_branch, branch_source, default_branch_verified = resolve_default_branch(
        path,
        branch,
        branch_status,
        origin_status.zero? && Support.present?(origin)
      )
      placement = managed_path?(path) ? "managed" : "attached"
      declaration = declaration_for(
        id: identifier,
        path: path,
        placement: placement,
        workload: workload.fetch("name"),
        profile: workload.fetch("profile"),
        remote: remote,
        default_branch: default_branch,
        default_branch_verified: default_branch_verified
      )
      blockers = []
      warnings = []
      blockers << "HEAD is detached; choose a branch before connecting" unless branch_status.zero?
      blockers << "repository has no verifiable HEAD: #{sha_error}" unless sha_status.zero? && Support.present?(sha)
      blockers << "git status failed: #{changes_error}" unless changes_status.zero?
      blockers << remote.fetch("blocker") if remote["blocker"]
      blockers << "default branch could not be resolved from local Git state" unless Support.present?(default_branch)
      unless default_branch_verified
        warnings << "provider default branch is not available in local origin/HEAD; the checked-out branch is recorded as an unverified fallback"
      end
      blockers.concat(existing_state_blockers(identifier, path, declaration))
      blockers.concat(reference_bridge_blockers(identifier, path))
      project = config.project_verification(logical_key: identifier, expected_path: path)
      bridge_state = existing_bridge_state(identifier, blockers)
      {
        "repository_id" => identifier,
        "path" => path,
        "relative_to_root" => relative,
        "placement" => placement,
        "provider" => remote.fetch("provider"),
        "locator" => remote.fetch("locator"),
        "owner" => remote.fetch("owner"),
        "branch" => branch_status.zero? ? branch : nil,
        "verified_default_branch" => default_branch,
        "default_branch_verified" => default_branch_verified,
        "default_branch_source" => branch_source,
        "sha" => sha_status.zero? ? sha : nil,
        "clean" => changes_status.zero? ? changes.empty? : nil,
        "changes" => changes_status.zero? && !changes.empty? ? changes.lines.map(&:rstrip) : [],
        "workload" => workload,
        "instructions" => instruction_files(path),
        "bridge" => {
          "mode" => "reference",
          "profile" => workload.fetch("profile"),
          "status" => bridge_state
        },
        "project_registration" => project,
        "proposed_declaration" => declaration,
        "warnings" => warnings,
        "blockers" => blockers.compact.uniq,
        "status" => blockers.empty? ? (bridge_state == "valid" ? "noop" : "ready") : "blocked"
      }
    rescue Error => e
      {
        "repository_id" => identifier || repository_identifier(path),
        "path" => path,
        "relative_to_root" => relative,
        "blockers" => [e.message],
        "status" => "blocked"
      }
    end

    def repository_identifier(path)
      value = File.basename(path).downcase.gsub(/[^a-z0-9._-]+/, "-")
      value = value.gsub(/\A[^a-z0-9]+|[^a-z0-9]+\z/, "")
      raise ValidationError, "repository name cannot produce a stable identifier: #{File.basename(path)}" if value.empty?

      Support.validate_identifier!(value, label: "discovered repository ID")
      value
    end

    def mark_identifier_collisions!(repositories)
      repositories.group_by { |item| item["repository_id"] }.each_value do |items|
        next if items.length == 1

        paths = items.map { |item| item["path"] }.join(", ")
        items.each do |item|
          item["blockers"] << "duplicate repository ID requires an explicit declaration: #{paths}"
          item["blockers"].uniq!
          item["status"] = "blocked"
        end
      end
    end

    def remote_identity(origin, identifier)
      if origin.match?(%r{\Ahttps?://})
        uri = URI.parse(origin)
        if uri.user || uri.password
          return local_identity(identifier).merge(
            "blocker" => "origin contains embedded credentials and was not recorded"
          )
        end
        host = uri.host.to_s.downcase
        path = uri.path.to_s.sub(%r{\A/}, "").sub(/\.git\z/, "")
        return hosted_identity(host, path, canonical_url: origin)
      end
      if origin.match?(%r{\Assh://})
        uri = URI.parse(origin)
        return remote_blocker("origin SSH URL is invalid", identifier) if uri.password

        host = uri.host.to_s.downcase
        path = uri.path.to_s.sub(%r{\A/}, "").sub(/\.git\z/, "")
        return hosted_identity(host, path, canonical_url: origin)
      end
      if (match = origin.match(/\A(?:[A-Za-z0-9._-]+@)?([^:\/]+):([^\/].+)\z/))
        return hosted_identity(match[1].downcase, match[2].sub(/\.git\z/, ""), canonical_url: origin)
      end
      if origin.match?(%r{\Afile://})
        uri = URI.parse(origin)
        return remote_blocker("origin contains embedded credentials and was not recorded", identifier) if uri.user || uri.password

        return local_identity(identifier)
      end
      if origin.match?(%r{\Agit://})
        uri = URI.parse(origin)
        return remote_blocker("origin contains embedded credentials and was not recorded", identifier) if uri.user || uri.password

        path = uri.path.to_s.sub(/\.git\z/, "")
        owner = File.basename(File.dirname(path))
        return {
          "provider" => "git",
          "locator" => origin,
          "owner" => Support.present?(owner) ? owner : "local",
          "remote_url" => origin
        }
      end
      return local_identity(identifier) if Pathname.new(origin).absolute?

      remote_blocker("origin URL format is unsupported", identifier)
    rescue URI::InvalidURIError
      remote_blocker("origin URL is invalid", identifier)
    end

    def hosted_identity(host, locator, canonical_url:)
      provider = config.providers.find do |_name, item|
        %w[github gitlab bitbucket].include?(item["kind"]) &&
          item.fetch("host", "").downcase == host
      end
      unless provider
        owner = locator.split("/")[0...-1].join("/")
        return {
          "provider" => "git",
          "locator" => canonical_url,
          "owner" => Support.present?(owner) ? owner : host,
          "remote_url" => canonical_url
        }
      end
      unless HOSTED_LOCATOR.match?(locator)
        return remote_blocker("hosted origin locator is invalid", File.basename(locator))
      end
      {
        "provider" => provider.first,
        "locator" => locator,
        "owner" => locator.split("/")[0...-1].join("/"),
        "remote_url" => canonical_url
      }
    end

    def local_identity(identifier)
      {
        "provider" => "existing-local",
        "locator" => identifier,
        "owner" => "local",
        "remote_url" => nil
      }
    end

    def remote_blocker(message, identifier)
      local_identity(identifier).merge("blocker" => message)
    end

    def resolve_default_branch(path, current_branch, branch_status, has_origin)
      remote_head, _error, status = git(
        path,
        "symbolic-ref",
        "--quiet",
        "--short",
        "refs/remotes/origin/HEAD"
      )
      if status.zero? && remote_head.start_with?("origin/")
        return [remote_head.delete_prefix("origin/"), "origin_head", true]
      end
      if branch_status.zero?
        source = has_origin ? "checked_out_branch_fallback" : "local_checked_out_branch"
        return [current_branch, source, !has_origin]
      end

      [nil, "unresolved", false]
    end

    def classify_workload(path, relative)
      tokens = relative.downcase.split(File::SEPARATOR)
      root_files = Dir.children(path).map(&:downcase)
      name = if root_files.include?("chart.yaml") || (tokens & %w[chart charts helm]).any?
               "charts"
             elsif root_files.any? { |item| item.end_with?(".tf") } ||
                   (tokens & %w[environment environments infra infrastructure platform terraform kubernetes k8s clusters]).any?
               "environments"
             elsif (tokens & %w[patch patching cve vulnerabilities]).any?
               "patching"
             elsif (tokens & %w[compliance controls rmf ato]).any?
               "compliance"
             elsif (tokens & %w[research]).any?
               "research"
             elsif (tokens & %w[operations ops]).any?
               "operations"
             else
               "development"
             end
      {
        "name" => name,
        "profile" => WORKLOAD_PROFILES.fetch(name, "application"),
        "source" => name == "development" ? "safe_default" : "local_path_or_root_markers"
      }
    rescue Errno::EACCES, Errno::ENOENT
      { "name" => "development", "profile" => "application", "source" => "safe_default" }
    end

    def managed_path?(path)
      Support.contained_path(config.root, path, label: "discovered repository path")
      true
    rescue ConfigurationError
      false
    end

    def declaration_for(id:, path:, placement:, workload:, profile:, remote:, default_branch:,
                        default_branch_verified:)
      value = {
        "id" => id,
        "placement" => placement,
        "workload" => workload,
        "provider" => remote.fetch("provider"),
        "locator" => remote.fetch("locator"),
        "owner" => remote.fetch("owner"),
        "default_branch" => default_branch,
        "default_branch_verified" => default_branch_verified,
        "bridge" => {
          "profile" => profile,
          "mode" => "reference"
        },
        "codex_project" => {
          "expectation" => "saved_exact_path",
          "logical_key" => id
        }
      }
      value["local_path"] = Support.relative_path(config.root, path) if placement == "managed"
      value
    end

    def existing_state_blockers(identifier, path, declaration)
      blockers = []
      existing_declaration = config.repository_declarations.find { |item| item["id"] == identifier }
      if existing_declaration && existing_declaration != declaration
        blockers << "existing portable declaration differs from discovery"
      end
      repository = config.repository(identifier)
      if repository
        begin
          registered = config.repository_path(repository)
          blockers << "existing local registration points to a different path" unless File.realpath(registered) == File.realpath(path)
        rescue ConfigurationError, Errno::ENOENT, Errno::ELOOP
          blockers << "existing local registration cannot be resolved safely"
        end
      end
      blockers
    end

    def reference_bridge_blockers(identifier, path)
      repository = config.repository(identifier)
      if repository
        plan = BridgeStore.new(config).plan(
          repository_id: identifier,
          mode: "reference",
          profile: repository["bridge_profile"] || "application"
        )
        return Array(plan["blockers"]) if plan["desired_state"] == "valid" || plan["blockers"].any?
      end
      target = File.join(path, "AGENTS.override.md")
      return [] unless File.exist?(target) || File.symlink?(target)

      ["refusing to overwrite unmanaged bridge target: AGENTS.override.md"]
    end

    def existing_bridge_state(identifier, blockers)
      return "blocked" if blockers.any?
      return "not_installed" unless config.repository(identifier)

      repository = config.repository(identifier)
      plan = BridgeStore.new(config).plan(
        repository_id: identifier,
        mode: "reference",
        profile: repository["bridge_profile"] || "application"
      )
      plan["desired_state"]
    rescue Error
      "not_installed"
    end

    def instruction_files(path)
      Dir.glob(File.join(path, "**", "{AGENTS.md,AGENTS.override.md}"), File::FNM_DOTMATCH)
         .reject { |item| item.split(File::SEPARATOR).include?(".git") }
         .sort
         .map { |item| Support.relative_path(path, item) }
    end

    def write_connection_state(items)
      declarations = Support.load_data(config.repository_declarations_path)
      entries = Array(declarations["repositories"])
      registry = File.file?(config.local_registry_path) ? Support.load_data(config.local_registry_path) : {
        "api_version" => "flightdeck.dev/v1alpha1",
        "kind" => "LocalRepositoryRegistry",
        "repositories" => {}
      }
      registry["repositories"] ||= {}
      items.each do |item|
        id = item.fetch("repository_id")
        entries << item.fetch("proposed_declaration") unless entries.any? { |entry| entry["id"] == id }
        registry["repositories"][id] ||= local_record(item)
      end
      declarations["repositories"] = entries.sort_by { |item| item.fetch("id") }
      registry["repositories"] = registry.fetch("repositories").sort.to_h
      write_yaml_if_changed(config.repository_declarations_path, declarations)
      write_yaml_if_changed(config.local_registry_path, registry)
      refreshed = Config.new(root: config.root)
      refreshed.repository_declarations
      refreshed.repositories.each { |repository| refreshed.repository_path(repository) }
    end

    def write_yaml_if_changed(path, value)
      content = YAML.dump(value)
      return if File.file?(path) && File.read(path, encoding: "UTF-8") == content

      Support.atomic_write(path, content)
    end

    def install_selected(refreshed, items, failure_policy)
      receipts = []
      stopped = false
      items.each do |item|
        if stopped
          receipts << selected_receipt(
            refreshed,
            item,
            status: "not_attempted",
            record: nil,
            errors: ["stopped after earlier repository failure"]
          )
          next
        end
        begin
          record = BridgeStore.new(refreshed).install(
            repository_id: item.fetch("repository_id"),
            mode: "reference",
            profile: item.dig("bridge", "profile")
          )
          receipts << selected_receipt(
            refreshed,
            item,
            status: record.fetch("action"),
            record: record,
            errors: []
          )
        rescue Error => e
          receipts << selected_receipt(
            refreshed,
            item,
            status: "error",
            record: nil,
            errors: [e.message]
          )
        end
        stopped = failure_policy == "stop" && receipts.last.fetch("errors").any?
      end
      result = {
        "schema_version" => "flightdeck.bridge-setup-receipt/v1",
        "schema" => "hub/schemas/bridge-setup-receipt.schema.json",
        "generated_at" => Time.now.utc.iso8601,
        "failure_policy" => failure_policy,
        "declarations" => Support.relative_path(refreshed.root, refreshed.repository_declarations_path),
        "receipt_path" => refreshed.workspace.fetch("bridge_setup_receipt", "hub/state/bridge-repos.json"),
        "ok" => receipts.all? { |item| item.fetch("errors").empty? },
        "complete" => receipts.all? { |item| item["complete"] },
        "repositories" => receipts,
        "summary" => {
          "total" => receipts.length,
          "installed" => receipts.count { |item| item.dig("bridge", "status") == "installed" },
          "noop" => receipts.count { |item| item.dig("bridge", "status") == "noop" },
          "blocked" => receipts.count { |item| %w[blocked error not_attempted].include?(item.dig("bridge", "status")) },
          "project_verified" => receipts.count { |item| item.dig("project_registration", "status") == "verified" },
          "project_pending" => receipts.count { |item| item.dig("project_registration", "status") != "verified" }
        }
      }
      Support.atomic_write(
        refreshed.bridge_setup_receipt_path,
        "#{JSON.pretty_generate(result)}\n"
      )
      result
    end

    def selected_receipt(refreshed, item, status:, record:, errors:)
      project = refreshed.project_verification(
        logical_key: item.fetch("repository_id"),
        expected_path: item.fetch("path")
      )
      {
        "repository_id" => item.fetch("repository_id"),
        "git_root" => item.fetch("path"),
        "checkout" => {
          "path" => item.fetch("path"),
          "exists" => true,
          "registered" => true,
          "git_root_verified" => true,
          "branch" => item["branch"],
          "sha" => item["sha"],
          "clean" => item["clean"],
          "changes" => item["changes"]
        },
        "bridge" => {
          "status" => status,
          "mode" => "reference",
          "profile" => item.dig("bridge", "profile"),
          "record" => record
        },
        "project_registration" => project,
        "errors" => errors,
        "complete" => errors.empty? &&
          %w[installed noop].include?(status) &&
          project["status"] == "verified"
      }
    end

    def local_record(item)
      {
        "display_name" => item.fetch("repository_id").tr("-_", " ").split.map(&:capitalize).join(" "),
        "local_path" => item["placement"] == "attached" ?
          item.fetch("path") :
          Support.relative_path(config.root, item.fetch("path")),
        "placement" => item.fetch("placement"),
        "provider" => item.fetch("provider"),
        "locator" => item.fetch("locator"),
        "owner" => item.fetch("owner"),
        "default_branch" => item.fetch("verified_default_branch"),
        "default_branch_verified" => item.fetch("default_branch_verified"),
        "default_branch_source" => item.fetch("default_branch_source"),
        "kind" => "repository",
        "workload_ids" => [item.dig("workload", "name")],
        "roles" => ["source"],
        "bridge_profile" => item.dig("bridge", "profile"),
        "bridge_mode" => "reference",
        "instructions" => {
          "repo_policy_path" => "AGENTS.md",
          "hub_bridge_required" => true
        },
        "codex_project_key" => item.fetch("repository_id"),
        "codex_project_expectation" => "saved_exact_path"
      }.compact
    end

    def connection_result(plan_value, bridge_receipt:, changed:, stopped:)
      bridge_items = bridge_receipt ? bridge_receipt.fetch("repositories").to_h { |item| [item["repository_id"], item] } : {}
      repositories = plan_value.fetch("repositories").map do |item|
        bridge = bridge_items[item["repository_id"]]
        if item.fetch("blockers").any?
          item.merge("connection_status" => "blocked", "bridge_receipt" => nil)
        elsif bridge
          item.merge(
            "connection_status" => bridge.fetch("errors").empty? ? "connected" : "blocked",
            "bridge_receipt" => bridge
          )
        else
          item.merge("connection_status" => stopped ? "not_attempted" : "connected", "bridge_receipt" => nil)
        end
      end
      blockers = repositories.count { |item| item["connection_status"] == "blocked" }
      project_pending = repositories.count do |item|
        item["connection_status"] == "connected" &&
          item.dig("bridge_receipt", "project_registration", "status") != "verified"
      end
      project_verified = repositories.count do |item|
        item["connection_status"] == "connected" &&
          item.dig("bridge_receipt", "project_registration", "status") == "verified"
      end
      no_repositories = repositories.empty?
      {
        "schema_version" => "flightdeck.setup-receipt/v1",
        "repositories_root" => plan_value.fetch("repositories_root"),
        "failure_policy" => plan_value.fetch("failure_policy"),
        "ok" => blockers.zero? && (!bridge_receipt || bridge_receipt["ok"]),
        "complete" => !no_repositories && blockers.zero? && project_pending.zero? && !stopped,
        "status" => if no_repositories
                      "no_repositories_found"
                    elsif stopped
                      "stopped_before_changes"
                    elsif blockers.positive?
                      "connected_with_blockers"
                    elsif project_pending.positive?
                      "connected_projects_pending"
                    else
                      "ready"
                    end,
        "changed" => changed,
        "tracked_repository_files_changed" => false,
        "repositories" => repositories,
        "summary" => {
          "discovered" => repositories.length,
          "connected" => repositories.count { |item| item["connection_status"] == "connected" },
          "blocked" => blockers,
          "project_verified" => project_verified,
          "project_pending" => project_pending
        },
        "project_registration" => {
          "required_paths" => repositories.select { |item| item["connection_status"] == "connected" }
                                          .map { |item| item.fetch("path") },
          "verification" => "refreshed_live_project_list_exact_path"
        },
        "bridge_receipt" => bridge_receipt,
        "next" => if no_repositories
                    "Choose an absolute folder that contains the Git repositories to connect."
                  elsif blockers.positive?
                    "Resolve only the listed repository conflicts, then run setup connect again."
                  else
                    "Register each required path as a Codex project, verify the exact path, and run Doctor."
                  end
      }
    end

    def summary_for(repositories)
      {
        "discovered" => repositories.length,
        "ready" => repositories.count { |item| item["status"] == "ready" },
        "noop" => repositories.count { |item| item["status"] == "noop" },
        "blocked" => repositories.count { |item| item["status"] == "blocked" },
        "dirty_preserved" => repositories.count { |item| item["clean"] == false },
        "default_branch_pending" => repositories.count { |item| item["default_branch_verified"] == false },
        "project_verified" => repositories.count { |item| item.dig("project_registration", "status") == "verified" },
        "project_pending" => repositories.count { |item| item.dig("project_registration", "status") != "verified" }
      }
    end

    def git(path, *arguments)
      Support.capture("git", *arguments, chdir: path)
    end
  end
end
