# frozen_string_literal: true

require "base64"
require "json"
require_relative "mission_store"

module Flightdeck
  class SkillTelemetry
    API_VERSION = "flightdeck.skill-telemetry/v1"
    CAPABILITY = "flightdeck.command.skill-telemetry.v1"
    SCHEMA = "hub/schemas/skill-telemetry.schema.json"
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100
    CURSOR_PREFIX = "v1."
    FAILURE_STATUSES = %w[failed blocked unknown_outcome].freeze

    class ContractError < Error
      attr_reader :code, :operation_id

      def initialize(code, message, operation_id: nil)
        super(message)
        @code = code
        @operation_id = operation_id
      end
    end

    def initialize(config)
      @config = config
      @store = MissionStore.new(config)
    end

    def snapshot(operation_id:, limit: DEFAULT_LIMIT, cursor: nil)
      verify_capability!
      validate_limit!(limit)
      mission = @store.snapshot(operation_id)
      generation, after_key = decode_cursor(cursor)
      if generation && generation != mission.dig("status", "generation")
        raise ContractError.new("snapshot_changed", "Mission changed; restart telemetry pagination.", operation_id: operation_id)
      end

      all_summaries = summarize(mission)
      if after_key && !all_summaries.any? { |item| skill_key(item) == after_key }
        raise ContractError.new("invalid_cursor", "Telemetry cursor is invalid.", operation_id: operation_id)
      end
      summaries = all_summaries
      summaries = summaries.drop_while { |item| (skill_key(item) <=> after_key) <= 0 } if after_key
      page = summaries.first(limit)
      next_cursor = summaries.length > limit ? encode_cursor(mission.dig("status", "generation"), skill_key(page.last)) : nil
      statuses = all_summaries.map { |item| item["lifecycle_status"] }
      status = operation_status(statuses)
      {
        "api_version" => API_VERSION,
        "kind" => "MissionSkillTelemetrySnapshot",
        "schema" => SCHEMA,
        "capability" => CAPABILITY,
        "operation_id" => mission.dig("metadata", "id"),
        "snapshot_generation" => mission.dig("status", "generation"),
        "status" => status,
        "partial_failure" => status == "partial_failure",
        "counts" => {
          "skills" => all_summaries.length,
          "children" => Array(mission.dig("status", "skill_events")).map { |event| event["node_id"] }.uniq.length,
          "events" => Array(mission.dig("status", "skill_events")).length,
          "failed_skills" => statuses.count { |value| FAILURE_STATUSES.include?(value) }
        },
        "skills" => page,
        "next_cursor" => next_cursor
      }
    rescue ValidationError => e
      code = e.message.include?("mission not found") ? "operation_not_found" : "malformed_operation_record"
      raise ContractError.new(code, "Mission telemetry is unavailable.", operation_id: operation_id)
    rescue UsageError
      raise ContractError.new("invalid_request", "Skill telemetry request is invalid.")
    end

    private

    def summarize(mission)
      groups = Array(mission.dig("status", "skill_events")).group_by { |event| [event["skill_id"], event["skill_version"]] }
      values = groups.map do |(skill_id, skill_version), events|
        children = events.group_by { |event| event["node_id"] }.map do |_node_id, child_events|
          ordered = child_events.sort_by { |event| [event["observed_at"], event["evidence_id"]] }
          first = ordered.first
          latest = ordered.last
          {
            "node_id" => latest["node_id"],
            "task_id" => latest["task_id"],
            "host_id" => latest["host_id"],
            "runtime_project_id" => latest["runtime_project_id"],
            "logical_project_key" => latest["logical_project_key"],
            "project_label" => latest["logical_project_key"],
            "lifecycle_status" => latest["lifecycle_status"],
            "first_observed_at" => first["observed_at"],
            "last_observed_at" => latest["observed_at"],
            "event_count" => ordered.length,
            "latest_evidence_id" => latest["evidence_id"],
            "latest_event_digest" => latest["event_digest"],
            "evidence_source" => latest["evidence_source"]
          }
        end.sort_by { |child| [child["logical_project_key"], child["node_id"], child["task_id"]] }
        {
          "skill_id" => skill_id,
          "skill_version" => skill_version,
          "lifecycle_status" => aggregate_status(children.map { |child| child["lifecycle_status"] }),
          "first_observed_at" => events.map { |event| event["observed_at"] }.min,
          "last_observed_at" => events.map { |event| event["observed_at"] }.max,
          "event_count" => events.length,
          "children" => children
        }
      end.sort_by { |item| skill_key(item) }
      values
    end

    def aggregate_status(statuses)
      return "unknown_outcome" if statuses.include?("unknown_outcome")
      return "failed" if statuses.include?("failed")
      return "blocked" if statuses.include?("blocked")
      return "started" if statuses.include?("started")
      return "succeeded" if statuses.include?("succeeded")

      "completed"
    end

    def operation_status(statuses)
      return "absent" if statuses.empty?
      return "partial_failure" if statuses.any? { |status| FAILURE_STATUSES.include?(status) }
      return "in_progress" if statuses.include?("started")

      "succeeded"
    end

    def verify_capability!
      compatibility_path = File.join(@config.root, "hub", "compatibility.json")
      schema_path = File.join(@config.root, SCHEMA)
      unless File.file?(compatibility_path) && !File.symlink?(compatibility_path) && File.file?(schema_path) && !File.symlink?(schema_path)
        raise ContractError.new("unsupported_hub_contract", "Hub does not declare skill telemetry v1.")
      end
      compatibility = Support.load_data(compatibility_path)
      schema = Support.load_data(schema_path)
      capability = compatibility.dig("capabilities", CAPABILITY)
      unless capability
        raise ContractError.new("unsupported_hub_contract", "Hub does not declare skill telemetry v1.")
      end
      required_paths = ["lib/flightdeck/skill_telemetry.rb", SCHEMA]
      unless compatibility["schema_version"] == "flightdeck.hub-compatibility/v1" &&
             compatibility["product"] == "flightdeck" && capability.is_a?(Hash) &&
             schema["$id"] == "https://flightdeck.dev/schemas/skill-telemetry.schema.json" &&
             capability["kind"] == "command" &&
             capability.dig("probe", "help_contains") == "bin/flightdeck mission skill-telemetry " &&
             required_paths.all? { |path| Array(capability["managed_paths"]).include?(path) }
        raise ContractError.new("incompatible_hub_contract", "Hub skill telemetry capability is incomplete.")
      end
    rescue ConfigurationError, ValidationError, SystemCallError
      raise ContractError.new("incompatible_hub_contract", "Hub skill telemetry capability is malformed.")
    end

    def validate_limit!(limit)
      return if limit.is_a?(Integer) && limit.positive? && limit <= MAX_LIMIT

      raise ContractError.new("invalid_limit", "Limit must be from 1 through #{MAX_LIMIT}.")
    end

    def skill_key(item)
      [item["skill_id"], item["skill_version"].to_s]
    end

    def encode_cursor(generation, key)
      encoded = Base64.urlsafe_encode64(JSON.generate({ "generation" => generation, "after" => key }), padding: false)
      "#{CURSOR_PREFIX}#{encoded}"
    end

    def decode_cursor(cursor)
      return [nil, nil] if cursor.nil?
      value = cursor.to_s
      encoded = value.delete_prefix(CURSOR_PREFIX)
      unless value.bytesize <= 512 && value.start_with?(CURSOR_PREFIX) && encoded.match?(/\A[A-Za-z0-9_-]+\z/)
        raise ContractError.new("invalid_cursor", "Telemetry cursor is invalid.")
      end

      parsed = JSON.parse(Base64.urlsafe_decode64(encoded))
      unless parsed.is_a?(Hash) && parsed.keys.sort == %w[after generation] && parsed["generation"].is_a?(Integer) &&
             parsed["generation"] >= 0 && parsed["after"].is_a?(Array) && parsed["after"].length == 2 &&
             parsed["after"].all? { |part| part.is_a?(String) && part.bytesize <= 128 }
        raise ContractError.new("invalid_cursor", "Telemetry cursor is invalid.")
      end
      [parsed["generation"], parsed["after"]]
    rescue ArgumentError, JSON::ParserError
      raise ContractError.new("invalid_cursor", "Telemetry cursor is invalid.")
    end
  end
end
