# frozen_string_literal: true

require "digest"
require_relative "config"

module Flightdeck
  class BridgeStore
    MODES = %w[reference materialized repo-native].freeze

    attr_reader :config

    def initialize(config)
      @config = config
    end

    def plan(repository_id:, mode:, profile: nil)
      mode = mode.to_s
      raise UsageError, "bridge mode must be one of: #{MODES.join(', ')}" unless MODES.include?(mode)

      repository = config.repository(repository_id)
      raise ValidationError, "unknown repository: #{repository_id}" unless repository
      root = repository_root(repository)
      profile ||= repository["bridge_profile"] || repository["workload"] || "application"
      definition = profile_definition(profile)
      targets = case mode
                when "reference" then ["AGENTS.override.md"]
                when "materialized"
                  [
                    ".flightdeck/bridge/AGENTS.md",
                    "AGENTS.override.md",
                    *Array(definition["required_docs"]).map { |path| File.join(".flightdeck/bridge", path) }
                  ]
                when "repo-native" then ["AGENTS.md"]
                end
      record = record_for(repository_id)
      record_valid, record_errors = record_integrity(
        record,
        repository_root: root,
        mode: mode,
        profile: profile
      )
      blockers = []
      desired_state = "not_installed"
      if record
        if record_valid
          desired_state = "valid"
        else
          desired_state = "drift"
          blockers.concat(record_errors.map { |message| "record_drift: #{message}" })
        end
      elsif mode == "repo-native"
        agents = File.join(root, "AGENTS.md")
        blockers << "repo-native mode requires existing AGENTS.md" unless File.file?(agents)
        blockers << "repo-native mode requires tracked AGENTS.md" if File.file?(agents) && !tracked?(root, "AGENTS.md")
        marker = "<!-- flightdeck-bridge:#{manifest.fetch('bridge_version')} -->"
        if File.file?(agents) && File.read(agents, encoding: "UTF-8").include?(marker)
          blockers << "unmanaged repo-native bridge marker already exists"
        end
      else
        targets.select { |path| File.exist?(File.join(root, path)) }.each do |path|
          blockers << "refusing to overwrite unmanaged bridge target: #{path}"
        end
      end
      {
        "read_only" => true,
        "repository_id" => repository_id,
        "repository_root" => root,
        "mode" => mode,
        "profile" => profile,
        "version" => manifest.fetch("bridge_version"),
        "template" => definition.fetch("template"),
        "targets" => targets,
        "existing_targets" => targets.select { |path| File.exist?(File.join(root, path)) },
        "agents_files" => instruction_files(root),
        "desired_state" => desired_state,
        "blockers" => blockers,
        "idempotent" => desired_state == "valid",
        "overwrite_policy" => "refuse",
        "records_to" => Support.relative_path(config.root, config.bridge_registry_path)
      }
    end

    def install(repository_id:, mode:, profile: nil, acknowledge_repo_native: false)
      plan_value = plan(repository_id: repository_id, mode: mode, profile: profile)
      if mode == "repo-native" && !acknowledge_repo_native
        raise UsageError, "--acknowledge-repo-native is required"
      end
      unless plan_value.fetch("blockers").empty?
        raise ValidationError, plan_value.fetch("blockers").join("; ")
      end
      if plan_value["desired_state"] == "valid"
        return record_for(repository_id).merge(
          "action" => "noop",
          "verified" => true
        )
      end

      root = plan_value.fetch("repository_root")
      artifacts = []
      target = case mode
               when "reference"
                 template = render_template(plan_value.fetch("template"), root, mode: mode)
                 write_new(File.join(root, "AGENTS.override.md"), template)
                 ignore_locally(root, "/AGENTS.override.md")
                 File.join(root, "AGENTS.override.md")
               when "materialized"
                 policy = File.join(root, ".flightdeck", "bridge", "AGENTS.md")
                 local_root = File.dirname(policy)
                 required_docs = Array(profile_definition(plan_value.fetch("profile"))["required_docs"])
                 copies = required_docs.map do |relative|
                   source = config.root_path(relative, label: "bridge source document")
                   raise ValidationError, "bridge source document does not exist: #{relative}" unless File.file?(source)

                   [source, Support.contained_path(local_root, relative, label: "materialized bridge document")]
                 end
                 override_path = File.join(root, "AGENTS.override.md")
                 ([policy, override_path] + copies.map(&:last)).each do |path|
                   raise ValidationError, "refusing to overwrite existing bridge target: #{path}" if File.exist?(path)
                 end
                 template = render_template(
                   plan_value.fetch("template"),
                   ".",
                   mode: mode,
                   hub_root: ".flightdeck/bridge"
                 )
                 write_new(policy, template)
                 override = <<~MARKDOWN
                   # Flightdeck materialized bridge

                   Read `./AGENTS.md` completely, then read
                   `./.flightdeck/bridge/AGENTS.md`. Repository rules own commands,
                   tests, and layout. The stricter security and authorization rule wins.
                 MARKDOWN
                 write_new(override_path, override)
                 copies.each do |source, destination|
                   write_new(destination, File.read(source, encoding: "UTF-8"))
                 end
                 ignore_locally(root, "/AGENTS.override.md")
                 ignore_locally(root, "/.flightdeck/")
                 artifacts.concat([override_path, *copies.map(&:last)])
                 policy
               when "repo-native"
                 agents = File.join(root, "AGENTS.md")
                 raise ValidationError, "repo-native mode requires existing AGENTS.md" unless File.file?(agents)
                 _tracked_output, _tracked_error, tracked_status = Support.capture(
                   "git", "ls-files", "--error-unmatch", "--", "AGENTS.md", chdir: root
                 )
                 raise ValidationError, "repo-native mode requires tracked AGENTS.md" unless tracked_status.zero?
                 existing = File.read(agents, encoding: "UTF-8")
                 marker = "<!-- flightdeck-bridge:#{plan_value.fetch('version')} -->"
                 raise ValidationError, "repo-native bridge marker already exists" if existing.include?(marker)

                 template = repo_native_policy(
                   profile: plan_value.fetch("profile"),
                   version: plan_value.fetch("version")
                 )
                 permissions = File.stat(agents).mode & 0o777
                 Support.atomic_write(agents, "#{existing.rstrip}\n\n#{marker}\n#{template}\n")
                 File.chmod(permissions, agents)
                 agents
               end
      artifacts.unshift(target)

      record = {
        "repository_id" => repository_id,
        "repository_root" => root,
        "mode" => mode,
        "profile" => plan_value.fetch("profile"),
        "version" => plan_value.fetch("version"),
        "portable" => mode != "reference",
        "target" => Support.relative_path(root, target),
        "sha256" => Digest::SHA256.file(target).hexdigest,
        "artifacts" => artifacts.uniq.map do |path|
          {
            "path" => Support.relative_path(root, path),
            "sha256" => Digest::SHA256.file(path).hexdigest
          }
        end.sort_by { |item| item["path"] },
        "hub_root" => config.root,
        "installed_at" => Time.now.utc.iso8601
      }
      update_registry(record)
      record.merge("action" => "installed", "verified" => true)
    end

    def records
      return [] unless File.file?(config.bridge_registry_path)

      value = Support.load_data(config.bridge_registry_path)
      Array(value["bridges"])
    end

    def record_for(repository_id)
      records.find { |item| item["repository_id"] == repository_id.to_s }
    end

    private

    def manifest
      @manifest ||= Support.load_data(File.join(config.root, "hub", "bridges", "manifest.yaml"))
    end

    def profile_definition(name)
      value = manifest.fetch("profiles", {})[name.to_s]
      raise ValidationError, "unknown bridge profile: #{name}" unless value.is_a?(Hash)

      value
    end

    def repository_root(repository)
      path = config.repository_path(repository)
      raise ValidationError, "repository directory does not exist: #{path}" unless Dir.exist?(path)
      output, error, status = Support.capture("git", "rev-parse", "--show-toplevel", chdir: path)
      raise ValidationError, "repository Git root unavailable: #{error}" unless status.zero?
      raise ValidationError, "registered path is not the Git root" unless File.realpath(output) == File.realpath(path)

      path
    end

    def instruction_files(root)
      Dir.glob(File.join(root, "**", "{AGENTS.md,AGENTS.override.md}"), File::FNM_DOTMATCH)
         .reject { |path| path.split(File::SEPARATOR).include?(".git") }
         .sort
         .map do |path|
        relative = Support.relative_path(root, path)
        {
          "path" => relative,
          "tracked" => tracked?(root, relative),
          "ignored" => ignored?(root, relative)
        }
      end
    end

    def record_integrity(record, repository_root:, mode:, profile:)
      return [false, []] unless record

      errors = []
      errors << "mode differs from declaration" unless record["mode"] == mode
      errors << "profile differs from declaration" unless record["profile"] == profile
      errors << "bridge version is stale" unless record["version"].to_s == manifest.fetch("bridge_version").to_s
      begin
        errors << "repository root differs" unless File.realpath(record.fetch("repository_root")) == File.realpath(repository_root)
        errors << "Hub root differs" unless File.realpath(record.fetch("hub_root")) == File.realpath(config.root)
        target = Support.contained_path(repository_root, record.fetch("target"), label: "bridge target")
        if !File.file?(target)
          errors << "recorded target is missing"
        elsif Digest::SHA256.file(target).hexdigest != record["sha256"]
          errors << "recorded target digest differs"
        end
        Array(record.fetch("artifacts")).each do |artifact|
          path = Support.contained_path(repository_root, artifact.fetch("path"), label: "bridge artifact")
          if !File.file?(path)
            errors << "artifact is missing: #{artifact['path']}"
          elsif Digest::SHA256.file(path).hexdigest != artifact["sha256"]
            errors << "artifact digest differs: #{artifact['path']}"
          end
        end
        if %w[reference materialized].include?(mode)
          errors << "AGENTS.override.md is not Git-locally ignored" unless ignored?(repository_root, "AGENTS.override.md")
          errors << "AGENTS.override.md is tracked" if tracked?(repository_root, "AGENTS.override.md")
        end
        if mode == "materialized" && !ignored?(repository_root, ".flightdeck/bridge/AGENTS.md")
          errors << "materialized bridge pack is not Git-locally ignored"
        end
      rescue KeyError, ConfigurationError, Errno::ENOENT, Errno::ELOOP => e
        errors << e.message
      end
      [errors.empty?, errors]
    end

    def tracked?(root, relative)
      _output, _error, status = Support.capture(
        "git", "ls-files", "--error-unmatch", "--", relative, chdir: root
      )
      status.zero?
    end

    def ignored?(root, relative)
      _output, _error, status = Support.capture(
        "git", "check-ignore", "-q", "--", relative, chdir: root
      )
      status.zero?
    end

    def render_template(relative, repository_root, mode:, hub_root: config.root)
      path = config.root_path(relative, label: "bridge template")
      raise ValidationError, "bridge template does not exist: #{relative}" unless File.file?(path)

      File.read(path, encoding: "UTF-8")
          .gsub("{{HUB_ROOT}}", hub_root)
          .gsub("{{REPOSITORY_ROOT}}", repository_root)
          .gsub("{{BRIDGE_MODE}}", mode)
          .gsub("{{BRIDGE_VERSION}}", manifest.fetch("bridge_version").to_s)
    end

    def repo_native_policy(profile:, version:)
      profile_rule = case profile
                     when "charts"
                       "Render and inspect affected manifests; review identity, RBAC, networking, secrets, storage, images, pod security, upgrades, and rollback."
                     when "patching"
                       "Preserve runtime contracts and require rebuilt-image, scan, digest, SBOM when supported, downstream, and runtime validation evidence."
                     when "environments"
                       "Separate desired state from live observations and use read-only environment inspection by default."
                     else
                       "Validate authorization at the service-side owning boundary and run repository-native focused checks."
                     end
      <<~MARKDOWN
        # Flightdeck portable bridge

        Bridge version: `#{version}`
        Bridge mode: `repo-native`
        Bridge profile: `#{profile}`

        Read this repository's applicable `AGENTS.md` files before acting.
        Repository rules own layout, commands, tests, generated files, and
        implementation mechanics. The stricter security or authorization rule
        wins. Keep implementation in this repository and record branch, SHA,
        dirty state, exact validation inputs, checks, evidence, and residual risk.

        #{profile_rule}

        Do not commit, push, publish, create or update a pull request, deploy,
        mutate a shared environment, submit compliance material, accept risk,
        close a POA&M item, or communicate externally without the applicable
        explicit human authorization.
      MARKDOWN
    end

    def write_new(path, content)
      raise ValidationError, "refusing to overwrite existing bridge target: #{path}" if File.exist?(path)

      Support.atomic_write(path, content)
    end

    def ignore_locally(root, entry)
      output, error, status = Support.capture("git", "rev-parse", "--git-path", "info/exclude", chdir: root)
      raise ValidationError, "cannot resolve Git exclude file: #{error}" unless status.zero?

      path = File.expand_path(output, root)
      existing = File.file?(path) ? File.read(path, encoding: "UTF-8").lines.map(&:chomp) : []
      return if existing.include?(entry)

      Support.atomic_write(path, "#{existing.join("\n")}#{existing.empty? ? '' : "\n"}#{entry}\n")
    end

    def update_registry(record)
      value = File.file?(config.bridge_registry_path) ? Support.load_data(config.bridge_registry_path) : {
        "api_version" => "flightdeck.dev/v1alpha1",
        "kind" => "BridgeRegistry",
        "bridges" => []
      }
      records = Array(value["bridges"]).reject { |item| item["repository_id"] == record["repository_id"] }
      records << record
      value["bridges"] = records.sort_by { |item| item["repository_id"] }
      Support.atomic_yaml(config.bridge_registry_path, value)
    end
  end
end
