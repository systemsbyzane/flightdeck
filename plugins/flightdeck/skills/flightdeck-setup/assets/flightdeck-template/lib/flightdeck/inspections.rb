# frozen_string_literal: true

require "digest"
require_relative "bridge_store"

module Flightdeck
  class GitInspector
    def initialize(root)
      @root = root
    end

    def inspect(repository)
      base = {
        "workload" => repository["workload"],
        "name" => repository["id"],
        "path" => repository["path"],
        "remote_refs_fetched" => false
      }
      path = Support.contained_path(@root, repository.fetch("path"), label: "repository path")
      base["path"] = Support.relative_path(@root, path)
      return base.merge("error" => "checkout directory does not exist") unless Dir.exist?(path)

      root, error, status = git(path, "rev-parse", "--show-toplevel")
      return base.merge("error" => "path is not a Git working tree: #{error}") unless status.zero?
      return base.merge("error" => "registered path is not the Git root") unless File.realpath(root) == File.realpath(path)

      branch, _branch_error, branch_status = git(path, "symbolic-ref", "--quiet", "--short", "HEAD")
      sha, = git(path, "rev-parse", "HEAD")
      changes, changes_error, changes_status = git(path, "status", "--porcelain=v1", "--untracked-files=normal")
      return base.merge("error" => "git status failed: #{changes_error}") unless changes_status.zero?

      upstream, _upstream_error, upstream_status = git(path, "rev-parse", "--abbrev-ref", "@{upstream}")
      ahead = behind = nil
      if upstream_status.zero?
        counts, _counts_error, count_status = git(path, "rev-list", "--left-right", "--count", "HEAD...@{upstream}")
        ahead, behind = counts.split.map(&:to_i) if count_status.zero?
      end

      agents = File.file?(File.join(path, "AGENTS.md"))
      override = File.file?(File.join(path, "AGENTS.override.md"))
      ignored = tracked = false
      if override
        _output, _error, ignored_status = git(path, "check-ignore", "-q", "--", "AGENTS.override.md")
        _tracked_output, _tracked_error, tracked_status = git(path, "ls-files", "--error-unmatch", "--", "AGENTS.override.md")
        ignored = ignored_status.zero?
        tracked = tracked_status.zero?
      end
      base.merge(
        "branch" => branch_status.zero? ? branch : nil,
        "detached" => !branch_status.zero?,
        "sha" => sha,
        "dirty" => !changes.empty?,
        "changes" => changes.empty? ? [] : changes.lines.map(&:rstrip),
        "upstream" => upstream_status.zero? ? upstream : nil,
        "ahead" => ahead,
        "behind" => behind,
        "instructions" => {
          "agents" => agents,
          "override" => override,
          "override_shadows_agents" => agents && override,
          "override_ignored" => ignored,
          "override_tracked" => tracked
        }
      )
    rescue ConfigurationError, StandardError => e
      base.merge("error" => e.message)
    end

    private

    def git(path, *arguments)
      Support.capture("git", *arguments, chdir: path)
    end
  end

  class ComplianceChecker
    DIRECTORIES = %w[
      generated generated-documents evidence evidence-index
      control-assessment control-assessments poam
    ].freeze

    def initialize(root)
      @root = root
    end

    def run
      root = File.join(@root, "compliance")
      return { "pairs" => [], "issues" => [] } unless Dir.exist?(root)

      paths = Dir.glob(File.join(root, "**", "{*.json,*.yaml,*.yml}"), File::FNM_EXTGLOB).select do |path|
        path.split(File::SEPARATOR).any? { |part| DIRECTORIES.include?(part) }
      end
      groups = paths.group_by { |path| File.join(File.dirname(path), File.basename(path, File.extname(path))) }
      pairs = []
      issues = []
      groups.sort.each do |base, files|
        json = files.select { |path| File.extname(path).downcase == ".json" }
        yaml = files.select { |path| %w[.yaml .yml].include?(File.extname(path).downcase) }
        if json.one? && yaml.empty?
          value = parse(json.first, issues)
          unless standalone_json?(value)
            issues << issue("warning", "compliance.orphan_json", base, "JSON sidecar has no YAML peer")
          end
        end
        issues << issue("warning", "compliance.orphan_yaml", base, "YAML sidecar has no JSON peer") if yaml.any? && json.empty?
        issues << issue("error", "compliance.duplicate_yaml", base, "both YAML extensions are present") if yaml.length > 1
        next unless json.one? && yaml.one?

        left = parse(json.first, issues)
        right = parse(yaml.first, issues, aliases: true)
        equivalent = left == right unless left.nil? || right.nil?
        if equivalent == false
          issues << issue("error", "compliance.sidecar_mismatch", base, "JSON and YAML are not semantically equivalent")
        end
        pairs << {
          "base" => relative(base),
          "json" => relative(json.first),
          "yaml" => relative(yaml.first),
          "equivalent" => equivalent
        }
      end
      { "pairs" => pairs, "issues" => issues }
    end

    private

    def parse(path, issues, aliases: false)
      Support.load_data(path, aliases: aliases)
    rescue ValidationError => e
      code = File.extname(path).downcase == ".json" ? "compliance.invalid_json" : "compliance.invalid_yaml"
      issues << issue("error", code, path, e.message)
      nil
    end

    def standalone_json?(value)
      value.is_a?(Hash) && value["bomFormat"] == "CycloneDX"
    end

    def issue(severity, code, path, message)
      { "severity" => severity, "code" => code, "scope" => relative(path), "message" => message }
    end

    def relative(path)
      Support.relative_path(@root, path)
    end
  end

  class HandoffChecker
    TEXT_EXTENSIONS = %w[.md .yaml .yml .json .txt].freeze
    PATTERNS = [
      /\b(?:TBD|TODO|FIXME|CHANGEME|REPLACE_ME)\b/i,
      /\{\{[^}]+\}\}/,
      /^\s*(?:[-*]\s+|[^:]+:\s*)\.\.\.\s*$/,
      /<(?:(?:fill|replace|insert|enter)[^>]*)>/i
    ].freeze

    def initialize(root)
      @root = root
    end

    def run
      handoffs = File.join(@root, "handoffs")
      return [] unless Dir.exist?(handoffs)

      Dir.glob(File.join(handoffs, "**", "*")).sort.filter_map do |path|
        next unless File.file?(path) && TEXT_EXTENSIONS.include?(File.extname(path).downcase)

        matches = []
        File.foreach(path, encoding: "UTF-8").with_index(1) do |line, number|
          if PATTERNS.any? { |pattern| pattern.match?(line) }
            matches << { "line" => number, "text" => line.strip[0, 160] }
          end
        end
        next if matches.empty?

        {
          "severity" => "warning",
          "code" => "handoff.placeholder",
          "scope" => Support.relative_path(@root, path),
          "message" => "handoff contains #{matches.length} placeholder line(s)",
          "details" => matches
        }
      rescue EncodingError, ArgumentError => e
        {
          "severity" => "warning",
          "code" => "handoff.unreadable",
          "scope" => Support.relative_path(@root, path),
          "message" => e.message
        }
      end
    end
  end

  class BridgeChecker
    def initialize(config)
      @config = config
    end

    def run
      store = BridgeStore.new(@config)
      manifest = Support.load_data(File.join(@config.root, "hub", "bridges", "manifest.yaml"))
      store.records.flat_map do |record|
        inspect_record(record, manifest)
      end
    rescue ValidationError, ConfigurationError => e
      [issue("error", "bridge.registry_invalid", "hub/state/bridges.yaml", e.message)]
    end

    private

    def inspect_record(record, manifest)
      id = record["repository_id"] || "unknown"
      issues = []
      unless BridgeStore::MODES.include?(record["mode"])
        issues << issue("error", "bridge.mode_invalid", id, "unsupported bridge mode")
        return issues
      end
      repository = @config.repository(id)
      return [issue("error", "bridge.repository_missing", id, "recorded repository is not registered")] unless repository

      root = @config.root_path(repository.fetch("path"), label: "repository path")
      target = Support.contained_path(root, record.fetch("target"), label: "bridge target")
      if !File.file?(target)
        issues << issue("error", "bridge.target_missing", id, "recorded target is missing")
      elsif Digest::SHA256.file(target).hexdigest != record["sha256"]
        issues << issue("error", "bridge.drift", id, "bridge digest differs from its registry record")
      end
      Array(record["artifacts"]).each do |artifact|
        next if artifact["path"] == record["target"]

        artifact_path = Support.contained_path(root, artifact.fetch("path"), label: "bridge artifact")
        if !File.file?(artifact_path)
          issues << issue("error", "bridge.artifact_missing", id, "recorded bridge artifact is missing: #{artifact['path']}")
        elsif Digest::SHA256.file(artifact_path).hexdigest != artifact.fetch("sha256")
          issues << issue("error", "bridge.artifact_drift", id, "bridge artifact digest differs: #{artifact['path']}")
        end
      rescue KeyError => e
        issues << issue("error", "bridge.record_invalid", id, e.message)
      end
      if record["version"].to_s != manifest.fetch("bridge_version").to_s
        issues << issue("warning", "bridge.version_drift", id, "bridge version differs from current manifest")
      end
      if %w[reference materialized].include?(record["mode"])
        _ignored_output, _ignored_error, ignored_status = Support.capture(
          "git", "check-ignore", "-q", "--", "AGENTS.override.md", chdir: root
        )
        _tracked_output, _tracked_error, tracked_status = Support.capture(
          "git", "ls-files", "--error-unmatch", "--", "AGENTS.override.md", chdir: root
        )
        issues << issue("error", "bridge.override_unprotected", id, "AGENTS.override.md is not Git-locally ignored") unless ignored_status.zero?
        issues << issue("error", "bridge.override_tracked", id, "local bridge override must not be tracked") if tracked_status.zero?
      end
      if record["mode"] == "materialized"
        _ignored_output, _ignored_error, ignored_status = Support.capture(
          "git", "check-ignore", "-q", "--", ".flightdeck/bridge/AGENTS.md", chdir: root
        )
        issues << issue("error", "bridge.materialized_unprotected", id, "materialized bridge pack is not Git-locally ignored") unless ignored_status.zero?
      end
      portable_text = portable_bridge_text(record, root, target)
      if portable_text && absolute_machine_path?(portable_text)
        issues << issue("error", "bridge.absolute_path_leak", id, "portable bridge content contains a machine-specific absolute path")
      end
      Array(manifest.dig("profiles", record["profile"], "required_docs")).each do |relative|
        unless File.file?(@config.root_path(relative, label: "required bridge document"))
          issues << issue("error", "bridge.reference_missing", id, "required Hub document is missing: #{relative}")
        end
      end
      issues
    rescue KeyError, ConfigurationError => e
      [issue("error", "bridge.record_invalid", id, e.message)]
    end

    def issue(severity, code, scope, message)
      { "severity" => severity, "code" => code, "scope" => scope, "message" => message }
    end

    def portable_bridge_text(record, root, target)
      case record["mode"]
      when "repo-native"
        marker = "<!-- flightdeck-bridge:#{record['version']} -->"
        text = File.file?(target) ? File.read(target, encoding: "UTF-8") : ""
        text.split(marker, 2)[1]
      when "materialized"
        Array(record["artifacts"]).filter_map do |artifact|
          path = Support.contained_path(root, artifact.fetch("path"), label: "bridge artifact")
          File.read(path, encoding: "UTF-8") if File.file?(path)
        end.join("\n")
      end
    end

    def absolute_machine_path?(text)
      text.match?(%r{(?:^|[\s`"'(])/(?:Users|home|private|Volumes|var|opt|tmp)/}) ||
        text.match?(/[A-Za-z]:\\[^\\\s]+/)
    end
  end

  class AutomationChecker
    def initialize(root)
      @root = root
    end

    def run
      Dir.glob(File.join(@root, "hub", "automations", "*.yaml")).sort.filter_map do |path|
        value = Support.load_data(path)
        next if value["enabled"] == false && value.dig("activation", "policy") == "explicit_user_enablement"

        {
          "severity" => "error",
          "code" => "automation.unsafe_default",
          "scope" => Support.relative_path(@root, path),
          "message" => "automation templates must be disabled and require explicit enablement"
        }
      rescue ValidationError => e
        {
          "severity" => "error",
          "code" => "automation.invalid",
          "scope" => Support.relative_path(@root, path),
          "message" => e.message
        }
      end
    end
  end
end
