# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "openssl"
require "securerandom"
require "time"

module Flightdeck
  # Durable service-side authorization and renderer-safe observation boundary
  # for OMP-backed execution of an already-confirmed authored Operation.
  # Conversation runtime binding remains owned by WorkStore and is never
  # substituted by this adapter.
  class OmpOperationExecution
    EXECUTION_CAPABILITY = "flightdeck.command.omp-operation-execution.v1"
    OBSERVATION_CAPABILITY = "flightdeck.command.omp-operation-observation.v1"
    PLAN_REQUEST = "flightdeck.omp-operation.execution-plan-request/v1"
    PLAN_RESULT = "flightdeck.omp-operation.execution-plan-result/v1"
    BIND_REQUEST = "flightdeck.omp-operation.bind-request/v1"
    BIND_RESULT = "flightdeck.omp-operation.bind-result/v1"
    OBSERVE_REQUEST = "flightdeck.omp-operation.observe-request/v1"
    OBSERVE_RESULT = "flightdeck.omp-operation.observe-result/v1"
    OPEN_REQUEST = "flightdeck.omp-operation.open-request/v1"
    OPEN_RESULT = "flightdeck.omp-operation.open-result/v1"
    ERROR_RESULT = "flightdeck.omp-operation.error-result/v1"
    RECORD_VERSION = "flightdeck.omp-operation.record/v1"
    MAX_REQUEST_BYTES = 131_072
    MAX_RECORD_BYTES = 2_097_152
    MAX_OBSERVATIONS = 200
    MAX_AGENTS = 50
    MAX_TASK_BYTES = 8_192
    MAX_SUMMARY_BYTES = 2_048
    MAX_ACTION_BYTES = 512
    MAX_SUBAGENTS = 1_000
    MAX_SEQUENCE = 1_000_000
    EXECUTION_ID = /\Aomp-execution-[0-9a-f]{24}\z/
    EXECUTION_GENERATION = /\Aomp-execution-generation-[0-9a-f]{48}\z/
    AGENT_ID = /\Aflightdeck-agent-[0-9a-f]{48}\z/
    BINDING_GENERATION = /\Aomp-binding-generation-[0-9a-f]{48}\z/
    OPERATION_ID = /\Aoperation-[0-9a-f]{24}\z/
    WORK_ID = /\Awork-[0-9a-f]{24}\z/
    REQUEST_KEY = /\A[a-zA-Z0-9][a-zA-Z0-9._:-]{7,127}\z/
    OPAQUE_SESSION = /\A[A-Za-z0-9][A-Za-z0-9._:-]{7,511}\z/
    MODEL = /\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,127}\z/
    SHA256 = /\A[0-9a-f]{64}\z/
    EVIDENCE_REF = /\Aomp-evidence-[0-9a-f]{48}\z/
    SECRET_VALUE = /(?:-----BEGIN [A-Z ]*PRIVATE KEY-----|\bAKIA[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bBearer\s+[A-Za-z0-9._~+\/-]{16,}|\b(?:password|secret|access[_-]?token|oauth[_-]?token)\s*[:=]\s*\S+)/i
    LIFECYCLES = %w[
      queued starting running waiting needs_approval blocked review_ready
      failed_validation runtime_failure cancelled unknown_outcome
    ].freeze
    TERMINAL_LIFECYCLES = %w[review_ready failed_validation runtime_failure cancelled unknown_outcome].freeze
    TOOL_KINDS = %w[filesystem shell lsp subagent network other].freeze
    TOOL_STATUSES = %w[queued running succeeded failed blocked].freeze
    TOOL_PROFILES = %w[read_only workspace_write].freeze
    REASONING_EFFORTS = %w[low medium high xhigh].freeze
    SCHEMAS = %w[
      omp-operation-types.schema.json
      omp-operation-execution-plan-request.schema.json
      omp-operation-execution-plan-result.schema.json
      omp-operation-bind-request.schema.json
      omp-operation-bind-result.schema.json
      omp-operation-observe-request.schema.json
      omp-operation-observe-result.schema.json
      omp-operation-open-request.schema.json
      omp-operation-open-result.schema.json
      omp-operation-error-result.schema.json
    ].freeze

    class ContractError < ValidationError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    def initialize(config, clock: -> { Time.now.utc }, random_hex: ->(bytes) { SecureRandom.hex(bytes) })
      @config = config
      @clock = clock
      @random_hex = random_hex
    end

    def self.load_request(path)
      raise UsageError, "--request must name a JSON file" unless path.to_s.end_with?(".json")

      stat = File.lstat(path)
      raise UsageError, "--request must be a regular non-symlink JSON file" unless stat.file? && !stat.symlink?
      raise UsageError, "--request exceeds #{MAX_REQUEST_BYTES} bytes" if stat.size > MAX_REQUEST_BYTES

      content = File.read(path, MAX_REQUEST_BYTES + 1, encoding: "UTF-8")
      raise UsageError, "--request exceeds #{MAX_REQUEST_BYTES} bytes" if content.bytesize > MAX_REQUEST_BYTES
      value = JSON.parse(content)
      raise UsageError, "--request must contain one JSON object" unless value.is_a?(Hash)

      Support.stringify(value)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => e
      raise UsageError, "--request is unavailable: #{e.class}"
    rescue JSON::ParserError
      raise UsageError, "--request is invalid JSON"
    end

    def self.error_result(operation, error)
      code = error.respond_to?(:code) ? error.code : (error.is_a?(UsageError) ? "malformed_request" : "internal_error")
      {
        "schema_version" => ERROR_RESULT,
        "schema" => "hub/schemas/omp-operation-error-result.schema.json",
        "ok" => false,
        "operation" => operation,
        "error" => { "code" => code, "message" => error.message.to_s[0, 512] }
      }
    end

    # Authorizes OMP execution only after the exact Work proposal has been
    # launched and the current native dispatch plan has been re-verified.
    def plan(request)
      verify_capabilities!
      fields = %w[
        schema_version work_id operation_id confirmation dispatch_generation
        dispatch_plan_digest idempotency_key agents
      ]
      expect_object!(request, fields, "OMP execution plan request")
      expect_version!(request, PLAN_REQUEST)
      work_id = bounded_id!(request.fetch("work_id"), WORK_ID, "work_id")
      operation_id = bounded_id!(request.fetch("operation_id"), OPERATION_ID, "operation_id")
      idempotency_key = bounded_id!(request.fetch("idempotency_key"), REQUEST_KEY, "idempotency_key")
      confirmation = exact_confirmation!(request.fetch("confirmation"), operation_id)
      dispatch_generation = bounded_id!(request.fetch("dispatch_generation"), /\Adispatch-generation-[0-9a-f]{48}\z/, "dispatch_generation")
      dispatch_digest = sha256!(request.fetch("dispatch_plan_digest"), "dispatch_plan_digest")
      request_digest = Digest::SHA256.hexdigest(canonical_json(request.reject { |key, _| key == "idempotency_key" }))
      key_digest = Digest::SHA256.hexdigest(idempotency_key)

      with_lock(File::LOCK_EX) do
        existing = read_record(operation_id, allow_missing: true)
        if existing
          unless existing["work_id"] == work_id && existing["idempotency_key_digest"] == key_digest &&
                 existing["request_digest"] == request_digest
            raise ContractError.new("duplicate_request_conflict", "Operation execution identity is already bound to different content")
          end
          return plan_result(existing, replayed: true)
        end
      end

      lifecycle = launched_lifecycle!(work_id, operation_id, confirmation)
      dispatch = exact_dispatch_plan!(work_id, operation_id, dispatch_generation, dispatch_digest)
      mission = MissionStore.new(@config, clock: @clock).snapshot(operation_id)
      agents = normalize_agents!(request.fetch("agents"), mission, dispatch)

      with_lock(File::LOCK_EX) do
        existing = read_record(operation_id, allow_missing: true)
        if existing
          unless existing["work_id"] == work_id && existing["idempotency_key_digest"] == key_digest &&
                 existing["request_digest"] == request_digest
            raise ContractError.new("duplicate_request_conflict", "Operation execution identity is already bound to different content")
          end
          return plan_result(existing, replayed: true)
        end

        now = timestamp
        seed = Digest::SHA256.hexdigest(canonical_json([operation_id, request_digest, @random_hex.call(16)]))
        execution_id = "omp-execution-#{seed[0, 24]}"
        execution_digest = Digest::SHA256.hexdigest(canonical_json([
          EXECUTION_CAPABILITY, work_id, operation_id, lifecycle.fetch("proposal"), dispatch_generation,
          dispatch_digest, agents
        ]))
        execution_generation = "omp-execution-generation-#{execution_digest[0, 48]}"
        record = {
          "schema_version" => RECORD_VERSION,
          "work_id" => work_id,
          "operation_id" => operation_id,
          "execution_id" => execution_id,
          "execution_generation" => execution_generation,
          "execution_digest" => execution_digest,
          "adapter" => "omp",
          "state" => "authorized",
          "idempotency_key_digest" => key_digest,
          "request_digest" => request_digest,
          "authoring" => {
            "plan_id" => confirmation.fetch("plan_id"),
            "plan_generation" => confirmation.fetch("plan_generation"),
            "plan_digest" => confirmation.fetch("plan_digest"),
            "plan_token_digest" => Digest::SHA256.hexdigest(confirmation.fetch("plan_token")),
            "confirmation_digest" => Digest::SHA256.hexdigest(canonical_json(confirmation)),
            "state" => "confirmed"
          },
          "dispatch" => {
            "generation" => dispatch_generation,
            "plan_digest" => dispatch_digest,
            "strategy" => dispatch.dig("policy", "strategy"),
            "max_concurrency" => dispatch.dig("policy", "max_concurrency")
          },
          "agents" => agents.map do |agent|
            agent.merge(
              "binding" => {
                "state" => "unbound", "generation" => nil, "session_ref_digest" => nil,
                "idempotency_key_digest" => nil, "request_digest" => nil, "bound_at" => nil
              },
              "observations" => []
            )
          end,
          "created_at" => now,
          "updated_at" => now,
          "record_digest" => nil
        }
        write_record!(record)
        plan_result(record, replayed: false)
      end
    rescue WorkStore::ContractError => e
      raise translate_work_error(e)
    rescue ValidationError, ConfigurationError, KeyError => e
      raise e if e.is_a?(ContractError)

      raise ContractError.new("operation_identity_conflict", "authoritative launched Operation state is unavailable or malformed")
    end

    def bind(request)
      verify_capabilities!
      fields = %w[
        schema_version work_id operation_id execution_id execution_generation execution_digest
        agent_id binding_idempotency_key omp_session_ref
      ]
      expect_object!(request, fields, "OMP agent bind request")
      expect_version!(request, BIND_REQUEST)
      operation_id = bounded_id!(request.fetch("operation_id"), OPERATION_ID, "operation_id")
      idempotency_key = bounded_id!(request.fetch("binding_idempotency_key"), REQUEST_KEY, "binding_idempotency_key")
      session_ref = bounded_id!(request.fetch("omp_session_ref"), OPAQUE_SESSION, "omp_session_ref")

      with_lock(File::LOCK_EX) do
        record = read_record(operation_id)
        verify_execution_identity!(record, request)
        agent = find_agent!(record, request.fetch("agent_id"))
        session_digest = Digest::SHA256.hexdigest(session_ref)
        key_digest = Digest::SHA256.hexdigest(idempotency_key)
        content_digest = Digest::SHA256.hexdigest(canonical_json(
          request.reject { |key, _| %w[binding_idempotency_key omp_session_ref].include?(key) }
            .merge("omp_session_ref_digest" => session_digest)
        ))
        binding = agent.fetch("binding")
        if binding["state"] == "bound"
          unless binding["idempotency_key_digest"] == key_digest && binding["request_digest"] == content_digest &&
                 secure_equal?(binding["session_ref_digest"], session_digest)
            raise ContractError.new("duplicate_request_conflict", "Flightdeck agent is already bound to a different OMP session")
          end
          return bind_result(record, agent, replayed: true)
        end

        now = timestamp
        generation_digest = Digest::SHA256.hexdigest(canonical_json([
          record.fetch("execution_digest"), agent.fetch("agent_id"), session_digest, key_digest
        ]))
        binding.merge!(
          "state" => "bound",
          "generation" => "omp-binding-generation-#{generation_digest[0, 48]}",
          "session_ref_digest" => session_digest,
          "idempotency_key_digest" => key_digest,
          "request_digest" => content_digest,
          "bound_at" => now
        )
        record["state"] = "running"
        record["updated_at"] = now
        write_record!(record)
        bind_result(record, agent, replayed: false)
      end
    end

    def observe(request)
      verify_capabilities!
      fields = %w[
        schema_version work_id operation_id execution_id execution_generation execution_digest
        agent_id binding_generation observation_id sequence lifecycle action_summary tool subagents
        attention error_code observed_at final_result omp_session_ref signature
      ]
      expect_object!(request, fields, "OMP observation request")
      expect_version!(request, OBSERVE_REQUEST)
      operation_id = bounded_id!(request.fetch("operation_id"), OPERATION_ID, "operation_id")

      with_lock(File::LOCK_EX) do
        record = read_record(operation_id)
        verify_execution_identity!(record, request)
        agent = find_agent!(record, request.fetch("agent_id"))
        binding = agent.fetch("binding")
        raise ContractError.new("agent_unbound", "Flightdeck agent has no OMP session binding") unless binding["state"] == "bound"
        unless secure_equal?(binding.fetch("generation"), request.fetch("binding_generation").to_s)
          raise ContractError.new("stale_binding", "OMP observation does not match the current agent binding generation")
        end
        authenticate_observation!(binding, request)
        observation = normalize_observation!(request)
        key_digest = Digest::SHA256.hexdigest(observation.fetch("observation_id"))
        content_digest = Digest::SHA256.hexdigest(canonical_json(observation))
        replay = agent.fetch("observations").find { |item| item["observation_id_digest"] == key_digest }
        if replay
          unless replay["content_digest"] == content_digest
            raise ContractError.new("duplicate_request_conflict", "observation_id is already bound to different content")
          end
          return observe_result(record, agent, replayed: true)
        end
        observations = agent.fetch("observations")
        if observations.any? && TERMINAL_LIFECYCLES.include?(observations.last.fetch("lifecycle"))
          raise ContractError.new("out_of_order_observation", "terminal OMP agent lifecycle cannot accept another observation")
        end
        raise ContractError.new("observation_limit_exceeded", "agent observation history is full") if observations.length >= MAX_OBSERVATIONS
        expected_sequence = observations.empty? ? 1 : observations.last.fetch("sequence") + 1
        unless observation.fetch("sequence") == expected_sequence
          raise ContractError.new("out_of_order_observation", "OMP observation sequence is not the exact next sequence")
        end
        if observations.any? && Time.iso8601(observation.fetch("observed_at")) < Time.iso8601(observations.last.fetch("observed_at"))
          raise ContractError.new("out_of_order_observation", "OMP observation time precedes the accepted observation")
        end

        observations << observation.merge(
          "observation_id_digest" => key_digest,
          "content_digest" => content_digest
        ).reject { |key, _| key == "observation_id" }
        now = timestamp
        record["updated_at"] = [now, observation.fetch("observed_at")].max_by { |value| Time.iso8601(value) }
        record["state"] = derive_execution_state(record)
        write_record!(record)
        observe_result(record, agent, replayed: false)
      end
    end

    def open(request)
      verify_capabilities!
      fields = %w[schema_version work_id operation_id execution_id]
      expect_object!(request, fields, "OMP execution open request")
      expect_version!(request, OPEN_REQUEST)
      operation_id = bounded_id!(request.fetch("operation_id"), OPERATION_ID, "operation_id")
      with_existing_lock(File::LOCK_SH) do
        record = read_record(operation_id)
        unless record["work_id"] == request.fetch("work_id") && record["execution_id"] == request.fetch("execution_id")
          raise ContractError.new("operation_identity_conflict", "OMP recovery identity does not match the durable execution")
        end
        open_result(record)
      end
    end

    # Read-only authenticated projection used by Mission/Operations. It returns
    # no OMP session reference, binding secret, native project identity, task
    # text, prompt, or raw OMP payload.
    def mission_projection(operation_id)
      return {} unless OPERATION_ID.match?(operation_id.to_s)
      return {} unless File.file?(record_path(operation_id))

      verify_capabilities!
      with_existing_lock(File::LOCK_SH) do
        record = read_record(operation_id)
        record.fetch("agents").to_h do |agent|
          [agent.fetch("node_id"), safe_agent_projection(agent)]
        end
      end
    rescue ContractError
      raise
    rescue SystemCallError, IOError, JSON::ParserError
      raise ContractError.new("execution_store_invalid", "OMP execution state is unavailable or malformed")
    end

    def apply_to_mission!(mission)
      operation_id = mission.dig("metadata", "id")
      projections = mission_projection(operation_id)
      return mission if projections.empty?

      Array(mission.dig("spec", "graph", "nodes")).each do |node|
        projection = projections[node["id"]]
        next unless projection

        node["omp_execution"] = projection
        observation = projection["observation"]
        next unless observation

        node["observed_state"] = mission_state(observation.fetch("lifecycle"))
        node["status_code"] = "omp_#{observation.fetch('lifecycle')}"
        node["observed_at"] = observation.fetch("observed_at")
        node["updated_at"] = [node["updated_at"], observation.fetch("observed_at")].compact.max_by { |value| Time.iso8601(value) }
        if observation["lifecycle"] == "review_ready"
          node["validation_status"] = "passed"
          node["output_refs"] = Array(observation.dig("final_result", "evidence_refs")).map do |reference|
            { "type" => "review", "ref" => "review:omp/#{reference}", "digest" => Digest::SHA256.hexdigest(reference) }
          end
        elsif observation["lifecycle"] == "failed_validation"
          node["validation_status"] = "failed"
        end
      end
      projected_at = projections.values.filter_map { |projection| projection.dig("observation", "observed_at") }
        .max_by { |value| Time.iso8601(value) }
      if projected_at
        mission.fetch("metadata")["updated_at"] = [mission.dig("metadata", "updated_at"), projected_at]
          .compact.max_by { |value| Time.iso8601(value) }
      end
      mission
    end

    private

    def verify_capabilities!
      compatibility_path = File.join(@config.root, "hub", "compatibility.json")
      schema_paths = SCHEMAS.map { |name| File.join(@config.root, "hub", "schemas", name) }
      unless [compatibility_path, *schema_paths].all? { |path| File.file?(path) && !File.symlink?(path) }
        raise ContractError.new("unsupported_hub_contract", "Hub does not declare the OMP Operation execution contract")
      end
      compatibility = Support.load_data(compatibility_path)
      execution = compatibility.dig("capabilities", EXECUTION_CAPABILITY)
      observation = compatibility.dig("capabilities", OBSERVATION_CAPABILITY)
      runtime = compatibility["runtime_capabilities"]
      managed = Array(execution&.fetch("managed_paths", [])) + Array(observation&.fetch("managed_paths", []))
      required = ["lib/flightdeck/omp_operation_execution.rb", *SCHEMAS.map { |name| "hub/schemas/#{name}" }]
      valid = compatibility["schema_version"] == "flightdeck.hub-compatibility/v1" &&
        compatibility["product"] == "flightdeck" && compatibility["template_version"] == "1.8.0" &&
        execution.is_a?(Hash) && observation.is_a?(Hash) &&
        execution["kind"] == "command" && observation["kind"] == "command" &&
        execution["declaration_required"] == true && observation["declaration_required"] == true &&
        execution.dig("probe", "help_contains") == "bin/flightdeck operation execution-plan " &&
        observation.dig("probe", "help_contains") == "bin/flightdeck operation execution-open " &&
        runtime.dig("conversation", "adapter") == "codex" &&
        runtime.dig("operation_execution", "adapter") == "omp" &&
        runtime.dig("adapters", "codex", "available") == true &&
        runtime.dig("adapters", "omp", "available") == true &&
        required.all? { |path| managed.include?(path) }
      raise ContractError.new("unsupported_hub_contract", "Hub does not declare the OMP Operation execution contract") unless valid
    rescue ValidationError
      raise ContractError.new("unsupported_hub_contract", "Hub does not declare the OMP Operation execution contract")
    end

    def launched_lifecycle!(work_id, operation_id, confirmation)
      result = WorkStore.new(@config, clock: @clock).lifecycle_open(
        "schema_version" => WorkStore::LIFECYCLE_OPEN_REQUEST, "work_id" => work_id
      )
      lifecycle = result.fetch("proposals").find { |item| item.dig("proposal", "operation_id") == operation_id }
      unless lifecycle && lifecycle["state"] == "launched" && result.dig("active_operation", "operation_id") == operation_id
        raise ContractError.new("proposal_not_launched", "OMP execution requires the exact confirmed and launched Operation proposal")
      end
      expected = OperationAuthoring::CONFIRMATION_FIELDS.to_h { |field| [field, lifecycle.dig("proposal", field)] }
      unless secure_equal_json?(expected, confirmation)
        raise ContractError.new("stale_or_tampered_confirmation", "OMP execution confirmation does not match the launched proposal")
      end
      lifecycle
    end

    def exact_dispatch_plan!(work_id, operation_id, generation, digest)
      result = WorkStore.new(@config, clock: @clock).dispatch_plan(
        "schema_version" => WorkStore::DISPATCH_PLAN_REQUEST,
        "work_id" => work_id,
        "operation_id" => operation_id
      )
      unless secure_equal_json?(
        result.slice("dispatch_generation", "dispatch_plan_digest"),
        { "dispatch_generation" => generation, "dispatch_plan_digest" => digest }
      )
        raise ContractError.new("stale_or_mismatched_plan", "OMP execution does not match the current exact dispatch plan")
      end
      result
    end

    def exact_confirmation!(value, operation_id)
      expect_object!(value, OperationAuthoring::CONFIRMATION_FIELDS, "OMP execution confirmation")
      confirmation = Support.stringify(value)
      bounded_id!(confirmation.fetch("operation_id"), OPERATION_ID, "confirmation.operation_id")
      raise ContractError.new("operation_identity_conflict", "confirmation names a foreign Operation") unless confirmation["operation_id"] == operation_id
      bounded_id!(confirmation.fetch("plan_id"), /\Aplan-[0-9a-f]{48}\z/, "confirmation.plan_id")
      bounded_id!(confirmation.fetch("plan_generation"), /\Ageneration-[0-9a-f]{48}\z/, "confirmation.plan_generation")
      sha256!(confirmation.fetch("plan_digest"), "confirmation.plan_digest")
      sha256!(confirmation.fetch("plan_token"), "confirmation.plan_token")
      confirmation
    end

    def normalize_agents!(value, mission, dispatch)
      unless value.is_a?(Array) && value.length.between?(1, MAX_AGENTS)
        raise ContractError.new("malformed_request", "agents are outside the bounded Operation graph")
      end
      nodes = Array(mission.dig("spec", "graph", "nodes"))
      targets = dispatch.fetch("targets").to_h { |target| [target.fetch("node_id"), target] }
      by_node = value.map do |raw|
        fields = %w[node_id authorized_task requested_model reasoning_effort tool_policy]
        expect_object!(raw, fields, "OMP execution agent")
        node_id = bounded_id!(raw.fetch("node_id"), Support::IDENTIFIER, "agent.node_id")
        node = nodes.find { |candidate| candidate["id"] == node_id }
        target = targets[node_id]
        raise ContractError.new("operation_identity_conflict", "agent names a foreign Operation node") unless node && target
        task = safe_text!(raw.fetch("authorized_task"), "authorized_task", MAX_TASK_BYTES)
        model = raw["requested_model"]
        bounded_id!(model, MODEL, "requested_model") if model
        reasoning = raw.fetch("reasoning_effort")
        unless reasoning.nil? || REASONING_EFFORTS.include?(reasoning)
          raise ContractError.new("malformed_request", "reasoning_effort is unsupported")
        end
        tool_policy = normalize_tool_policy!(raw.fetch("tool_policy"), target.fetch("access_mode"))
        identity = Digest::SHA256.hexdigest(canonical_json([
          mission.dig("metadata", "id"), node_id, target.fetch("logical_project_key"),
          target.fetch("authorization_boundary"), dispatch.fetch("dispatch_plan_digest")
        ]))
        [node_id, {
          "agent_id" => "flightdeck-agent-#{identity[0, 48]}",
          "node_id" => node_id,
          "logical_project_key" => target.fetch("logical_project_key"),
          "dependencies" => Array(node["dependencies"]).sort,
          "execution_order" => topological_order(nodes).fetch(node_id),
          "authorized_task" => task,
          "requested_model" => model,
          "reasoning_effort" => reasoning,
          "tool_policy" => tool_policy,
          "native_authorization" => target.slice(
            "dispatch_id", "runtime_project_id", "project_path_digest", "host_id",
            "authorization_boundary", "execution_mode", "access_mode", "work_type"
          )
        }]
      end.to_h
      expected = nodes.map { |node| node.fetch("id") }.sort
      unless by_node.keys.sort == expected && by_node.length == value.length
        raise ContractError.new("operation_identity_conflict", "agents must exactly cover the authored Operation graph")
      end
      by_node.values.sort_by { |agent| [agent.fetch("execution_order"), agent.fetch("node_id")] }
    end

    def normalize_tool_policy!(value, access_mode)
      expect_object!(value, %w[profile allowed_tool_kinds network_access], "OMP tool policy")
      profile = value.fetch("profile")
      kinds = value.fetch("allowed_tool_kinds")
      network = value.fetch("network_access")
      unless TOOL_PROFILES.include?(profile) && kinds.is_a?(Array) && kinds.uniq == kinds &&
             kinds.length <= TOOL_KINDS.length && kinds.all? { |kind| TOOL_KINDS.include?(kind) } && [true, false].include?(network)
        raise ContractError.new("malformed_request", "OMP tool policy is invalid")
      end
      if access_mode == "read_only" && profile != "read_only"
        raise ContractError.new("authorization_conflict", "write-capable OMP tools exceed the authored read-only target")
      end
      if network || kinds.include?("network")
        raise ContractError.new("authorization_conflict", "external network tools require a separately declared authorization contract")
      end
      { "profile" => profile, "allowed_tool_kinds" => kinds.sort, "network_access" => false }
    end

    def topological_order(nodes)
      remaining = nodes.to_h { |node| [node.fetch("id"), Array(node["dependencies"])] }
      order = {}
      until remaining.empty?
        ready = remaining.select { |_id, dependencies| dependencies.all? { |dependency| order.key?(dependency) } }.keys.sort
        raise ContractError.new("operation_identity_conflict", "Operation dependency graph is cyclic") if ready.empty?
        ready.each do |id|
          dependencies = remaining.fetch(id)
          order[id] = dependencies.empty? ? 0 : dependencies.map { |dependency| order.fetch(dependency) }.max + 1
          remaining.delete(id)
        end
      end
      order
    end

    def normalize_observation!(request)
      lifecycle = request.fetch("lifecycle")
      raise ContractError.new("malformed_request", "OMP lifecycle is unsupported") unless LIFECYCLES.include?(lifecycle)
      sequence = request.fetch("sequence")
      unless sequence.is_a?(Integer) && sequence.between?(1, MAX_SEQUENCE)
        raise ContractError.new("malformed_request", "observation sequence is outside its bounded contract")
      end
      observation_id = bounded_id!(request.fetch("observation_id"), REQUEST_KEY, "observation_id")
      observed_at = canonical_time!(request.fetch("observed_at"), "observed_at")
      action = request["action_summary"]
      action = safe_text!(action, "action_summary", MAX_ACTION_BYTES) if action
      tool = normalize_tool!(request["tool"])
      subagents = normalize_subagents!(request.fetch("subagents"))
      attention = normalize_attention!(request.fetch("attention"))
      error_code = request["error_code"]
      bounded_id!(error_code, Support::IDENTIFIER, "error_code") if error_code
      final = normalize_final!(request["final_result"], lifecycle)
      {
        "observation_id" => observation_id,
        "sequence" => sequence,
        "lifecycle" => lifecycle,
        "action_summary" => action,
        "tool" => tool,
        "subagents" => subagents,
        "attention" => attention,
        "error_code" => error_code,
        "observed_at" => observed_at,
        "final_result" => final
      }
    end

    def normalize_tool!(value)
      return nil if value.nil?

      expect_object!(value, %w[kind status], "OMP tool observation")
      unless TOOL_KINDS.include?(value["kind"]) && TOOL_STATUSES.include?(value["status"])
        raise ContractError.new("malformed_request", "OMP tool observation is invalid")
      end
      Support.stringify(value)
    end

    def normalize_subagents!(value)
      fields = %w[active completed failed blocked]
      expect_object!(value, fields, "OMP subagent observation")
      unless fields.all? { |field| value[field].is_a?(Integer) && value[field].between?(0, MAX_SUBAGENTS) }
        raise ContractError.new("malformed_request", "OMP subagent counts are invalid")
      end
      Support.stringify(value)
    end

    def normalize_attention!(value)
      expect_object!(value, %w[required code], "OMP attention observation")
      unless [true, false].include?(value["required"])
        raise ContractError.new("malformed_request", "attention.required must be boolean")
      end
      code = value["code"]
      bounded_id!(code, Support::IDENTIFIER, "attention.code") if code
      if value["required"] != !code.nil?
        raise ContractError.new("malformed_request", "attention code must be present exactly when attention is required")
      end
      Support.stringify(value)
    end

    def normalize_final!(value, lifecycle)
      terminal = TERMINAL_LIFECYCLES.include?(lifecycle)
      if value.nil?
        raise ContractError.new("malformed_request", "terminal OMP observations require final_result") if terminal
        return nil
      end
      raise ContractError.new("malformed_request", "nonterminal OMP observations cannot include final_result") unless terminal

      expect_object!(value, %w[summary evidence_refs], "OMP final result")
      summary = safe_text!(value.fetch("summary"), "final_result.summary", MAX_SUMMARY_BYTES)
      refs = value.fetch("evidence_refs")
      unless refs.is_a?(Array) && refs.length.between?(lifecycle == "review_ready" ? 1 : 0, 50) &&
             refs.uniq == refs && refs.all? { |reference| EVIDENCE_REF.match?(reference.to_s) }
        raise ContractError.new("malformed_request", "final evidence references are outside their bounded contract")
      end
      { "summary" => summary, "evidence_refs" => refs.sort }
    end

    def authenticate_observation!(binding, request)
      session_ref = bounded_id!(request.fetch("omp_session_ref"), OPAQUE_SESSION, "omp_session_ref")
      unless secure_equal?(Digest::SHA256.hexdigest(session_ref), binding.fetch("session_ref_digest"))
        raise ContractError.new("authentication_failed", "OMP session binding does not match the Flightdeck agent")
      end
      signature = request.fetch("signature").to_s
      raise ContractError.new("authentication_failed", "OMP observation signature is invalid") unless SHA256.match?(signature)
      payload = request.reject { |key, _| %w[omp_session_ref signature].include?(key) }
      expected = OpenSSL::HMAC.hexdigest("SHA256", session_ref, canonical_json(payload))
      raise ContractError.new("authentication_failed", "OMP observation signature is invalid") unless secure_equal?(signature, expected)
    end

    def verify_execution_identity!(record, request)
      exact = {
        "work_id" => record.fetch("work_id"),
        "operation_id" => record.fetch("operation_id"),
        "execution_id" => record.fetch("execution_id"),
        "execution_generation" => record.fetch("execution_generation"),
        "execution_digest" => record.fetch("execution_digest")
      }
      actual = exact.keys.to_h { |field| [field, request[field]] }
      unless secure_equal_json?(exact, actual)
        raise ContractError.new("operation_identity_conflict", "OMP request does not match the exact durable execution identity")
      end
    end

    def find_agent!(record, agent_id)
      bounded_id!(agent_id, AGENT_ID, "agent_id")
      agent = record.fetch("agents").find { |candidate| candidate["agent_id"] == agent_id }
      raise ContractError.new("operation_identity_conflict", "agent_id is foreign to this Operation execution") unless agent

      agent
    end

    def plan_result(record, replayed:)
      {
        "schema_version" => PLAN_RESULT,
        "schema" => "hub/schemas/omp-operation-execution-plan-result.schema.json",
        "ok" => true,
        "capability" => EXECUTION_CAPABILITY,
        "work_id" => record.fetch("work_id"),
        "operation_id" => record.fetch("operation_id"),
        "execution" => execution_projection(record),
        "authorization" => authorization_projection(record),
        "runtime_boundary" => { "conversation" => "codex", "operation_execution" => "omp" },
        "policy" => record.fetch("dispatch").slice("strategy", "max_concurrency"),
        "agents" => record.fetch("agents").map { |agent| native_agent_projection(agent) },
        "replayed" => replayed
      }
    end

    def bind_result(record, agent, replayed:)
      {
        "schema_version" => BIND_RESULT,
        "schema" => "hub/schemas/omp-operation-bind-result.schema.json",
        "ok" => true,
        "capability" => EXECUTION_CAPABILITY,
        "operation_id" => record.fetch("operation_id"),
        "execution_id" => record.fetch("execution_id"),
        "agent_id" => agent.fetch("agent_id"),
        "binding" => agent.fetch("binding").slice("state", "generation", "bound_at"),
        "replayed" => replayed
      }
    end

    def observe_result(record, agent, replayed:)
      {
        "schema_version" => OBSERVE_RESULT,
        "schema" => "hub/schemas/omp-operation-observe-result.schema.json",
        "ok" => true,
        "capability" => OBSERVATION_CAPABILITY,
        "operation_id" => record.fetch("operation_id"),
        "execution_id" => record.fetch("execution_id"),
        "execution_state" => record.fetch("state"),
        "agent" => safe_agent_projection(agent),
        "replayed" => replayed
      }
    end

    def open_result(record)
      {
        "schema_version" => OPEN_RESULT,
        "schema" => "hub/schemas/omp-operation-open-result.schema.json",
        "ok" => true,
        "capability" => OBSERVATION_CAPABILITY,
        "work_id" => record.fetch("work_id"),
        "operation_id" => record.fetch("operation_id"),
        "execution" => execution_projection(record),
        "authorization" => authorization_projection(record),
        "runtime_boundary" => { "conversation" => "codex", "operation_execution" => "omp" },
        "progress" => progress_projection(record),
        "agents" => record.fetch("agents").map { |agent| safe_agent_projection(agent) }
      }
    end

    def execution_projection(record)
      record.slice("execution_id", "execution_generation", "execution_digest", "state", "created_at", "updated_at")
    end

    def authorization_projection(record)
      record.fetch("authoring").slice(
        "state", "plan_id", "plan_generation", "plan_digest", "plan_token_digest", "confirmation_digest"
      ).merge(
        "dispatch_generation" => record.dig("dispatch", "generation"),
        "dispatch_plan_digest" => record.dig("dispatch", "plan_digest")
      )
    end

    def native_agent_projection(agent)
      agent.slice(
        "agent_id", "node_id", "logical_project_key", "dependencies", "execution_order",
        "authorized_task", "requested_model", "reasoning_effort", "tool_policy", "native_authorization"
      ).merge("binding_state" => agent.dig("binding", "state"))
    end

    def safe_agent_projection(agent)
      latest = agent.fetch("observations").last
      observation = latest&.reject { |key, _| %w[observation_id_digest content_digest].include?(key) }
      {
        "agent_id" => agent.fetch("agent_id"),
        "node_id" => agent.fetch("node_id"),
        "logical_project_key" => agent.fetch("logical_project_key"),
        "dependencies" => agent.fetch("dependencies"),
        "execution_order" => agent.fetch("execution_order"),
        "requested_model" => agent["requested_model"],
        "binding_state" => agent.dig("binding", "state"),
        "observation" => observation
      }
    end

    def progress_projection(record)
      projections = record.fetch("agents").map { |agent| safe_agent_projection(agent) }
      counts = LIFECYCLES.to_h { |state| [state, projections.count { |agent| agent.dig("observation", "lifecycle") == state }] }
      counts["unobserved"] = projections.count { |agent| agent["observation"].nil? }
      {
        "counts" => counts,
        "attention_required" => projections.count { |agent| agent.dig("observation", "attention", "required") == true },
        "terminal" => projections.count { |agent| TERMINAL_LIFECYCLES.include?(agent.dig("observation", "lifecycle")) }
      }
    end

    def derive_execution_state(record)
      lifecycles = record.fetch("agents").filter_map { |agent| agent.dig("observations", -1, "lifecycle") }
      return "authorized" if lifecycles.empty?
      return "attention_required" if lifecycles.any? { |state| %w[needs_approval blocked unknown_outcome].include?(state) }
      return "failed" if lifecycles.any? { |state| %w[failed_validation runtime_failure].include?(state) }
      if lifecycles.length == record.fetch("agents").length && lifecycles.all? { |state| TERMINAL_LIFECYCLES.include?(state) }
        return "cancelled" if lifecycles.include?("cancelled")

        return "review_ready"
      end

      "running"
    end

    def mission_state(lifecycle)
      case lifecycle
      when "queued" then "dispatch_pending"
      when "starting", "running", "waiting" then "running"
      when "unknown_outcome" then "dispatch_unknown"
      else lifecycle
      end
    end

    def read_record(operation_id, allow_missing: false)
      path = record_path(operation_id)
      return nil if allow_missing && !File.exist?(path)
      stat = File.lstat(path)
      raise ContractError.new("execution_store_invalid", "OMP execution record is not a regular file") unless stat.file? && !stat.symlink?
      raise ContractError.new("execution_store_invalid", "OMP execution record exceeds its bounded contract") if stat.size > MAX_RECORD_BYTES
      record = JSON.parse(File.read(path, MAX_RECORD_BYTES + 1, encoding: "UTF-8"))
      validate_record!(Support.stringify(record), operation_id)
    rescue Errno::ENOENT
      raise ContractError.new("not_created", "OMP execution does not exist")
    rescue JSON::ParserError, Errno::EACCES, Errno::ELOOP
      raise ContractError.new("execution_store_invalid", "OMP execution state is unavailable or malformed")
    end

    def validate_record!(record, expected_operation_id = nil)
      fields = %w[
        schema_version work_id operation_id execution_id execution_generation execution_digest adapter state
        idempotency_key_digest request_digest authoring dispatch agents created_at updated_at record_digest
      ]
      expect_object!(record, fields, "OMP execution record", code: "execution_store_invalid")
      valid = record["schema_version"] == RECORD_VERSION && WORK_ID.match?(record["work_id"].to_s) &&
        OPERATION_ID.match?(record["operation_id"].to_s) && (!expected_operation_id || record["operation_id"] == expected_operation_id) &&
        EXECUTION_ID.match?(record["execution_id"].to_s) && EXECUTION_GENERATION.match?(record["execution_generation"].to_s) &&
        SHA256.match?(record["execution_digest"].to_s) && record["adapter"] == "omp" &&
        %w[authorized running attention_required failed cancelled review_ready].include?(record["state"]) &&
        SHA256.match?(record["idempotency_key_digest"].to_s) && SHA256.match?(record["request_digest"].to_s) &&
        record["agents"].is_a?(Array) && record["agents"].length.between?(1, MAX_AGENTS)
      raise ContractError.new("execution_store_invalid", "OMP execution record identity is invalid") unless valid
      canonical_time!(record["created_at"], "created_at", code: "execution_store_invalid")
      canonical_time!(record["updated_at"], "updated_at", code: "execution_store_invalid")
      expected_digest = Digest::SHA256.hexdigest(canonical_json(record.merge("record_digest" => nil)))
      unless secure_equal?(expected_digest, record["record_digest"])
        raise ContractError.new("execution_store_invalid", "OMP execution record digest is invalid")
      end
      validate_authoring_record!(record.fetch("authoring"))
      validate_dispatch_record!(record.fetch("dispatch"))
      record.fetch("agents").each { |agent| validate_persisted_agent!(agent) }
      unless record.fetch("agents").map { |agent| agent.fetch("agent_id") }.uniq.length == record.fetch("agents").length &&
             record.fetch("agents").map { |agent| agent.fetch("node_id") }.uniq.length == record.fetch("agents").length
        raise ContractError.new("execution_store_invalid", "OMP execution agent identities are not unique")
      end
      scan_safe!(record)
      record
    rescue ContractError => error
      raise error if error.code == "execution_store_invalid"

      raise ContractError.new("execution_store_invalid", "OMP execution record is invalid")
    end

    def validate_authoring_record!(authoring)
      fields = %w[plan_id plan_generation plan_digest plan_token_digest confirmation_digest state]
      expect_object!(authoring, fields, "OMP authoring binding record", code: "execution_store_invalid")
      unless authoring["plan_id"].to_s.match?(/\Aplan-[0-9a-f]{48}\z/) &&
             authoring["plan_generation"].to_s.match?(/\Ageneration-[0-9a-f]{48}\z/) &&
             %w[plan_digest plan_token_digest confirmation_digest].all? { |field| SHA256.match?(authoring[field].to_s) } &&
             authoring["state"] == "confirmed"
        raise ContractError.new("execution_store_invalid", "OMP authoring binding record is invalid")
      end
    end

    def validate_dispatch_record!(dispatch)
      fields = %w[generation plan_digest strategy max_concurrency]
      expect_object!(dispatch, fields, "OMP dispatch binding record", code: "execution_store_invalid")
      unless dispatch["generation"].to_s.match?(/\Adispatch-generation-[0-9a-f]{48}\z/) &&
             SHA256.match?(dispatch["plan_digest"].to_s) && dispatch["strategy"] == "parallel_independent" &&
             dispatch["max_concurrency"].is_a?(Integer) && dispatch["max_concurrency"].between?(1, 8)
        raise ContractError.new("execution_store_invalid", "OMP dispatch binding record is invalid")
      end
    end

    def validate_persisted_agent!(agent)
      fields = %w[
        agent_id node_id logical_project_key dependencies execution_order authorized_task requested_model
        reasoning_effort tool_policy native_authorization binding observations
      ]
      expect_object!(agent, fields, "OMP execution agent record", code: "execution_store_invalid")
      unless AGENT_ID.match?(agent["agent_id"].to_s) && Support::IDENTIFIER.match?(agent["node_id"].to_s) &&
             Support::IDENTIFIER.match?(agent["logical_project_key"].to_s) && agent["dependencies"].is_a?(Array) &&
             agent["dependencies"].uniq == agent["dependencies"] && agent["dependencies"].all? { |item| Support::IDENTIFIER.match?(item.to_s) } &&
             agent["execution_order"].is_a?(Integer) && agent["execution_order"] >= 0 &&
             agent["observations"].is_a?(Array) && agent["observations"].length <= MAX_OBSERVATIONS
        raise ContractError.new("execution_store_invalid", "OMP execution agent record is invalid")
      end
      safe_text!(agent["authorized_task"], "authorized_task", MAX_TASK_BYTES)
      unless (agent["requested_model"].nil? || MODEL.match?(agent["requested_model"].to_s)) &&
             (agent["reasoning_effort"].nil? || REASONING_EFFORTS.include?(agent["reasoning_effort"]))
        raise ContractError.new("execution_store_invalid", "OMP execution model policy is invalid")
      end
      validate_persisted_tool_policy!(agent.fetch("tool_policy"), agent.dig("native_authorization", "access_mode"))
      validate_native_authorization!(agent.fetch("native_authorization"))
      binding = agent.fetch("binding")
      expect_object!(binding, %w[state generation session_ref_digest idempotency_key_digest request_digest bound_at], "OMP binding record", code: "execution_store_invalid")
      if binding["state"] == "bound"
        unless BINDING_GENERATION.match?(binding["generation"].to_s) &&
               %w[session_ref_digest idempotency_key_digest request_digest].all? { |field| SHA256.match?(binding[field].to_s) }
          raise ContractError.new("execution_store_invalid", "OMP binding record is invalid")
        end
        canonical_time!(binding["bound_at"], "bound_at", code: "execution_store_invalid")
      elsif binding["state"] != "unbound" || binding.reject { |key, _| key == "state" }.values.any?
        raise ContractError.new("execution_store_invalid", "unbound OMP agent contains private binding state")
      end
      sequences = agent.fetch("observations").map { |observation| observation["sequence"] }
      unless sequences == (1..sequences.length).to_a
        raise ContractError.new("execution_store_invalid", "OMP observation sequence is invalid")
      end
      agent.fetch("observations").each { |observation| validate_persisted_observation!(observation) }
    end

    def validate_persisted_tool_policy!(policy, access_mode)
      expect_object!(policy, %w[profile allowed_tool_kinds network_access], "OMP persisted tool policy", code: "execution_store_invalid")
      kinds = policy["allowed_tool_kinds"]
      valid = TOOL_PROFILES.include?(policy["profile"]) && kinds.is_a?(Array) && kinds.uniq == kinds &&
        kinds.length <= TOOL_KINDS.length && kinds.all? { |kind| TOOL_KINDS.include?(kind) } &&
        policy["network_access"] == false && !kinds.include?("network") &&
        (access_mode != "read_only" || policy["profile"] == "read_only")
      raise ContractError.new("execution_store_invalid", "OMP persisted tool policy is invalid") unless valid
    end

    def validate_native_authorization!(authorization)
      fields = %w[
        dispatch_id runtime_project_id project_path_digest host_id authorization_boundary
        execution_mode access_mode work_type
      ]
      expect_object!(authorization, fields, "OMP native authorization record", code: "execution_store_invalid")
      valid = authorization["dispatch_id"].to_s.match?(/\Adispatch-[0-9a-f]{24}\z/) &&
        WorkStore::OPAQUE_RUNTIME_ID.match?(authorization["runtime_project_id"].to_s) &&
        SHA256.match?(authorization["project_path_digest"].to_s) &&
        Support::IDENTIFIER.match?(authorization["host_id"].to_s) &&
        Support::IDENTIFIER.match?(authorization["authorization_boundary"].to_s) &&
        %w[local worktree].include?(authorization["execution_mode"]) &&
        %w[read_only write].include?(authorization["access_mode"]) &&
        Support::IDENTIFIER.match?(authorization["work_type"].to_s)
      raise ContractError.new("execution_store_invalid", "OMP native authorization record is invalid") unless valid
    end

    def validate_persisted_observation!(observation)
      fields = %w[
        sequence lifecycle action_summary tool subagents attention error_code observed_at final_result
        observation_id_digest content_digest
      ]
      expect_object!(observation, fields, "OMP persisted observation", code: "execution_store_invalid")
      unless observation["sequence"].is_a?(Integer) && observation["sequence"].between?(1, MAX_SEQUENCE) &&
             LIFECYCLES.include?(observation["lifecycle"]) &&
             SHA256.match?(observation["observation_id_digest"].to_s) && SHA256.match?(observation["content_digest"].to_s)
        raise ContractError.new("execution_store_invalid", "OMP persisted observation is invalid")
      end
      canonical_time!(observation["observed_at"], "observed_at", code: "execution_store_invalid")
      safe_text!(observation["action_summary"], "action_summary", MAX_ACTION_BYTES) if observation["action_summary"]
      normalize_tool!(observation["tool"])
      normalize_subagents!(observation["subagents"])
      normalize_attention!(observation["attention"])
      bounded_id!(observation["error_code"], Support::IDENTIFIER, "error_code") if observation["error_code"]
      normalize_final!(observation["final_result"], observation["lifecycle"])
    rescue ContractError => error
      raise error if error.code == "execution_store_invalid"

      raise ContractError.new("execution_store_invalid", "OMP persisted observation is invalid")
    end

    def write_record!(record)
      record["record_digest"] = nil
      record["record_digest"] = Digest::SHA256.hexdigest(canonical_json(record))
      validate_record!(record, record.fetch("operation_id"))
      content = "#{JSON.pretty_generate(record)}\n"
      raise ContractError.new("execution_store_invalid", "OMP execution record exceeds its bounded contract") if content.bytesize > MAX_RECORD_BYTES
      FileUtils.mkdir_p(state_dir, mode: 0o700)
      Support.atomic_write(record_path(record.fetch("operation_id")), content)
    rescue SystemCallError, IOError
      raise ContractError.new("unknown_outcome", "OMP execution persistence was interrupted; recover with execution-open")
    end

    def state_dir
      @config.root_path("hub/state/omp-operation-execution", label: "OMP Operation execution state")
    end

    def record_path(operation_id)
      File.join(state_dir, "#{Digest::SHA256.hexdigest(operation_id.to_s)}.json")
    end

    def with_lock(mode)
      FileUtils.mkdir_p(state_dir, mode: 0o700)
      lock_path = File.join(state_dir, ".lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        unless lock.stat.file? && !File.symlink?(lock_path) && lock.flock(mode | File::LOCK_NB)
          raise ContractError.new("execution_store_invalid", "OMP execution state lock is unavailable")
        end
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise ContractError.new("execution_store_invalid", "OMP execution state lock is unavailable")
    end

    def with_existing_lock(mode)
      lock_path = File.join(state_dir, ".lock")
      File.open(lock_path, File::RDWR) do |lock|
        unless lock.stat.file? && !File.symlink?(lock_path) && lock.flock(mode | File::LOCK_NB)
          raise ContractError.new("execution_store_invalid", "OMP execution state lock is unavailable")
        end
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise ContractError.new("not_created", "OMP execution does not exist")
    end

    def expect_object!(value, fields, label, code: "malformed_request")
      unless value.is_a?(Hash) && value.keys.sort == fields.sort
        raise ContractError.new(code, "#{label} must contain exactly: #{fields.join(', ')}")
      end
    end

    def expect_version!(request, version)
      raise ContractError.new("unsupported_schema", "request schema_version is unsupported") unless request["schema_version"] == version
    end

    def bounded_id!(value, pattern, label)
      unless value.is_a?(String) && value.bytesize <= 512 && pattern.match?(value)
        raise ContractError.new("malformed_request", "#{label} is invalid")
      end
      value
    end

    def sha256!(value, label)
      bounded_id!(value, SHA256, label)
    end

    def safe_text!(value, label, maximum)
      unless value.is_a?(String) && !value.strip.empty? && value.bytesize <= maximum &&
             !value.match?(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/) &&
             !value.match?(SECRET_VALUE)
        raise ContractError.new("untrusted_payload", "#{label} is empty, oversized, unsafe, or secret-like")
      end
      value.strip
    end

    def canonical_time!(value, label, code: "malformed_request")
      parsed = Time.iso8601(value.to_s)
      raise ArgumentError unless value.is_a?(String) && value.end_with?("Z") && parsed.utc_offset.zero?
      value
    rescue ArgumentError
      raise ContractError.new(code, "#{label} must be a canonical UTC timestamp")
    end

    def scan_safe!(value, path = "record")
      case value
      when Hash
        value.each do |key, item|
          if key.to_s.match?(/(?:secret|password|credential|oauth|raw_prompt|raw_reasoning|system_prompt|tool_schema|environment_variables|omp_session_ref)/i)
            raise ContractError.new("execution_store_invalid", "OMP execution record contains a prohibited field")
          end
          scan_safe!(item, "#{path}.#{key}")
        end
      when Array
        value.each_with_index { |item, index| scan_safe!(item, "#{path}[#{index}]") }
      when String
        if value.bytesize > MAX_TASK_BYTES || value.match?(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/) || value.match?(SECRET_VALUE)
          raise ContractError.new("execution_store_invalid", "OMP execution record contains unsafe text")
        end
      end
    end

    def translate_work_error(error)
      code = case error.code
             when "not_created" then "proposal_not_launched"
             when "stale_or_mismatched_plan" then "stale_or_mismatched_plan"
             when "operation_identity_conflict", "conflicting_operation" then "operation_identity_conflict"
             when "unknown_outcome" then "unknown_outcome"
             else "operation_identity_conflict"
             end
      ContractError.new(code, "authoritative Work/Operation lifecycle rejected OMP execution: #{error.message}")
    end

    def timestamp
      @clock.call.utc.iso8601
    end

    def canonical_json(value)
      JSON.generate(canonicalize(value))
    end

    def canonicalize(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonicalize(value[key])] }
      when Array then value.map { |item| canonicalize(item) }
      else value
      end
    end

    def secure_equal_json?(left, right)
      secure_equal?(canonical_json(Support.stringify(left)), canonical_json(Support.stringify(right)))
    end

    def secure_equal?(left, right)
      left = left.to_s
      right = right.to_s
      left.bytesize == right.bytesize && OpenSSL.fixed_length_secure_compare(left, right)
    end
  end
end
