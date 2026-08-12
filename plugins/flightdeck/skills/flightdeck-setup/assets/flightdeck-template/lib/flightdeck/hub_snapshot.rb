# frozen_string_literal: true

require_relative "bridge_store"
require_relative "operation_execution"

module Flightdeck
  # Read-only, renderer-safe projection of a selected Hub.  This deliberately
  # does not reuse route-plan output: route plans contain local paths, opaque
  # runtime IDs, and bridge handoff material that must stay outside a UI view.
  class HubSnapshot
    API_VERSION = "flightdeck.hub-snapshot/v1"
    SCHEMA = "hub/schemas/hub-snapshot.schema.json"
    CAPABILITY = "flightdeck.command.hub-snapshot.v1"

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
      repositories = @config.repository_declarations.map { |declaration| repository_project!(declaration) }
      projects = [coordinator, *repositories.sort_by { |project| project.fetch("logical_project_key") }]

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
        "projects" => projects
      }
    rescue ConfigurationError, ValidationError, KeyError
      raise SnapshotError.new("registry_invalid", "Hub registry is invalid.")
    end

    private

    def compatibility!
      path = File.join(@config.root, "hub", "compatibility.json")
      schema = File.join(@config.root, SCHEMA)
      unless File.file?(path) && !File.symlink?(path) && File.file?(schema) && !File.symlink?(schema)
        raise SnapshotError.new("unsupported_hub_contract", "Selected Hub does not declare the Hub snapshot v1 contract.")
      end

      value = Support.load_data(path)
      capability = value.dig("capabilities", CAPABILITY)
      doctor = value.dig("capabilities", "flightdeck.command.doctor.v1")
      unless value["schema_version"] == "flightdeck.hub-compatibility/v1" &&
             value["product"] == "flightdeck" && capability.is_a?(Hash) && capability["kind"] == "command" &&
             doctor.is_a?(Hash) && doctor["kind"] == "command" &&
             value["runtime_capabilities"].is_a?(Hash)
        raise SnapshotError.new("unsupported_hub_contract", "Selected Hub does not declare the Hub snapshot v1 contract.")
      end
      value
    rescue ValidationError
      raise SnapshotError.new("unsupported_hub_contract", "Selected Hub does not declare the Hub snapshot v1 contract.")
    end

    # Membership is reconciled deterministically: the coordinator is the one
    # configured coordination key; repository members are only durable
    # declarations, sorted by logical key.  Local registries and verification
    # records can prove those declarations but cannot add a member.
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
      unless repository
        raise SnapshotError.new("project_unavailable", "A declared repository is unavailable.")
      end

      expected_path = @config.repository_path(repository)
      verification!(key, expected_path)
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
      OperationExecution.runtime_capabilities_projection!(compatibility.fetch("runtime_capabilities"))
    rescue OperationExecution::ContractError
      raise SnapshotError.new("unsupported_hub_contract", "Selected Hub has invalid runtime capability metadata.")
    end

    def safe_label!(value, fallback)
      label = value.to_s.strip
      label = fallback if label.empty?
      unless label.length <= 128 && !label.match?(/[\u0000-\u001f\u007f\\\\\/]/)
        raise SnapshotError.new("registry_invalid", "Hub display metadata is invalid.")
      end
      label
    end
  end
end
