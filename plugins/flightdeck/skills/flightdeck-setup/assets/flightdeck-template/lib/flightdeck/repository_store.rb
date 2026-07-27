# frozen_string_literal: true

require "uri"
require_relative "bridge_store"

module Flightdeck
  class RepositoryStore
    LOCATOR = /\A[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)+\z/
    HOST = /\A[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?\z/
    SCP_URL = /\Agit@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?:[A-Za-z0-9_.\/-]+(?:\.git)?\z/

    attr_reader :config

    def initialize(config)
      @config = config
    end

    def onboard(workload_name:, provider_name:, locator:, repository_id:, name: nil, url: nil,
                owner: nil, default_branch: nil, bridge_mode: "reference", bridge_profile: nil,
                acknowledge_repo_native: false)
      Support.validate_identifier!(repository_id, label: "repository ID")
      raise ValidationError, "repository already registered: #{repository_id}" if config.repository(repository_id)

      workload = config.workload(workload_name)
      raise ValidationError, "unknown workload: #{workload_name}" unless workload.is_a?(Hash)
      provider = config.provider(provider_name)
      raise ValidationError, "unknown provider: #{provider_name}" unless provider.is_a?(Hash)
      if provider["kind"] == "remote_validation"
        raise ValidationError, "remote-validation contexts must be configured and verified as Codex projects; they are not cloned"
      end

      local_name = name || locator.to_s.split("/").last.sub(/\.git\z/, "")
      Support.validate_directory!(local_name, label: "local repository name")
      root_value = workload.dig("dynamic_repositories", "clone_root") || workload.fetch("path")
      checkout_root = config.root_path(root_value, label: "checkout root")
      target = Support.contained_path(checkout_root, local_name, label: "repository target")
      FileUtils.mkdir_p(checkout_root)

      provider_kind = provider.fetch("kind")
      if provider_kind != "existing_local"
        raise UsageError, "--default-branch is required for cloned repositories" unless Support.present?(default_branch)
        validate_branch!(default_branch)
      end
      resolved_owner = resolve_owner(provider_kind, locator, owner)
      remote_url = resolve_url(provider, locator, url)
      if provider.fetch("kind") == "existing_local"
        target = existing_local_target(locator)
      else
        raise ValidationError, "target already exists: #{target}" if File.exist?(target)
        _output, error, status = Support.capture(
          "git", "clone", "--branch", default_branch, "--single-branch", "--",
          remote_url, target, chdir: checkout_root, timeout: 300
        )
        raise ValidationError, "clone failed: #{error}" unless status.zero?
      end

      verification = verify_repository(target, require_clean: provider.fetch("kind") != "existing_local")
      if default_branch && verification["branch"] != default_branch
        raise ValidationError, "verified branch #{verification['branch'].inspect} does not match requested default branch #{default_branch.inspect}"
      end
      placement = begin
        Support.contained_path(config.root, target, label: "repository target")
        "managed"
      rescue ConfigurationError
        "attached"
      end
      local_path = placement == "attached" ? File.realpath(target) : Support.relative_path(config.root, target)
      record = {
        "display_name" => local_name.tr("-_", " ").split.map(&:capitalize).join(" "),
        "local_path" => local_path,
        "placement" => placement,
        "remote_url" => remote_url,
        "provider" => provider_name,
        "locator" => locator,
        "owner" => resolved_owner,
        "default_branch" => default_branch || verification["branch"],
        "default_branch_verified" => true,
        "kind" => "repository",
        "workload_ids" => [workload_name],
        "roles" => ["source"],
        "bridge_profile" => bridge_profile || default_profile(workload_name),
        "bridge_mode" => bridge_mode,
        "instructions" => {
          "repo_policy_path" => "AGENTS.md",
          "hub_bridge_required" => true
        },
        "codex_project_key" => repository_id,
        "codex_project_expectation" => "saved_exact_path"
      }
      previous_registry = File.file?(config.local_registry_path) ? File.read(config.local_registry_path, encoding: "UTF-8") : nil
      update_registry(repository_id, record)
      begin
        bridge = BridgeStore.new(Config.new(root: config.root)).install(
          repository_id: repository_id,
          mode: bridge_mode,
          profile: record["bridge_profile"],
          acknowledge_repo_native: acknowledge_repo_native
        )
      rescue StandardError
        if previous_registry
          Support.atomic_write(config.local_registry_path, previous_registry)
        else
          FileUtils.rm_f(config.local_registry_path)
        end
        raise
      end
      {
        "repository_id" => repository_id,
        "target" => target,
        "provider" => provider_name,
        "remote_url" => remote_url,
        "verification" => verification,
        "bridge" => bridge,
        "project_registration" => {
          "logical_key" => repository_id,
          "runtime_project_id" => nil,
          "required" => true,
          "verified" => false,
          "next" => "Register the exact target as a Codex project, refresh the live project list, and verify it before dispatch."
        }
      }
    end

    private

    def resolve_url(provider, locator, explicit_url)
      kind = provider.fetch("kind")
      value = explicit_url.to_s if Support.present?(explicit_url)
      value = case kind
              when "github" then value || hosted_url(provider.fetch("host", "github.com"), locator)
              when "gitlab" then value || hosted_url(provider.fetch("host", "gitlab.com"), locator)
              when "bitbucket" then value || hosted_url(provider.fetch("host", "bitbucket.org"), locator)
              when "git" then value || locator.to_s
              when "existing_local" then ""
              else raise ValidationError, "provider #{kind} cannot onboard a local checkout"
              end
      reject_embedded_credentials!(value)
      value
    end

    def hosted_url(host, locator)
      raise UsageError, "repository locator must use namespace/name form" unless LOCATOR.match?(locator.to_s)
      raise ValidationError, "provider host is invalid" unless HOST.match?(host.to_s)

      "https://#{host}/#{locator}.git"
    end

    def resolve_owner(kind, locator, explicit)
      value = explicit.to_s.strip if Support.present?(explicit)
      if !Support.present?(value) && %w[github gitlab bitbucket].include?(kind)
        raise UsageError, "repository locator must use namespace/name form" unless LOCATOR.match?(locator.to_s)

        value = locator.to_s.split("/")[0...-1].join("/")
      end
      value = "local" if kind == "existing_local" && !Support.present?(value)
      raise UsageError, "--owner is required for generic Git repositories" unless Support.present?(value)

      value
    end

    def validate_branch!(value)
      _output, error, status = Support.capture("git", "check-ref-format", "--branch", value.to_s, chdir: config.root)
      raise UsageError, "invalid default branch: #{error}" unless status.zero?
    end

    def reject_embedded_credentials!(url)
      return if url.empty?
      if url.start_with?("git@")
        raise ValidationError, "invalid SCP-style Git URL" unless SCP_URL.match?(url)

        return
      end

      uri = URI.parse(url)
      raise ValidationError, "remote URL must not contain embedded credentials" if uri.user || uri.password
      raise ValidationError, "unsupported remote URL scheme" unless %w[https ssh git file].include?(uri.scheme)
    rescue URI::InvalidURIError => e
      raise ValidationError, "invalid remote URL: #{e.message}"
    end

    def existing_local_target(locator)
      expanded = File.expand_path(locator.to_s)
      raise ValidationError, "existing-local path must be an absolute directory" unless Pathname.new(expanded).absolute? && Dir.exist?(expanded)

      File.realpath(expanded)
    rescue Errno::ENOENT, Errno::ELOOP
      raise ValidationError, "existing-local path cannot be resolved safely"
    end

    def verify_repository(path, require_clean:)
      root, error, status = Support.capture("git", "rev-parse", "--show-toplevel", chdir: path)
      raise ValidationError, "cloned path is not a Git repository: #{error}" unless status.zero?
      raise ValidationError, "Git root does not match target" unless File.realpath(root) == File.realpath(path)

      branch, _branch_error, branch_status = Support.capture("git", "symbolic-ref", "--quiet", "--short", "HEAD", chdir: path)
      sha, sha_error, sha_status = Support.capture("git", "rev-parse", "HEAD", chdir: path)
      raise ValidationError, "repository has no verifiable HEAD: #{sha_error}" unless sha_status.zero? && Support.present?(sha)
      remote, _remote_error, remote_status = Support.capture("git", "remote", "get-url", "origin", chdir: path)
      dirty, dirty_error, dirty_status = Support.capture("git", "status", "--porcelain=v1", chdir: path)
      raise ValidationError, "git status failed: #{dirty_error}" unless dirty_status.zero?
      raise ValidationError, "new checkout is unexpectedly dirty" if require_clean && !dirty.empty?
      raise ValidationError, "new checkout has no origin remote" if require_clean && (!remote_status.zero? || !Support.present?(remote))

      {
        "branch" => branch_status.zero? ? branch : nil,
        "detached" => !branch_status.zero?,
        "sha" => sha,
        "origin" => remote_status.zero? ? remote : nil,
        "clean" => dirty.empty?,
        "changes" => dirty.empty? ? [] : dirty.lines.map(&:rstrip)
      }
    end

    def default_profile(workload)
      %w[charts patching environments].include?(workload) ? workload : "application"
    end

    def update_registry(repository_id, record)
      value = File.file?(config.local_registry_path) ? Support.load_data(config.local_registry_path) : {
        "api_version" => "flightdeck.dev/v1alpha1",
        "kind" => "LocalRepositoryRegistry",
        "repositories" => {}
      }
      value["repositories"] ||= {}
      raise ValidationError, "repository already registered: #{repository_id}" if value["repositories"].key?(repository_id)

      value["repositories"][repository_id] = record
      Support.atomic_yaml(config.local_registry_path, value)
    end
  end
end
