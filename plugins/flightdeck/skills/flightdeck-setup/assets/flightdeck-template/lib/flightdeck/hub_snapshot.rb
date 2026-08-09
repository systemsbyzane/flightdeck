# frozen_string_literal: true

require_relative "bridge_store"

module Flightdeck
  # Read-only, renderer-safe projection of a selected Hub. Route plans are not
  # reused because they contain paths, runtime IDs, and bridge handoff data.
  class HubSnapshot
    API_VERSION = "flightdeck.hub-snapshot/v1"
    SCHEMA = "hub/schemas/hub-snapshot.schema.json"
    CAPABILITY = "flightdeck.command.hub-snapshot.v1"
    MAX_PROJECTS = 200

    class SnapshotError < Error
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    def initialize(config)
      @config = config
    end

    def snapshot
      compatibility = compatibility!
      coordinator = coordinator_project!
      if @config.repository_declarations.length >= MAX_PROJECTS
        raise SnapshotError.new("project_limit_exceeded", "Hub project declarations exceed the safety limit.")
      end
      repositories = @config.repository_declarations.map { |declaration| repository_project!(declaration) }
      {
        "api_version" => API_VERSION,
        "kind" => "HubSnapshot",
        "schema" => SCHEMA,
        "ok" => true,
        "hub" => {
          "display_name" => safe_label!(@config.data.dig("metadata", "name"), "Hub"),
          "template_version" => compatibility.fetch("template_version"),
          "health" => { "capability" => "flightdeck.command.doctor.v1" }
        },
        "runtime_capabilities" => runtime_capabilities!(compatibility),
        "projects" => [coordinator, *repositories.sort_by { |project| project.fetch("logical_project_key") }]
      }
    rescue ConfigurationError, ValidationError, KeyError
      raise SnapshotError.new("registry_invalid", "Hub registry is invalid.")
    end

    private

    def compatibility!
      compatibility_path = File.join(@config.root, "hub", "compatibility.json")
      schema_path = File.join(@config.root, SCHEMA)
      unless [compatibility_path, schema_path].all? { |path| File.file?(path) && !File.symlink?(path) }
        raise SnapshotError.new("unsupported_hub_contract", "Selected Hub does not declare the Hub snapshot v1 contract.")
      end
      value = Support.load_data(compatibility_path)
      capability = value.dig("capabilities", CAPABILITY)
      doctor = value.dig("capabilities", "flightdeck.command.doctor.v1")
      managed = Array(capability&.fetch("managed_paths", []))
      unless value["schema_version"] == "flightdeck.hub-compatibility/v1" && value["product"] == "flightdeck" &&
             capability.is_a?(Hash) && capability["kind"] == "command" &&
             capability.dig("probe", "help_contains") == "bin/flightdeck hub snapshot " &&
             ["lib/flightdeck/hub_snapshot.rb", SCHEMA].all? { |path| managed.include?(path) } &&
             doctor.is_a?(Hash) && doctor["kind"] == "command" && value["runtime_capabilities"].is_a?(Hash) &&
             value["template_version"].to_s.match?(/\A[0-9]+\.[0-9]+\.[0-9]+\z/)
        raise SnapshotError.new("unsupported_hub_contract", "Selected Hub does not declare the Hub snapshot v1 contract.")
      end
      value
    rescue ValidationError
      raise SnapshotError.new("unsupported_hub_contract", "Selected Hub does not declare the Hub snapshot v1 contract.")
    end

    def coordinator_project!
      key = @config.workspace.fetch("coordination_project_key")
      project = @config.codex_project(key)
      raise SnapshotError.new("registry_invalid", "Hub coordinator declaration is invalid.") unless project.is_a?(Hash)

      verification!(key, project.fetch("path"))
      {
        "logical_project_key" => key,
        "display_label" => safe_label!(project["display_name"], "Hub coordinator"),
        "workload" => "coordination",
        "availability" => "registered",
        "bridge_health" => "not_applicable",
        "destination" => "hub_coordinator",
        "routing_capability" => "coordinate_and_route"
      }
    end

    def repository_project!(declaration)
      key = declaration.dig("codex_project", "logical_key")
      repository = @config.repository(declaration.fetch("id"))
      raise SnapshotError.new("project_unavailable", "A declared repository is unavailable.") unless repository

      verification!(key, @config.repository_path(repository))
      bridge = BridgeStore.new(@config).plan(
        repository_id: declaration.fetch("id"),
        mode: declaration.dig("bridge", "mode"),
        profile: declaration.dig("bridge", "profile")
      )
      unless bridge["desired_state"] == "valid" && Array(bridge["blockers"]).empty?
        raise SnapshotError.new("bridge_unhealthy", "A declared repository bridge is unhealthy.")
      end
      {
        "logical_project_key" => key,
        "display_label" => safe_label!(repository["display_name"] || key, "Project"),
        "workload" => declaration.fetch("workload"),
        "availability" => "registered",
        "bridge_health" => "healthy",
        "destination" => "repository_routing_hint",
        "routing_capability" => "route_through_hub"
      }
    rescue ConfigurationError
      raise
    rescue ValidationError
      raise SnapshotError.new("project_unavailable", "A declared repository is unavailable.")
    end

    def verification!(key, expected_path)
      result = @config.project_verification(logical_key: key, expected_path: expected_path)
      return if result["status"] == "verified"

      code = result["recorded_path"] ? "project_verification_conflict" : "project_verification_missing"
      raise SnapshotError.new(code, "A declared project is not exactly verified.")
    end

    def runtime_capabilities!(compatibility)
      value = compatibility.fetch("runtime_capabilities")
      adapters = value["adapters"]
      controls = adapters.dig("codex", "optional_controls") if adapters.is_a?(Hash)
      unless value["primary_runtime"] == "codex" && adapters.is_a?(Hash) &&
             adapters.dig("codex", "available") == true && adapters.dig("omp", "available") == false &&
             controls.is_a?(Array) && controls.uniq == controls &&
             controls.all? { |control| %w[model reasoning_effort].include?(control) }
        raise SnapshotError.new("unsupported_hub_contract", "Selected Hub has invalid runtime capability metadata.")
      end
      {
        "primary_runtime" => "codex",
        "adapters" => {
          "codex" => { "available" => true, "optional_controls" => controls },
          "omp" => { "available" => false }
        }
      }
    end

    def safe_label!(value, fallback)
      label = value.to_s.strip
      label = fallback if label.empty?
      unless label.length <= 128 && !label.match?(/[\u0000-\u001f\u007f\\\/]/)
        raise SnapshotError.new("registry_invalid", "Hub display metadata is invalid.")
      end
      label
    end
  end
end
