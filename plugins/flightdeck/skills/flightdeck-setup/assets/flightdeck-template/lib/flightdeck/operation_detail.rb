# frozen_string_literal: true

require "json"
require_relative "operation_authoring"
require_relative "mission_store"

module Flightdeck
  # Evidence-bounded, client-safe detail for one exact authored Operation.
  class OperationDetail
    CAPABILITY = "flightdeck.command.operation-detail.v1"
    REQUEST = "flightdeck.operation-detail.request/v1"
    RESULT = "flightdeck.operation-detail.result/v1"
    ERROR = "flightdeck.operation-detail.error/v1"
    V2_CAPABILITY = "flightdeck.command.operation-detail.v2"
    V2_REQUEST = "flightdeck.operation-detail.request/v2"
    V2_RESULT = "flightdeck.operation-detail.result/v2"
    V2_ERROR = "flightdeck.operation-detail.error/v2"
    MAX_REQUEST_BYTES = 16_384

    class ContractError < ValidationError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    def initialize(config, clock: -> { Time.now.utc })
      @config = config
      @clock = clock
    end

    def self.load_request(path)
      raise UsageError, "--request must name a JSON file" unless path.to_s.end_with?(".json")
      stat = File.lstat(path)
      raise UsageError, "--request must be a regular non-symlink JSON file" unless stat.file? && !stat.symlink?
      raise UsageError, "--request exceeds #{MAX_REQUEST_BYTES} bytes" if stat.size > MAX_REQUEST_BYTES
      value = JSON.parse(File.read(path, MAX_REQUEST_BYTES + 1, encoding: "UTF-8"))
      raise UsageError, "--request must contain one JSON object" unless value.is_a?(Hash)
      Support.stringify(value)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => e
      raise UsageError, "--request is unavailable: #{e.class}"
    rescue JSON::ParserError
      raise UsageError, "--request is invalid JSON"
    end

    def self.error_result(error, request: nil)
      code = error.respond_to?(:code) ? error.code : (error.is_a?(UsageError) ? "malformed_request" : "internal_error")
      v2 = request.is_a?(Hash) && request["schema_version"] == V2_REQUEST
      { "schema_version" => v2 ? V2_ERROR : ERROR,
        "schema" => v2 ? "hub/schemas/operation-detail-v2-error.schema.json" : "hub/schemas/operation-detail-error.schema.json", "ok" => false,
        "error" => { "code" => code, "message" => error.message.to_s[0, 512] } }
    end

    def detail(request)
      return detail_v2(request) if request.is_a?(Hash) && request["schema_version"] == V2_REQUEST

      verify_capability!(CAPABILITY, %w[operation-detail-request.schema.json operation-detail-result.schema.json operation-detail-error.schema.json], "v1")
      unless request.is_a?(Hash) && request.keys.sort == %w[operation_id schema_version] && request["schema_version"] == REQUEST
        raise ContractError.new("malformed_request", "Operation detail request is invalid")
      end
      operation_id = request.fetch("operation_id").to_s
      binding = OperationAuthoring.new(@config).operation(
        "schema_version" => OperationAuthoring::OPERATION_REQUEST,
        "operation_id" => operation_id
      )
      unless binding["outcome"] == "created" && Support.present?(binding["mission_id"])
        raise ContractError.new("operation_unavailable", "Operation is not bound to a created durable record")
      end

      mission = MissionStore.new(@config, clock: @clock).status(binding.fetch("mission_id"))
      nodes = Array(mission.dig("spec", "graph", "nodes"))
      criteria = Array(mission.dig("spec", "success_criteria"))
      criterion_text = criteria.to_h { |item| [item.fetch("id"), item.fetch("text")] }
      agents = nodes.map { |node| agent_projection(node, criterion_text) }.sort_by { |agent| [agent.fetch("project"), agent.fetch("name")] }
      totals = validation_totals(nodes)
      {
        "schema_version" => RESULT,
        "schema" => "hub/schemas/operation-detail-result.schema.json",
        "ok" => true,
        "operation" => {
          "operation_id" => operation_id,
          "title" => safe_text(mission.dig("metadata", "title"), 256),
          "status" => map_state(mission.dig("status", "state")),
          "origin" => "work",
          "created_at" => mission.dig("metadata", "created_at"),
          "updated_at" => mission.dig("metadata", "updated_at"),
          "goal" => safe_text(mission.dig("spec", "outcome"), 2048),
          "mode" => mission.dig("spec", "mode"),
          "authorization" => {
            "scope" => "selected_projects_only",
            "external_actions_authorized" => false
          },
          "progress" => progress(nodes),
          "agents" => agents,
          "dependencies" => dependency_projection(nodes),
          "changes" => unavailable_evidence,
          "skills" => unavailable_evidence,
          "artifacts" => artifact_projection(nodes),
          "approvals" => approval_projection(nodes),
          "validation" => { "state" => totals.values.sum.positive? ? "available" : "unavailable", "totals" => totals },
          "result" => result_projection(mission, totals),
          "not_performed" => Array(mission.dig("spec", "non_goals")).map { |item| safe_text(item, 1024) }
        }
      }
    rescue KeyError, ValidationError => e
      raise e if e.is_a?(ContractError)
      raise ContractError.new("invalid_hub_state", "Operation detail is invalid")
    end

    private

    def verify_capability!(capability_id, schemas, label)
      compatibility_path = File.join(@config.root, "hub", "compatibility.json")
      paths = [compatibility_path, File.join(@config.root, "lib", "flightdeck", "operation_detail.rb")] + schemas.map { |name| File.join(@config.root, "hub", "schemas", name) }
      unless paths.all? { |path| File.file?(path) && !File.symlink?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Operation detail #{label}")
      end
      capability = Support.load_data(compatibility_path).dig("capabilities", capability_id)
      managed = ["lib/flightdeck/operation_detail.rb"] + schemas.map { |name| "hub/schemas/#{name}" }
      unless capability.is_a?(Hash) && capability["kind"] == "command" && capability.dig("probe", "help_contains") == "bin/flightdeck operation detail " && managed.all? { |path| Array(capability["managed_paths"]).include?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Operation detail #{label}")
      end
      schemas.each do |name|
        schema = Support.load_data(File.join(@config.root, "hub", "schemas", name))
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Operation detail #{label}") unless schema["$id"] == "https://flightdeck.dev/schemas/#{name}"
      end
    rescue SystemCallError, ValidationError
      raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Operation detail #{label}")
    end

    def detail_v2(request)
      schemas = %w[operation-detail-v2-request.schema.json operation-detail-v2-result.schema.json operation-detail-v2-error.schema.json]
      verify_capability!(V2_CAPABILITY, schemas, "v2")
      unless request.keys.sort == %w[operation_id schema_version]
        raise ContractError.new("malformed_request", "Operation detail v2 request is invalid")
      end

      operation_id = request.fetch("operation_id").to_s
      binding = OperationAuthoring.new(@config).operation(
        "schema_version" => OperationAuthoring::OPERATION_REQUEST,
        "operation_id" => operation_id
      )
      unless binding["outcome"] == "created" && Support.present?(binding["mission_id"])
        raise ContractError.new("operation_unavailable", "Operation is not bound to a created durable record")
      end

      mission = MissionStore.new(@config, clock: @clock).status(binding.fetch("mission_id"))
      nodes = Array(mission.dig("spec", "graph", "nodes"))
      agents = nodes.map { |node| agent_projection_v2(node) }.sort_by do |agent|
        [agent.fetch("execution_order") || 1_000_000, agent.fetch("node_id")]
      end
      observations = agents.filter_map { |agent| agent.dig("last_observation", "observed_at") }
      criteria = success_criteria_projection(mission, nodes)
      {
        "schema_version" => V2_RESULT,
        "schema" => "hub/schemas/operation-detail-v2-result.schema.json",
        "ok" => true,
        "operation" => {
          "operation_id" => operation_id,
          "classification" => "authored_operation",
          "source" => { "kind" => "mission_record", "source_id" => "mission:#{binding.fetch('mission_id')}" },
          "title" => safe_text(mission.dig("metadata", "title"), 256),
          "status" => operation_state_v2(mission, agents),
          "timestamps" => {
            "created_at" => mission.dig("metadata", "created_at"),
            "updated_at" => mission.dig("metadata", "updated_at"),
            "last_observed_at" => observations.max_by { |value| Time.iso8601(value) }
          },
          "goal" => safe_text(mission.dig("spec", "outcome"), 2048),
          "mode" => mission.dig("spec", "mode"),
          "project_scope" => project_scope_projection(nodes),
          "authorization" => {
            "scope" => "selected_projects_only",
            "boundary_id" => mission.dig("spec", "authorization_boundary"),
            "external_actions_authorized" => false
          },
          "heartbeat" => {
            "stale_after_seconds" => mission.dig("spec", "budgets", "stale_after_seconds")
          },
          "success_criteria" => criteria,
          "progress" => progress_v2(agents),
          "agents" => agents,
          "dependencies" => dependency_projection_v2(nodes),
          "validation" => aggregate_validation(agents),
          "checks" => unavailable_summary,
          "changes" => unavailable_summary,
          "artifacts" => aggregate_artifacts(agents),
          "approvals" => aggregate_approvals(agents),
          "evidence" => aggregate_evidence(agents),
          "result" => aggregate_result(agents),
          "not_performed" => Array(mission.dig("spec", "non_goals")).map { |item| safe_text(item, 1024) }
        }
      }
    rescue KeyError, ValidationError => e
      raise e if e.is_a?(ContractError)
      raise ContractError.new("invalid_hub_state", "Operation detail v2 is invalid")
    end

    def agent_projection(node, criterion_text)
      key = node.fetch("logical_project_key")
      results = Array(node["criterion_results"]).map do |item|
        { "criterion" => criterion_text[item.fetch("criterion_id")] || item.fetch("criterion_id"),
          "disposition" => item.fetch("disposition"), "status_code" => item.fetch("status_code") }
      end
      {
        "agent_id" => node.fetch("id"),
        "name" => agent_name(key),
        "project" => project_label(key),
        "status" => map_state(node.fetch("observed_state")),
        "activity" => node["status_code"] ? node["status_code"].to_s.tr("_", " ") : nil,
        "observed_at" => node["observed_at"],
        "validation" => results,
        "changed_files" => unavailable_evidence,
        "skills" => unavailable_evidence
      }
    end

    def agent_projection_v2(node)
      execution = node["operation_execution"]
      start = node["operation_execution_start"]
      observation = execution&.fetch("observation", nil)
      lifecycle = agent_state_v2(node, execution, observation, start)
      {
        "agent_id" => execution&.fetch("agent_id", nil),
        "node_id" => node.fetch("id"),
        "name" => agent_name(node.fetch("logical_project_key")),
        "logical_project_key" => node.fetch("logical_project_key"),
        "project" => project_label(node.fetch("logical_project_key")),
        "role" => safe_label(node["work_type"] || "operation", 128),
        "dependencies" => Array(node["dependencies"]).sort,
        "execution_order" => execution&.fetch("execution_order", nil),
        "lifecycle" => lifecycle,
        "binding" => { "state" => execution ? execution.fetch("binding_state") : "unavailable" },
        "current_activity" => activity_projection(observation, start),
        "last_observation" => observation_projection(observation),
        "validation" => criterion_results_projection(node),
        "checks" => unavailable_summary,
        "changes" => unavailable_summary,
        "artifacts" => agent_artifacts(node, observation),
        "approvals" => agent_approvals(node, observation, start),
        "result" => agent_result(observation)
      }
    end

    def agent_state_v2(node, execution, observation, start)
      return "stalled" if node["observed_state"] == "stale" && node["status_code"] == "execution_heartbeat_stale"
      return "needs_recovery" if start&.fetch("state", nil) == "retry_authorized"
      return "failed" if start&.fetch("state", nil) == "failed"
      if observation
        return {
          "queued" => "queued", "starting" => "starting", "running" => "working", "waiting" => "waiting",
          "needs_approval" => "approval_required", "blocked" => "waiting", "review_ready" => "review_ready",
          "failed_validation" => "failed", "runtime_failure" => "failed", "cancelled" => "cancelled",
          "unknown_outcome" => "needs_recovery"
        }.fetch(observation.fetch("lifecycle"))
      end
      return execution.fetch("binding_state") == "bound" ? "starting" : "queued" if execution

      case node.fetch("observed_state")
      when "dispatch_unknown" then "needs_recovery"
      when "needs_approval" then "approval_required"
      when "blocked", "awaiting_handoff" then "waiting"
      when "running" then "working"
      when "review_ready" then "review_ready"
      when "failed_validation", "runtime_failure" then "failed"
      when "cancelled" then "cancelled"
      else "queued"
      end
    end

    def operation_state_v2(mission, agents)
      return "completed" if mission.dig("status", "state") == "complete"

      states = agents.map { |agent| agent.fetch("lifecycle") }
      %w[needs_recovery failed approval_required stalled waiting working starting queued].each do |state|
        return state if states.include?(state)
      end
      return "review_ready" if states.all? { |state| state == "review_ready" }
      return "cancelled" if states.all? { |state| state == "cancelled" }

      "needs_recovery"
    end

    def project_scope_projection(nodes)
      nodes.map do |node|
        {
          "logical_project_key" => node.fetch("logical_project_key"),
          "display_name" => project_label(node.fetch("logical_project_key")),
          "execution_mode" => node.fetch("execution_mode"),
          "access_mode" => node.fetch("access_mode"),
          "work_type" => safe_label(node.fetch("work_type"), 128)
        }
      end.uniq.sort_by { |item| item.fetch("logical_project_key") }
    end

    def success_criteria_projection(mission, nodes)
      Array(mission.dig("spec", "success_criteria")).map do |criterion|
        assigned = nodes.select { |node| Array(node["criterion_ids"]).include?(criterion.fetch("id")) }
        results = assigned.flat_map { |node| Array(node["criterion_results"]) }
          .select { |item| item["criterion_id"] == criterion.fetch("id") }
        disposition = results.empty? ? nil : results.map { |item| item.fetch("disposition") }.uniq.one? ? results.first.fetch("disposition") : "degraded"
        {
          "criterion_id" => criterion.fetch("id"),
          "summary" => safe_text(criterion.fetch("text"), 1024),
          "assigned_node_ids" => assigned.map { |node| node.fetch("id") }.sort,
          "assigned_agent_ids" => assigned.filter_map { |node| node.dig("operation_execution", "agent_id") }.sort,
          "disposition" => disposition
        }
      end
    end

    def activity_projection(observation, start = nil)
      latest_failure = start&.fetch("latest_failure", nil) if %w[retry_authorized failed].include?(start&.fetch("state", nil))
      if !observation && latest_failure
        return {
          "availability" => "available",
          "action_summary" => safe_text(latest_failure.fetch("summary"), 512),
          "tool" => nil,
          "observed_at" => latest_failure.fetch("failed_at")
        }
      end
      return { "availability" => "unavailable", "action_summary" => nil, "tool" => nil, "observed_at" => nil } unless observation

      {
        "availability" => observation["action_summary"] || observation["tool"] ? "available" : "unavailable",
        "action_summary" => safe_nullable(observation["action_summary"], 512),
        "tool" => observation["tool"]&.slice("kind", "status"),
        "observed_at" => observation.fetch("observed_at")
      }
    end

    def observation_projection(observation)
      return {
        "availability" => "unavailable", "sequence" => nil, "lifecycle" => nil,
        "observed_at" => nil, "tool" => nil, "subagents" => nil,
        "attention" => nil, "error_code" => nil
      } unless observation

      {
        "availability" => "available",
        "sequence" => observation.fetch("sequence"),
        "lifecycle" => observation.fetch("lifecycle"),
        "observed_at" => observation.fetch("observed_at"),
        "tool" => observation["tool"]&.slice("kind", "status"),
        "subagents" => observation.fetch("subagents"),
        "attention" => observation.fetch("attention"),
        "error_code" => observation["error_code"]
      }
    end

    def criterion_results_projection(node)
      items = Array(node["criterion_results"]).map do |item|
        {
          "criterion_id" => item.fetch("criterion_id"),
          "disposition" => item.fetch("disposition"),
          "status_code" => item.fetch("status_code")
        }
      end
      { "availability" => items.empty? ? "unavailable" : "available", "items" => items }
    end

    def agent_artifacts(node, observation)
      items = Array(node["output_declarations"]).filter_map do |item|
        next unless item.is_a?(Hash) && Support.present?(item["type"])

        { "kind" => "declared_output", "reference" => item["artifact_id"], "label" => safe_nullable(item["type"], 128) }
      end
      Array(observation&.dig("final_result", "evidence_refs")).each do |reference|
        items << { "kind" => "evidence", "reference" => reference, "label" => nil }
      end
      { "availability" => items.empty? ? "unavailable" : "available", "items" => items }
    end

    def agent_approvals(node, observation, start = nil)
      start_failure = start&.fetch("latest_failure", nil) if %w[retry_authorized failed].include?(start&.fetch("state", nil))
      required = observation&.dig("attention", "required") == true || node["observed_state"] == "needs_approval" || !start_failure.nil?
      items = required ? [{
        "state" => "required",
        "code" => observation&.dig("attention", "code") || start_failure&.fetch("failure_code", nil) || node["status_code"],
        "summary" => start_failure ? "Agent start recovery required" : "Operator decision required"
      }] : []
      { "availability" => items.empty? ? "unavailable" : "available", "items" => items }
    end

    def agent_result(observation)
      final = observation&.fetch("final_result", nil)
      return { "availability" => "unavailable", "summary" => nil, "evidence_refs" => [] } unless final

      {
        "availability" => "available",
        "summary" => safe_text(final.fetch("summary"), 2048),
        "evidence_refs" => Array(final["evidence_refs"])
      }
    end

    def dependency_projection_v2(nodes)
      nodes.flat_map do |node|
        Array(node["dependencies"]).map do |source|
          { "from_node_id" => source, "to_node_id" => node.fetch("id") }
        end
      end
    end

    def progress_v2(agents)
      states = %w[queued starting working waiting approval_required review_ready completed failed needs_recovery stalled cancelled]
      { "total" => agents.length, "counts" => states.to_h { |state| [state, agents.count { |agent| agent["lifecycle"] == state }] } }
    end

    def aggregate_validation(agents)
      items = agents.flat_map { |agent| agent.dig("validation", "items") }
      { "availability" => items.empty? ? "unavailable" : "available", "items" => items }
    end

    def aggregate_artifacts(agents)
      items = agents.flat_map { |agent| agent.dig("artifacts", "items") }.uniq
      { "availability" => items.empty? ? "unavailable" : "available", "items" => items }
    end

    def aggregate_approvals(agents)
      items = agents.flat_map { |agent| agent.dig("approvals", "items") }
      { "availability" => items.empty? ? "unavailable" : "available", "items" => items }
    end

    def aggregate_evidence(agents)
      refs = agents.flat_map { |agent| agent.dig("result", "evidence_refs") }.uniq.sort
      { "availability" => refs.empty? ? "unavailable" : "available", "references" => refs }
    end

    def aggregate_result(agents)
      results = agents.map { |agent| agent["result"] }.select { |result| result["availability"] == "available" }
      return { "availability" => "unavailable", "summary" => nil, "evidence_refs" => [] } if results.empty?

      {
        "availability" => "available",
        "summary" => safe_text(results.map { |result| result.fetch("summary") }.join(" "), 2048),
        "evidence_refs" => results.flat_map { |result| result.fetch("evidence_refs") }.uniq.sort
      }
    end

    def unavailable_summary
      { "availability" => "unavailable", "items" => [] }
    end

    def safe_nullable(value, max)
      return nil unless Support.present?(value)

      safe_text(value, max)
    end

    def safe_label(value, max)
      safe_text(value.to_s.tr("_", " "), max)
    end

    def project_label(key)
      declaration = @config.repository_declarations.find { |item| item.dig("codex_project", "logical_key") == key }
      project = @config.codex_project(key)
      safe_text(declaration&.fetch("name", nil) || declaration&.fetch("id", nil) || project&.fetch("display_name", nil) || key, 256)
    end

    def agent_name(key)
      words = key.to_s.split(/[-_.]+/).reject(&:empty?).map(&:capitalize).join(" ")
      safe_text("#{words} Agent", 256)
    end

    def dependency_projection(nodes)
      labels = nodes.to_h { |node| [node.fetch("id"), agent_name(node.fetch("logical_project_key"))] }
      nodes.flat_map do |node|
        Array(node["dependencies"]).map do |source|
          { "from_agent" => labels[source] || source, "to_agent" => labels[node.fetch("id")], "state" => map_state(node.fetch("observed_state")) }
        end
      end
    end

    def artifact_projection(nodes)
      items = nodes.flat_map do |node|
        Array(node["output_declarations"]).filter_map do |item|
          next unless item.is_a?(Hash) && Support.present?(item["type"])
          { "project" => project_label(node.fetch("logical_project_key")), "type" => item.fetch("type"), "label" => item["artifact_id"] }
        end
      end
      { "state" => items.empty? ? "unavailable" : "available", "items" => items }
    end

    def approval_projection(nodes)
      items = nodes.filter_map do |node|
        next unless node["observed_state"] == "needs_approval"
        { "project" => project_label(node.fetch("logical_project_key")), "state" => "required", "summary" => node["status_code"]&.to_s&.tr("_", " ") || "Operator decision required" }
      end
      { "state" => items.empty? ? "none" : "available", "items" => items }
    end

    def validation_totals(nodes)
      totals = { "passed" => 0, "failed" => 0, "blocked" => 0, "degraded" => 0 }
      nodes.each do |node|
        Array(node["criterion_results"]).each { |item| totals[item.fetch("disposition")] += 1 if totals.key?(item["disposition"]) }
      end
      totals
    end

    def result_projection(mission, totals)
      terminal = %w[review_ready failed_validation runtime_failure cancelled complete].include?(mission.dig("status", "state"))
      observed = totals.values.sum
      return { "state" => "unavailable", "summary" => nil } unless terminal && observed.positive?
      summary = "Validated #{observed} criterion result#{observed == 1 ? '' : 's'}: #{totals['passed']} passed, #{totals['failed']} failed, #{totals['blocked']} blocked, and #{totals['degraded']} degraded."
      { "state" => "available", "summary" => summary }
    end

    def progress(nodes)
      counts = %w[queued working waiting approval_required blocked review_ready failed_validation cancelled reconcile_required].to_h { |state| [state, 0] }
      nodes.each { |node| counts[map_state(node.fetch("observed_state"))] += 1 }
      { "total" => nodes.length, "counts" => counts }
    end

    def unavailable_evidence
      { "state" => "unavailable", "items" => [] }
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

    def safe_text(value, max)
      text = value.to_s.strip.gsub(/[\u0000-\u001f\u007f]/, " ").gsub(/\s+/, " ")
      raise ContractError.new("invalid_hub_state", "Operation detail contains invalid display text") if text.empty?
      text[0, max]
    end
  end
end
