# frozen_string_literal: true

require_relative "support"
require "uri"

module Flightdeck
  class Config
    attr_reader :root, :path, :data

    def initialize(root:, path: nil)
      @root = File.expand_path(root)
      @path = File.expand_path(path || ENV.fetch("FLIGHTDECK_CONFIG", File.join(@root, "flightdeck.yaml")))
      raise ConfigurationError, "missing Hub configuration: #{@path}" unless File.file?(@path)

      @data = Support.load_data(@path)
      raise ConfigurationError, "flightdeck.yaml must contain a mapping" unless @data.is_a?(Hash)
    rescue ValidationError => e
      raise ConfigurationError, e.message
    end

    def workspace
      mapping("workspace")
    end

    def workloads
      mapping("workloads")
    end

    def workload(name)
      workloads[name.to_s]
    end

    def codex_projects
      mapping("codex_projects")
    end

    def codex_project(name)
      codex_projects[name.to_s]
    end

    def providers
      mapping("providers")
    end

    def provider(name)
      providers[name.to_s]
    end

    def environments
      mapping("environments")
    end

    def workflows
      mapping("workflow_adapters")
    end

    def routing
      mapping("routing")
    end

    def mission_defaults
      mapping("mission_control")
    end

    def mission_budgets
      defaults = {
        "max_units" => 50,
        "max_retries" => 3,
        "max_actions" => 200,
        "max_forwarded_bytes" => 65_536,
        "max_duration_seconds" => 604_800,
        "stale_after_seconds" => 3_600,
        "max_record_bytes" => 2_097_152
      }
      value = mission_defaults.fetch("budgets", {})
      raise ConfigurationError, "flightdeck.yaml mission_control.budgets must be a mapping" unless value.is_a?(Hash)

      defaults.merge(value).each_with_object({}) do |(name, limit), output|
        unless limit.is_a?(Integer) && limit.positive?
          raise ConfigurationError, "mission budget #{name} must be a positive integer"
        end
        output[name] = limit
      end
    end

    def task_dir
      root_path(workspace.fetch("task_records_root", "hub/tasks"), label: "task root")
    end

    def mission_dir
      root_path(workspace.fetch("mission_records_root", "hub/missions"), label: "mission root")
    end

    def report_dir
      root_path(workspace.fetch("report_root", "hub/reports"), label: "report root")
    end

    def local_registry_path
      root_path(workspace.fetch("local_registry", "hub/state/repositories.yaml"), label: "local registry")
    end

    def bridge_registry_path
      root_path(workspace.fetch("bridge_registry", "hub/state/bridges.yaml"), label: "bridge registry")
    end

    def repository_declarations_path
      root_path(
        workspace.fetch("repository_declarations", "hub/repositories.yaml"),
        label: "repository declarations"
      )
    end

    def project_registry_path
      root_path(
        workspace.fetch("project_registry", "hub/state/projects.yaml"),
        label: "project registry"
      )
    end

    def bridge_setup_receipt_path
      root_path(
        workspace.fetch("bridge_setup_receipt", "hub/state/bridge-repos.json"),
        label: "bridge setup receipt"
      )
    end

    def repository_declarations
      value = Support.load_data(repository_declarations_path)
      unless value["api_version"] == "flightdeck.dev/v1alpha1" &&
             value["kind"] == "RepositoryDeclarations"
        raise ConfigurationError, "repository declarations must use flightdeck.dev/v1alpha1 RepositoryDeclarations"
      end
      entries = value.fetch("repositories", [])
      raise ConfigurationError, "repository declarations repositories must be an array" unless entries.is_a?(Array)

      ids = {}
      project_keys = {}
      entries.map do |item|
        normalized = normalize_declaration(item)
        id = normalized.fetch("id")
        raise ConfigurationError, "duplicate repository declaration: #{id}" if ids[id]

        project_key = normalized.dig("codex_project", "logical_key")
        if project_keys[project_key]
          raise ConfigurationError, "duplicate declared logical project key: #{project_key}"
        end
        ids[id] = true
        project_keys[project_key] = true
        normalized
      end.sort_by { |item| item["id"] }
    rescue ValidationError, KeyError => e
      raise ConfigurationError, e.message
    end

    def project_verifications
      return {} unless File.file?(project_registry_path)

      value = Support.load_data(project_registry_path)
      unless value["api_version"] == "flightdeck.dev/v1alpha1" &&
             value["kind"] == "CodexProjectVerifications"
        raise ConfigurationError, "project registry must use flightdeck.dev/v1alpha1 CodexProjectVerifications"
      end
      projects = value.fetch("projects", {})
      raise ConfigurationError, "project registry projects must be a mapping" unless projects.is_a?(Hash)

      projects.each_with_object({}) do |(key, item), output|
        logical_key = key.to_s
        Support.validate_identifier!(logical_key, label: "project verification logical key")
        raise ConfigurationError, "project verification #{logical_key} must be a mapping" unless item.is_a?(Hash)

        record = Support.stringify(item)
        required = %w[
          logical_key runtime_project_id path verified verification_source verified_at
        ]
        missing = required.reject { |name| Support.present?(record[name]) || record[name] == true }
        unless missing.empty?
          raise ConfigurationError,
                "project verification #{logical_key} missing: #{missing.join(', ')}"
        end
        unless record["logical_key"] == logical_key
          raise ConfigurationError,
                "project verification map key must equal logical_key: #{logical_key}"
        end
        unless record["runtime_project_id"].is_a?(String) &&
               record["runtime_project_id"].length <= 512 &&
               !record["runtime_project_id"].match?(/[\u0000-\u001f\u007f]/)
          raise ConfigurationError,
                "project verification #{logical_key} runtime_project_id must be an opaque non-control string"
        end
        unless Pathname.new(record["path"].to_s).absolute?
          raise ConfigurationError, "project verification #{logical_key} path must be absolute"
        end
        unless record["verified"] == true &&
               record["verification_source"] == "live_project_list_exact_path"
          raise ConfigurationError,
                "project verification #{logical_key} must come from a refreshed live project list exact-path match"
        end

        output[logical_key] = record
      end
    rescue ValidationError, UsageError => e
      raise ConfigurationError, e.message
    end

    def project_verification(logical_key:, expected_path:)
      key = logical_key.to_s
      Support.validate_identifier!(key, label: "logical project key")
      record = project_verifications[key]
      base = {
        "expectation" => "saved_exact_path",
        "logical_key" => key,
        "runtime_project_id" => nil,
        "status" => "pending",
        "work" => "register_or_open_then_refresh_and_require_exact_path",
        "recorded_path" => nil,
        "exact_path_match" => false,
        "verification_source" => nil
      }
      return base unless record

      exact_path = begin
        File.realpath(record.fetch("path")) == File.realpath(expected_path)
      rescue KeyError, Errno::ENOENT, Errno::ELOOP
        false
      end
      verified = record["verified"] == true &&
        record["logical_key"] == key &&
        record["verification_source"] == "live_project_list_exact_path" &&
        Support.present?(record["runtime_project_id"]) &&
        exact_path
      base.merge(
        "runtime_project_id" => verified ? record["runtime_project_id"] : nil,
        "status" => verified ? "verified" : "conflict",
        "work" => verified ? "none" : "retry_registration_then_one_manual_action",
        "recorded_path" => record["path"],
        "exact_path_match" => exact_path,
        "verification_source" => record["verification_source"]
      )
    rescue UsageError => e
      raise ConfigurationError, e.message
    end

    def repositories
      configured = mapping("repositories").map do |name, item|
        normalize_repository(name, item, "stable")
      end
      return configured unless File.file?(local_registry_path)

      local = Support.load_data(local_registry_path)
      entries = local.fetch("repositories", {})
      raise ConfigurationError, "local registry repositories must be a mapping" unless entries.is_a?(Hash)

      merged = configured.each_with_object({}) { |item, out| out[item["id"]] = item }
      entries.each { |name, item| merged[name.to_s] = normalize_repository(name, item, "local") }
      merged.values
    rescue ValidationError => e
      raise ConfigurationError, e.message
    end

    def repository(name)
      repositories.find { |item| item["id"] == name.to_s }
    end

    def repository_path(repository)
      value = repository.fetch("path")
      placement = repository.fetch("placement", "managed")
      unless %w[managed attached].include?(placement)
        raise ConfigurationError, "repository placement must be managed or attached"
      end

      return root_path(value, label: "repository path") if placement == "managed"

      unless repository["registry_origin"] == "local"
        raise ConfigurationError, "attached repository paths must come from ignored local state"
      end
      unless Pathname.new(value.to_s).absolute?
        raise ConfigurationError, "attached repository path must be absolute"
      end

      File.expand_path(value)
    end

    def workflow_path(type)
      entry = workflows[type.to_s]
      return nil unless Support.present?(entry)

      root_path(entry.to_s, label: "workflow #{type}")
    end

    def root_path(value, label: "path")
      Support.contained_path(root, value, label: label)
    end

    private

    def mapping(name)
      value = data.fetch(name, {})
      raise ConfigurationError, "flightdeck.yaml #{name} must be a mapping" unless value.is_a?(Hash)

      value
    end

    def normalize_repository(name, item, origin)
      value = item.is_a?(Hash) ? item.dup : { "local_path" => item.to_s }
      value["id"] = name.to_s
      value["local_path"] ||= value["path"]
      value["path"] = value["local_path"]
      value["placement"] ||= "managed"
      value["workloads"] = Array(value["workload_ids"] || value["workloads"] || value["workload"]).map(&:to_s)
      value["workload"] ||= value["workloads"].first || "shared"
      value["registry_origin"] = origin
      value
    end

    def normalize_declaration(item)
      raise ConfigurationError, "repository declaration must be a mapping" unless item.is_a?(Hash)

      value = Support.stringify(item)
      value["placement"] ||= "managed"
      required = %w[
        id workload provider locator owner default_branch
        default_branch_verified bridge codex_project
      ]
      missing = required.reject { |key| Support.present?(value[key]) || value[key] == false }
      raise ConfigurationError, "repository declaration missing: #{missing.join(', ')}" unless missing.empty?

      Support.validate_identifier!(value["id"], label: "repository declaration ID")
      raise ConfigurationError, "unknown declared workload: #{value['workload']}" unless workload(value["workload"])
      raise ConfigurationError, "unknown declared provider: #{value['provider']}" unless provider(value["provider"])
      unless %w[managed attached].include?(value["placement"])
        raise ConfigurationError, "declared repository placement must be managed or attached"
      end
      unless [true, false].include?(value["default_branch_verified"])
        raise ConfigurationError, "declared default_branch_verified must be boolean"
      end
      if value["placement"] == "managed"
        raise ConfigurationError, "managed declaration default branch must be verified" unless value["default_branch_verified"] == true
        raise ConfigurationError, "managed declaration local_path is required" unless Support.present?(value["local_path"])
        if Pathname.new(value["local_path"].to_s).absolute?
          raise ConfigurationError, "declared repository path must be Hub-relative"
        end
        root_path(value["local_path"], label: "declared repository path")
      elsif value.key?("local_path")
        raise ConfigurationError, "attached declarations must not store a machine-local path"
      end
      if value["provider"] == "existing-local" && Pathname.new(value["locator"].to_s).absolute?
        raise ConfigurationError, "existing-local declaration locator must be portable"
      end
      begin
        locator_uri = URI.parse(value["locator"].to_s)
        if locator_uri.scheme && (locator_uri.user || locator_uri.password)
          raise ConfigurationError, "repository declaration locator must not contain credentials"
        end
      rescue URI::InvalidURIError => e
        raise ConfigurationError, "repository declaration locator is invalid: #{e.message}"
      end

      bridge = value["bridge"]
      project = value["codex_project"]
      raise ConfigurationError, "repository declaration bridge must be a mapping" unless bridge.is_a?(Hash)
      raise ConfigurationError, "repository declaration codex_project must be a mapping" unless project.is_a?(Hash)
      unless %w[reference materialized repo-native].include?(bridge["mode"])
        raise ConfigurationError, "declared bridge mode must be reference, materialized, or repo-native"
      end
      raise ConfigurationError, "declared bridge profile is required" unless Support.present?(bridge["profile"])
      unless project["expectation"] == "saved_exact_path" && Support.present?(project["logical_key"])
        raise ConfigurationError, "declared Codex project must require saved_exact_path and logical_key"
      end
      Support.validate_identifier!(project["logical_key"], label: "declared logical project key")

      value
    rescue UsageError => e
      raise ConfigurationError, e.message
    end
  end
end
