# frozen_string_literal: true

require_relative "mission_store"

module Flightdeck
  class MissionSync
    BATCH_FIELDS = %w[api_version kind schema mission_id observed_at observations].freeze
    BASE_OBSERVATION_FIELDS = %w[
      node_id logical_project_key runtime_project_id project_path_digest host_id
      task_id cursor revision event_id observed_state status_code observed_at worktree_ready
    ].freeze
    OPTIONAL_OBSERVATION_FIELDS = %w[skill_events].freeze
    SKILL_EVENT_FIELDS = %w[
      schema_version skill_id skill_version lifecycle_status observed_at evidence_id evidence_source
    ].freeze
    SKILL_LIFECYCLE_STATUSES = %w[started completed succeeded failed blocked unknown_outcome].freeze
    SKILL_EVIDENCE_SOURCE = "codex_task_skill_event"
    MAX_SKILL_EVENTS_PER_OBSERVATION = 100
    MAX_SKILL_EVENTS_PER_MISSION = 1_000
    FINAL_RESULT_STATES = %w[review_ready failed_validation].freeze
    OUTCOME_FIELDS = %w[schema_version code validation output_declarations criterion_results].freeze
    CRITERION_RESULT_FIELDS = %w[criterion_id disposition status_code].freeze
    VALIDATIONS = %w[passed failed not_applicable].freeze
    def initialize(store)
      @store = store
    end

    def plan(slug:, observations_path:)
      mission = @store.snapshot(slug)
      batch, digest = load_batch(observations_path, mission)
      with_plan_token(plan_from(mission, batch, digest), batch)
    end

    def apply(slug:, observations_path:, plan_token: nil)
      unless MissionStore::SHA256.match?(plan_token.to_s)
        raise ValidationError, "sync-apply requires a valid plan_token from sync-plan"
      end
      mission_snapshot = @store.snapshot(slug)
      raw = read_observation_file(observations_path, mission_snapshot)
      digest = Digest::SHA256.hexdigest(raw)
      batch = parse_json(raw, observations_path)
      result = nil
      @store.mutate(slug) do |mission|
        enforce_input_budget!(raw, mission)
        plan = with_plan_token(plan_from(mission, batch, digest), batch)
        unless secure_equal?(plan.fetch("plan_token"), plan_token)
          raise ValidationError, "sync plan_token does not match the locked mission generation, observations, or actions"
        end
        plan.fetch("accepted").each do |change|
          node = mission.dig("spec", "graph", "nodes").find { |item| item["id"] == change["node_id"] }
          node["cursor"] = change["cursor"]
          node["revision"] = change["revision"]
          node["event_id"] = change["event_id"]
          node["event_digest"] = change["event_digest"]
          node["seen_event_ids"] = (Array(node["seen_event_ids"]) + [change["event_id"]]).last(256)
          node["observed_state"] = change["state"]
          node["status_code"] = change["status_code"]
          node["observed_at"] = change["observed_at"]
          node["updated_at"] = change["observed_at"]
          node["outcome_code"] = change["outcome_code"]
          node["validation_status"] = change["validation_status"]
          node["output_declarations"] = change["output_declarations"]
          node["output_refs"] = change["output_refs"]
          node["criterion_results"] = change["criterion_results"]
          merge_skill_events!(mission, change["skill_events"])
          if change["state"] == "runtime_failure"
            node["retries"] = node["retries"].to_i + 1
            maximum = mission.dig("spec", "budgets", "max_retries").to_i
            raise ValidationError, "unit retry budget exhausted for #{node['id']}" if node["retries"] > maximum
          end
        end
        existing_action_keys = mission.dig("status", "outbox").to_h { |action| [action["idempotency_key"], true] }
        actions_added = plan.fetch("actions").count { |action| !existing_action_keys[action["idempotency_key"]] }
        @store.append_actions!(mission, plan.fetch("actions"))
        mission["status"]["state"] = MissionGraph.new(mission.dig("spec", "graph", "nodes")).derive_state(
          current_state: mission.dig("status", "state")
        )
        if plan.fetch("accepted").any? || actions_added.positive?
          mission.dig("status", "history") << {
            "at" => batch.fetch("observed_at"),
            "event" => "sync_applied",
            "source_digest" => digest,
            "accepted" => plan.fetch("accepted").length,
            "ignored" => plan.fetch("ignored").length,
            "actions_added" => actions_added
          }
          mission.dig("status", "history").shift while mission.dig("status", "history").length > 2048
        end
        result = plan.merge(
          "applied" => true,
          "resulting_state" => mission.dig("status", "state")
        )
      end
      result
    end

    private

    def load_batch(path, mission)
      raw = read_observation_file(path, mission)
      [parse_json(raw, path), Digest::SHA256.hexdigest(raw)]
    end

    def read_observation_file(path, mission)
      stat = File.lstat(path)
      raise ValidationError, "observation path must be a regular file: #{path}" unless stat.file?
      raise ValidationError, "observation file is unreadable: #{path}" unless File.readable?(path)

      maximum = mission.dig("spec", "budgets", "max_forwarded_bytes").to_i
      size = File.size(path)
      raise ValidationError, "observation input exceeds max_forwarded_bytes budget" if size > maximum

      raw = File.binread(path)
      enforce_input_budget!(raw, mission)
      raw
    rescue Errno::ENOENT
      raise ValidationError, "observation file does not exist: #{path}"
    rescue SystemCallError => e
      raise ValidationError, "observation file is unreadable: #{path} (#{e.class})"
    end

    def parse_json(raw, path)
      value = JSON.parse(raw)
      raise ValidationError, "observation file must contain a mapping" unless value.is_a?(Hash)

      Support.stringify(value)
    rescue JSON::ParserError => e
      raise ValidationError, "#{path} is invalid JSON: #{e.message}"
    end

    def enforce_input_budget!(raw, mission)
      maximum = mission.dig("spec", "budgets", "max_forwarded_bytes").to_i
      raise ValidationError, "observation input exceeds max_forwarded_bytes budget" if raw.bytesize > maximum
    end

    def plan_from(mission, batch, digest)
      validate_batch!(batch, mission)
      raise ValidationError, "dispatch_only missions do not monitor or sync" if mission.dig("spec", "mode") == "dispatch_only"
      @store.enforce_sync_ready!(mission)
      pending_worktree = mission.dig("spec", "graph", "nodes").find do |node|
        node["execution_mode"] == "worktree" && !Support.present?(node["task_id"])
      end
      if pending_worktree
        raise ValidationError, "worktree creation is pending or unknown for #{pending_worktree['id']}"
      end

      simulated = Support.stringify(mission)
      accepted = []
      ignored = []
      batch.fetch("observations").each do |observation|
        node = simulated.dig("spec", "graph", "nodes").find { |item| item["id"] == observation["node_id"] }
        if observation["observed_state"] == "notLoaded"
          ignored << {
            "node_id" => observation["node_id"],
            "event_id" => observation["event_id"],
            "reason" => "not_loaded"
          }
          next
        end
        reason = stale_reason(node, observation)
        if reason
          ignored << {
            "node_id" => observation["node_id"],
            "event_id" => observation["event_id"],
            "reason" => reason
          }
          next
        end

        state = observation["observed_state"]
        declarations = observation.dig("outcome", "output_declarations") || []
        skill_events = materialize_skill_events(node, observation["skill_events"] || [])
        output_refs = declarations.empty? ? [] : @store.materialize_output_refs(node, declarations)
        change = {
          "node_id" => observation["node_id"],
          "cursor" => observation["cursor"],
          "revision" => observation["revision"],
          "event_id" => observation["event_id"],
          "state" => state,
          "status_code" => observation["status_code"],
          "observed_at" => observation["observed_at"],
          "outcome_code" => observation.dig("outcome", "code"),
          "validation_status" => observation.dig("outcome", "validation"),
          "output_declarations" => declarations,
          "output_refs" => output_refs,
          "criterion_results" => observation.dig("outcome", "criterion_results") || [],
          "skill_events" => skill_events
        }
        change["event_digest"] = @store.observation_event_digest(change)
        if state == "runtime_failure" && node["retries"].to_i + 1 > mission.dig("spec", "budgets", "max_retries").to_i
          raise ValidationError, "unit retry budget exhausted for #{node['id']}"
        end
        accepted << change
        node["cursor"] = change["cursor"]
        node["revision"] = change["revision"]
        node["event_id"] = change["event_id"]
        node["event_digest"] = change["event_digest"]
        node["seen_event_ids"] = (Array(node["seen_event_ids"]) + [change["event_id"]]).last(256)
        node["observed_state"] = state
        node["status_code"] = change["status_code"]
        node["observed_at"] = change["observed_at"]
        node["outcome_code"] = change["outcome_code"]
        node["validation_status"] = change["validation_status"]
        node["output_declarations"] = change["output_declarations"]
        node["output_refs"] = change["output_refs"]
        node["criterion_results"] = change["criterion_results"]
        simulated["status"]["skill_events"] = merged_skill_events(simulated, change["skill_events"])
      end
      actions = coordination_actions(simulated, accepted)
      existing_keys = mission.dig("status", "outbox").to_h { |action| [action["idempotency_key"], true] }
      new_actions = actions.count { |action| !existing_keys[action["idempotency_key"]] }
      maximum_actions = mission.dig("spec", "budgets", "max_actions").to_i
      if mission.dig("status", "outbox").length + new_actions > maximum_actions
        raise ValidationError, "mission action budget exhausted (max #{maximum_actions})"
      end
      {
        "schema_version" => "flightdeck.mission-sync-plan/v1",
        "mission_id" => mission.dig("metadata", "id"),
        "base_generation" => mission.dig("status", "generation"),
        "source_digest" => digest,
        "read_only" => true,
        "accepted" => accepted,
        "ignored" => ignored,
        "actions" => actions,
        "resulting_state" => MissionGraph.new(simulated.dig("spec", "graph", "nodes")).derive_state(
          current_state: simulated.dig("status", "state")
        )
      }
    end

    def validate_batch!(batch, mission)
      exact_keys!(batch, BATCH_FIELDS, "observation batch")
      raise ValidationError, "observation api_version is invalid" unless batch["api_version"] == "flightdeck.dev/v1alpha1"
      raise ValidationError, "observation kind must be MissionObservationBatch" unless batch["kind"] == "MissionObservationBatch"
      unless batch["schema"] == "hub/schemas/mission-observation.schema.json"
        raise ValidationError, "observation schema is invalid"
      end
      unless batch["mission_id"] == mission.dig("metadata", "id")
        raise ValidationError, "observation mission identity drift"
      end
      parse_time!(batch["observed_at"], "observation batch observed_at")
      observations = batch["observations"]
      raise ValidationError, "observations must be a list" unless observations.is_a?(Array)
      raise ValidationError, "observation count exceeds max_units budget" if observations.length > mission.dig("spec", "budgets", "max_units").to_i

      seen_nodes = {}
      observations.each_with_index do |observation, index|
        raise ValidationError, "observation #{index} must be a mapping" unless observation.is_a?(Hash)
        final_result = FINAL_RESULT_STATES.include?(observation["observed_state"].to_s)
        required_fields = final_result ? BASE_OBSERVATION_FIELDS + ["outcome"] : BASE_OBSERVATION_FIELDS
        allowed_fields = required_fields + OPTIONAL_OBSERVATION_FIELDS
        exact_required_keys!(observation, required_fields, allowed_fields, "observation #{index}")
        node = mission.dig("spec", "graph", "nodes").find { |item| item["id"] == observation["node_id"] }
        raise ValidationError, "observation references unknown node #{observation['node_id']}" unless node
        raise ValidationError, "duplicate observation for node #{observation['node_id']}" if seen_nodes[observation["node_id"]]
        seen_nodes[observation["node_id"]] = true
        validate_identity!(node, observation)
        validate_sequence!(observation)
        validate_skill_events!(observation["skill_events"] || [], index)
        validate_outcome!(node, observation) if final_result
      end
    end

    def validate_skill_events!(events, observation_index)
      raise ValidationError, "observation #{observation_index} skill_events must be a list" unless events.is_a?(Array)
      if events.length > MAX_SKILL_EVENTS_PER_OBSERVATION
        raise ValidationError, "observation #{observation_index} skill_events exceeds #{MAX_SKILL_EVENTS_PER_OBSERVATION}"
      end
      evidence_ids = {}
      events.each_with_index do |event, event_index|
        raise ValidationError, "skill event #{event_index} must be a mapping" unless event.is_a?(Hash)
        exact_keys!(event, SKILL_EVENT_FIELDS, "skill event #{event_index}")
        unless event["schema_version"] == "flightdeck.skill-invocation-event/v1"
          raise ValidationError, "skill event #{event_index} schema_version is invalid"
        end
        validate_bounded_identifier!(event["skill_id"], "skill event #{event_index} skill_id")
        if event["skill_version"]
          unless event["skill_version"].is_a?(String) && event["skill_version"].match?(/\A[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\z/)
            raise ValidationError, "skill event #{event_index} skill_version is invalid"
          end
        end
        unless SKILL_LIFECYCLE_STATUSES.include?(event["lifecycle_status"])
          raise ValidationError, "skill event #{event_index} lifecycle_status is invalid"
        end
        parse_time!(event["observed_at"], "skill event #{event_index} observed_at")
        validate_opaque_event_id!(event["evidence_id"], "skill event #{event_index} evidence_id")
        unless event["evidence_source"] == SKILL_EVIDENCE_SOURCE
          raise ValidationError, "skill event #{event_index} evidence_source is invalid"
        end
        if evidence_ids[event["evidence_id"]]
          raise ValidationError, "duplicate skill evidence_id #{event['evidence_id']} in observation"
        end
        evidence_ids[event["evidence_id"]] = true
      end
    end

    def materialize_skill_events(node, events)
      events.map do |event|
        materialized = {
          "schema_version" => event["schema_version"],
          "skill_id" => event["skill_id"],
          "skill_version" => event["skill_version"],
          "lifecycle_status" => event["lifecycle_status"],
          "observed_at" => Time.iso8601(event["observed_at"]).utc.iso8601,
          "evidence_id" => event["evidence_id"],
          "evidence_source" => event["evidence_source"],
          "node_id" => node["id"],
          "logical_project_key" => node["logical_project_key"],
          "runtime_project_id" => node["runtime_project_id"],
          "host_id" => node["host_id"],
          "task_id" => node["task_id"]
        }
        materialized["event_digest"] = Digest::SHA256.hexdigest(JSON.generate(materialized.sort.to_h))
        materialized
      end
    end

    def merged_skill_events(mission, incoming)
      existing = Array(mission.dig("status", "skill_events"))
      by_id = existing.to_h { |event| [[event["node_id"], event["task_id"], event["evidence_id"]], event] }
      incoming.each do |event|
        key = [event["node_id"], event["task_id"], event["evidence_id"]]
        prior = by_id[key]
        if prior && prior != event
          raise ValidationError, "conflicting skill evidence_id #{event['evidence_id']}"
        end
        by_id[key] = event
      end
      merged = by_id.values.sort_by do |event|
        [event["observed_at"], event["node_id"], event["task_id"], event["evidence_id"]]
      end
      if merged.length > MAX_SKILL_EVENTS_PER_MISSION
        raise ValidationError, "mission skill event budget exhausted (max #{MAX_SKILL_EVENTS_PER_MISSION})"
      end
      merged
    end

    def merge_skill_events!(mission, incoming)
      mission["status"]["skill_events"] = merged_skill_events(mission, incoming)
    end

    def validate_opaque_event_id!(value, label)
      unless value.is_a?(String) && !value.empty? && value.bytesize <= 512 && !value.match?(/[\u0000-\u001f\u007f]/)
        raise ValidationError, "#{label} must be an opaque non-control string up to 512 bytes"
      end
    end

    def validate_identity!(node, observation)
      {
        "logical_project_key" => "logical project",
        "runtime_project_id" => "runtime project",
        "project_path_digest" => "project path digest",
        "host_id" => "host",
        "task_id" => "task"
      }.each do |field, label|
        unless Support.present?(node[field]) && observation[field] == node[field]
          raise ValidationError, "observation #{label} identity drift for #{node['id']}"
        end
      end
      if node["execution_mode"] == "worktree" && observation["worktree_ready"] != true
        raise ValidationError, "worktree creation is not confirmed for #{node['id']}"
      end
      unless [true, false].include?(observation["worktree_ready"])
        raise ValidationError, "observation worktree_ready must be boolean"
      end
    end

    def validate_sequence!(observation)
      %w[cursor event_id].each do |field|
        value = observation[field]
        unless value.is_a?(String) && !value.empty? && value.bytesize <= 512 && !value.match?(/[\u0000-\u001f\u007f]/)
          raise ValidationError, "observation #{field} must be an opaque non-control string up to 512 bytes"
        end
      end
      revision = observation["revision"]
      raise ValidationError, "observation revision must be a non-negative integer" unless revision.is_a?(Integer) && revision >= 0
      parse_time!(observation["observed_at"], "observation observed_at")
      unless MissionGraph::OBSERVED_STATES.include?(observation["observed_state"].to_s)
        raise ValidationError, "unknown observed state #{observation['observed_state']}; idle, done, and complete are not completion"
      end
      validate_bounded_identifier!(observation["status_code"], "observation status_code")
    end

    def validate_outcome!(node, observation)
      outcome = observation["outcome"]
      raise ValidationError, "observation outcome must be a mapping" unless outcome.is_a?(Hash)
      exact_keys!(outcome, OUTCOME_FIELDS, "observation outcome")
      unless outcome["schema_version"] == "flightdeck.child-outcome/v1"
        raise ValidationError, "child outcome schema_version is invalid"
      end
      validate_bounded_identifier!(outcome["code"], "child outcome code")
      unless observation["status_code"] == outcome["code"]
        raise ValidationError, "final observation status_code must equal child outcome code"
      end
      raise ValidationError, "child outcome validation is invalid" unless VALIDATIONS.include?(outcome["validation"])
      state = observation["observed_state"]
      if state == "failed_validation" && outcome["validation"] != "failed"
        raise ValidationError, "failed_validation observation requires failed outcome validation"
      end
      if state == "review_ready" && outcome["validation"] != "passed"
        raise ValidationError, "review_ready observation requires passed outcome validation"
      end
      criterion_results = outcome["criterion_results"]
      raise ValidationError, "child outcome criterion_results must be a list" unless criterion_results.is_a?(Array)
      expected_criterion_ids = Array(node["criterion_ids"])
      actual_criterion_ids = []
      criterion_results.each_with_index do |result, index|
        raise ValidationError, "criterion result #{index} must be a mapping" unless result.is_a?(Hash)
        exact_keys!(result, CRITERION_RESULT_FIELDS, "criterion result #{index}")
        validate_bounded_identifier!(result["criterion_id"], "criterion result ID")
        validate_bounded_identifier!(result["status_code"], "criterion result status_code")
        unless MissionStore::CRITERION_DISPOSITIONS.include?(result["disposition"])
          raise ValidationError, "criterion result #{index} disposition is invalid"
        end
        actual_criterion_ids << result["criterion_id"]
      end
      unless actual_criterion_ids == expected_criterion_ids
        raise ValidationError, "child outcome criterion_results must exactly match assigned criterion IDs in order"
      end
      if state == "review_ready" && criterion_results.any? { |result| result["disposition"] != "passed" }
        raise ValidationError, "review_ready observation requires every assigned criterion to pass"
      end
      if state == "failed_validation" && criterion_results.all? { |result| result["disposition"] == "passed" }
        raise ValidationError, "failed_validation observation requires at least one unmet criterion"
      end
      declarations = outcome["output_declarations"]
      raise ValidationError, "child outcome output_declarations must be a list" unless declarations.is_a?(Array)
      if state == "review_ready" && declarations.empty?
        raise ValidationError, "review_ready observation requires at least one typed output declaration"
      end
      @store.materialize_output_refs(node, declarations) unless declarations.empty?
      bytes = JSON.generate(declarations).bytesize
      maximum = @store.config.mission_budgets.fetch("max_forwarded_bytes")
      raise ValidationError, "child outcome output_declarations exceed max_forwarded_bytes" if bytes > maximum
    end

    def stale_reason(node, observation)
      return "duplicate_event_id" if Array(node["seen_event_ids"]).include?(observation["event_id"])
      current_revision = node["revision"]
      return nil if current_revision.nil?
      return "stale_revision" if observation["revision"] < current_revision
      if observation["revision"] == current_revision
        if observation["cursor"] == node["cursor"] && observation["event_id"] == node["event_id"]
          return "duplicate_cursor_revision"
        end
        raise ValidationError, "conflicting non-monotonic observation for #{node['id']}"
      end
      return "stale_cursor" if observation["cursor"] == node["cursor"]

      nil
    end

    def coordination_actions(mission, accepted)
      return [] if accepted.empty?

      mode = mission.dig("spec", "mode")
      nodes = mission.dig("spec", "graph", "nodes")
      graph = MissionGraph.new(nodes)
      actions = []
      accepted.each do |change|
        next unless change["state"] == "dispatch_unknown"
        actions << @store.action_record(
          mission,
          type: "observe",
          payload: { "node_id" => change["node_id"], "reason" => "dispatch_unknown" },
          trigger: "#{change['event_id']}:#{change['status_code']}"
        )
      end
      if mode == "supervised"
        nodes.each do |consumer|
          next if consumer["dependencies"].empty? || !graph.dependencies_ready?(consumer)
          state = consumer["observed_state"]
          next unless state == "planned"

          dependencies = nodes.select { |node| consumer["dependencies"].include?(node["id"]) }
          refs = @store.handoffable_dependency_refs(mission, consumer)
          next unless refs
          actions << @store.action_record(
            mission,
            type: "dependency_handoff",
            payload: {
              "node_id" => consumer["id"],
              "dependency_node_ids" => consumer["dependencies"].sort,
              "output_refs" => refs,
              "artifact_resolver" => refs.any? { |ref| ref["ref"].to_s.start_with?("artifact:") } ? consumer["artifact_resolver"] : nil
            },
            trigger: dependencies.map { |node| "#{node['event_id']}:#{node['event_digest']}:#{node['status_code']}" }.join(":")
          )
        end
      end
      if @store.fan_in_ready?(mission)
        required = graph.required_nodes.sort_by { |node| node["id"] }
        actions << @store.action_record(
          mission,
          type: "offer_fan_in",
          payload: { "required_node_ids" => required.map { |node| node["id"] } },
          trigger: required.map { |node| "#{node['event_id']}:#{node['event_digest']}:#{node['status_code']}" }.join(":")
        )
      end
      actions
    end

    def with_plan_token(plan, batch)
      token_input = {
        "mission_id" => plan.fetch("mission_id"),
        "base_generation" => plan.fetch("base_generation"),
        "source_digest" => plan.fetch("source_digest"),
        "observation_hashes" => batch.fetch("observations").map do |observation|
          Digest::SHA256.hexdigest(canonical_json(observation))
        end,
        "event_ids" => batch.fetch("observations").map { |observation| observation["event_id"] },
        "accepted" => plan.fetch("accepted"),
        "ignored" => plan.fetch("ignored"),
        "actions" => plan.fetch("actions").map do |action|
          action.slice("id", "type", "idempotency_key", "trigger_digest", "authorization_boundary", "payload")
        end,
        "resulting_state" => plan.fetch("resulting_state")
      }
      plan.merge("plan_token" => Digest::SHA256.hexdigest(canonical_json(token_input)))
    end

    def canonical_json(value)
      normalized = case value
                   when Hash
                     value.keys.map(&:to_s).sort.to_h { |key| [key, canonical_value(value[key])] }
                   else
                     canonical_value(value)
                   end
      JSON.generate(normalized)
    end

    def canonical_value(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.to_h { |key| [key, canonical_value(value[key])] }
      when Array
        value.map { |item| canonical_value(item) }
      else
        value
      end
    end

    def secure_equal?(left, right)
      return false unless left.bytesize == right.to_s.bytesize

      left.bytes.zip(right.to_s.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
    end

    def validate_bounded_identifier!(value, label)
      Support.validate_identifier!(value, label: label)
      raise UsageError, "#{label} exceeds 128 bytes" if value.to_s.bytesize > 128
    rescue UsageError => e
      raise ValidationError, e.message
    end

    def exact_keys!(value, expected, label)
      missing = expected.reject { |field| value.key?(field) }
      unknown = value.keys - expected
      raise ValidationError, "#{label} missing fields: #{missing.join(', ')}" unless missing.empty?
      raise ValidationError, "#{label} contains forbidden fields: #{unknown.join(', ')}" unless unknown.empty?
    end

    def exact_required_keys!(value, required, allowed, label)
      keys = value.keys.map(&:to_s)
      missing = required - keys
      extra = keys - allowed
      raise ValidationError, "#{label} missing fields: #{missing.join(', ')}" unless missing.empty?
      raise ValidationError, "#{label} contains forbidden fields: #{extra.join(', ')}" unless extra.empty?
    end

    def parse_time!(value, label)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      raise ValidationError, "#{label} must be an ISO 8601 timestamp"
    end
  end
end
