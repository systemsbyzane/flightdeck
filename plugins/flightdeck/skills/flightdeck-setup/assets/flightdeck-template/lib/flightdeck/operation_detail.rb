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
    MAX_REQUEST_BYTES = 16_384

    class ContractError < ValidationError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    def initialize(config)
      @config = config
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

    def self.error_result(error)
      code = error.respond_to?(:code) ? error.code : (error.is_a?(UsageError) ? "malformed_request" : "internal_error")
      { "schema_version" => ERROR, "schema" => "hub/schemas/operation-detail-error.schema.json", "ok" => false,
        "error" => { "code" => code, "message" => error.message.to_s[0, 512] } }
    end

    def detail(request)
      verify_capability!
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

      mission = MissionStore.new(@config).status(binding.fetch("mission_id"))
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

    def verify_capability!
      schemas = %w[operation-detail-request.schema.json operation-detail-result.schema.json operation-detail-error.schema.json]
      compatibility_path = File.join(@config.root, "hub", "compatibility.json")
      paths = [compatibility_path, File.join(@config.root, "lib", "flightdeck", "operation_detail.rb")] + schemas.map { |name| File.join(@config.root, "hub", "schemas", name) }
      unless paths.all? { |path| File.file?(path) && !File.symlink?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Operation detail v1")
      end
      capability = Support.load_data(compatibility_path).dig("capabilities", CAPABILITY)
      managed = ["lib/flightdeck/operation_detail.rb"] + schemas.map { |name| "hub/schemas/#{name}" }
      unless capability.is_a?(Hash) && capability["kind"] == "command" && capability.dig("probe", "help_contains") == "bin/flightdeck operation detail " && managed.all? { |path| Array(capability["managed_paths"]).include?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Operation detail v1")
      end
      schemas.each do |name|
        schema = Support.load_data(File.join(@config.root, "hub", "schemas", name))
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Operation detail v1") unless schema["$id"] == "https://flightdeck.dev/schemas/#{name}"
      end
    rescue SystemCallError, ValidationError
      raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Operation detail v1")
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
