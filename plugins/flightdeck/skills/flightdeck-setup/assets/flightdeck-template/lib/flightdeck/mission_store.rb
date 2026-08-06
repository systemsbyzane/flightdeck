# frozen_string_literal: true

require "digest"
require "base64"
require_relative "mission_graph"

module Flightdeck
  class MissionStore
    MODES = %w[dispatch_only watch_only supervised].freeze
    EXECUTION_MODES = %w[local worktree].freeze
    ACTION_TYPES = %w[observe dependency_handoff offer_fan_in].freeze
    ACTION_STATES = %w[pending prepared acknowledged failed].freeze
    ARTIFACT_RESOLVER_KINDS = %w[same_host_workspace external_approved].freeze
    CRITERION_DISPOSITIONS = %w[passed failed blocked degraded].freeze
    AUTHORIZED_TARGET_FIELDS = %w[
      logical_project_key runtime_project_id project_path_digest host_id execution_mode access_mode
    ].freeze
    SECRET_KEY = /(?:secret|password|credential|access[_-]?token|private[_-]?key|kubeconfig)/i
    SECRET_VALUE = /(?:-----BEGIN [A-Z ]*PRIVATE KEY-----|\bAKIA[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bBearer\s+[A-Za-z0-9._~+\/-]{16,})/
    SHA256 = /\A[0-9a-f]{64}\z/
    SAFE_ID_SOURCE = "[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?"
    TASK_BINDING_SOURCE = "[A-Za-z0-9_-]+"
    TERMINAL_REF = /\A(?:check|review):[A-Za-z0-9][A-Za-z0-9._~:\/#@+-]{0,1534}\z/
    OUTPUT_REF = /\A(?:codex-task:#{SAFE_ID_SOURCE}\/#{TASK_BINDING_SOURCE}|artifact:#{SAFE_ID_SOURCE}\/#{SAFE_ID_SOURCE}\/#{TASK_BINDING_SOURCE}\/[0-9a-f]{64}\/#{SAFE_ID_SOURCE}|(?:check|review):[A-Za-z0-9][A-Za-z0-9._~:\/#@+-]{0,1534})\z/
    REQUIRED_NODE_FIELDS = %w[
      id logical_project_key runtime_project_id project_path project_path_digest
      host_id task_id pending_client_id execution_mode access_mode work_type required dependencies
      accepted_input_types allowed_output_types authorization_boundary artifact_resolver cursor revision
      event_id event_digest seen_event_ids observed_state retries created_at updated_at dispatched_at
      observed_at status_code outcome_code validation_status output_declarations output_refs criterion_ids criterion_results
    ].freeze
    REQUIRED_ACTION_FIELDS = %w[
      id type idempotency_key trigger_digest authorization_boundary status payload attempts created_at
      updated_at prepared_at acknowledged_at failure_code
    ].freeze

    attr_reader :config

    def initialize(config, clock: -> { Time.now.utc })
      @config = config
      @clock = clock
    end

    def create(slug:, title:, outcome:, mode: nil, success_criteria: nil, non_goals: [],
               authorized_targets: [])
      Support.validate_slug!(slug, label: "mission slug")
      validate_text!(title, "--title", max: 256)
      validate_text!(outcome, "--outcome", max: 2048)
      selected_mode = (mode || config.mission_defaults.fetch("default_mode", "dispatch_only")).to_s
      raise UsageError, "unknown mission mode: #{selected_mode}" unless MODES.include?(selected_mode)
      criterion_texts = Array(success_criteria).map { |value| normalize_bounded_text!(value, "success criterion") }
      if criterion_texts.empty? && selected_mode == "dispatch_only"
        criterion_texts = [outcome.to_s.strip]
      elsif criterion_texts.empty?
        raise UsageError, "at least one --success-criterion is required for #{selected_mode} missions"
      end
      goals_excluded = Array(non_goals).map { |value| normalize_bounded_text!(value, "non-goal") }
      raise UsageError, "success criteria must be unique" unless criterion_texts.uniq.length == criterion_texts.length
      raise UsageError, "non-goals must be unique" unless goals_excluded.uniq.length == goals_excluded.length
      criteria = criterion_texts.each_with_index.map do |text, index|
        { "id" => format("criterion-%03d", index + 1), "text" => text }
      end
      targets = normalize_authorized_targets!(authorized_targets)
      if selected_mode != "dispatch_only" && targets.empty?
        raise UsageError, "at least one --authorized-target-json is required for #{selected_mode} missions"
      end
      authorization_boundary = derive_authorization_boundary(slug, targets, criteria, goals_excluded)

      now = timestamp
      mission = {
        "api_version" => "flightdeck.dev/v1alpha1",
        "kind" => "MissionRecord",
        "schema" => "hub/schemas/mission.schema.json",
        "metadata" => {
          "id" => slug,
          "title" => title.to_s.strip,
          "created_at" => now,
          "updated_at" => now
        },
        "spec" => {
          "mode" => selected_mode,
          "outcome" => outcome.to_s.strip,
          "success_criteria" => criteria,
          "non_goals" => goals_excluded,
          "authorized_targets" => targets,
          "authorization_boundary" => authorization_boundary,
          "budgets" => config.mission_budgets,
          "graph" => { "nodes" => [] }
        },
        "status" => {
          "state" => "planned",
          "generation" => 0,
          "closed_at" => nil,
          "checkpoint" => { "number" => 0, "at" => nil, "generation" => 0 },
          "outbox" => [],
          "history" => [
            { "at" => now, "event" => "created", "state" => "planned" }
          ]
        }
      }
      validate_or_raise!(mission, expected_slug: slug)

      FileUtils.mkdir_p(config.mission_dir)
      root_lock = File.join(config.mission_dir, ".lock")
      with_file_lock(root_lock, File::LOCK_EX) do
        directory = mission_dir(slug)
        raise ValidationError, "mission already exists: #{slug}" if File.exist?(directory)

        Dir.mkdir(directory, 0o700)
        begin
          Support.atomic_yaml(mission_path(slug), mission)
        rescue StandardError
          Dir.rmdir(directory) if Dir.exist?(directory) && Dir.empty?(directory)
          raise
        end
      end
      mission
    end

    # Builds and validates a complete Mission without persisting it. This is the
    # service-side preview boundary used by typed authoring clients.
    def preview_complete(slug:, title:, outcome:, mode: nil, success_criteria: nil, non_goals: [],
                         authorized_targets: [], nodes: [])
      mission = build_complete_mission(
        slug: slug,
        title: title,
        outcome: outcome,
        mode: mode,
        success_criteria: success_criteria,
        non_goals: non_goals,
        authorized_targets: authorized_targets,
        nodes: nodes
      )
      validate_or_raise!(mission, expected_slug: slug)
      mission
    end

    # Persists the already-complete graph as one Mission record. No partial
    # Mission is visible if graph construction or the final atomic write fails.
    def create_complete(slug:, title:, outcome:, mode: nil, success_criteria: nil, non_goals: [],
                        authorized_targets: [], nodes: [], authoring_binding: nil)
      mission = preview_complete(
        slug: slug,
        title: title,
        outcome: outcome,
        mode: mode,
        success_criteria: success_criteria,
        non_goals: non_goals,
        authorized_targets: authorized_targets,
        nodes: nodes
      )
      if authoring_binding
        value = Support.stringify(authoring_binding)
        required = %w[operation_digest plan_id plan_digest]
        unless value.keys.sort == required.sort &&
               MissionStore::SHA256.match?(value["operation_digest"].to_s) &&
               MissionStore::SHA256.match?(value["plan_digest"].to_s) &&
               value["plan_id"].to_s.match?(/\Aplan-[0-9a-f]{48}\z/)
          raise UsageError, "Mission authoring binding is invalid"
        end
        mission["metadata"]["authoring"] = required.to_h { |field| [field, value.fetch(field)] }
      end
      validate_or_raise!(mission, expected_slug: slug)
      persist_complete_mission!(mission)
    end

    def fetch(slug)
      Support.validate_slug!(slug, label: "mission slug")
      path = mission_path(slug)
      raise ValidationError, "mission does not exist: #{slug}" unless File.file?(path)

      value = Support.load_data(path)
      raise ValidationError, "mission #{slug} must contain a mapping" unless value.is_a?(Hash)

      value
    end

    def snapshot(slug)
      with_lock(slug, shared: true) do
        mission = fetch(slug)
        validate_or_raise!(mission, expected_slug: slug)
        mission
      end
    end

    def add_node(slug:, node_id:, logical_project_key:, project_path: nil, project_path_digest: nil,
                 runtime_project_id:, host_id:, execution_mode:, access_mode:, work_type:, required:,
                 dependencies: [], accepted_input_types: [], allowed_output_types:,
                 artifact_resolver_kind: nil, artifact_resolver_id: nil, criterion_ids: nil)
      mutate(slug) do |mission|
        enforce_open!(mission)
        enforce_duration!(mission)
        enforce_graph_mutable!(mission)
        Support.validate_identifier!(node_id, label: "node ID")
        Support.validate_identifier!(logical_project_key, label: "logical project key")
        validate_opaque!(runtime_project_id, "runtime project ID")
        validate_opaque!(host_id, "host ID")
        Support.validate_identifier!(work_type, label: "work type")
        raise UsageError, "execution mode must be local or worktree" unless EXECUTION_MODES.include?(execution_mode.to_s)
        raise UsageError, "access mode must be read_only or write" unless %w[read_only write].include?(access_mode.to_s)
        raise UsageError, "choose exactly one of --project-path or --project-path-digest" if !!project_path == !!project_path_digest
        path, digest = normalize_project_identity(project_path, project_path_digest)
        boundary = mission.dig("spec", "authorization_boundary")
        target = {
          "logical_project_key" => logical_project_key.to_s,
          "runtime_project_id" => runtime_project_id.to_s,
          "project_path_digest" => digest,
          "host_id" => host_id.to_s,
          "execution_mode" => execution_mode.to_s,
          "access_mode" => access_mode.to_s
        }
        unless mission.dig("spec", "authorized_targets").include?(target)
          raise ValidationError, "node #{node_id} is outside the mission authorized target scope"
        end
        artifact_resolver = normalize_artifact_resolver!(artifact_resolver_kind, artifact_resolver_id)
        known_criteria = mission.dig("spec", "success_criteria").map { |criterion| criterion["id"] }
        raw_assignments = Array(criterion_ids).map(&:to_s)
        raise UsageError, "criterion IDs must be unique" unless raw_assignments.uniq.length == raw_assignments.length
        assignments = if criterion_ids.nil? && mission.dig("spec", "mode") == "dispatch_only" && required == true
                        known_criteria
                      else
                        raw_assignments
                      end
        assignments.each { |id| Support.validate_identifier!(id, label: "criterion ID") }
        unknown_criteria = assignments - known_criteria
        raise UsageError, "unknown criterion IDs: #{unknown_criteria.join(', ')}" unless unknown_criteria.empty?
        if required == true && assignments.empty?
          raise UsageError, "required nodes must declare at least one --criterion-id"
        end
        deps = Array(dependencies).map(&:to_s).uniq
        deps.each { |id| Support.validate_identifier!(id, label: "dependency node ID") }
        accepts = Array(accepted_input_types).map(&:to_s).uniq
        outputs = Array(allowed_output_types).map(&:to_s).uniq
        accepts.each { |value| Support.validate_identifier!(value, label: "accepted input type") }
        outputs.each { |value| Support.validate_identifier!(value, label: "allowed output type") }
        raise UsageError, "at least one --allows-output is required" if outputs.empty?
        raise UsageError, "a node with dependencies requires at least one --accepts" if deps.any? && accepts.empty?
        nodes = mission.dig("spec", "graph", "nodes")
        raise ValidationError, "mission node already exists: #{node_id}" if nodes.any? { |node| node["id"] == node_id }
        max_units = mission.dig("spec", "budgets", "max_units").to_i
        raise ValidationError, "mission unit budget exhausted (max #{max_units})" if nodes.length >= max_units

        now = timestamp
        nodes << {
          "id" => node_id,
          "logical_project_key" => logical_project_key,
          "runtime_project_id" => runtime_project_id.to_s,
          "project_path" => path,
          "project_path_digest" => digest,
          "host_id" => host_id,
          "task_id" => nil,
          "pending_client_id" => nil,
          "execution_mode" => execution_mode.to_s,
          "access_mode" => access_mode.to_s,
          "work_type" => work_type,
          "required" => required,
          "dependencies" => deps,
          "accepted_input_types" => accepts,
          "allowed_output_types" => outputs,
          "authorization_boundary" => boundary,
          "artifact_resolver" => artifact_resolver,
          "criterion_ids" => assignments,
          "cursor" => nil,
          "revision" => nil,
          "event_id" => nil,
          "event_digest" => nil,
          "seen_event_ids" => [],
          "observed_state" => "planned",
          "retries" => 0,
          "created_at" => now,
          "updated_at" => now,
          "dispatched_at" => nil,
          "observed_at" => nil,
          "status_code" => nil,
          "outcome_code" => nil,
          "validation_status" => nil,
          "output_declarations" => [],
          "output_refs" => [],
          "criterion_results" => []
        }
        graph_errors = MissionGraph.new(nodes).validate
        raise ValidationError, graph_errors.join("; ") unless graph_errors.empty?

        record_event!(mission, "node_added", "node_id" => node_id)
        derive_state!(mission)
      end
    end

    def record_dispatch(slug:, node_id:, runtime_project_id:, host_id:, task_id: nil,
                        pending_client_id: nil, project_path: nil, project_path_digest: nil,
                        dispatch_unknown: false)
      mutate(slug) do |mission|
        enforce_open!(mission)
        enforce_duration!(mission)
        enforce_criterion_coverage!(mission)
        node = find_node!(mission, node_id)
        raise ValidationError, "node #{node_id} dependencies are not ready" unless MissionGraph.new(nodes(mission)).dependencies_ready?(node) || node["dependencies"].empty?
        unless %w[planned dispatch_pending dispatch_unknown awaiting_handoff running].include?(node["observed_state"])
          raise ValidationError, "node #{node_id} is not dispatchable from #{node['observed_state']}"
        end
        raise ValidationError, "node #{node_id} is stale and non-actionable" if stale_delivery_target?(node, mission)
        validate_opaque!(runtime_project_id, "runtime project ID")
        validate_opaque!(host_id, "host ID")
        raise ValidationError, "dispatch host identity drift for #{node_id}" unless node["host_id"] == host_id
        if dispatch_unknown
          raise UsageError, "--dispatch-unknown cannot include --task-id" if task_id
        elsif !task_id && !pending_client_id
          raise UsageError, "one of --task-id or --pending-client-id is required"
        end
        validate_opaque!(task_id, "task ID") if task_id
        validate_opaque!(pending_client_id, "pending client ID") if pending_client_id
        verify_project_identity!(node, project_path, project_path_digest)
        if node["runtime_project_id"] && node["runtime_project_id"] != runtime_project_id
          raise ValidationError, "dispatch runtime project identity drift for #{node_id}"
        end
        if node["task_id"] && node["task_id"] != task_id
          raise ValidationError, "dispatch task identity drift for #{node_id}"
        end
        if node["pending_client_id"] && pending_client_id && node["pending_client_id"] != pending_client_id
          raise ValidationError, "dispatch pending client identity drift for #{node_id}"
        end
        if node["pending_client_id"] && task_id && node["pending_client_id"] != pending_client_id
          raise ValidationError, "resolved task must reconcile the recorded pending client ID for #{node_id}"
        end

        desired_task = task_id || node["task_id"]
        desired_client = task_id ? nil : (pending_client_id || node["pending_client_id"])
        prepared_handoff = node["dependencies"].empty? ? nil : prepared_dependency_handoff!(mission, node)
        desired_state = if dispatch_unknown
                          "dispatch_unknown"
                        elsif task_id
                          prepared_handoff ? "awaiting_handoff" : "running"
                        else
                          "dispatch_pending"
                        end
        unchanged = node["runtime_project_id"] == runtime_project_id &&
          node["task_id"] == desired_task && node["pending_client_id"] == desired_client &&
          node["observed_state"] == desired_state
        next if unchanged

        now = timestamp
        node["runtime_project_id"] = runtime_project_id
        node["task_id"] = desired_task
        node["pending_client_id"] = desired_client
        node["observed_state"] = desired_state
        node["dispatched_at"] ||= now
        node["updated_at"] = now
        record_event!(mission, "dispatch_recorded", "node_id" => node_id,
                      "receipt" => dispatch_unknown ? "unknown" : (task_id ? "task" : "pending_client"))
        if dispatch_unknown && mission.dig("spec", "mode") != "dispatch_only"
          append_actions!(mission, [
            action_record(
              mission,
              type: "observe",
              payload: { "node_id" => node_id, "reason" => "dispatch_unknown" },
              trigger: "dispatch-unknown:#{node_id}:#{runtime_project_id}"
            )
          ])
        end
        derive_state!(mission)
      end
    end

    def status(slug)
      mission = snapshot(slug)
      view = Support.stringify(mission)
      apply_stale_states!(view)
      prepared_handoff_nodes = outbox(view).filter_map do |action|
        action.dig("payload", "node_id") if action["type"] == "dependency_handoff" && action["status"] == "prepared"
      end
      nodes(view).each do |node|
        next unless node["observed_state"] == "awaiting_handoff" && prepared_handoff_nodes.include?(node["id"])

        node["observed_state"] = "running"
        node["status_code"] = "handing_off"
      end
      derive_state!(view, touch: false)
      view["status"]["fan_in_ready"] = fan_in_ready?(view)
      view["status"]["prepared_actions"] = outbox(view).count { |action| action["status"] == "prepared" }
      view
    end

    def validate(slug)
      validate_object(fetch(slug), expected_slug: slug)
    end

    def all
      return [] unless Dir.exist?(config.mission_dir)

      Dir.glob(File.join(config.mission_dir, "*", "mission.yaml")).sort.filter_map do |path|
        value = Support.load_data(path)
        value if value.is_a?(Hash)
      rescue ValidationError => e
        { "metadata" => { "id" => File.basename(File.dirname(path)) }, "invalid" => e.message, "path" => path }
      end
    end

    def outbox_for(slug)
      status(slug).dig("status", "outbox")
    end

    def next_actions(slug)
      mission = snapshot(slug)
      apply_stale_states!(mission)
      max_retries = mission.dig("spec", "budgets", "max_retries").to_i
      outbox(mission).select do |action|
        available = action["status"] == "pending" ||
          (action["status"] == "failed" && action["attempts"].to_i <= max_retries)
        next false unless available
        next true unless action["type"] == "dependency_handoff"

        consumer = find_node!(mission, action.dig("payload", "node_id"))
        next false if action["status"] == "failed" && consumer["observed_state"] != "planned"
        %w[planned awaiting_handoff].include?(consumer["observed_state"]) &&
          !stale_delivery_target?(consumer, mission)
      end
    end

    def prepare_action(slug:, action_id:)
      mutate(slug) do |mission|
        enforce_open!(mission)
        enforce_duration!(mission)
        raise ValidationError, "another action is prepared but unacknowledged" if outbox(mission).any? { |item| item["status"] == "prepared" }
        action = find_action!(mission, action_id)
        validate_action_authorization!(mission, action)
        validate_action_artifact_binding!(mission, action)
        validate_action_delivery!(mission, action)
        unless %w[pending failed].include?(action["status"])
          raise ValidationError, "action #{action_id} is not available for prepare"
        end
        raise ValidationError, "action type #{action['type']} is denied" unless ACTION_TYPES.include?(action["type"])
        max_retries = mission.dig("spec", "budgets", "max_retries").to_i
        if action["attempts"].to_i > max_retries
          raise ValidationError, "action retry budget exhausted for #{action_id}"
        end
        now = timestamp
        action["status"] = "prepared"
        action["attempts"] = action["attempts"].to_i + 1
        action["prepared_at"] = now
        action["updated_at"] = now
        action["failure_code"] = nil
        record_event!(mission, "action_prepared", "action_id" => action_id)
      end
    end

    def acknowledge_action(slug:, action_id:)
      finish_action(slug, action_id, "acknowledged", nil)
    end

    def fail_action(slug:, action_id:, code:)
      Support.validate_identifier!(code, label: "failure code")
      finish_action(slug, action_id, "failed", code)
    end

    def checkpoint(slug)
      mutate(slug) do |mission|
        enforce_open!(mission)
        enforce_no_prepared!(mission)
        now = timestamp
        checkpoint = mission.dig("status", "checkpoint")
        checkpoint["number"] = checkpoint["number"].to_i + 1
        checkpoint["at"] = now
        checkpoint["generation"] = mission.dig("status", "generation").to_i + 1
        record_event!(mission, "checkpointed", "checkpoint" => checkpoint["number"])
      end
    end

    def close(slug)
      mutate(slug) do |mission|
        enforce_open!(mission)
        enforce_no_prepared!(mission)
        raise ValidationError, "mission is not ready for explicit close" unless fan_in_ready?(mission)

        now = timestamp
        nodes(mission).each do |node|
          completed = %w[review_ready complete].include?(node["observed_state"])
          node["observed_state"] = completed ? "complete" : "cancelled"
          unless completed
            node["cursor"] = nil
            node["revision"] = nil
            node["event_id"] = nil
            node["event_digest"] = nil
            node["seen_event_ids"] = []
            node["observed_at"] = nil
            node["status_code"] = nil
            node["outcome_code"] = nil
            node["validation_status"] = nil
            node["output_declarations"] = []
            node["output_refs"] = []
            node["criterion_results"] = []
          end
          node["updated_at"] = now
        end
        mission["status"]["state"] = "complete"
        mission["status"]["closed_at"] = now
        record_event!(mission, "explicit_close", "state" => "complete")
      end
    end

    def fan_in_ready?(mission)
      return false unless MissionGraph.new(nodes(mission)).fan_in_ready?

      required = nodes(mission).select { |node| node["required"] == true }
      criteria = mission.dig("spec", "success_criteria")
      return false unless criteria.is_a?(Array) && !criteria.empty?

      criteria.all? do |criterion|
        next false unless criterion.is_a?(Hash)

        assigned = required.select { |node| Array(node["criterion_ids"]).include?(criterion["id"]) }
        assigned.any? && assigned.all? do |node|
          result = Array(node["criterion_results"]).find do |item|
            item.is_a?(Hash) && item["criterion_id"] == criterion["id"]
          end
          result && result["disposition"] == "passed"
        end
      end
    end

    def automatic_handoff_ref?(producer, ref)
      return false unless ref.is_a?(Hash)

      value = ref["ref"].to_s
      if value.start_with?("artifact:")
        resolver = producer["artifact_resolver"]
        return false unless resolver.is_a?(Hash) && SHA256.match?(ref["digest"].to_s)

        parts = value.delete_prefix("artifact:").split("/", -1)
        parts.length == 5 &&
          parts[0] == resolver["id"] &&
          parts[1] == producer["id"] &&
          parts[2] == task_identity_binding(producer["task_id"]) &&
          parts[3] == ref["digest"] &&
          identifier?(parts[4])
      elsif value.start_with?("codex-task:")
        parts = value.delete_prefix("codex-task:").split("/", -1)
        parts.length == 2 &&
          parts[0] == producer["id"] &&
          parts[1] == task_identity_binding(producer["task_id"])
      else
        false
      end
    end

    def handoffable_dependency_refs(mission, consumer)
      by_id = nodes(mission).to_h { |node| [node["id"], node] }
      dependency_ids = Array(consumer["dependencies"])
      return nil if dependency_ids.empty?

      refs = dependency_ids.sort.flat_map do |dependency_id|
        producer = by_id[dependency_id]
        return nil unless producer

        accepted = Array(consumer["accepted_input_types"])
        eligible = Array(producer["output_refs"]).select do |ref|
          accepted.include?(ref["type"]) && automatic_handoff_ref?(producer, ref)
        end
        return nil if eligible.empty?

        eligible
      end
      refs.uniq.sort_by { |ref| [ref["type"], ref["ref"], ref["digest"].to_s] }
    end

    def materialize_output_refs(producer, declarations)
      raise ValidationError, "output_declarations must be a list" unless declarations.is_a?(Array)
      unless Support.present?(producer["task_id"])
        raise ValidationError, "output declarations require an exact persisted producer task identity"
      end

      refs = declarations.each_with_index.map do |declaration, index|
        unless declaration.is_a?(Hash)
          raise ValidationError, "output declaration #{index} must be a mapping"
        end
        type = declaration["type"]
        validate_identifier!(type, "output declaration #{index} type")
        unless Array(producer["allowed_output_types"]).include?(type)
          raise ValidationError, "output type #{type} is not allowed for #{producer['id']}"
        end

        if declaration.keys.sort == %w[artifact_id digest type]
          resolver = producer["artifact_resolver"]
          unless resolver.is_a?(Hash)
            raise ValidationError, "artifact output declaration #{index} requires a producer artifact resolver"
          end
          validate_identifier!(declaration["artifact_id"], "output declaration #{index} artifact_id")
          unless SHA256.match?(declaration["digest"].to_s)
            raise ValidationError, "output declaration #{index} digest must be lowercase sha256"
          end
          {
            "type" => type,
            "ref" => "artifact:#{resolver['id']}/#{producer['id']}/#{task_identity_binding(producer['task_id'])}/#{declaration['digest']}/#{declaration['artifact_id']}",
            "digest" => declaration["digest"]
          }
        elsif declaration.keys.sort == %w[codex_task type]
          unless declaration["codex_task"] == true
            raise ValidationError, "output declaration #{index} codex_task must be true"
          end
          {
            "type" => type,
            "ref" => "codex-task:#{producer['id']}/#{task_identity_binding(producer['task_id'])}",
            "digest" => nil
          }
        elsif declaration.keys.sort == %w[digest ref type]
          unless TERMINAL_REF.match?(declaration["ref"].to_s)
            raise ValidationError, "output declaration #{index} terminal reference must use check: or review:"
          end
          digest = declaration["digest"]
          if digest && !SHA256.match?(digest.to_s)
            raise ValidationError, "output declaration #{index} digest must be lowercase sha256 or null"
          end
          { "type" => type, "ref" => declaration["ref"], "digest" => digest }
        else
          raise ValidationError,
                "output declaration #{index} must be an artifact, codex_task, or terminal declaration"
        end
      end
      unless refs.uniq.length == refs.length
        raise ValidationError, "output declarations must materialize unique references"
      end

      refs
    rescue UsageError => e
      raise ValidationError, e.message
    end

    def observation_event_digest(change)
      Digest::SHA256.hexdigest(
        canonical_json(
          "node_id" => change["node_id"],
          "cursor" => change["cursor"],
          "revision" => change["revision"],
          "event_id" => change["event_id"],
          "state" => change["state"],
          "status_code" => change["status_code"],
          "observed_at" => change["observed_at"],
          "outcome_code" => change["outcome_code"],
          "validation_status" => change["validation_status"],
          "output_declarations" => change["output_declarations"],
          "criterion_results" => change["criterion_results"]
        )
      )
    end

    def mutate(slug)
      result = nil
      with_lock(slug, shared: false) do
        mission = fetch(slug)
        validate_or_raise!(mission, expected_slug: slug)
        previous = YAML.dump(mission)
        yield mission
        validate_or_raise!(mission, expected_slug: slug)
        unless YAML.dump(mission) == previous
          mission["status"]["generation"] = mission.dig("status", "generation").to_i + 1
          mission["metadata"]["updated_at"] = timestamp
          validate_or_raise!(mission, expected_slug: slug)
          Support.atomic_yaml(mission_path(slug), mission)
        end
        result = mission
      end
      result
    end

    def append_actions!(mission, actions)
      validate_mission_authorization!(mission)
      enforce_criterion_coverage!(mission) unless actions.empty?
      existing = outbox(mission).to_h { |action| [action["idempotency_key"], true] }
      max_actions = mission.dig("spec", "budgets", "max_actions").to_i
      actions.each do |action|
        validate_action_authorization!(mission, action)
        validate_action_artifact_binding!(mission, action)
        validate_action_delivery!(mission, action)
        next if existing[action.fetch("idempotency_key")]
        raise ValidationError, "mission action budget exhausted (max #{max_actions})" if outbox(mission).length >= max_actions

        outbox(mission) << action
        existing[action.fetch("idempotency_key")] = true
      end
    end

    def enforce_sync_ready!(mission)
      enforce_open!(mission)
      enforce_duration!(mission)
      enforce_no_prepared!(mission)
    end

    def action_record(mission, type:, payload:, trigger:)
      raise ValidationError, "action type #{type} is denied" unless ACTION_TYPES.include?(type)
      validate_mission_authorization!(mission)
      safe_payload = Support.stringify(payload)
      boundary = mission.dig("spec", "authorization_boundary")
      trigger_digest = Digest::SHA256.hexdigest(trigger.to_s)
      key = action_idempotency_key(
        mission.dig("metadata", "id"), boundary, type, trigger_digest, safe_payload
      )
      now = timestamp
      action = {
        "id" => "action-#{key[0, 20]}",
        "type" => type,
        "idempotency_key" => key,
        "trigger_digest" => trigger_digest,
        "authorization_boundary" => boundary,
        "status" => "pending",
        "payload" => safe_payload,
        "attempts" => 0,
        "created_at" => now,
        "updated_at" => now,
        "prepared_at" => nil,
        "acknowledged_at" => nil,
        "failure_code" => nil
      }
      validate_action_artifact_binding!(mission, action)
      validate_action_delivery!(mission, action)
      action
    end

    def validate_object(mission, expected_slug: nil)
      errors = []
      return ["mission must contain a mapping"] unless mission.is_a?(Hash)

      errors << "api_version must be flightdeck.dev/v1alpha1" unless mission["api_version"] == "flightdeck.dev/v1alpha1"
      errors << "kind must be MissionRecord" unless mission["kind"] == "MissionRecord"
      errors << "schema must be hub/schemas/mission.schema.json" unless mission["schema"] == "hub/schemas/mission.schema.json"
      %w[metadata spec status].each { |field| errors << "#{field} must be a mapping" unless mission[field].is_a?(Hash) }
      return errors unless %w[metadata spec status].all? { |field| mission[field].is_a?(Hash) }

      id = mission.dig("metadata", "id")
      errors << "metadata.id does not match mission directory" if expected_slug && id != expected_slug
      begin
        Support.validate_slug!(id, label: "mission metadata.id")
      rescue UsageError => e
        errors << e.message
      end
      %w[title created_at updated_at].each do |field|
        errors << "metadata.#{field} is required" unless Support.present?(mission.dig("metadata", field))
      end
      authoring = mission.dig("metadata", "authoring")
      if authoring
        unless authoring.is_a?(Hash) && authoring.keys.sort == %w[operation_digest plan_digest plan_id]
          errors << "metadata.authoring must be a closed operation and plan binding"
        else
          errors << "metadata.authoring operation_digest must be sha256" unless SHA256.match?(authoring["operation_digest"].to_s)
          errors << "metadata.authoring plan_digest must be sha256" unless SHA256.match?(authoring["plan_digest"].to_s)
          errors << "metadata.authoring plan_id is invalid" unless authoring["plan_id"].to_s.match?(/\Aplan-[0-9a-f]{48}\z/)
        end
      end
      %w[metadata.created_at metadata.updated_at].each do |field|
        Time.iso8601(Support.dig_path(mission, field).to_s)
      rescue ArgumentError
        errors << "#{field} must be an ISO 8601 timestamp"
      end
      mode = mission.dig("spec", "mode")
      errors << "unknown mission mode #{mode}" unless MODES.include?(mode.to_s)
      errors << "spec.outcome is required" unless Support.present?(mission.dig("spec", "outcome"))
      begin
        validate_text!(mission.dig("spec", "outcome"), "spec.outcome", max: 2048)
      rescue UsageError => e
        errors << e.message
      end
      criteria = mission.dig("spec", "success_criteria")
      errors.concat(validate_success_criteria(criteria))
      errors.concat(validate_text_list(mission.dig("spec", "non_goals"), "spec.non_goals", min: 0))
      targets = mission.dig("spec", "authorized_targets")
      errors.concat(validate_authorized_targets(targets))
      if mode != "dispatch_only" && targets.is_a?(Array) && targets.empty?
        errors << "spec.authorized_targets must not be empty for #{mode} missions"
      end
      errors << "spec.authorization_boundary is required" unless Support.present?(mission.dig("spec", "authorization_boundary"))
      begin
        validate_identifier!(mission.dig("spec", "authorization_boundary"), "mission authorization boundary")
      rescue UsageError => e
        errors << e.message
      end
      if criteria.is_a?(Array) && mission.dig("spec", "non_goals").is_a?(Array) && targets.is_a?(Array)
        expected_boundary = derive_authorization_boundary(
          id.to_s, targets, criteria, mission.dig("spec", "non_goals")
        )
        unless mission.dig("spec", "authorization_boundary") == expected_boundary
          errors << "spec.authorization_boundary does not match the normalized authorized scope and mission intent"
        end
      end
      budgets = mission.dig("spec", "budgets")
      errors << "spec.budgets must be a mapping" unless budgets.is_a?(Hash)
      required_budgets.each do |name|
        value = budgets && budgets[name]
        errors << "spec.budgets.#{name} must be a positive integer" unless value.is_a?(Integer) && value.positive?
      end
      graph = mission.dig("spec", "graph")
      node_values = graph.is_a?(Hash) ? graph["nodes"] : nil
      errors << "spec.graph.nodes must be a list" unless node_values.is_a?(Array)
      if node_values.is_a?(Array)
        max_units = budgets.is_a?(Hash) ? budgets["max_units"].to_i : 0
        errors << "mission exceeds max_units budget" if max_units.positive? && node_values.length > max_units
        errors.concat(validate_nodes(node_values, mission))
        errors.concat(MissionGraph.new(node_values).validate)
        if graph_frozen?(mission)
          errors.concat(criterion_coverage_errors(mission))
        end
      end
      status = mission["status"]
      errors << "unknown mission status #{status['state']}" unless MissionGraph::NODE_STATES.include?(status["state"].to_s)
      errors << "status.generation must be a non-negative integer" unless status["generation"].is_a?(Integer) && status["generation"] >= 0
      errors << "status.history must be a list" unless status["history"].is_a?(Array)
      errors << "status.outbox must be a list" unless status["outbox"].is_a?(Array)
      if status["outbox"].is_a?(Array)
        errors.concat(validate_actions(
          status["outbox"], budgets, mission.dig("spec", "authorization_boundary"), id
        ))
      end
      errors.concat(validate_action_targets(status["outbox"], node_values, mission)) if status["outbox"].is_a?(Array) && node_values.is_a?(Array)
      errors.concat(validate_dependent_dispatch_actions(status["outbox"], node_values)) if status["outbox"].is_a?(Array) && node_values.is_a?(Array)
      if status["state"] == "complete"
        errors << "complete mission requires closed_at" unless Support.present?(status["closed_at"])
        errors << "complete mission requires explicit_close history" unless Array(status["history"]).last.to_h["event"] == "explicit_close"
        errors << "complete mission requires every success criterion covered and passed" unless fan_in_ready?(mission)
      elsif Support.present?(status["closed_at"])
        errors << "only a complete mission may have closed_at"
      end
      begin
        scan_safe_persisted!(mission)
      rescue ValidationError => e
        errors << e.message
      end
      record_bytes = YAML.dump(mission).bytesize
      max_bytes = budgets.is_a?(Hash) ? budgets["max_record_bytes"].to_i : 0
      errors << "mission record exceeds max_record_bytes budget" if max_bytes.positive? && record_bytes > max_bytes
      errors.uniq
    end

    private

    def build_complete_mission(slug:, title:, outcome:, mode:, success_criteria:, non_goals:,
                               authorized_targets:, nodes:)
      Support.validate_slug!(slug, label: "mission slug")
      validate_text!(title, "--title", max: 256)
      validate_text!(outcome, "--outcome", max: 2048)
      selected_mode = (mode || config.mission_defaults.fetch("default_mode", "dispatch_only")).to_s
      raise UsageError, "unknown mission mode: #{selected_mode}" unless MODES.include?(selected_mode)

      criterion_texts = Array(success_criteria).map do |value|
        normalize_bounded_text!(value, "success criterion")
      end
      if criterion_texts.empty? && selected_mode == "dispatch_only"
        criterion_texts = [outcome.to_s.strip]
      elsif criterion_texts.empty?
        raise UsageError, "at least one --success-criterion is required for #{selected_mode} missions"
      end
      goals_excluded = Array(non_goals).map { |value| normalize_bounded_text!(value, "non-goal") }
      raise UsageError, "success criteria must be unique" unless criterion_texts.uniq.length == criterion_texts.length
      raise UsageError, "non-goals must be unique" unless goals_excluded.uniq.length == goals_excluded.length
      criteria = criterion_texts.each_with_index.map do |text, index|
        { "id" => format("criterion-%03d", index + 1), "text" => text }
      end
      targets = normalize_authorized_targets!(authorized_targets)
      raise UsageError, "at least one authorized target is required" if targets.empty?
      authorization_boundary = derive_authorization_boundary(slug, targets, criteria, goals_excluded)
      now = timestamp
      mission = {
        "api_version" => "flightdeck.dev/v1alpha1",
        "kind" => "MissionRecord",
        "schema" => "hub/schemas/mission.schema.json",
        "metadata" => {
          "id" => slug,
          "title" => title.to_s.strip,
          "created_at" => now,
          "updated_at" => now
        },
        "spec" => {
          "mode" => selected_mode,
          "outcome" => outcome.to_s.strip,
          "success_criteria" => criteria,
          "non_goals" => goals_excluded,
          "authorized_targets" => targets,
          "authorization_boundary" => authorization_boundary,
          "budgets" => config.mission_budgets,
          "graph" => { "nodes" => [] }
        },
        "status" => {
          "state" => "planned",
          "generation" => 0,
          "closed_at" => nil,
          "checkpoint" => { "number" => 0, "at" => nil, "generation" => 0 },
          "outbox" => [],
          "history" => [
            { "at" => now, "event" => "created", "state" => "planned" }
          ]
        }
      }

      Array(nodes).each do |node|
        append_complete_node!(mission, node)
      end
      enforce_criterion_coverage!(mission)
      mission
    end

    def append_complete_node!(mission, attributes)
      unless attributes.is_a?(Hash) && attributes.keys.all? { |key| key.is_a?(Symbol) }
        raise UsageError, "complete Mission node input must use typed fields"
      end
      node_id = attributes.fetch(:node_id)
      logical_project_key = attributes.fetch(:logical_project_key)
      runtime_project_id = attributes.fetch(:runtime_project_id)
      project_path_digest = attributes.fetch(:project_path_digest)
      host_id = attributes.fetch(:host_id)
      execution_mode = attributes.fetch(:execution_mode).to_s
      access_mode = attributes.fetch(:access_mode).to_s
      work_type = attributes.fetch(:work_type)
      required = attributes.fetch(:required)
      dependencies = Array(attributes.fetch(:dependencies, [])).map(&:to_s)
      accepted_input_types = Array(attributes.fetch(:accepted_input_types, [])).map(&:to_s)
      allowed_output_types = Array(attributes.fetch(:allowed_output_types)).map(&:to_s)
      criterion_ids = Array(attributes.fetch(:criterion_ids, [])).map(&:to_s)

      Support.validate_identifier!(node_id, label: "node ID")
      Support.validate_identifier!(logical_project_key, label: "logical project key")
      validate_opaque!(runtime_project_id, "runtime project ID")
      validate_opaque!(host_id, "host ID")
      Support.validate_identifier!(work_type, label: "work type")
      raise UsageError, "required must be boolean" unless [true, false].include?(required)
      raise UsageError, "execution mode must be local or worktree" unless EXECUTION_MODES.include?(execution_mode)
      raise UsageError, "access mode must be read_only or write" unless %w[read_only write].include?(access_mode)
      unless SHA256.match?(project_path_digest.to_s)
        raise UsageError, "project path digest must be a lowercase sha256"
      end
      target = {
        "logical_project_key" => logical_project_key.to_s,
        "runtime_project_id" => runtime_project_id.to_s,
        "project_path_digest" => project_path_digest.to_s,
        "host_id" => host_id.to_s,
        "execution_mode" => execution_mode,
        "access_mode" => access_mode
      }
      unless mission.dig("spec", "authorized_targets").include?(target)
        raise ValidationError, "node #{node_id} is outside the mission authorized target scope"
      end

      known_criteria = mission.dig("spec", "success_criteria").map { |criterion| criterion["id"] }
      raise UsageError, "criterion IDs must be unique" unless criterion_ids.uniq.length == criterion_ids.length
      criterion_ids.each { |id| Support.validate_identifier!(id, label: "criterion ID") }
      unknown_criteria = criterion_ids - known_criteria
      raise UsageError, "unknown criterion IDs: #{unknown_criteria.join(', ')}" unless unknown_criteria.empty?
      raise UsageError, "required nodes must declare at least one criterion ID" if required && criterion_ids.empty?

      raise UsageError, "dependencies must be unique" unless dependencies.uniq.length == dependencies.length
      raise UsageError, "accepted input types must be unique" unless accepted_input_types.uniq.length == accepted_input_types.length
      raise UsageError, "allowed output types must be unique" unless allowed_output_types.uniq.length == allowed_output_types.length
      dependencies.each { |id| Support.validate_identifier!(id, label: "dependency node ID") }
      accepted_input_types.each { |value| Support.validate_identifier!(value, label: "accepted input type") }
      allowed_output_types.each { |value| Support.validate_identifier!(value, label: "allowed output type") }
      raise UsageError, "at least one allowed output type is required" if allowed_output_types.empty?
      if dependencies.any? && accepted_input_types.empty?
        raise UsageError, "a node with dependencies requires at least one accepted input type"
      end

      node_values = mission.dig("spec", "graph", "nodes")
      raise ValidationError, "mission node already exists: #{node_id}" if node_values.any? { |node| node["id"] == node_id }
      max_units = mission.dig("spec", "budgets", "max_units").to_i
      raise ValidationError, "mission unit budget exhausted (max #{max_units})" if node_values.length >= max_units
      now = timestamp
      node_values << {
        "id" => node_id.to_s,
        "logical_project_key" => logical_project_key.to_s,
        "runtime_project_id" => runtime_project_id.to_s,
        "project_path" => nil,
        "project_path_digest" => project_path_digest.to_s,
        "host_id" => host_id.to_s,
        "task_id" => nil,
        "pending_client_id" => nil,
        "execution_mode" => execution_mode,
        "access_mode" => access_mode,
        "work_type" => work_type.to_s,
        "required" => required,
        "dependencies" => dependencies,
        "accepted_input_types" => accepted_input_types,
        "allowed_output_types" => allowed_output_types,
        "authorization_boundary" => mission.dig("spec", "authorization_boundary"),
        "artifact_resolver" => nil,
        "criterion_ids" => criterion_ids,
        "cursor" => nil,
        "revision" => nil,
        "event_id" => nil,
        "event_digest" => nil,
        "seen_event_ids" => [],
        "observed_state" => "planned",
        "retries" => 0,
        "created_at" => now,
        "updated_at" => now,
        "dispatched_at" => nil,
        "observed_at" => nil,
        "status_code" => nil,
        "outcome_code" => nil,
        "validation_status" => nil,
        "output_declarations" => [],
        "output_refs" => [],
        "criterion_results" => []
      }
      graph_errors = MissionGraph.new(node_values).validate
      raise ValidationError, graph_errors.join("; ") unless graph_errors.empty?

      record_event!(mission, "node_added", "node_id" => node_id.to_s)
      derive_state!(mission)
    rescue KeyError => e
      raise UsageError, "complete Mission node missing field: #{e.key}"
    end

    def persist_complete_mission!(mission)
      slug = mission.dig("metadata", "id")
      validate_or_raise!(mission, expected_slug: slug)
      FileUtils.mkdir_p(config.mission_dir)
      root_lock = File.join(config.mission_dir, ".lock")
      with_file_lock(root_lock, File::LOCK_EX) do
        directory = mission_dir(slug)
        raise ValidationError, "mission already exists: #{slug}" if File.exist?(directory)

        Dir.mkdir(directory, 0o700)
        begin
          Support.atomic_yaml(mission_path(slug), mission)
        rescue StandardError
          Dir.rmdir(directory) if Dir.exist?(directory) && Dir.empty?(directory)
          raise
        end
      end
      mission
    end

    def validate_nodes(node_values, mission)
      errors = []
      node_values.each_with_index do |node, index|
        next unless node.is_a?(Hash)

        missing = REQUIRED_NODE_FIELDS.reject { |field| node.key?(field) }
        errors << "node #{index} missing fields: #{missing.join(', ')}" unless missing.empty?
        errors << "node #{node['id']} project path digest is required" unless Support.present?(node["project_path_digest"])
        errors << "node #{node['id']} project path must be absolute" if node["project_path"] && !Pathname.new(node["project_path"].to_s).absolute?
        errors << "node #{node['id']} project path digest must be sha256" if node["project_path_digest"] && !SHA256.match?(node["project_path_digest"].to_s)
        errors << "node #{node['id']} execution mode is invalid" unless EXECUTION_MODES.include?(node["execution_mode"].to_s)
        errors << "node #{node['id']} access mode is invalid" unless %w[read_only write].include?(node["access_mode"].to_s)
        target = AUTHORIZED_TARGET_FIELDS.to_h { |field| [field, node[field]] }
        unless Array(mission.dig("spec", "authorized_targets")).include?(target)
          errors << "node #{node['id']} is outside the mission authorized target scope"
        end
        unless node["authorization_boundary"] == mission.dig("spec", "authorization_boundary")
          errors << "node #{node['id']} authorization boundary must exactly match mission authorization boundary"
        end
        errors.concat(validate_artifact_resolver(node["artifact_resolver"], "node #{node['id']}"))
        errors << "node #{node['id']} seen_event_ids must be a list" unless node["seen_event_ids"].is_a?(Array)
        errors << "node #{node['id']} accepted_input_types must be a list" unless node["accepted_input_types"].is_a?(Array)
        errors << "node #{node['id']} allowed_output_types must be a non-empty list" unless node["allowed_output_types"].is_a?(Array) && !node["allowed_output_types"].empty?
        errors << "node #{node['id']} output_declarations must be a list" unless node["output_declarations"].is_a?(Array)
        errors << "node #{node['id']} output_refs must be a list" unless node["output_refs"].is_a?(Array)
        if node["output_declarations"].is_a?(Array) && node["output_refs"].is_a?(Array)
          begin
            expected_refs = node["output_declarations"].empty? ? [] : materialize_output_refs(node, node["output_declarations"])
            unless node["output_refs"] == expected_refs
              errors << "node #{node['id']} output_refs do not match core-materialized output_declarations"
            end
          rescue ValidationError => e
            errors << "node #{node['id']} #{e.message}"
          end
          errors.concat(validate_output_refs(node["output_refs"], "node #{node['id']}", allowed: Array(node["allowed_output_types"])))
          if node["output_refs"].any? { |ref| artifact_ref?(ref) } && node["artifact_resolver"].nil?
            errors << "node #{node['id']} artifact output requires an artifact resolver"
          end
          node["output_refs"].each_with_index do |ref, ref_index|
            next unless ref.is_a?(Hash) && %w[artifact: codex-task:].any? { |prefix| ref["ref"].to_s.start_with?(prefix) }
            next if automatic_handoff_ref?(node, ref)

            errors << "node #{node['id']} output ref #{ref_index} lacks canonical producer task provenance"
          end
        end
        if node["event_digest"] && !SHA256.match?(node["event_digest"].to_s)
          errors << "node #{node['id']} event digest must be lowercase sha256 or null"
        end
        if Support.present?(node["observed_at"]) && !Support.present?(node["event_digest"])
          errors << "node #{node['id']} accepted observation requires an event digest"
        elsif Support.present?(node["event_digest"])
          event_change = {
            "node_id" => node["id"],
            "cursor" => node["cursor"],
            "revision" => node["revision"],
            "event_id" => node["event_id"],
            "state" => node["observed_state"] == "complete" ? "review_ready" : node["observed_state"],
            "status_code" => node["status_code"],
            "observed_at" => node["observed_at"],
            "outcome_code" => node["outcome_code"],
            "validation_status" => node["validation_status"],
            "output_declarations" => node["output_declarations"],
            "criterion_results" => node["criterion_results"]
          }
          unless node["event_digest"] == observation_event_digest(event_change)
            errors << "node #{node['id']} event digest does not match its persisted observation declaration"
          end
        end
        if node["status_code"]
          begin
            validate_identifier!(node["status_code"], "node #{node['id']} status code")
          rescue UsageError => e
            errors << e.message
          end
        end
        criterion_ids = node["criterion_ids"]
        unless criterion_ids.is_a?(Array)
          errors << "node #{node['id']} criterion_ids must be a list"
          criterion_ids = []
        end
        known_criteria = Array(mission.dig("spec", "success_criteria")).filter_map do |criterion|
          criterion["id"] if criterion.is_a?(Hash)
        end
        errors << "node #{node['id']} criterion_ids must be unique" unless criterion_ids.uniq.length == criterion_ids.length
        unknown_criteria = criterion_ids - known_criteria
        errors << "node #{node['id']} references unknown criterion IDs: #{unknown_criteria.join(', ')}" unless unknown_criteria.empty?
        if node["required"] == true && criterion_ids.empty?
          errors << "required node #{node['id']} must declare at least one criterion ID"
        end
        errors.concat(validate_criterion_results(node, criterion_ids))
        if Support.present?(node["observed_at"]) && !Support.present?(node["status_code"])
          errors << "node #{node['id']} accepted observation requires a status code"
        end
        if node["outcome_code"]
          begin
            validate_identifier!(node["outcome_code"], "node #{node['id']} outcome code")
          rescue UsageError => e
            errors << e.message
          end
        end
        if %w[review_ready failed_validation complete].include?(node["observed_state"]) &&
           node["status_code"] != node["outcome_code"]
          errors << "node #{node['id']} final status code must equal outcome code"
        end
        errors << "node #{node['id']} revision must be non-negative" if !node["revision"].nil? && (!node["revision"].is_a?(Integer) || node["revision"].negative?)
        errors << "node #{node['id']} retries must be non-negative" unless node["retries"].is_a?(Integer) && node["retries"] >= 0
        if node["observed_state"] == "complete" && mission.dig("status", "state") != "complete"
          errors << "node #{node['id']} complete requires explicit mission close"
        end
      end
      errors
    end

    def validate_actions(actions, budgets, mission_boundary, mission_id)
      errors = []
      max_actions = budgets.is_a?(Hash) ? budgets["max_actions"].to_i : 0
      errors << "mission exceeds max_actions budget" if max_actions.positive? && actions.length > max_actions
      ids = {}
      keys = {}
      prepared = 0
      actions.each_with_index do |action, index|
        unless action.is_a?(Hash)
          errors << "status.outbox[#{index}] must be a mapping"
          next
        end
        missing = REQUIRED_ACTION_FIELDS.reject { |field| action.key?(field) }
        errors << "action #{index} missing fields: #{missing.join(', ')}" unless missing.empty?
        errors << "action #{action['id']} uses denied type #{action['type']}" unless ACTION_TYPES.include?(action["type"].to_s)
        errors << "action #{action['id']} has invalid state" unless ACTION_STATES.include?(action["status"].to_s)
        errors << "action #{action['id']} idempotency key must be sha256" unless SHA256.match?(action["idempotency_key"].to_s)
        errors << "action #{action['id']} trigger digest must be sha256" unless SHA256.match?(action["trigger_digest"].to_s)
        errors << "action #{action['id']} authorization boundary is required" unless Support.present?(action["authorization_boundary"])
        unless action["authorization_boundary"] == mission_boundary
          errors << "action #{action['id']} authorization boundary must exactly match mission authorization boundary"
        end
        errors << "duplicate action ID #{action['id']}" if ids[action["id"]]
        errors << "duplicate action idempotency key" if keys[action["idempotency_key"]]
        ids[action["id"]] = true
        keys[action["idempotency_key"]] = true
        prepared += 1 if action["status"] == "prepared"
        errors.concat(validate_action_payload(action))
        if SHA256.match?(action["trigger_digest"].to_s) && action["payload"].is_a?(Hash)
          expected_key = action_idempotency_key(
            mission_id, mission_boundary, action["type"], action["trigger_digest"], action["payload"]
          )
          errors << "action #{action['id']} idempotency identity does not match its payload" unless action["idempotency_key"] == expected_key
          errors << "action #{action['id']} ID does not match its idempotency identity" unless action["id"] == "action-#{expected_key[0, 20]}"
        end
      end
      errors << "only one side effect may be prepared" if prepared > 1
      errors
    end

    def validate_action_payload(action)
      payload = action["payload"]
      return ["action #{action['id']} payload must be a mapping"] unless payload.is_a?(Hash)

      expected = case action["type"]
                 when "observe" then %w[node_id reason]
                 when "dependency_handoff" then %w[node_id dependency_node_ids output_refs artifact_resolver]
                 when "offer_fan_in" then %w[required_node_ids]
                 else []
                 end
      unknown = payload.keys - expected
      missing = expected.reject { |key| payload.key?(key) }
      output = []
      output << "action #{action['id']} payload contains forbidden fields: #{unknown.join(', ')}" unless unknown.empty?
      output << "action #{action['id']} payload missing fields: #{missing.join(', ')}" unless missing.empty?
      output << "action #{action['id']} observe reason is invalid" if action["type"] == "observe" && payload["reason"] != "dispatch_unknown"
      if action["type"] == "dependency_handoff"
        output << "action #{action['id']} dependency_node_ids must be a list" unless payload["dependency_node_ids"].is_a?(Array)
        output << "action #{action['id']} output_refs must be a list" unless payload["output_refs"].is_a?(Array)
        output.concat(validate_output_refs(payload["output_refs"], "action #{action['id']}")) if payload["output_refs"].is_a?(Array)
        output.concat(validate_artifact_resolver(payload["artifact_resolver"], "action #{action['id']}"))
      end
      output
    end

    def validate_action_targets(actions, node_values, mission)
      by_id = node_values.to_h { |node| [node["id"], node] }
      actions.flat_map do |action|
        next [] unless action.is_a?(Hash) && action["payload"].is_a?(Hash)

        payload = action["payload"]
        case action["type"]
        when "observe"
          by_id[payload["node_id"]] ? [] : ["action #{action['id']} targets undeclared node"]
        when "dependency_handoff"
          consumer = by_id[payload["node_id"]]
          output = consumer ? [] : ["action #{action['id']} targets undeclared node"]
          if consumer && Array(payload["dependency_node_ids"]).sort != Array(consumer["dependencies"]).sort
            output << "action #{action['id']} dependency set does not match declared graph"
          end
          if consumer
            output.concat(validate_output_refs(Array(payload["output_refs"]), "action #{action['id']}", allowed: Array(consumer["accepted_input_types"])))
            output.concat(validate_action_handoff_completeness(action, consumer, mission))
            output.concat(validate_action_artifact_binding(action, consumer, by_id))
            output.concat(validate_action_delivery(action, consumer, mission: mission, historical: true))
          end
          output
        when "offer_fan_in"
          unknown = Array(payload["required_node_ids"]).reject { |id| by_id[id] && by_id[id]["required"] == true }
          unknown.empty? ? [] : ["action #{action['id']} fan-in references undeclared or optional nodes"]
        else
          []
        end
      end
    end

    def validate_dependent_dispatch_actions(actions, node_values)
      node_values.flat_map do |node|
        next [] unless node.is_a?(Hash) && !Array(node["dependencies"]).empty?
        next [] unless %w[dispatch_pending dispatch_unknown awaiting_handoff].include?(node["observed_state"])

        allowed_statuses = %w[prepared failed]
        matching = actions.select do |action|
          action.is_a?(Hash) && action["type"] == "dependency_handoff" &&
            action.dig("payload", "node_id") == node["id"] && allowed_statuses.include?(action["status"])
        end
        if matching.length == 1
          []
        else
          ["dependent node #{node['id']} #{node['observed_state']} requires exactly one preserved dependency handoff action"]
        end
      end
    end

    def validate_action_handoff_completeness(action, consumer, mission)
      if %w[acknowledged failed].include?(action["status"])
        by_id = nodes(mission).to_h { |node| [node["id"], node] }
        refs = Array(action.dig("payload", "output_refs"))
        missing = Array(consumer["dependencies"]).reject do |dependency_id|
          producer = by_id[dependency_id]
          producer && refs.any? do |ref|
            Array(consumer["accepted_input_types"]).include?(ref["type"]) &&
              automatic_handoff_ref?(producer, ref)
          end
        end
        return [] if missing.empty?

        return ["action #{action['id']} requires at least one accepted automatic handoff ref from every declared dependency"]
      end

      expected = handoffable_dependency_refs(mission, consumer)
      if expected.nil?
        return ["action #{action['id']} requires at least one accepted automatic handoff ref from every declared dependency"]
      end
      return [] if Array(action.dig("payload", "output_refs")) == expected

      ["action #{action['id']} output refs do not exactly match the complete handoffable dependency set"]
    end

    def validate_output_refs(refs, context, allowed: nil)
      errors = []
      refs.each_with_index do |ref, index|
        unless ref.is_a?(Hash)
          errors << "#{context} output ref #{index} must be a mapping"
          next
        end
        unknown = ref.keys - %w[type ref digest]
        missing = %w[type ref digest].reject { |field| ref.key?(field) }
        errors << "#{context} output ref #{index} contains forbidden fields: #{unknown.join(', ')}" unless unknown.empty?
        errors << "#{context} output ref #{index} missing fields: #{missing.join(', ')}" unless missing.empty?
        errors << "#{context} output ref #{index} type is not declared" if allowed && !allowed.include?(ref["type"])
        errors << "#{context} output ref #{index} reference is invalid" unless OUTPUT_REF.match?(ref["ref"].to_s)
        digest = ref["digest"]
        errors << "#{context} output ref #{index} digest is invalid" if digest && !SHA256.match?(digest.to_s)
        errors << "#{context} artifact output ref #{index} requires digest" if ref["ref"].to_s.start_with?("artifact:") && digest.nil?
      end
      errors
    end

    def validate_action_artifact_binding(action, consumer, by_id)
      payload = action["payload"]
      dependencies = Array(payload["dependency_node_ids"]).filter_map { |id| by_id[id] }
      refs = Array(payload["output_refs"])
      errors = []
      refs.each_with_index do |ref, index|
        producers = dependencies.select { |producer| Array(producer["output_refs"]).include?(ref) }
        if producers.empty? && %w[acknowledged failed].include?(action["status"])
          producers = dependencies.select { |producer| automatic_handoff_ref?(producer, ref) }
        end
        if producers.empty?
          errors << "action #{action['id']} output ref #{index} is not produced by a declared dependency"
          next
        end
        eligible = producers.select { |producer| automatic_handoff_ref?(producer, ref) }
        if eligible.empty?
          errors << "action #{action['id']} output ref #{index} lacks canonical producer provenance for automatic handoff"
          next
        end
        next unless artifact_ref?(ref)

        if consumer["artifact_resolver"].nil?
          errors << "action #{action['id']} artifact handoff requires a consumer artifact resolver"
          next
        end
        eligible.each do |producer|
          unless producer["artifact_resolver"] == consumer["artifact_resolver"]
            errors << "action #{action['id']} artifact resolver mismatch for #{producer['id']} -> #{consumer['id']}"
          end
          if consumer.dig("artifact_resolver", "kind") == "same_host_workspace" &&
             producer["host_id"] != consumer["host_id"]
            errors << "action #{action['id']} same_host_workspace artifact crosses host identity"
          end
        end
      end
      expected = refs.any? { |ref| artifact_ref?(ref) } ? consumer["artifact_resolver"] : nil
      unless payload["artifact_resolver"] == expected
        errors << "action #{action['id']} artifact resolver binding does not match the declared graph"
      end
      errors.uniq
    end

    def validate_action_delivery(action, consumer, mission:, require_receipt: false, historical: false)
      return [] if action["status"] == "acknowledged" || (historical && action["status"] == "failed")
      return [] unless action["type"] == "dependency_handoff"

      exact_idle_receipt = consumer["observed_state"] == "awaiting_handoff" &&
        Support.present?(consumer["task_id"]) && Support.present?(consumer["runtime_project_id"]) &&
        Support.present?(consumer["host_id"])
      durable_unresolved_receipt = historical && action["status"] == "prepared" &&
        Support.present?(consumer["runtime_project_id"]) && Support.present?(consumer["host_id"]) &&
        !Support.present?(consumer["task_id"]) &&
        (
          (consumer["observed_state"] == "dispatch_pending" && Support.present?(consumer["pending_client_id"])) ||
          consumer["observed_state"] == "dispatch_unknown"
        )
      return [] if durable_unresolved_receipt
      return ["action #{action['id']} cannot target a stale consumer"] if stale_delivery_target?(consumer, mission)
      if !historical && action["status"] == "failed" && consumer["observed_state"] != "planned"
        return ["action #{action['id']} failed dependency handoff is not retryable after a dispatch receipt"]
      end

      if require_receipt
        exact_idle_receipt ? [] :
          ["action #{action['id']} delivery requires an awaiting_handoff task, runtime project, and host receipt"]
      elsif consumer["observed_state"] == "planned" || exact_idle_receipt
        []
      else
        ["action #{action['id']} dependency handoff requires a planned consumer or awaiting_handoff receipt"]
      end
    end

    def validate_action_artifact_binding!(mission, action)
      return true unless action["type"] == "dependency_handoff"

      by_id = nodes(mission).to_h { |node| [node["id"], node] }
      consumer = by_id[action.dig("payload", "node_id")]
      raise ValidationError, "action #{action['id']} targets undeclared node" unless consumer

      errors = validate_action_artifact_binding(action, consumer, by_id)
      raise ValidationError, errors.join("; ") unless errors.empty?

      true
    end

    def prepared_dependency_handoff!(mission, consumer)
      candidates = outbox(mission).select do |action|
        action["type"] == "dependency_handoff" && action["status"] == "prepared" &&
          action.dig("payload", "node_id") == consumer["id"]
      end
      unless candidates.length == 1
        raise ValidationError,
              "dependent node #{consumer['id']} requires its exact prepared dependency handoff before dispatch"
      end

      action = candidates.first
      errors = validate_action_handoff_completeness(action, consumer, mission)
      errors.concat(validate_action_artifact_binding(action, consumer, nodes(mission).to_h { |node| [node["id"], node] }))
      raise ValidationError, errors.join("; ") unless errors.empty?

      action
    end

    def validate_action_delivery!(mission, action, require_receipt: false)
      return true unless action["type"] == "dependency_handoff"

      consumer = find_node!(mission, action.dig("payload", "node_id"))
      errors = validate_action_delivery(action, consumer, mission: mission, require_receipt: require_receipt)
      raise ValidationError, errors.join("; ") unless errors.empty?

      true
    end

    def validate_artifact_resolver(resolver, context)
      return [] if resolver.nil?
      return ["#{context} artifact resolver must be a mapping or null"] unless resolver.is_a?(Hash)

      errors = []
      unknown = resolver.keys - %w[kind id]
      missing = %w[kind id].reject { |field| resolver.key?(field) }
      errors << "#{context} artifact resolver contains forbidden fields: #{unknown.join(', ')}" unless unknown.empty?
      errors << "#{context} artifact resolver missing fields: #{missing.join(', ')}" unless missing.empty?
      unless ARTIFACT_RESOLVER_KINDS.include?(resolver["kind"].to_s)
        errors << "#{context} artifact resolver kind is invalid"
      end
      begin
        validate_identifier!(resolver["id"], "#{context} artifact resolver ID")
      rescue UsageError => e
        errors << e.message
      end
      errors
    end

    def artifact_ref?(ref)
      ref.is_a?(Hash) && ref["ref"].to_s.start_with?("artifact:")
    end

    def apply_stale_states!(mission)
      nodes(mission).each do |node|
        node["observed_state"] = "stale" if stale_delivery_target?(node, mission)
      end
      mission
    end

    def stale_delivery_target?(node, mission)
      return true if node["observed_state"] == "stale"
      return false unless %w[running dispatch_pending].include?(node["observed_state"])

      reference = node["observed_at"] || node["dispatched_at"] || node["updated_at"]
      return false unless reference

      @clock.call - Time.iso8601(reference) > mission.dig("spec", "budgets", "stale_after_seconds").to_i
    rescue ArgumentError
      true
    end

    def finish_action(slug, action_id, state, code)
      mutate(slug) do |mission|
        enforce_open!(mission)
        action = find_action!(mission, action_id)
        validate_action_authorization!(mission, action)
        validate_action_artifact_binding!(mission, action)
        if state == "acknowledged"
          validate_action_delivery!(mission, action, require_receipt: action["type"] == "dependency_handoff")
        end
        raise ValidationError, "action #{action_id} is not prepared" unless action["status"] == "prepared"
        now = timestamp
        action["status"] = state
        action["updated_at"] = now
        action["acknowledged_at"] = state == "acknowledged" ? now : nil
        action["failure_code"] = code
        if state == "acknowledged" && action["type"] == "dependency_handoff"
          consumer = find_node!(mission, action.dig("payload", "node_id"))
          consumer["observed_state"] = "running"
          consumer["updated_at"] = now
        end
        record_event!(mission, state == "acknowledged" ? "action_acknowledged" : "action_failed",
                      "action_id" => action_id, "code" => code)
      end
    end

    def derive_state!(mission, touch: true)
      state = MissionGraph.new(nodes(mission)).derive_state(current_state: mission.dig("status", "state"))
      mission["status"]["state"] = state
      mission["metadata"]["updated_at"] = timestamp if touch
      state
    end

    def validate_mission_authorization!(mission)
      boundary = mission.dig("spec", "authorization_boundary")
      validate_identifier!(boundary, "mission authorization boundary")
      targets = normalize_authorized_targets!(mission.dig("spec", "authorized_targets"))
      expected = derive_authorization_boundary(
        mission.dig("metadata", "id"), targets,
        mission.dig("spec", "success_criteria"), mission.dig("spec", "non_goals")
      )
      unless boundary == expected
        raise ValidationError, "mission authorization boundary does not match normalized authorized scope and intent"
      end
      nodes(mission).each do |node|
        target = AUTHORIZED_TARGET_FIELDS.to_h { |field| [field, node[field]] }
        unless targets.include?(target)
          raise ValidationError, "node #{node['id']} is outside the mission authorized target scope"
        end
        unless node["authorization_boundary"] == boundary
          raise ValidationError, "node #{node['id']} authorization boundary does not match mission"
        end
        Array(node["dependencies"]).each do |dependency_id|
          producer = nodes(mission).find { |item| item["id"] == dependency_id }
          next unless producer
          unless producer["authorization_boundary"] == node["authorization_boundary"]
            raise ValidationError, "dependency authorization boundary mismatch for #{producer['id']} -> #{node['id']}"
          end
        end
      end
      true
    rescue UsageError => e
      raise ValidationError, e.message
    end

    def validate_action_authorization!(mission, action)
      validate_mission_authorization!(mission)
      boundary = mission.dig("spec", "authorization_boundary")
      unless action["authorization_boundary"] == boundary
        raise ValidationError, "action #{action['id']} authorization boundary does not match mission"
      end
      true
    end

    def nodes(mission)
      mission.dig("spec", "graph", "nodes")
    end

    def outbox(mission)
      mission.dig("status", "outbox")
    end

    def find_node!(mission, node_id)
      node = nodes(mission).find { |item| item["id"] == node_id.to_s }
      raise ValidationError, "unknown mission node: #{node_id}" unless node

      node
    end

    def find_action!(mission, action_id)
      action = outbox(mission).find { |item| item["id"] == action_id.to_s }
      raise ValidationError, "unknown mission action: #{action_id}" unless action

      action
    end

    def record_event!(mission, event, fields = {})
      mission.dig("status", "history") << { "at" => timestamp, "event" => event }.merge(fields.compact)
      mission.dig("status", "history").shift while mission.dig("status", "history").length > 2048
    end

    def enforce_open!(mission)
      raise ValidationError, "mission is already complete" if mission.dig("status", "state") == "complete"
    end

    def enforce_graph_mutable!(mission)
      return unless graph_frozen?(mission)

      raise ValidationError,
            "mission graph is frozen once execution begins; create a new mission for newly discovered owners"
    end

    def graph_frozen?(mission)
      execution_markers = nodes(mission).any? do |node|
        Support.present?(node["task_id"]) ||
          Support.present?(node["pending_client_id"]) ||
          Support.present?(node["dispatched_at"]) ||
          Support.present?(node["observed_at"]) ||
          Support.present?(node["cursor"]) ||
          !node["revision"].nil? ||
          Support.present?(node["event_id"]) ||
          !Array(node["seen_event_ids"]).empty? ||
          node["retries"].to_i.positive? ||
          Support.present?(node["status_code"]) ||
          Support.present?(node["outcome_code"]) ||
          Support.present?(node["validation_status"]) ||
          !Array(node["output_refs"]).empty? ||
          !Array(node["criterion_results"]).empty? ||
          node["observed_state"] != "planned"
      end
      mission.dig("status", "state") != "planned" || execution_markers || !outbox(mission).empty?
    end

    def enforce_no_prepared!(mission)
      if outbox(mission).any? { |action| action["status"] == "prepared" }
        raise ValidationError, "prepared side effect is unacknowledged"
      end
    end

    def enforce_duration!(mission)
      created = Time.iso8601(mission.dig("metadata", "created_at"))
      maximum = mission.dig("spec", "budgets", "max_duration_seconds").to_i
      raise ValidationError, "mission duration budget exhausted" if @clock.call - created > maximum
    end

    def validate_or_raise!(mission, expected_slug: nil)
      errors = validate_object(mission, expected_slug: expected_slug)
      raise ValidationError, errors.join("; ") unless errors.empty?
    end

    def validate_opaque!(value, label)
      string = value.to_s
      unless !string.empty? && string.bytesize <= 512 && !string.match?(/[\u0000-\u001f\u007f]/)
        raise UsageError, "#{label} must be an opaque non-control string up to 512 bytes"
      end
      string
    end

    def validate_identifier!(value, label)
      Support.validate_identifier!(value, label: label)
      raise UsageError, "#{label} exceeds 128 bytes" if value.to_s.bytesize > 128
    end

    def validate_text!(value, label, max:)
      text = value.to_s.strip
      raise UsageError, "#{label} cannot be blank" unless Support.present?(text)
      raise UsageError, "#{label} exceeds #{max} bytes" if text.bytesize > max
      raise UsageError, "#{label} contains control characters" if text.match?(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/)
      raise UsageError, "#{label} appears to contain a secret" if SECRET_VALUE.match?(text)
      text
    end

    def normalize_bounded_text!(value, label)
      validate_text!(value, label, max: 1024)
    end

    def validate_text_list(value, label, min:)
      return ["#{label} must be a list"] unless value.is_a?(Array)

      errors = []
      errors << "#{label} requires at least #{min} item" if value.length < min
      errors << "#{label} entries must be unique" unless value.uniq.length == value.length
      value.each_with_index do |item, index|
        unless item.is_a?(String)
          errors << "#{label}[#{index}] must be a string"
          next
        end
        begin
          normalize_bounded_text!(item, "#{label}[#{index}]")
        rescue UsageError => e
          errors << e.message
        end
      end
      errors
    end

    def normalize_artifact_resolver!(kind, id)
      if Support.present?(kind) != Support.present?(id)
        raise UsageError, "--artifact-resolver-kind and --artifact-resolver-id must be provided together"
      end
      return nil unless Support.present?(kind)

      unless ARTIFACT_RESOLVER_KINDS.include?(kind.to_s)
        raise UsageError, "artifact resolver kind must be same_host_workspace or external_approved"
      end
      validate_identifier!(id, "artifact resolver ID")
      { "kind" => kind.to_s, "id" => id.to_s }
    end

    def normalize_authorized_targets!(values)
      targets = Array(values).map.with_index do |value, index|
        unless value.is_a?(Hash)
          raise UsageError, "authorized target #{index} must be a mapping"
        end
        target = Support.stringify(value)
        unknown = target.keys - AUTHORIZED_TARGET_FIELDS
        missing = AUTHORIZED_TARGET_FIELDS.reject { |field| target.key?(field) }
        raise UsageError, "authorized target #{index} contains forbidden fields: #{unknown.join(', ')}" unless unknown.empty?
        raise UsageError, "authorized target #{index} missing fields: #{missing.join(', ')}" unless missing.empty?
        AUTHORIZED_TARGET_FIELDS.each do |field|
          raise UsageError, "authorized target #{index}.#{field} must be a string" unless target[field].is_a?(String)
        end
        Support.validate_identifier!(target["logical_project_key"], label: "authorized target logical project key")
        validate_opaque!(target["runtime_project_id"], "authorized target runtime project ID")
        validate_opaque!(target["host_id"], "authorized target host ID")
        unless SHA256.match?(target["project_path_digest"].to_s)
          raise UsageError, "authorized target project path digest must be a lowercase sha256"
        end
        unless EXECUTION_MODES.include?(target["execution_mode"].to_s)
          raise UsageError, "authorized target execution mode must be local or worktree"
        end
        unless %w[read_only write].include?(target["access_mode"].to_s)
          raise UsageError, "authorized target access mode must be read_only or write"
        end
        AUTHORIZED_TARGET_FIELDS.to_h { |field| [field, target[field].to_s] }
      end
      sorted = targets.sort_by { |target| canonical_json(target) }
      raise UsageError, "authorized targets must be unique" unless sorted.uniq.length == sorted.length

      sorted
    end

    def validate_authorized_targets(value)
      return ["spec.authorized_targets must be a list"] unless value.is_a?(Array)

      normalized = normalize_authorized_targets!(value)
      normalized == value ? [] : ["spec.authorized_targets must use canonical sorted normalized form"]
    rescue UsageError => e
      [e.message]
    end

    def derive_authorization_boundary(slug, targets, criteria, non_goals)
      digest = Digest::SHA256.hexdigest(
        canonical_json(
          "mission_id" => slug,
          "authorized_targets" => targets,
          "success_criteria" => criteria,
          "non_goals" => non_goals
        )
      )
      "scope-#{digest[0, 48]}"
    end

    def validate_success_criteria(value)
      return ["spec.success_criteria must be a list"] unless value.is_a?(Array)

      errors = []
      errors << "spec.success_criteria requires at least 1 item" if value.empty?
      ids = []
      texts = []
      value.each_with_index do |criterion, index|
        unless criterion.is_a?(Hash)
          errors << "spec.success_criteria[#{index}] must be a mapping"
          next
        end
        unknown = criterion.keys - %w[id text]
        missing = %w[id text].reject { |field| criterion.key?(field) }
        errors << "spec.success_criteria[#{index}] contains forbidden fields: #{unknown.join(', ')}" unless unknown.empty?
        errors << "spec.success_criteria[#{index}] missing fields: #{missing.join(', ')}" unless missing.empty?
        expected_id = format("criterion-%03d", index + 1)
        errors << "spec.success_criteria[#{index}].id must equal #{expected_id}" unless criterion["id"] == expected_id
        unless criterion["text"].is_a?(String)
          errors << "spec.success_criteria[#{index}].text must be a string"
          next
        end
        begin
          normalize_bounded_text!(criterion["text"], "spec.success_criteria[#{index}].text")
        rescue UsageError => e
          errors << e.message
        end
        ids << criterion["id"]
        texts << criterion["text"]
      end
      errors << "spec.success_criteria IDs must be unique" unless ids.uniq.length == ids.length
      errors << "spec.success_criteria text must be unique" unless texts.uniq.length == texts.length
      errors
    end

    def criterion_coverage_errors(mission)
      criterion_ids = Array(mission.dig("spec", "success_criteria")).filter_map do |criterion|
        criterion["id"] if criterion.is_a?(Hash)
      end
      required_assignments = nodes(mission).select { |node| node["required"] == true }.flat_map do |node|
        Array(node["criterion_ids"])
      end.uniq
      missing = criterion_ids - required_assignments
      missing.empty? ? [] : ["required mission nodes do not cover criterion IDs: #{missing.join(', ')}"]
    end

    def enforce_criterion_coverage!(mission)
      errors = criterion_coverage_errors(mission)
      raise ValidationError, errors.join("; ") unless errors.empty?

      true
    end

    def validate_criterion_results(node, criterion_ids)
      results = node["criterion_results"]
      return ["node #{node['id']} criterion_results must be a list"] unless results.is_a?(Array)

      errors = []
      result_ids = []
      results.each_with_index do |result, index|
        unless result.is_a?(Hash)
          errors << "node #{node['id']} criterion result #{index} must be a mapping"
          next
        end
        unknown = result.keys - %w[criterion_id disposition status_code]
        missing = %w[criterion_id disposition status_code].reject { |field| result.key?(field) }
        errors << "node #{node['id']} criterion result #{index} contains forbidden fields: #{unknown.join(', ')}" unless unknown.empty?
        errors << "node #{node['id']} criterion result #{index} missing fields: #{missing.join(', ')}" unless missing.empty?
        result_ids << result["criterion_id"]
        unless CRITERION_DISPOSITIONS.include?(result["disposition"].to_s)
          errors << "node #{node['id']} criterion result #{index} disposition is invalid"
        end
        begin
          validate_identifier!(result["criterion_id"], "node #{node['id']} criterion result ID")
          validate_identifier!(result["status_code"], "node #{node['id']} criterion result status code")
        rescue UsageError => e
          errors << e.message
        end
      end
      final = %w[review_ready failed_validation complete].include?(node["observed_state"])
      if final && result_ids != criterion_ids
        errors << "node #{node['id']} terminal criterion results must exactly match assigned criterion IDs in order"
      elsif !final && !results.empty?
        errors << "node #{node['id']} nonterminal state must not persist criterion results"
      end
      if %w[review_ready complete].include?(node["observed_state"]) &&
         results.any? { |result| !result.is_a?(Hash) || result["disposition"] != "passed" }
        errors << "node #{node['id']} review-ready criterion results must all pass"
      end
      if node["observed_state"] == "failed_validation" &&
         results.all? { |result| result.is_a?(Hash) && result["disposition"] == "passed" }
        errors << "node #{node['id']} failed validation requires at least one unmet criterion"
      end
      errors
    end

    def task_identity_binding(task_id)
      return nil unless Support.present?(task_id)

      Base64.urlsafe_encode64(task_id.to_s, padding: false)
    end

    def action_idempotency_key(mission_id, boundary, type, trigger_digest, payload)
      Digest::SHA256.hexdigest(
        [mission_id, boundary, type, trigger_digest, canonical_json(payload)].join("\0")
      )
    end

    def identifier?(value)
      Support::IDENTIFIER.match?(value.to_s) && value.to_s.bytesize <= 128
    end

    def canonical_json(value)
      JSON.generate(canonical_value(value))
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

    def normalize_project_identity(path, digest)
      if path
        expanded = File.expand_path(path.to_s)
        raise UsageError, "project path must be absolute" unless Pathname.new(path.to_s).absolute?
        [expanded, Digest::SHA256.hexdigest(expanded)]
      else
        value = digest.to_s.downcase
        raise UsageError, "project path digest must be a lowercase sha256" unless SHA256.match?(value)
        [nil, value]
      end
    end

    def verify_project_identity!(node, path, digest)
      return unless path || digest

      actual_path, actual_digest = normalize_project_identity(path, digest)
      if node["project_path"] && actual_path != node["project_path"]
        raise ValidationError, "dispatch project path identity drift for #{node['id']}"
      end
      if actual_digest != node["project_path_digest"]
        raise ValidationError, "dispatch project path digest identity drift for #{node['id']}"
      end
    end

    def scan_safe_persisted!(value, path = "$", ancestors = {})
      identity = value.object_id
      if value.is_a?(Hash) || value.is_a?(Array)
        raise ValidationError, "mission record contains a recursive value" if ancestors[identity]
        ancestors[identity] = true
      end
      case value
      when Hash
        value.each do |key, item|
          raise ValidationError, "mission record contains secret-like field #{path}.#{key}" if SECRET_KEY.match?(key.to_s)
          scan_safe_persisted!(item, "#{path}.#{key}", ancestors)
        end
      when Array
        value.each_with_index { |item, index| scan_safe_persisted!(item, "#{path}[#{index}]", ancestors) }
      when String
        raise ValidationError, "mission record field #{path} exceeds 2048 bytes" if value.bytesize > 2048
        raise ValidationError, "mission record field #{path} appears to contain a secret" if SECRET_VALUE.match?(value)
      end
    ensure
      ancestors.delete(identity) if value.is_a?(Hash) || value.is_a?(Array)
    end

    def required_budgets
      %w[
        max_units max_retries max_actions max_forwarded_bytes
        max_duration_seconds stale_after_seconds max_record_bytes
      ]
    end

    def mission_dir(slug)
      Support.contained_path(config.mission_dir, slug.to_s, label: "mission slug")
    end

    def mission_path(slug)
      File.join(mission_dir(slug), "mission.yaml")
    end

    def with_lock(slug, shared:)
      directory = mission_dir(slug)
      raise ValidationError, "mission does not exist: #{slug}" unless File.directory?(directory)
      mode = shared ? File::LOCK_SH : File::LOCK_EX
      with_file_lock(File.join(directory, ".lock"), mode) { yield }
    end

    def with_file_lock(path, mode)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
        acquired = lock.flock(mode | File::LOCK_NB)
        raise ValidationError, "mission concurrent writer or lease conflict" unless acquired

        yield
      ensure
        lock.flock(File::LOCK_UN) if acquired
      end
    end

    def timestamp
      @clock.call.utc.iso8601(6)
    end
  end
end
