# frozen_string_literal: true

require_relative "mission_store"
require_relative "operation_authoring"
require_relative "task_store"

module Flightdeck
  # Read-only, redacted projection of durable Hub task and Mission records.
  # It intentionally has no adapter to Codex task recents: only local Hub
  # records are eligible for display.
  class OperationsSnapshot
    API_VERSION = "flightdeck.operations-snapshot/v1"
    SCHEMA = "hub/schemas/operations-snapshot.schema.json"
    CAPABILITY = "flightdeck.command.operations-snapshot.v1"
    DETAIL_IDENTITY_CAPABILITY = "flightdeck.command.operations-snapshot-detail-identity.v1"
    MAX_OPERATIONS = 1_000
    MAX_ALERTS = 100
    STATUSES = %w[
      queued working waiting approval_required blocked review_ready failed_validation
      cancelled reconcile_required
    ].freeze
    ALERT_STATUSES = %w[blocked approval_required failed_validation reconcile_required].freeze
    SKILL_FAILURE_STATUSES = %w[failed blocked unknown_outcome].freeze

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
      detail_identities = OperationAuthoring.new(@config).snapshot_detail_identities
      operations = mission_operations(detail_identities) + task_operations
      operations.sort_by! { |operation| [operation.fetch("updated_at"), operation.fetch("operation_id")] }.reverse!
      alerts = operations.filter_map do |operation|
        next unless ALERT_STATUSES.include?(operation.fetch("status"))

        {
          "operation_id" => operation.fetch("operation_id"),
          "status" => operation.fetch("status"),
          "detail" => operation.fetch("detail")
        }
      end.first(MAX_ALERTS)
      {
        "api_version" => API_VERSION,
        "kind" => "OperationsSnapshot",
        "schema" => SCHEMA,
        "ok" => true,
        "runtime_capabilities" => runtime_capabilities!,
        "summary" => {
          "counts" => STATUSES.to_h { |status| [status, operations.count { |item| item["status"] == status }] },
          "alerts" => alerts
        },
        "operations" => operations
      }
    rescue ConfigurationError, ValidationError, KeyError, SystemCallError
      raise SnapshotError.new("invalid_hub_state", "Hub Operations state is invalid.")
    end

    private

    def compatibility!
      paths = [File.join(@config.root, "hub", "compatibility.json"), File.join(@config.root, SCHEMA)]
      unless paths.all? { |path| File.file?(path) && !File.symlink?(path) }
        raise SnapshotError.new("unsupported_hub_contract", "Selected Hub does not declare the Operations snapshot v1 contract.")
      end
      value = Support.load_data(paths.first)
      capability = value.dig("capabilities", CAPABILITY)
      detail_capability = value.dig("capabilities", DETAIL_IDENTITY_CAPABILITY)
      authoring_capability = value.dig("capabilities", OperationAuthoring::CAPABILITY)
      managed = Array(capability&.fetch("managed_paths", []))
      detail_managed = Array(detail_capability&.fetch("managed_paths", []))
      unless value["schema_version"] == "flightdeck.hub-compatibility/v1" && value["product"] == "flightdeck" &&
             capability.is_a?(Hash) && capability["kind"] == "command" &&
             capability.dig("probe", "help_contains") == "bin/flightdeck hub operations-snapshot " &&
             [
               "lib/flightdeck/mission_store.rb", "lib/flightdeck/operation_execution.rb",
               "lib/flightdeck/operations_snapshot.rb", "hub/schemas/operation-execution-types.schema.json", SCHEMA
             ].all? { |path| managed.include?(path) } &&
             detail_capability.is_a?(Hash) && detail_capability["kind"] == "command" &&
             detail_capability.dig("probe", "help_contains") == "bin/flightdeck hub operations-snapshot " &&
             [
               "lib/flightdeck/mission_store.rb", "lib/flightdeck/operation_execution.rb",
               "lib/flightdeck/operation_authoring.rb", "lib/flightdeck/operations_snapshot.rb",
               "hub/schemas/operation-execution-types.schema.json", SCHEMA
             ].all? { |path| detail_managed.include?(path) } &&
             authoring_capability.is_a?(Hash) && authoring_capability["kind"] == "command"
        raise SnapshotError.new("unsupported_hub_contract", "Selected Hub does not declare the Operations snapshot v1 contract.")
      end
    rescue ValidationError
      raise SnapshotError.new("unsupported_hub_contract", "Selected Hub does not declare the Operations snapshot v1 contract.")
    end

    def runtime_capabilities!
      value = Support.load_data(File.join(@config.root, "hub", "compatibility.json")).fetch("runtime_capabilities")
      OperationExecution.runtime_capabilities_projection!(value)
    rescue OperationExecution::ContractError
      raise SnapshotError.new("unsupported_hub_contract", "Selected Hub has invalid runtime capability metadata.")
    end

    def mission_operations(detail_identities)
      store = MissionStore.new(@config)
      record_ids(@config.mission_dir, "mission").map do |id|
        raise SnapshotError.new("invalid_hub_state", "Hub Operations state is invalid.") unless store.validate(id).empty?
        mission = store.status(id)

        events = Array(mission.dig("status", "skill_events"))
        nodes = Array(mission.dig("spec", "graph", "nodes")).map { |node| mission_child(node, events) }
        operation(
          "mission", id, mission.dig("metadata", "title"), mission.dig("status", "state"),
          mission.dig("metadata", "created_at"), mission.dig("metadata", "updated_at"),
          { "mode" => mission.dig("spec", "mode"), "logical_project_keys" => nodes.map { |node| node["logical_project_key"] }.uniq.sort },
          nodes, detail: detail_identity(detail_identities[id]), skills: skill_summary(events)
        )
      end
    end

    def task_operations
      store = TaskStore.new(@config)
      record_ids(@config.task_dir, "task").map do |id|
        task = store.fetch(id)
        errors = store.validate(id)
        raise SnapshotError.new("invalid_hub_state", "Hub Operations state is invalid.") unless errors.empty?

        workload = task.dig("spec", "workload_id")
        children = Array(task.dig("status", "units")).filter_map { |unit| task_child(unit, workload) }
        operation("task", id, task.dig("metadata", "title"), task_status(task), task.dig("metadata", "created_at"), task.dig("metadata", "updated_at"),
                  { "workload" => workload }, children, validation: task_validation(task))
      end
    end

    def operation(kind, id, title, state, created_at, updated_at, route_scope, children, detail: unavailable_detail, validation: nil, skills: unavailable_skills)
      value = {
        "operation_id" => "#{kind}:#{id}",
        "operation_kind" => kind,
        "detail" => detail,
        "display_title" => safe_title(title, id),
        "status" => map_state(state),
        "created_at" => iso8601!(created_at),
        "updated_at" => iso8601!(updated_at),
        "route_scope" => route_scope.reject { |_key, value| value.nil? },
        "children" => children,
        "skills" => skills
      }
      value["validation"] = validation if validation
      value
    end

    def detail_identity(operation_id)
      return unavailable_detail if operation_id.nil?
      unless operation_id.to_s.match?(/\Aoperation-[0-9a-f]{24}\z/)
        raise SnapshotError.new("invalid_hub_state", "Hub Operation detail identity is invalid.")
      end

      { "availability" => "available", "operation_id" => operation_id }
    end

    def unavailable_detail
      { "availability" => "unavailable" }
    end

    def mission_child(node, events)
      child(
        node.fetch("id"), node.fetch("logical_project_key"), node.fetch("observed_state"),
        node.fetch("created_at"), node.fetch("updated_at"),
        activity: node["status_code"], observed_at: node["observed_at"],
        validation: node_validation(node), artifacts: node_artifacts(node),
        skills: skill_summary(events.select { |event| event["node_id"] == node["id"] }),
        execution: node["operation_execution"] || { "availability" => "unavailable" }
      )
    end

    def task_child(unit, workload)
      return nil unless unit.is_a?(Hash) && Support.present?(unit["logical_project_key"])

      child(unit.fetch("id"), unit.fetch("logical_project_key"), unit.fetch("state"), nil, nil, workload: workload)
    end

    def child(id, logical_key, state, created_at, updated_at, workload: nil, activity: nil, observed_at: nil, validation: nil, artifacts: nil, skills: unavailable_skills, execution: { "availability" => "unavailable" })
      key = identifier!(logical_key)
      info = project_info(key, workload)
      value = {
        "child_id" => identifier!(id),
        "logical_project_key" => key,
        "display_label" => info.fetch("display_label"),
        "role_name" => info.fetch("role_name"),
        "status" => map_state(state),
        "skills" => skills,
        "execution" => execution
      }
      value["created_at"] = iso8601!(created_at) if created_at
      value["updated_at"] = iso8601!(updated_at) if updated_at
      value["activity"] = { "code" => identifier!(activity), "observed_at" => iso8601!(observed_at) } if activity && observed_at
      value["validation"] = validation if validation
      value["artifacts"] = artifacts if artifacts && !artifacts.empty?
      value
    end

    def skill_summary(events)
      items = events.group_by { |event| [event["skill_id"], event["skill_version"]] }.map do |(skill_id, skill_version), skill_events|
        latest_by_child = skill_events.group_by { |event| event["node_id"] }.values.map do |child_events|
          child_events.max_by { |event| [event["observed_at"], event["evidence_id"]] }
        end
        statuses = latest_by_child.map { |event| event["lifecycle_status"] }
        {
          "skill_id" => identifier!(skill_id),
          "skill_version" => skill_version,
          "lifecycle_status" => aggregate_skill_status(statuses)
        }
      end.sort_by { |item| [item["skill_id"], item["skill_version"].to_s] }
      state = if items.empty?
                "absent"
              elsif items.any? { |item| SKILL_FAILURE_STATUSES.include?(item["lifecycle_status"]) }
                "partial_failure"
              elsif items.any? { |item| item["lifecycle_status"] == "started" }
                "in_progress"
              else
                "succeeded"
              end
      { "state" => state, "items" => items }
    end

    def unavailable_skills
      { "state" => "unavailable", "items" => [] }
    end

    def aggregate_skill_status(statuses)
      return "unknown_outcome" if statuses.include?("unknown_outcome")
      return "failed" if statuses.include?("failed")
      return "blocked" if statuses.include?("blocked")
      return "started" if statuses.include?("started")
      return "succeeded" if statuses.include?("succeeded")

      "completed"
    end

    def project_info(key, fallback_workload)
      declaration = @config.repository_declarations.find { |item| item.dig("codex_project", "logical_key") == key }
      project = @config.codex_project(key)
      workload = declaration&.fetch("workload", nil) || project&.fetch("workload_id", nil) || fallback_workload
      label = if declaration
                safe_label(declaration["display_name"] || declaration["id"], key)
              elsif project
                safe_label(project["display_name"], key)
              else
                key
              end
      role = case workload
             when "environments", "charts" then "Platform Agent"
             when "patching" then "Patching Agent"
             when "development" then "Development Agent"
             when "research" then "Research Agent"
             when "compliance" then "Compliance Agent"
             when "operations" then "Operations Agent"
             else "Hub Agent"
             end
      { "display_label" => label, "role_name" => "#{role} — #{label}" }
    end

    def task_status(task)
      return "approval_required" if Array(task.dig("status", "approvals")).any? { |approval| approval["status"] == "pending" }
      return "failed_validation" if Array(task.dig("status", "checks")).any? { |check| check["status"] == "failed" }

      task.dig("status", "state")
    end

    def task_validation(task)
      checks = Array(task.dig("status", "checks"))
      return nil if checks.empty?

      { "passed" => checks.count { |check| check["status"] == "passed" }, "failed" => checks.count { |check| check["status"] == "failed" }, "unavailable" => checks.count { |check| %w[skipped unavailable].include?(check["status"]) } }
    end

    def node_validation(node)
      return nil unless node["validation_status"]

      { "status" => node.fetch("validation_status") }
    end

    def node_artifacts(node)
      Array(node["output_declarations"]).filter_map do |declaration|
        next unless declaration.is_a?(Hash) && declaration["type"]

        value = { "type" => identifier!(declaration["type"]) }
        value["artifact_id"] = identifier!(declaration["artifact_id"]) if declaration["artifact_id"]
        value
      end
    end

    def map_state(state)
      case state.to_s
      when "intake", "scoped", "designed", "authorized", "planned", "dispatch_pending" then "queued"
      when "executing", "running", "validating" then "working"
      when "integration_ready", "validation_ready", "awaiting_handoff" then "waiting"
      when "needs_approval", "approval_required" then "approval_required"
      when "blocked" then "blocked"
      when "review_ready", "closed", "complete", "completed" then "review_ready"
      when "failed_validation", "runtime_failure", "failed" then "failed_validation"
      when "cancelled" then "cancelled"
      else "reconcile_required"
      end
    end

    def record_ids(root, type)
      return [] unless Dir.exist?(root)
      raise SnapshotError.new("invalid_hub_state", "Hub Operations state is invalid.") if File.symlink?(root)

      entries = Dir.children(root).reject { |entry| entry == ".lock" || entry == ".authoring-operations" }.sort
      raise SnapshotError.new("operation_limit_exceeded", "Hub Operations state exceeds the safety limit.") if entries.length > MAX_OPERATIONS
      entries.map do |entry|
        Support.validate_slug!(entry, label: "#{type} slug")
        directory = File.join(root, entry)
        record = File.join(directory, "#{type}.yaml")
        unless File.directory?(directory) && !File.symlink?(directory) && File.file?(record) && !File.symlink?(record)
          raise SnapshotError.new("invalid_hub_state", "Hub Operations state is invalid.")
        end
        entry
      end
    end

    def identifier!(value)
      Support.validate_identifier!(value.to_s, label: "Operations identifier")
      value.to_s
    end

    def iso8601!(value)
      Time.iso8601(value.to_s)
      value.to_s
    rescue ArgumentError
      raise SnapshotError.new("invalid_hub_state", "Hub Operations state is invalid.")
    end

    def safe_title(value, fallback)
      safe_label(value, fallback, max: 256)
    end

    def safe_label(value, fallback, max: 128)
      label = value.to_s.strip
      label = fallback if label.empty? || label.length > max || label.match?(/[\u0000-\u001f\u007f\\\\\/]/)
      label
    end
  end
end
