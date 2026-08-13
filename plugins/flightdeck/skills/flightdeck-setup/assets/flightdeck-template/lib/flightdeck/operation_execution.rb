# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "openssl"
require "securerandom"
require "time"

module Flightdeck
  # Durable service-side authorization and renderer-safe observation boundary
  # for adapter-backed execution of an already-confirmed authored Operation.
  # Conversation runtime binding remains owned by WorkStore and is never
  # substituted by this adapter.
  class OperationExecution
    EXECUTION_CAPABILITY = "flightdeck.command.operation-execution.v1"
    OBSERVATION_CAPABILITY = "flightdeck.command.operation-observation.v1"
    START_RECOVERY_CAPABILITY = "flightdeck.command.operation-start-recovery.v1"
    AGENT_TELEMETRY_CAPABILITY = "flightdeck.command.operation-agent-telemetry.v1"
    PLAN_REQUEST = "flightdeck.operation-execution.execution-plan-request/v1"
    PLAN_RESULT = "flightdeck.operation-execution.execution-plan-result/v1"
    BIND_REQUEST = "flightdeck.operation-execution.bind-request/v1"
    BIND_RESULT = "flightdeck.operation-execution.bind-result/v1"
    OBSERVE_REQUEST = "flightdeck.operation-execution.observe-request/v1"
    OBSERVE_RESULT = "flightdeck.operation-execution.observe-result/v1"
    OBSERVE_V2_REQUEST = "flightdeck.operation-execution.observe-request/v2"
    OBSERVE_V2_RESULT = "flightdeck.operation-execution.observe-result/v2"
    OPEN_REQUEST = "flightdeck.operation-execution.open-request/v1"
    OPEN_RESULT = "flightdeck.operation-execution.open-result/v1"
    OPEN_V2_REQUEST = "flightdeck.operation-execution.open-request/v2"
    OPEN_V2_RESULT = "flightdeck.operation-execution.open-result/v2"
    ERROR_RESULT = "flightdeck.operation-execution.error-result/v1"
    START_REPORT_REQUEST = "flightdeck.operation-execution.start-report-request/v1"
    START_REPORT_RESULT = "flightdeck.operation-execution.start-report-result/v1"
    START_OPEN_REQUEST = "flightdeck.operation-execution.start-open-request/v1"
    START_OPEN_RESULT = "flightdeck.operation-execution.start-open-result/v1"
    RETRY_BIND_REQUEST = "flightdeck.operation-execution.retry-bind-request/v1"
    RETRY_BIND_RESULT = "flightdeck.operation-execution.retry-bind-result/v1"
    RECORD_VERSION = "flightdeck.operation-execution.record/v3"
    PREVIOUS_RECORD_VERSION = "flightdeck.operation-execution.record/v2"
    LEGACY_RECORD_VERSION = "flightdeck.operation-execution.record/v1"
    ADAPTER_CONFIGURATIONS = {
      "omp" => "flightdeck.adapter.omp.configuration/v1",
      "codex_app_server" => "flightdeck.adapter.codex-app-server.configuration/v1"
    }.freeze
    ADAPTER_STRUCTURED_CHANNELS = {
      "omp" => "flightdeck.runtime.omp-operation-observation/v1",
      "codex_app_server" => "flightdeck.runtime.codex-app-server-operation-observation/v1"
    }.freeze
    MAX_REQUEST_BYTES = 131_072
    MAX_RECORD_BYTES = 2_097_152
    MAX_OBSERVATIONS = 200
    MAX_START_FAILURES = 8
    MAX_AGENTS = 50
    MAX_RUNTIME_AGENTS = 64
    MAX_RUNTIME_AGENT_UPDATES = 64
    MAX_RUNTIME_AGENT_EVENTS = 200
    MAX_VALIDATIONS = 50
    MAX_TASK_BYTES = 8_192
    MAX_SUMMARY_BYTES = 2_048
    MAX_ACTION_BYTES = 512
    MAX_SUBAGENTS = 1_000
    MAX_SEQUENCE = 1_000_000
    EXECUTION_ID = /\Aoperation-execution-[0-9a-f]{24}\z/
    EXECUTION_GENERATION = /\Aoperation-execution-generation-[0-9a-f]{48}\z/
    AGENT_ID = /\Aflightdeck-agent-[0-9a-f]{48}\z/
    RUNTIME_AGENT_ID = /\Aoperation-runtime-agent-[0-9a-f]{48}\z/
    BINDING_GENERATION = /\Aoperation-execution-binding-generation-[0-9a-f]{48}\z/
    RETRY_GENERATION = /\Aoperation-execution-retry-generation-[0-9a-f]{48}\z/
    OPERATION_ID = /\Aoperation-[0-9a-f]{24}\z/
    WORK_ID = /\Awork-[0-9a-f]{24}\z/
    REQUEST_KEY = /\A[a-zA-Z0-9][a-zA-Z0-9._:-]{7,127}\z/
    OPAQUE_SESSION = /\A[A-Za-z0-9][A-Za-z0-9._:-]{7,511}\z/
    MODEL = /\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,127}\z/
    SHA256 = /\A[0-9a-f]{64}\z/
    EVIDENCE_REF = /\Aoperation-evidence-[0-9a-f]{48}\z/
    SECRET_VALUE = /(?:-----BEGIN [A-Z ]*PRIVATE KEY-----|\bAKIA[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bBearer\s+[A-Za-z0-9._~+\/-]{16,}|\b(?:password|secret|access[_-]?token|oauth[_-]?token)\s*[:=]\s*\S+)/i
    LIFECYCLES = %w[
      queued starting running waiting needs_approval blocked review_ready
      failed_validation runtime_failure cancelled unknown_outcome
    ].freeze
    TERMINAL_LIFECYCLES = %w[review_ready failed_validation runtime_failure cancelled unknown_outcome].freeze
    TOOL_KINDS = %w[filesystem shell lsp subagent network other].freeze
    TOOL_STATUSES = %w[queued running succeeded failed blocked].freeze
    TOOL_PROFILES = %w[read_only workspace_write].freeze
    RUNTIME_AGENT_KINDS = %w[task_agent subagent].freeze
    RUNTIME_AGENT_SOURCES = %w[bundled user project plugin unknown].freeze
    RUNTIME_EVENT_KINDS = %w[activity tool skill file change approval].freeze
    RUNTIME_EVENT_STATUSES = %w[queued running succeeded failed blocked requested granted denied].freeze
    FILE_ACTIONS = %w[read created modified deleted renamed].freeze
    CHANGE_ACTIONS = %w[created modified deleted renamed].freeze
    APPROVAL_STATES = %w[requested granted denied cancelled].freeze
    VALIDATION_STATES = %w[queued running passed failed blocked skipped].freeze
    REASONING_EFFORTS = %w[low medium high xhigh].freeze
    SCHEMAS = %w[
      operation-execution-types.schema.json
      operation-agent-telemetry-types.schema.json
      operation-execution-plan-request.schema.json
      operation-execution-plan-result.schema.json
      operation-execution-bind-request.schema.json
      operation-execution-bind-result.schema.json
      operation-execution-start-report-request.schema.json
      operation-execution-start-report-result.schema.json
      operation-execution-start-open-request.schema.json
      operation-execution-start-open-result.schema.json
      operation-execution-retry-bind-request.schema.json
      operation-execution-retry-bind-result.schema.json
      operation-execution-observe-request.schema.json
      operation-execution-observe-result.schema.json
      operation-execution-observe-v2-request.schema.json
      operation-execution-observe-v2-result.schema.json
      operation-execution-open-request.schema.json
      operation-execution-open-result.schema.json
      operation-execution-open-v2-request.schema.json
      operation-execution-open-v2-result.schema.json
      operation-execution-error-result.schema.json
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
        "schema" => "hub/schemas/operation-execution-error-result.schema.json",
        "ok" => false,
        "operation" => operation,
        "error" => { "code" => code, "message" => error.message.to_s[0, 512] }
      }
    end

    def self.runtime_capabilities_projection!(value)
      unless value.is_a?(Hash) && value.keys.sort == %w[adapters conversation operation_execution primary_runtime] &&
             value["primary_runtime"] == "codex" && value["conversation"] == { "adapter" => "codex" }
        raise ContractError.new("unsupported_hub_contract", "Hub runtime capability metadata is invalid")
      end
      operation = value["operation_execution"]
      adapters = value["adapters"]
      unless operation.is_a?(Hash) && operation.keys.sort == %w[execution_capability observation_capability selected_adapter] &&
             operation["execution_capability"] == EXECUTION_CAPABILITY &&
             operation["observation_capability"] == OBSERVATION_CAPABILITY && adapters.is_a?(Hash) &&
             adapters.keys.sort == %w[codex codex_app_server omp]
        raise ContractError.new("unsupported_hub_contract", "Hub runtime capability metadata is invalid")
      end
      codex = adapters["codex"]
      codex_valid = codex.is_a?(Hash) && codex.keys.sort == %w[available optional_controls structured_channels] &&
        codex["available"] == true && codex["structured_channels"] == ["flightdeck.runtime.work-recommendation/v1"] &&
        codex["optional_controls"].is_a?(Array) && codex["optional_controls"].uniq == codex["optional_controls"] &&
        codex["optional_controls"].all? { |control| %w[model reasoning_effort].include?(control) }
      raise ContractError.new("unsupported_hub_contract", "Hub conversation adapter metadata is invalid") unless codex_valid

      ADAPTER_CONFIGURATIONS.each do |id, schema|
        adapter = adapters[id]
        fields = %w[available configuration_schema execution_capability observation_capability optional_controls structured_channels]
        expected_channels = adapter&.fetch("available", nil) == true ? [ADAPTER_STRUCTURED_CHANNELS.fetch(id)] : []
        valid = adapter.is_a?(Hash) && adapter.keys.sort == fields.sort && [true, false].include?(adapter["available"]) &&
          adapter["configuration_schema"] == schema && adapter["execution_capability"] == EXECUTION_CAPABILITY &&
          adapter["observation_capability"] == OBSERVATION_CAPABILITY &&
          adapter["optional_controls"] == %w[model reasoning_effort tool_policy] &&
          adapter["structured_channels"] == expected_channels
        raise ContractError.new("unsupported_hub_contract", "Hub #{id} adapter metadata is invalid") unless valid
      end

      selected_id = operation["selected_adapter"]
      raise ContractError.new("unsupported_adapter", "selected Operation execution adapter is unsupported") unless ADAPTER_CONFIGURATIONS.key?(selected_id)
      raise ContractError.new("adapter_unavailable", "selected Operation execution adapter is unavailable") unless adapters.dig(selected_id, "available") == true

      {
        "primary_runtime" => "codex",
        "conversation" => { "adapter" => "codex" },
        "operation_execution" => operation,
        "adapters" => {
          "codex" => codex.slice("available", "optional_controls"),
          "omp" => adapters.fetch("omp").slice("available", "configuration_schema", "optional_controls"),
          "codex_app_server" => adapters.fetch("codex_app_server").slice("available", "configuration_schema", "optional_controls")
        }
      }
    end

    # Authorizes adapter execution only after the exact Work proposal has been
    # launched and the current native dispatch plan has been re-verified.
    def plan(request)
      adapter = verify_capabilities!
      fields = %w[
        schema_version adapter work_id operation_id confirmation dispatch_generation
        dispatch_plan_digest idempotency_key agents
      ]
      expect_object!(request, fields, "Operation execution plan request")
      expect_version!(request, PLAN_REQUEST)
      verify_adapter!(request.fetch("adapter"), adapter)
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
      agents = normalize_agents!(request.fetch("agents"), mission, dispatch, adapter)

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
        execution_id = "operation-execution-#{seed[0, 24]}"
        execution_digest = Digest::SHA256.hexdigest(canonical_json([
          EXECUTION_CAPABILITY, work_id, operation_id, lifecycle.fetch("proposal"), dispatch_generation,
          dispatch_digest, agents
        ]))
        execution_generation = "operation-execution-generation-#{execution_digest[0, 48]}"
        record = {
          "schema_version" => RECORD_VERSION,
          "work_id" => work_id,
          "operation_id" => operation_id,
          "execution_id" => execution_id,
          "execution_generation" => execution_generation,
          "execution_digest" => execution_digest,
          "adapter" => adapter,
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
              "start" => empty_start_record,
              "runtime_agents" => [],
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
      adapter = verify_capabilities!
      fields = %w[
        schema_version adapter work_id operation_id execution_id execution_generation execution_digest
        agent_id binding_idempotency_key adapter_session_ref
      ]
      expect_object!(request, fields, "Operation execution agent bind request")
      expect_version!(request, BIND_REQUEST)
      verify_adapter!(request.fetch("adapter"), adapter)
      operation_id = bounded_id!(request.fetch("operation_id"), OPERATION_ID, "operation_id")
      idempotency_key = bounded_id!(request.fetch("binding_idempotency_key"), REQUEST_KEY, "binding_idempotency_key")
      session_ref = bounded_id!(request.fetch("adapter_session_ref"), OPAQUE_SESSION, "adapter_session_ref")

      with_lock(File::LOCK_EX) do
        record = read_record(operation_id)
        verify_execution_identity!(record, request)
        agent = find_agent!(record, request.fetch("agent_id"))
        session_digest = Digest::SHA256.hexdigest(session_ref)
        key_digest = Digest::SHA256.hexdigest(idempotency_key)
        content_digest = Digest::SHA256.hexdigest(canonical_json(
          request.reject { |key, _| %w[binding_idempotency_key adapter_session_ref].include?(key) }
            .merge("adapter_session_ref_digest" => session_digest)
        ))
        binding = agent.fetch("binding")
        if binding["state"] == "bound"
          unless binding["idempotency_key_digest"] == key_digest && binding["request_digest"] == content_digest &&
                 secure_equal?(binding["session_ref_digest"], session_digest)
            raise ContractError.new("duplicate_request_conflict", "Flightdeck agent is already bound to a different adapter session")
          end
          return bind_result(record, agent, replayed: true)
        end
        start = start_record(agent)
        if start["state"] == "retry_authorized"
          raise ContractError.new("retry_generation_required", "Agent start recovery requires execution-retry-bind")
        elsif start["state"] == "failed"
          raise ContractError.new("retry_not_authorized", "Agent start failure is not retryable")
        end

        now = timestamp
        generation_digest = Digest::SHA256.hexdigest(canonical_json([
          record.fetch("execution_digest"), agent.fetch("agent_id"), session_digest, key_digest
        ]))
        binding.merge!(
          "state" => "bound",
          "generation" => "operation-execution-binding-generation-#{generation_digest[0, 48]}",
          "session_ref_digest" => session_digest,
          "idempotency_key_digest" => key_digest,
          "request_digest" => content_digest,
          "bound_at" => now
        )
        upgrade_record!(record)
        agent.fetch("start").merge!("state" => "bound", "retry_generation" => nil)
        record["state"] = "running"
        record["updated_at"] = now
        write_record!(record)
        bind_result(record, agent, replayed: false)
      end
    end

    # Persists a bounded renderer-safe failure when an authorized agent could
    # not acquire an adapter session. This boundary deliberately precedes the
    # private session binding and therefore authenticates against the exact
    # execution, dispatch, agent, and native route authorization instead.
    def start_report(request)
      adapter = verify_capabilities!
      fields = %w[
        schema_version adapter work_id operation_id execution_id execution_generation execution_digest
        agent_id dispatch_generation dispatch_id runtime_project_id retry_generation report_id failure
      ]
      expect_object!(request, fields, "Operation execution start failure report")
      expect_version!(request, START_REPORT_REQUEST)
      verify_adapter!(request.fetch("adapter"), adapter)
      operation_id = bounded_id!(request.fetch("operation_id"), OPERATION_ID, "operation_id")
      report_id = bounded_id!(request.fetch("report_id"), REQUEST_KEY, "report_id")
      retry_generation = request["retry_generation"]
      bounded_id!(retry_generation, RETRY_GENERATION, "retry_generation") if retry_generation
      failure = normalize_start_failure!(request.fetch("failure"))
      key_digest = Digest::SHA256.hexdigest(report_id)
      content_digest = Digest::SHA256.hexdigest(canonical_json(
        request.reject { |key, _| key == "report_id" }.merge("failure" => failure)
      ))

      with_lock(File::LOCK_EX) do
        record = read_record(operation_id)
        verify_execution_identity!(record, request)
        agent = find_agent!(record, request.fetch("agent_id"))
        verify_start_route!(record, agent, request)
        start = start_record(agent)
        replay = start.fetch("failures").find { |item| item["report_id_digest"] == key_digest }
        if replay
          unless replay["content_digest"] == content_digest
            raise ContractError.new("duplicate_request_conflict", "start failure report ID is already bound to different content")
          end
          return start_report_result(record, agent, replay, replayed: true)
        end
        raise ContractError.new("agent_already_bound", "bound Flightdeck agent cannot report a start failure") if agent.dig("binding", "state") == "bound" || start["state"] == "bound"
        raise ContractError.new("retry_not_authorized", "Agent start failure is not retryable") if start["state"] == "failed"
        raise ContractError.new("start_failure_limit_exceeded", "Agent start failure history is full") if start.fetch("failures").length >= MAX_START_FAILURES

        expected_generation = start["state"] == "retry_authorized" ? start["retry_generation"] : nil
        unless retry_generation == expected_generation
          code = expected_generation ? "stale_retry_generation" : "authorization_conflict"
          raise ContractError.new(code, "start failure report does not match the authorized start generation")
        end

        sequence = start.fetch("failures").length + 1
        resulting_generation = if failure.fetch("retryable")
                                 digest = Digest::SHA256.hexdigest(canonical_json([
                                   record.fetch("execution_digest"), agent.fetch("agent_id"), sequence, content_digest
                                 ]))
                                 "operation-execution-retry-generation-#{digest[0, 48]}"
                               end
        resulting_state = resulting_generation ? "retry_authorized" : "failed"
        entry = {
          "sequence" => sequence,
          "report_id_digest" => key_digest,
          "content_digest" => content_digest,
          "attempt_generation" => retry_generation,
          "failure_code" => failure.fetch("code"),
          "summary" => failure.fetch("summary"),
          "retryable" => failure.fetch("retryable"),
          "failed_at" => failure.fetch("failed_at"),
          "resulting_state" => resulting_state,
          "resulting_retry_generation" => resulting_generation
        }
        upgrade_record!(record)
        agent.fetch("start").fetch("failures") << entry
        agent.fetch("start")["state"] = resulting_state
        agent.fetch("start")["retry_generation"] = resulting_generation
        record["state"] = "attention_required"
        record["updated_at"] = [timestamp, failure.fetch("failed_at")].max_by { |value| Time.iso8601(value) }
        write_record!(record)
        start_report_result(record, agent, entry, replayed: false)
      end
    end

    def start_open(request)
      adapter = verify_capabilities!
      fields = %w[schema_version adapter work_id operation_id execution_id agent_id]
      expect_object!(request, fields, "Operation execution start recovery request")
      expect_version!(request, START_OPEN_REQUEST)
      verify_adapter!(request.fetch("adapter"), adapter)
      operation_id = bounded_id!(request.fetch("operation_id"), OPERATION_ID, "operation_id")
      with_existing_lock(File::LOCK_SH) do
        record = read_record(operation_id)
        unless record["work_id"] == request.fetch("work_id") && record["execution_id"] == request.fetch("execution_id")
          raise ContractError.new("operation_identity_conflict", "start recovery identity does not match the durable execution")
        end
        agent = find_agent!(record, request.fetch("agent_id"))
        start_open_result(record, agent)
      end
    end

    def retry_bind(request)
      adapter = verify_capabilities!
      fields = %w[
        schema_version adapter work_id operation_id execution_id execution_generation execution_digest
        agent_id dispatch_generation dispatch_id runtime_project_id retry_generation
        binding_idempotency_key adapter_session_ref
      ]
      expect_object!(request, fields, "Operation execution retry bind request")
      expect_version!(request, RETRY_BIND_REQUEST)
      verify_adapter!(request.fetch("adapter"), adapter)
      operation_id = bounded_id!(request.fetch("operation_id"), OPERATION_ID, "operation_id")
      retry_generation = bounded_id!(request.fetch("retry_generation"), RETRY_GENERATION, "retry_generation")
      idempotency_key = bounded_id!(request.fetch("binding_idempotency_key"), REQUEST_KEY, "binding_idempotency_key")
      session_ref = bounded_id!(request.fetch("adapter_session_ref"), OPAQUE_SESSION, "adapter_session_ref")

      with_lock(File::LOCK_EX) do
        record = read_record(operation_id)
        verify_execution_identity!(record, request)
        agent = find_agent!(record, request.fetch("agent_id"))
        verify_start_route!(record, agent, request)
        session_digest = Digest::SHA256.hexdigest(session_ref)
        key_digest = Digest::SHA256.hexdigest(idempotency_key)
        content_digest = Digest::SHA256.hexdigest(canonical_json(
          request.reject { |key, _| %w[binding_idempotency_key adapter_session_ref].include?(key) }
            .merge("adapter_session_ref_digest" => session_digest)
        ))
        binding = agent.fetch("binding")
        if binding["state"] == "bound"
          unless binding["idempotency_key_digest"] == key_digest && binding["request_digest"] == content_digest &&
                 secure_equal?(binding["session_ref_digest"], session_digest)
            raise ContractError.new("duplicate_request_conflict", "Flightdeck agent is already bound to a different adapter session")
          end
          return retry_bind_result(record, agent, replayed: true)
        end

        start = start_record(agent)
        raise ContractError.new("retry_not_authorized", "Agent start retry is not authorized") unless start["state"] == "retry_authorized"
        unless start["retry_generation"] == retry_generation
          raise ContractError.new("stale_retry_generation", "retry bind does not match the current authorized start generation")
        end

        now = timestamp
        generation_digest = Digest::SHA256.hexdigest(canonical_json([
          record.fetch("execution_digest"), agent.fetch("agent_id"), session_digest, key_digest, retry_generation
        ]))
        binding.merge!(
          "state" => "bound",
          "generation" => "operation-execution-binding-generation-#{generation_digest[0, 48]}",
          "session_ref_digest" => session_digest,
          "idempotency_key_digest" => key_digest,
          "request_digest" => content_digest,
          "bound_at" => now
        )
        upgrade_record!(record)
        agent.fetch("start").merge!("state" => "bound", "retry_generation" => nil)
        record["state"] = "running"
        record["updated_at"] = now
        write_record!(record)
        retry_bind_result(record, agent, replayed: false)
      end
    end

    def observe(request)
      adapter = verify_capabilities!
      v2 = request["schema_version"] == OBSERVE_V2_REQUEST
      fields = %w[
        schema_version adapter work_id operation_id execution_id execution_generation execution_digest
        agent_id binding_generation observation_id sequence lifecycle action_summary tool subagents
        attention error_code observed_at final_result adapter_session_ref signature
      ]
      fields << "runtime_agent_updates" if v2
      expect_object!(request, fields, "Operation execution observation request")
      expect_version!(request, v2 ? OBSERVE_V2_REQUEST : OBSERVE_REQUEST)
      verify_adapter!(request.fetch("adapter"), adapter)
      operation_id = bounded_id!(request.fetch("operation_id"), OPERATION_ID, "operation_id")

      with_lock(File::LOCK_EX) do
        record = read_record(operation_id)
        verify_execution_identity!(record, request)
        agent = find_agent!(record, request.fetch("agent_id"))
        binding = agent.fetch("binding")
        raise ContractError.new("agent_unbound", "Flightdeck agent has no adapter session binding") unless binding["state"] == "bound"
        unless secure_equal?(binding.fetch("generation"), request.fetch("binding_generation").to_s)
          raise ContractError.new("stale_binding", "observation does not match the current agent binding generation")
        end
        authenticate_observation!(binding, request)
        observation = normalize_observation!(request)
        runtime_updates = v2 ? normalize_runtime_agent_updates!(request.fetch("runtime_agent_updates")) : []
        key_digest = Digest::SHA256.hexdigest(observation.fetch("observation_id"))
        content_digest = Digest::SHA256.hexdigest(canonical_json(
          observation.merge("runtime_agent_updates" => runtime_updates)
        ))
        replay = agent.fetch("observations").find { |item| item["observation_id_digest"] == key_digest }
        if replay
          unless replay["content_digest"] == content_digest
            raise ContractError.new("duplicate_request_conflict", "observation_id is already bound to different content")
          end
          return observe_result(record, agent, replayed: true, v2: v2)
        end
        observations = agent.fetch("observations")
        if observations.any? && TERMINAL_LIFECYCLES.include?(observations.last.fetch("lifecycle"))
          raise ContractError.new("out_of_order_observation", "terminal agent lifecycle cannot accept another observation")
        end
        raise ContractError.new("observation_limit_exceeded", "agent observation history is full") if observations.length >= MAX_OBSERVATIONS
        expected_sequence = observations.empty? ? 1 : observations.last.fetch("sequence") + 1
        unless observation.fetch("sequence") == expected_sequence
          raise ContractError.new("out_of_order_observation", "observation sequence is not the exact next sequence")
        end
        if observations.any? && Time.iso8601(observation.fetch("observed_at")) < Time.iso8601(observations.last.fetch("observed_at"))
          raise ContractError.new("out_of_order_observation", "observation time precedes the accepted observation")
        end

        if v2
          agent["runtime_agents"] = apply_runtime_agent_updates!(
            record, agent, runtime_updates, observation.fetch("observed_at")
          )
        end

        observations << observation.merge(
          "observation_id_digest" => key_digest,
          "content_digest" => content_digest
        ).reject { |key, _| key == "observation_id" }
        now = timestamp
        record["updated_at"] = [now, observation.fetch("observed_at")].max_by { |value| Time.iso8601(value) }
        record["state"] = derive_execution_state(record)
        write_record!(record)
        observe_result(record, agent, replayed: false, v2: v2)
      end
    end

    def open(request)
      adapter = verify_capabilities!
      fields = %w[schema_version adapter work_id operation_id execution_id]
      expect_object!(request, fields, "Operation execution open request")
      v2 = request["schema_version"] == OPEN_V2_REQUEST
      expect_version!(request, v2 ? OPEN_V2_REQUEST : OPEN_REQUEST)
      verify_adapter!(request.fetch("adapter"), adapter)
      operation_id = bounded_id!(request.fetch("operation_id"), OPERATION_ID, "operation_id")
      with_existing_lock(File::LOCK_SH) do
        record = read_record(operation_id)
        unless record["work_id"] == request.fetch("work_id") && record["execution_id"] == request.fetch("execution_id")
          raise ContractError.new("operation_identity_conflict", "recovery identity does not match the durable execution")
        end
        open_result(record, v2: v2)
      end
    end

    # Read-only authenticated projection used by Mission/Operations. It returns
    # no adapter session reference, binding secret, native project identity,
    # task text, prompt, or raw adapter payload.
    def mission_projection(operation_id)
      mission_status_projection(operation_id, include_runtime_agents: false)
        .transform_values { |projection| projection.fetch("execution") }
    end

    def mission_status_projection(operation_id, include_runtime_agents: false)
      return {} unless OPERATION_ID.match?(operation_id.to_s)
      return {} unless File.file?(record_path(operation_id))

      verify_capabilities!
      with_existing_lock(File::LOCK_SH) do
        record = read_record(operation_id)
        record.fetch("agents").to_h do |agent|
          [agent.fetch("node_id"), {
            "execution" => safe_agent_projection(agent, include_runtime_agents: include_runtime_agents),
            "start" => safe_start_projection(agent)
          }]
        end
      end
    rescue ContractError
      raise
    rescue SystemCallError, IOError, JSON::ParserError
      raise ContractError.new("execution_store_invalid", "Operation execution state is unavailable or malformed")
    end

    def apply_to_mission!(mission)
      # Explicit completion owns the durable terminal state. A retained runtime
      # observation remains evidence, but must not reopen a completed Operation.
      return mission if mission.dig("status", "state") == "complete"

      operation_id = mission.dig("metadata", "id")
      projections = mission_status_projection(operation_id, include_runtime_agents: true)
      return mission if projections.empty?

      Array(mission.dig("spec", "graph", "nodes")).each do |node|
        status_projection = projections[node["id"]]
        next unless status_projection

        projection = status_projection.fetch("execution")
        node["operation_execution"] = projection
        start = status_projection.fetch("start")
        node["operation_execution_start"] = start
        observation = projection["observation"]
        unless observation
          latest_failure = start["latest_failure"]
          if latest_failure
            node["observed_state"] = start["state"] == "retry_authorized" ? "dispatch_unknown" : "runtime_failure"
            node["status_code"] = start["state"] == "retry_authorized" ? "execution_start_retry_authorized" : "execution_start_failed"
            node["observed_at"] = latest_failure.fetch("failed_at")
            node["updated_at"] = [node["updated_at"], latest_failure.fetch("failed_at")].compact.max_by { |value| Time.iso8601(value) }
          end
          next
        end

        if stale_observation?(mission, observation)
          node["observed_state"] = "stale"
          node["status_code"] = "execution_heartbeat_stale"
        else
          node["observed_state"] = mission_state(observation.fetch("lifecycle"))
          node["status_code"] = "execution_#{observation.fetch('lifecycle')}"
        end
        node["observed_at"] = observation.fetch("observed_at")
        node["updated_at"] = [node["updated_at"], observation.fetch("observed_at")].compact.max_by { |value| Time.iso8601(value) }
        if observation["lifecycle"] == "review_ready"
          node["validation_status"] = "passed"
          node["output_refs"] = Array(observation.dig("final_result", "evidence_refs")).map do |reference|
            { "type" => "review", "ref" => "review:operation-execution/#{reference}", "digest" => Digest::SHA256.hexdigest(reference) }
          end
        elsif observation["lifecycle"] == "failed_validation"
          node["validation_status"] = "failed"
        end
      end
      projected_at = projections.values.filter_map do |projection|
        projection.dig("execution", "observation", "observed_at") || projection.dig("start", "latest_failure", "failed_at")
      end
        .max_by { |value| Time.iso8601(value) }
      if projected_at
        mission.fetch("metadata")["updated_at"] = [mission.dig("metadata", "updated_at"), projected_at]
          .compact.max_by { |value| Time.iso8601(value) }
      end
      mission
    end

    private

    def stale_observation?(mission, observation)
      return false if TERMINAL_LIFECYCLES.include?(observation.fetch("lifecycle"))

      threshold = mission.dig("spec", "budgets", "stale_after_seconds")
      return false unless threshold.is_a?(Integer) && threshold.positive?

      @clock.call - Time.iso8601(observation.fetch("observed_at")) > threshold
    rescue ArgumentError
      true
    end

    def verify_capabilities!
      compatibility_path = File.join(@config.root, "hub", "compatibility.json")
      schema_paths = SCHEMAS.map { |name| File.join(@config.root, "hub", "schemas", name) }
      unless [compatibility_path, *schema_paths].all? { |path| File.file?(path) && !File.symlink?(path) }
        raise ContractError.new("unsupported_hub_contract", "Hub does not declare the Operation execution contract")
      end
      compatibility = Support.load_data(compatibility_path)
      execution = compatibility.dig("capabilities", EXECUTION_CAPABILITY)
      observation = compatibility.dig("capabilities", OBSERVATION_CAPABILITY)
      start_recovery = compatibility.dig("capabilities", START_RECOVERY_CAPABILITY)
      agent_telemetry = compatibility.dig("capabilities", AGENT_TELEMETRY_CAPABILITY)
      runtime = compatibility["runtime_capabilities"]
      self.class.runtime_capabilities_projection!(runtime)
      managed = Array(execution&.fetch("managed_paths", [])) + Array(observation&.fetch("managed_paths", [])) +
        Array(start_recovery&.fetch("managed_paths", [])) + Array(agent_telemetry&.fetch("managed_paths", []))
      required = ["lib/flightdeck/operation_execution.rb", *SCHEMAS.map { |name| "hub/schemas/#{name}" }]
      selected_id = runtime.dig("operation_execution", "selected_adapter")
      selected = runtime.dig("adapters", selected_id)

      valid = compatibility["schema_version"] == "flightdeck.hub-compatibility/v1" &&
        compatibility["product"] == "flightdeck" && compatibility["template_version"] == "1.12.0" &&
        execution.is_a?(Hash) && observation.is_a?(Hash) && start_recovery.is_a?(Hash) && agent_telemetry.is_a?(Hash) &&
        execution["kind"] == "command" && observation["kind"] == "command" && start_recovery["kind"] == "command" && agent_telemetry["kind"] == "command" &&
        execution["declaration_required"] == true && observation["declaration_required"] == true && start_recovery["declaration_required"] == true && agent_telemetry["declaration_required"] == true &&
        execution.dig("probe", "help_contains") == "bin/flightdeck operation execution-plan " &&
        observation.dig("probe", "help_contains") == "bin/flightdeck operation execution-open " &&
        start_recovery.dig("probe", "help_contains") == "bin/flightdeck operation execution-start-open " &&
        agent_telemetry.dig("probe", "help_contains") == "bin/flightdeck operation execution-open " &&
        selected.is_a?(Hash) && selected["configuration_schema"] == ADAPTER_CONFIGURATIONS.fetch(selected_id) &&
        selected["execution_capability"] == EXECUTION_CAPABILITY &&
        selected["observation_capability"] == OBSERVATION_CAPABILITY &&
        required.all? { |path| managed.include?(path) }
      raise ContractError.new("unsupported_hub_contract", "Hub does not declare the Operation execution contract") unless valid

      adapter_descriptor(selected_id, selected)
    rescue ContractError
      raise
    rescue ValidationError
      raise ContractError.new("unsupported_hub_contract", "Hub does not declare the Operation execution contract")
    end

    def adapter_descriptor(id, declaration)
      {
        "id" => id,
        "configuration_schema" => declaration.fetch("configuration_schema"),
        "execution_capability" => declaration.fetch("execution_capability"),
        "observation_capability" => declaration.fetch("observation_capability")
      }
    end

    def verify_adapter!(actual, expected)
      unless actual.is_a?(Hash) && ADAPTER_CONFIGURATIONS.key?(actual["id"])
        raise ContractError.new("unsupported_adapter", "Operation execution adapter is unsupported")
      end
      unless secure_equal_json?(actual, expected)
        raise ContractError.new("authorization_conflict", "Operation execution adapter does not match the selected Hub adapter")
      end
    end

    def launched_lifecycle!(work_id, operation_id, confirmation)
      result = WorkStore.new(@config, clock: @clock).lifecycle_open(
        "schema_version" => WorkStore::LIFECYCLE_OPEN_REQUEST, "work_id" => work_id
      )
      lifecycle = result.fetch("proposals").find { |item| item.dig("proposal", "operation_id") == operation_id }
      unless lifecycle && lifecycle["state"] == "launched" && result.dig("active_operation", "operation_id") == operation_id
        raise ContractError.new("proposal_not_launched", "Operation execution requires the exact confirmed and launched Operation proposal")
      end
      expected = OperationAuthoring::CONFIRMATION_FIELDS.to_h { |field| [field, lifecycle.dig("proposal", field)] }
      unless secure_equal_json?(expected, confirmation)
        raise ContractError.new("stale_or_tampered_confirmation", "Operation execution confirmation does not match the launched proposal")
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
        raise ContractError.new("stale_or_mismatched_plan", "Operation execution does not match the current exact dispatch plan")
      end
      result
    end

    def exact_confirmation!(value, operation_id)
      expect_object!(value, OperationAuthoring::CONFIRMATION_FIELDS, "Operation execution confirmation")
      confirmation = Support.stringify(value)
      bounded_id!(confirmation.fetch("operation_id"), OPERATION_ID, "confirmation.operation_id")
      raise ContractError.new("operation_identity_conflict", "confirmation names a foreign Operation") unless confirmation["operation_id"] == operation_id
      bounded_id!(confirmation.fetch("plan_id"), /\Aplan-[0-9a-f]{48}\z/, "confirmation.plan_id")
      bounded_id!(confirmation.fetch("plan_generation"), /\Ageneration-[0-9a-f]{48}\z/, "confirmation.plan_generation")
      sha256!(confirmation.fetch("plan_digest"), "confirmation.plan_digest")
      sha256!(confirmation.fetch("plan_token"), "confirmation.plan_token")
      confirmation
    end

    def normalize_agents!(value, mission, dispatch, adapter)
      unless value.is_a?(Array) && value.length.between?(1, MAX_AGENTS)
        raise ContractError.new("malformed_request", "agents are outside the bounded Operation graph")
      end
      nodes = Array(mission.dig("spec", "graph", "nodes"))
      targets = dispatch.fetch("targets").to_h { |target| [target.fetch("node_id"), target] }
      by_node = value.map do |raw|
        fields = %w[node_id authorized_task adapter_configuration]
        expect_object!(raw, fields, "Operation execution agent")
        node_id = bounded_id!(raw.fetch("node_id"), Support::IDENTIFIER, "agent.node_id")
        node = nodes.find { |candidate| candidate["id"] == node_id }
        target = targets[node_id]
        raise ContractError.new("operation_identity_conflict", "agent names a foreign Operation node") unless node && target
        task = safe_text!(raw.fetch("authorized_task"), "authorized_task", MAX_TASK_BYTES)
        configuration = raw.fetch("adapter_configuration")
        expect_object!(configuration, %w[adapter_id schema_version requested_model reasoning_effort tool_policy], "adapter configuration")
        unless configuration["adapter_id"] == adapter["id"] && configuration["schema_version"] == adapter["configuration_schema"]
          raise ContractError.new("authorization_conflict", "agent adapter configuration does not match the selected adapter")
        end
        model = configuration["requested_model"]
        bounded_id!(model, MODEL, "requested_model") if model
        reasoning = configuration.fetch("reasoning_effort")
        unless reasoning.nil? || REASONING_EFFORTS.include?(reasoning)
          raise ContractError.new("malformed_request", "reasoning_effort is unsupported")
        end
        tool_policy = normalize_tool_policy!(configuration.fetch("tool_policy"), target.fetch("access_mode"))
        adapter_configuration = {
          "adapter_id" => adapter.fetch("id"),
          "schema_version" => adapter.fetch("configuration_schema"),
          "requested_model" => model,
          "reasoning_effort" => reasoning,
          "tool_policy" => tool_policy
        }
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
          "adapter_configuration" => adapter_configuration,
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
      expect_object!(value, %w[profile allowed_tool_kinds network_access], "adapter tool policy")
      profile = value.fetch("profile")
      kinds = value.fetch("allowed_tool_kinds")
      network = value.fetch("network_access")
      unless TOOL_PROFILES.include?(profile) && kinds.is_a?(Array) && kinds.uniq == kinds &&
             kinds.length <= TOOL_KINDS.length && kinds.all? { |kind| TOOL_KINDS.include?(kind) } && [true, false].include?(network)
        raise ContractError.new("malformed_request", "adapter tool policy is invalid")
      end
      if access_mode == "read_only" && profile != "read_only"
        raise ContractError.new("authorization_conflict", "write-capable adapter tools exceed the authored read-only target")
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
      raise ContractError.new("malformed_request", "Operation execution lifecycle is unsupported") unless LIFECYCLES.include?(lifecycle)
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

    def normalize_runtime_agent_updates!(value)
      unless value.is_a?(Array) && value.length <= MAX_RUNTIME_AGENT_UPDATES
        raise ContractError.new("malformed_request", "runtime agent updates exceed their bounded contract")
      end
      updates = value.map do |raw|
        fields = %w[
          runtime_agent_ref parent_runtime_agent_ref parent_tool_call_ref runtime_session_ref agent_kind reported_name reported_role
          source project_scope lifecycle activity_summary event structured_yield validations error terminal_result
        ]
        expect_object!(raw, fields, "runtime agent update")
        runtime_ref = bounded_id!(raw.fetch("runtime_agent_ref"), OPAQUE_SESSION, "runtime_agent_ref")
        parent_ref = raw["parent_runtime_agent_ref"]
        bounded_id!(parent_ref, OPAQUE_SESSION, "parent_runtime_agent_ref") if parent_ref
        parent_tool_call_ref = raw["parent_tool_call_ref"]
        bounded_id!(parent_tool_call_ref, OPAQUE_SESSION, "parent_tool_call_ref") if parent_tool_call_ref
        session_ref = raw["runtime_session_ref"]
        bounded_id!(session_ref, OPAQUE_SESSION, "runtime_session_ref") if session_ref
        kind = raw.fetch("agent_kind")
        source = raw.fetch("source")
        lifecycle = raw.fetch("lifecycle")
        unless RUNTIME_AGENT_KINDS.include?(kind) && RUNTIME_AGENT_SOURCES.include?(source) && LIFECYCLES.include?(lifecycle)
          raise ContractError.new("malformed_request", "runtime agent classification or lifecycle is unsupported")
        end
        if kind == "task_agent" && (parent_ref || parent_tool_call_ref)
          raise ContractError.new("inconsistent_agent_identity", "runtime task agents cannot name a runtime parent")
        elsif kind == "subagent" && [parent_ref, parent_tool_call_ref].compact.length > 1
          raise ContractError.new("inconsistent_agent_identity", "runtime subagents cannot name conflicting parent evidence")
        end
        raise ContractError.new("inconsistent_agent_identity", "runtime agent cannot parent itself") if parent_ref == runtime_ref
        scope = raw.fetch("project_scope")
        expect_object!(scope, %w[node_id logical_project_key], "runtime agent project scope")
        node_id = bounded_id!(scope.fetch("node_id"), Support::IDENTIFIER, "project_scope.node_id")
        project_key = bounded_id!(scope.fetch("logical_project_key"), Support::IDENTIFIER, "project_scope.logical_project_key")
        event = normalize_runtime_event!(raw["event"])
        structured_yield = normalize_runtime_yield!(raw["structured_yield"])
        validations = normalize_runtime_validations!(raw.fetch("validations"))
        error = normalize_runtime_error!(raw["error"])
        terminal_result = normalize_runtime_terminal_result!(raw["terminal_result"], lifecycle)
        if lifecycle == "runtime_failure" && error.nil?
          raise ContractError.new("malformed_request", "runtime failure requires a bounded error")
        end
        if lifecycle == "needs_approval" && !(event && event["kind"] == "approval" && event.dig("detail", "state") == "requested")
          raise ContractError.new("malformed_request", "approval lifecycle requires a requested approval event")
        end
        {
          "runtime_agent_ref" => runtime_ref,
          "parent_runtime_agent_ref" => parent_ref,
          "parent_tool_call_ref" => parent_tool_call_ref,
          "runtime_session_ref" => session_ref,
          "agent_kind" => kind,
          "reported_name" => safe_text!(raw.fetch("reported_name"), "reported_name", 128),
          "reported_role" => safe_text!(raw.fetch("reported_role"), "reported_role", 128),
          "source" => source,
          "project_scope" => { "node_id" => node_id, "logical_project_key" => project_key },
          "lifecycle" => lifecycle,
          "activity_summary" => raw["activity_summary"] && safe_text!(raw["activity_summary"], "activity_summary", MAX_ACTION_BYTES),
          "event" => event,
          "structured_yield" => structured_yield,
          "validations" => validations,
          "error" => error,
          "terminal_result" => terminal_result
        }
      end
      refs = updates.map { |update| update.fetch("runtime_agent_ref") }
      unless refs.uniq.length == refs.length
        raise ContractError.new("duplicate_agent_identity", "runtime agent update contains duplicate identities")
      end
      updates
    end

    def normalize_runtime_event!(value)
      return nil if value.nil?

      expect_object!(value, %w[event_id sequence kind status summary occurred_at detail], "runtime agent event")
      event_id = bounded_id!(value.fetch("event_id"), REQUEST_KEY, "runtime event_id")
      sequence = value.fetch("sequence")
      kind = value.fetch("kind")
      status = value.fetch("status")
      unless sequence.is_a?(Integer) && sequence.between?(1, MAX_SEQUENCE) &&
             RUNTIME_EVENT_KINDS.include?(kind) && RUNTIME_EVENT_STATUSES.include?(status)
        raise ContractError.new("malformed_request", "runtime agent event is outside its bounded contract")
      end
      detail = normalize_runtime_event_detail!(kind, value["detail"])
      {
        "event_id" => event_id,
        "sequence" => sequence,
        "kind" => kind,
        "status" => status,
        "summary" => safe_text!(value.fetch("summary"), "runtime event summary", MAX_ACTION_BYTES),
        "occurred_at" => canonical_time!(value.fetch("occurred_at"), "runtime event occurred_at"),
        "detail" => detail
      }
    end

    def normalize_runtime_event_detail!(kind, value)
      case kind
      when "activity"
        raise ContractError.new("malformed_request", "activity event detail must be null") unless value.nil?
        nil
      when "tool"
        expect_object!(value, %w[name kind], "runtime tool event detail")
        tool_kind = value.fetch("kind")
        raise ContractError.new("malformed_request", "runtime tool kind is unsupported") unless TOOL_KINDS.include?(tool_kind)
        {
          "name" => safe_text!(value.fetch("name"), "tool name", 128),
          "kind" => tool_kind
        }
      when "skill"
        expect_object!(value, %w[skill_id source], "runtime skill event detail")
        source = value.fetch("source")
        raise ContractError.new("malformed_request", "skill source is unsupported") unless RUNTIME_AGENT_SOURCES.include?(source)
        {
          "skill_id" => bounded_id!(value.fetch("skill_id"), Support::IDENTIFIER, "skill_id"),
          "source" => source
        }
      when "file"
        expect_object!(value, %w[path action], "runtime file event detail")
        action = value.fetch("action")
        raise ContractError.new("malformed_request", "file action is unsupported") unless FILE_ACTIONS.include?(action)
        { "path" => safe_relative_path!(value.fetch("path")), "action" => action }
      when "change"
        expect_object!(value, %w[path action additions deletions evidence_ref], "runtime change event detail")
        action = value.fetch("action")
        additions = value.fetch("additions")
        deletions = value.fetch("deletions")
        evidence_ref = value["evidence_ref"]
        unless CHANGE_ACTIONS.include?(action) && additions.is_a?(Integer) && additions.between?(0, 1_000_000) &&
               deletions.is_a?(Integer) && deletions.between?(0, 1_000_000)
          raise ContractError.new("malformed_request", "change event detail is invalid")
        end
        bounded_id!(evidence_ref, EVIDENCE_REF, "change evidence_ref") if evidence_ref
        {
          "path" => safe_relative_path!(value.fetch("path")), "action" => action,
          "additions" => additions, "deletions" => deletions, "evidence_ref" => evidence_ref
        }
      when "approval"
        expect_object!(value, %w[approval_id state], "runtime approval event detail")
        state = value.fetch("state")
        raise ContractError.new("malformed_request", "approval state is unsupported") unless APPROVAL_STATES.include?(state)
        { "approval_id" => bounded_id!(value.fetch("approval_id"), REQUEST_KEY, "approval_id"), "state" => state }
      end
    end

    def normalize_runtime_yield!(value)
      return nil if value.nil?

      expect_object!(value, %w[summary evidence_refs], "runtime agent structured yield")
      {
        "summary" => safe_text!(value.fetch("summary"), "structured yield summary", MAX_SUMMARY_BYTES),
        "evidence_refs" => normalize_evidence_refs!(value.fetch("evidence_refs"), minimum: 0)
      }
    end

    def normalize_runtime_validations!(value)
      unless value.is_a?(Array) && value.length <= MAX_VALIDATIONS
        raise ContractError.new("malformed_request", "runtime validations exceed their bounded contract")
      end
      items = value.map do |item|
        expect_object!(item, %w[validation_id name status summary evidence_refs], "runtime validation")
        status = item.fetch("status")
        raise ContractError.new("malformed_request", "runtime validation status is unsupported") unless VALIDATION_STATES.include?(status)
        {
          "validation_id" => bounded_id!(item.fetch("validation_id"), REQUEST_KEY, "validation_id"),
          "name" => safe_text!(item.fetch("name"), "validation name", 128),
          "status" => status,
          "summary" => item["summary"] && safe_text!(item["summary"], "validation summary", MAX_ACTION_BYTES),
          "evidence_refs" => normalize_evidence_refs!(item.fetch("evidence_refs"), minimum: 0)
        }
      end
      unless items.map { |item| item.fetch("validation_id") }.uniq.length == items.length
        raise ContractError.new("duplicate_runtime_event", "runtime validation identities are duplicated")
      end
      items.sort_by { |item| item.fetch("validation_id") }
    end

    def normalize_runtime_error!(value)
      return nil if value.nil?

      expect_object!(value, %w[code summary retryable], "runtime agent error")
      retryable = value.fetch("retryable")
      raise ContractError.new("malformed_request", "runtime error retryable must be boolean") unless [true, false].include?(retryable)
      {
        "code" => bounded_id!(value.fetch("code"), Support::IDENTIFIER, "runtime error code"),
        "summary" => safe_text!(value.fetch("summary"), "runtime error summary", MAX_ACTION_BYTES),
        "retryable" => retryable
      }
    end

    def normalize_runtime_terminal_result!(value, lifecycle)
      terminal = TERMINAL_LIFECYCLES.include?(lifecycle)
      if value.nil?
        raise ContractError.new("malformed_request", "terminal runtime agents require terminal_result") if terminal
        return nil
      end
      raise ContractError.new("malformed_request", "nonterminal runtime agents cannot include terminal_result") unless terminal

      expect_object!(value, %w[status summary evidence_refs], "runtime agent terminal result")
      status = value.fetch("status")
      expected = {
        "review_ready" => "succeeded", "failed_validation" => "failed", "runtime_failure" => "failed",
        "cancelled" => "cancelled", "unknown_outcome" => "unknown"
      }.fetch(lifecycle)
      raise ContractError.new("inconsistent_agent_identity", "terminal result conflicts with lifecycle") unless status == expected
      {
        "status" => status,
        "summary" => safe_text!(value.fetch("summary"), "terminal result summary", MAX_SUMMARY_BYTES),
        "evidence_refs" => normalize_evidence_refs!(value.fetch("evidence_refs"), minimum: lifecycle == "review_ready" ? 1 : 0)
      }
    end

    def normalize_evidence_refs!(value, minimum:)
      unless value.is_a?(Array) && value.length.between?(minimum, 50) && value.uniq == value &&
             value.all? { |reference| EVIDENCE_REF.match?(reference.to_s) }
        raise ContractError.new("malformed_request", "evidence references are outside their bounded contract")
      end
      value.sort
    end

    def safe_relative_path!(value)
      unless value.is_a?(String) && value.bytesize.between?(1, 1024) && !value.start_with?("/", "~") &&
             !value.split("/").any? { |segment| segment.empty? || %w[. ..].include?(segment) } &&
             !value.match?(/[\u0000-\u001f\u007f]/)
        raise ContractError.new("untrusted_payload", "runtime file path must be a bounded relative path")
      end
      value
    end

    def apply_runtime_agent_updates!(record, owner, updates, observed_at)
      existing = Marshal.load(Marshal.dump(Array(owner["runtime_agents"])))

      existing_by_ref = existing.to_h { |item| [item.fetch("runtime_ref_digest"), item] }
      update_by_ref = updates.to_h { |item| [Digest::SHA256.hexdigest(item.fetch("runtime_agent_ref")), item] }
      new_count = update_by_ref.keys.count { |digest| !existing_by_ref.key?(digest) }
      if existing.length + new_count > MAX_RUNTIME_AGENTS
        raise ContractError.new("runtime_agent_limit_exceeded", "runtime agent history is full")
      end
      all_ids = existing_by_ref.transform_values { |item| item.fetch("agent_id") }
      update_by_ref.each_key do |digest|
        identity = Digest::SHA256.hexdigest(canonical_json([record.fetch("operation_id"), owner.fetch("agent_id"), digest]))
        all_ids[digest] ||= "operation-runtime-agent-#{identity[0, 48]}"
      end

      updates.each do |update|
        ref_digest = Digest::SHA256.hexdigest(update.fetch("runtime_agent_ref"))
        parent_digest = update["parent_runtime_agent_ref"] && Digest::SHA256.hexdigest(update.fetch("parent_runtime_agent_ref"))
        parent_tool_digest = update["parent_tool_call_ref"] && Digest::SHA256.hexdigest(update.fetch("parent_tool_call_ref"))
        parent_id = parent_digest && all_ids[parent_digest]
        if parent_digest && !parent_id
          raise ContractError.new("foreign_parent_identity", "runtime subagent parent is foreign to this Operation agent")
        end
        expected_scope = { "node_id" => owner.fetch("node_id"), "logical_project_key" => owner.fetch("logical_project_key") }
        unless secure_equal_json?(update.fetch("project_scope"), expected_scope)
          raise ContractError.new("foreign_project_scope", "runtime agent project scope exceeds its authorized Operation node")
        end
        metadata = {
          "agent_id" => all_ids.fetch(ref_digest),
          "parent" => if parent_digest
            { "availability" => "available", "agent_id" => parent_id, "tool_call_ref_digest" => nil }
          elsif parent_tool_digest
            { "availability" => "correlated", "agent_id" => nil, "tool_call_ref_digest" => parent_tool_digest }
          else
            { "availability" => "unavailable", "agent_id" => nil, "tool_call_ref_digest" => nil }
          end,
          "runtime_ref_digest" => ref_digest,
          "agent_kind" => update.fetch("agent_kind"),
          "reported_name" => update.fetch("reported_name"),
          "reported_role" => update.fetch("reported_role"),
          "source" => update.fetch("source"),
          "project_scope" => expected_scope
        }
        item = existing_by_ref[ref_digest]
        if item
          unless secure_equal_json?(item.slice(*metadata.keys), metadata)
            raise ContractError.new("inconsistent_agent_identity", "runtime agent immutable identity metadata changed")
          end
          if TERMINAL_LIFECYCLES.include?(item.fetch("lifecycle"))
            raise ContractError.new("out_of_order_observation", "terminal runtime agent cannot accept another update")
          end
          if Time.iso8601(observed_at) < Time.iso8601(item.fetch("updated_at"))
            raise ContractError.new("out_of_order_observation", "runtime agent update precedes its accepted state")
          end
        else
          item = metadata.merge(
            "session_ref_digest" => nil, "lifecycle" => "queued", "activity_summary" => nil,
            "events" => [], "structured_yield" => nil, "validations" => [], "error" => nil,
            "terminal_result" => nil, "created_at" => observed_at, "updated_at" => observed_at
          )
          existing << item
          existing_by_ref[ref_digest] = item
        end

        session_digest = update["runtime_session_ref"] && Digest::SHA256.hexdigest(update.fetch("runtime_session_ref"))
        if item["session_ref_digest"] && session_digest != item["session_ref_digest"]
          raise ContractError.new("inconsistent_agent_identity", "runtime agent session identity changed")
        end
        item["session_ref_digest"] ||= session_digest
        event = update["event"]
        if event
          validate_runtime_event_authorization!(owner, event)
          events = item.fetch("events")
          raise ContractError.new("runtime_event_limit_exceeded", "runtime agent event history is full") if events.length >= MAX_RUNTIME_AGENT_EVENTS
          expected_sequence = events.empty? ? 1 : events.last.fetch("sequence") + 1
          unless event.fetch("sequence") == expected_sequence
            raise ContractError.new("out_of_order_observation", "runtime agent event sequence is not the exact next sequence")
          end
          if Time.iso8601(event.fetch("occurred_at")) > Time.iso8601(observed_at) ||
             (events.any? && Time.iso8601(event.fetch("occurred_at")) < Time.iso8601(events.last.fetch("occurred_at")))
            raise ContractError.new("out_of_order_observation", "runtime agent event time is outside the accepted sequence")
          end
          event_id_digest = Digest::SHA256.hexdigest(event.fetch("event_id"))
          if existing.any? { |candidate| candidate.fetch("events").any? { |accepted| accepted["event_id_digest"] == event_id_digest } }
            raise ContractError.new("duplicate_runtime_event", "runtime event identity is already accepted")
          end
          events << event.merge("event_id_digest" => event_id_digest).reject { |key, _| key == "event_id" }
        end
        item.merge!(
          "lifecycle" => update.fetch("lifecycle"),
          "activity_summary" => update["activity_summary"],
          "structured_yield" => update["structured_yield"],
          "validations" => update.fetch("validations"),
          "error" => update["error"],
          "terminal_result" => update["terminal_result"],
          "updated_at" => observed_at
        )
      end

      validate_runtime_agent_graph!(existing, owner.fetch("agent_id"))
      existing.sort_by { |item| [runtime_agent_depth(item, existing, owner.fetch("agent_id")), item.fetch("agent_id")] }
    end

    def validate_runtime_event_authorization!(owner, event)
      access_mode = owner.dig("native_authorization", "access_mode")
      if event["kind"] == "change" || (event["kind"] == "file" && event.dig("detail", "action") != "read")
        raise ContractError.new("authorization_conflict", "runtime agent change exceeds a read-only Operation target") if access_mode == "read_only"
      end
      if event["kind"] == "tool"
        allowed = Array(owner.dig("adapter_configuration", "tool_policy", "allowed_tool_kinds"))
        unless allowed.include?(event.dig("detail", "kind"))
          raise ContractError.new("authorization_conflict", "runtime agent tool exceeds the authorized tool policy")
        end
      end
    end

    def validate_runtime_agent_graph!(items, owner_agent_id)
      ids = items.map { |item| item.fetch("agent_id") }
      unless ids.uniq.length == ids.length && items.map { |item| item.fetch("runtime_ref_digest") }.uniq.length == items.length
        raise ContractError.new("duplicate_agent_identity", "runtime agent identities are not unique")
      end
      by_id = items.to_h { |item| [item.fetch("agent_id"), item] }
      by_id.each do |id, item|
        next unless item.dig("parent", "availability") == "available"

        parent = item.dig("parent", "agent_id")
        raise ContractError.new("foreign_parent_identity", "runtime agent parent is foreign") unless parent == owner_agent_id || by_id.key?(parent)
        seen = { id => true }
        cursor = parent
        until cursor == owner_agent_id
          raise ContractError.new("inconsistent_agent_identity", "runtime agent hierarchy is cyclic") if seen[cursor]
          seen[cursor] = true
          ancestor = by_id[cursor]
          raise ContractError.new("foreign_parent_identity", "runtime agent parent is foreign") unless ancestor
          break unless ancestor.dig("parent", "availability") == "available"

          cursor = ancestor.dig("parent", "agent_id")
          raise ContractError.new("foreign_parent_identity", "runtime agent parent is foreign") unless cursor
        end
      end
    end

    def runtime_agent_depth(item, items, owner_agent_id)
      by_id = items.to_h { |candidate| [candidate.fetch("agent_id"), candidate] }
      depth = 1
      cursor = item
      while cursor.dig("parent", "availability") == "available"
        parent_id = cursor.dig("parent", "agent_id")
        depth += 1
        break if parent_id == owner_agent_id

        cursor = by_id.fetch(parent_id)
      end
      depth
    end

    def normalize_start_failure!(value)
      expect_object!(value, %w[code summary retryable failed_at], "Operation execution start failure")
      code = bounded_id!(value.fetch("code"), Support::IDENTIFIER, "failure.code")
      summary = safe_text!(value.fetch("summary"), "failure.summary", MAX_ACTION_BYTES)
      retryable = value.fetch("retryable")
      unless [true, false].include?(retryable)
        raise ContractError.new("malformed_request", "failure.retryable must be boolean")
      end
      {
        "code" => code,
        "summary" => summary,
        "retryable" => retryable,
        "failed_at" => canonical_time!(value.fetch("failed_at"), "failure.failed_at")
      }
    end

    def verify_start_route!(record, agent, request)
      expected = {
        "dispatch_generation" => record.dig("dispatch", "generation"),
        "dispatch_id" => agent.dig("native_authorization", "dispatch_id"),
        "runtime_project_id" => agent.dig("native_authorization", "runtime_project_id")
      }
      actual = expected.keys.to_h { |field| [field, request[field]] }
      unless secure_equal_json?(expected, actual)
        raise ContractError.new("authorization_conflict", "agent start request does not match the exact authorized dispatch route")
      end
    end

    def normalize_tool!(value)
      return nil if value.nil?

      expect_object!(value, %w[kind status], "adapter tool observation")
      unless TOOL_KINDS.include?(value["kind"]) && TOOL_STATUSES.include?(value["status"])
        raise ContractError.new("malformed_request", "adapter tool observation is invalid")
      end
      Support.stringify(value)
    end

    def normalize_subagents!(value)
      fields = %w[active completed failed blocked]
      expect_object!(value, fields, "adapter subagent observation")
      unless fields.all? { |field| value[field].is_a?(Integer) && value[field].between?(0, MAX_SUBAGENTS) }
        raise ContractError.new("malformed_request", "adapter subagent counts are invalid")
      end
      Support.stringify(value)
    end

    def normalize_attention!(value)
      expect_object!(value, %w[required code], "adapter attention observation")
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
        raise ContractError.new("malformed_request", "terminal observations require final_result") if terminal
        return nil
      end
      raise ContractError.new("malformed_request", "nonterminal observations cannot include final_result") unless terminal

      expect_object!(value, %w[summary evidence_refs], "Operation execution final result")
      summary = safe_text!(value.fetch("summary"), "final_result.summary", MAX_SUMMARY_BYTES)
      refs = value.fetch("evidence_refs")
      unless refs.is_a?(Array) && refs.length.between?(lifecycle == "review_ready" ? 1 : 0, 50) &&
             refs.uniq == refs && refs.all? { |reference| EVIDENCE_REF.match?(reference.to_s) }
        raise ContractError.new("malformed_request", "final evidence references are outside their bounded contract")
      end
      { "summary" => summary, "evidence_refs" => refs.sort }
    end

    def authenticate_observation!(binding, request)
      session_ref = bounded_id!(request.fetch("adapter_session_ref"), OPAQUE_SESSION, "adapter_session_ref")
      unless secure_equal?(Digest::SHA256.hexdigest(session_ref), binding.fetch("session_ref_digest"))
        raise ContractError.new("authentication_failed", "adapter session binding does not match the Flightdeck agent")
      end
      signature = request.fetch("signature").to_s
      raise ContractError.new("authentication_failed", "observation signature is invalid") unless SHA256.match?(signature)
      payload = request.reject { |key, _| %w[adapter_session_ref signature].include?(key) }
      expected = OpenSSL::HMAC.hexdigest("SHA256", session_ref, canonical_json(payload))
      raise ContractError.new("authentication_failed", "observation signature is invalid") unless secure_equal?(signature, expected)
    end

    def verify_execution_identity!(record, request)
      exact = {
        "adapter" => record.fetch("adapter"),
        "work_id" => record.fetch("work_id"),
        "operation_id" => record.fetch("operation_id"),
        "execution_id" => record.fetch("execution_id"),
        "execution_generation" => record.fetch("execution_generation"),
        "execution_digest" => record.fetch("execution_digest")
      }
      actual = exact.keys.to_h { |field| [field, request[field]] }
      unless secure_equal_json?(exact, actual)
        raise ContractError.new("operation_identity_conflict", "request does not match the exact durable execution identity")
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
        "schema" => "hub/schemas/operation-execution-plan-result.schema.json",
        "ok" => true,
        "capability" => EXECUTION_CAPABILITY,
        "adapter" => record.fetch("adapter"),
        "work_id" => record.fetch("work_id"),
        "operation_id" => record.fetch("operation_id"),
        "execution" => execution_projection(record),
        "authorization" => authorization_projection(record),
        "runtime_boundary" => runtime_boundary(record),
        "policy" => record.fetch("dispatch").slice("strategy", "max_concurrency"),
        "agents" => record.fetch("agents").map { |agent| native_agent_projection(agent) },
        "replayed" => replayed
      }
    end

    def bind_result(record, agent, replayed:)
      {
        "schema_version" => BIND_RESULT,
        "schema" => "hub/schemas/operation-execution-bind-result.schema.json",
        "ok" => true,
        "capability" => EXECUTION_CAPABILITY,
        "adapter" => record.fetch("adapter"),
        "operation_id" => record.fetch("operation_id"),
        "execution_id" => record.fetch("execution_id"),
        "agent_id" => agent.fetch("agent_id"),
        "binding" => agent.fetch("binding").slice("state", "generation", "bound_at"),
        "replayed" => replayed
      }
    end

    def start_report_result(record, agent, entry, replayed:)
      {
        "schema_version" => START_REPORT_RESULT,
        "schema" => "hub/schemas/operation-execution-start-report-result.schema.json",
        "ok" => true,
        "capability" => START_RECOVERY_CAPABILITY,
        "adapter" => record.fetch("adapter"),
        "operation_id" => record.fetch("operation_id"),
        "execution_id" => record.fetch("execution_id"),
        "agent_id" => agent.fetch("agent_id"),
        "failure" => start_failure_projection(entry),
        "recovery" => {
          "state" => entry.fetch("resulting_state"),
          "retry_generation" => entry["resulting_retry_generation"]
        },
        "replayed" => replayed
      }
    end

    def start_open_result(record, agent)
      start = start_record(agent)
      {
        "schema_version" => START_OPEN_RESULT,
        "schema" => "hub/schemas/operation-execution-start-open-result.schema.json",
        "ok" => true,
        "capability" => START_RECOVERY_CAPABILITY,
        "adapter" => record.fetch("adapter"),
        "work_id" => record.fetch("work_id"),
        "operation_id" => record.fetch("operation_id"),
        "execution_id" => record.fetch("execution_id"),
        "agent_id" => agent.fetch("agent_id"),
        "binding_state" => agent.dig("binding", "state"),
        "recovery" => {
          "state" => start.fetch("state"),
          "retry_generation" => start["retry_generation"]
        },
        "failures" => start.fetch("failures").map { |entry| start_failure_projection(entry) }
      }
    end

    def retry_bind_result(record, agent, replayed:)
      {
        "schema_version" => RETRY_BIND_RESULT,
        "schema" => "hub/schemas/operation-execution-retry-bind-result.schema.json",
        "ok" => true,
        "capability" => START_RECOVERY_CAPABILITY,
        "adapter" => record.fetch("adapter"),
        "operation_id" => record.fetch("operation_id"),
        "execution_id" => record.fetch("execution_id"),
        "agent_id" => agent.fetch("agent_id"),
        "binding" => agent.fetch("binding").slice("state", "generation", "bound_at"),
        "recovery" => { "state" => "bound", "retry_generation" => nil },
        "replayed" => replayed
      }
    end

    def start_failure_projection(entry)
      entry.slice("sequence", "failure_code", "summary", "retryable", "failed_at")
    end

    def observe_result(record, agent, replayed:, v2: false)
      {
        "schema_version" => v2 ? OBSERVE_V2_RESULT : OBSERVE_RESULT,
        "schema" => v2 ? "hub/schemas/operation-execution-observe-v2-result.schema.json" : "hub/schemas/operation-execution-observe-result.schema.json",
        "ok" => true,
        "capability" => v2 ? AGENT_TELEMETRY_CAPABILITY : OBSERVATION_CAPABILITY,
        "adapter" => record.fetch("adapter"),
        "operation_id" => record.fetch("operation_id"),
        "execution_id" => record.fetch("execution_id"),
        "execution_state" => record.fetch("state"),
        "agent" => safe_agent_projection(agent, include_runtime_agents: v2),
        "replayed" => replayed
      }
    end

    def open_result(record, v2: false)
      {
        "schema_version" => v2 ? OPEN_V2_RESULT : OPEN_RESULT,
        "schema" => v2 ? "hub/schemas/operation-execution-open-v2-result.schema.json" : "hub/schemas/operation-execution-open-result.schema.json",
        "ok" => true,
        "capability" => v2 ? AGENT_TELEMETRY_CAPABILITY : OBSERVATION_CAPABILITY,
        "adapter" => record.fetch("adapter"),
        "work_id" => record.fetch("work_id"),
        "operation_id" => record.fetch("operation_id"),
        "execution" => execution_projection(record),
        "authorization" => authorization_projection(record),
        "runtime_boundary" => runtime_boundary(record),
        "progress" => progress_projection(record),
        "agents" => record.fetch("agents").map { |agent| safe_agent_projection(agent, include_runtime_agents: v2) }
      }
    end

    def execution_projection(record)
      record.slice("execution_id", "execution_generation", "execution_digest", "state", "created_at", "updated_at")
    end

    def runtime_boundary(record)
      {
        "conversation" => { "adapter" => "codex" },
        "operation_execution" => record.fetch("adapter")
      }
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
        "authorized_task", "adapter_configuration", "native_authorization"
      ).merge("binding_state" => agent.dig("binding", "state"))
    end

    def safe_agent_projection(agent, include_runtime_agents: false)
      latest = agent.fetch("observations").last
      observation = latest&.reject { |key, _| %w[observation_id_digest content_digest].include?(key) }
      projection = {
        "agent_id" => agent.fetch("agent_id"),
        "node_id" => agent.fetch("node_id"),
        "logical_project_key" => agent.fetch("logical_project_key"),
        "dependencies" => agent.fetch("dependencies"),
        "execution_order" => agent.fetch("execution_order"),
        "adapter" => record_adapter_for(agent),
        "binding_state" => agent.dig("binding", "state"),
        "observation" => observation
      }
      projection["runtime_agents"] = Array(agent["runtime_agents"]).map { |item| runtime_agent_projection(item) } if include_runtime_agents
      projection
    end

    def runtime_agent_projection(agent)
      {
        "agent_id" => agent.fetch("agent_id"),
        "parent" => agent.fetch("parent"),
        "agent_kind" => agent.fetch("agent_kind"),
        "reported_name" => agent.fetch("reported_name"),
        "reported_role" => agent.fetch("reported_role"),
        "source" => agent.fetch("source"),
        "runtime" => {
          "agent_ref_digest" => agent.fetch("runtime_ref_digest"),
          "session_ref_digest" => agent["session_ref_digest"]
        },
        "project_scope" => agent.fetch("project_scope"),
        "lifecycle" => agent.fetch("lifecycle"),
        "activity_summary" => agent["activity_summary"],
        "events" => agent.fetch("events").map do |event|
          event.reject { |key, _| key == "event_id_digest" }
            .merge("event_id" => "operation-runtime-event-#{event.fetch('event_id_digest')[0, 48]}")
        end,
        "structured_yield" => agent["structured_yield"],
        "validations" => agent.fetch("validations"),
        "error" => agent["error"],
        "terminal_result" => agent["terminal_result"],
        "created_at" => agent.fetch("created_at"),
        "updated_at" => agent.fetch("updated_at")
      }
    end

    def safe_start_projection(agent)
      start = start_record(agent)
      {
        "state" => start.fetch("state"),
        "failure_count" => start.fetch("failures").length,
        "latest_failure" => start.fetch("failures").last && start_failure_projection(start.fetch("failures").last)
      }
    end

    def record_adapter_for(agent)
      configuration = agent.fetch("adapter_configuration")
      {
        "id" => configuration.fetch("adapter_id"),
        "configuration_schema" => configuration.fetch("schema_version"),
        "execution_capability" => EXECUTION_CAPABILITY,
        "observation_capability" => OBSERVATION_CAPABILITY
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
      start_states = record.fetch("agents").map { |agent| start_record(agent).fetch("state") }
      return "attention_required" if start_states.include?("retry_authorized")
      return "failed" if start_states.include?("failed")

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
      raise ContractError.new("execution_store_invalid", "Operation execution record is not a regular file") unless stat.file? && !stat.symlink?
      raise ContractError.new("execution_store_invalid", "Operation execution record exceeds its bounded contract") if stat.size > MAX_RECORD_BYTES
      record = JSON.parse(File.read(path, MAX_RECORD_BYTES + 1, encoding: "UTF-8"))
      validate_record!(Support.stringify(record), operation_id)
    rescue Errno::ENOENT
      raise ContractError.new("not_created", "Operation execution does not exist")
    rescue JSON::ParserError, Errno::EACCES, Errno::ELOOP
      raise ContractError.new("execution_store_invalid", "Operation execution state is unavailable or malformed")
    end

    def validate_record!(record, expected_operation_id = nil)
      fields = %w[
        schema_version work_id operation_id execution_id execution_generation execution_digest adapter state
        idempotency_key_digest request_digest authoring dispatch agents created_at updated_at record_digest
      ]
      expect_object!(record, fields, "Operation execution record", code: "execution_store_invalid")
      valid = [RECORD_VERSION, PREVIOUS_RECORD_VERSION, LEGACY_RECORD_VERSION].include?(record["schema_version"]) && WORK_ID.match?(record["work_id"].to_s) &&
        OPERATION_ID.match?(record["operation_id"].to_s) && (!expected_operation_id || record["operation_id"] == expected_operation_id) &&
        EXECUTION_ID.match?(record["execution_id"].to_s) && EXECUTION_GENERATION.match?(record["execution_generation"].to_s) &&
        SHA256.match?(record["execution_digest"].to_s) && valid_adapter_descriptor?(record["adapter"]) &&
        %w[authorized running attention_required failed cancelled review_ready].include?(record["state"]) &&
        SHA256.match?(record["idempotency_key_digest"].to_s) && SHA256.match?(record["request_digest"].to_s) &&
        record["agents"].is_a?(Array) && record["agents"].length.between?(1, MAX_AGENTS)
      raise ContractError.new("execution_store_invalid", "Operation execution record identity is invalid") unless valid
      canonical_time!(record["created_at"], "created_at", code: "execution_store_invalid")
      canonical_time!(record["updated_at"], "updated_at", code: "execution_store_invalid")
      expected_digest = Digest::SHA256.hexdigest(canonical_json(record.merge("record_digest" => nil)))
      unless secure_equal?(expected_digest, record["record_digest"])
        raise ContractError.new("execution_store_invalid", "Operation execution record digest is invalid")
      end
      validate_authoring_record!(record.fetch("authoring"))
      validate_dispatch_record!(record.fetch("dispatch"))
      record.fetch("agents").each { |agent| validate_persisted_agent!(agent, record.fetch("schema_version")) }
      unless record.fetch("agents").all? do |agent|
        agent.dig("adapter_configuration", "adapter_id") == record.dig("adapter", "id") &&
          agent.dig("adapter_configuration", "schema_version") == record.dig("adapter", "configuration_schema")
      end
        raise ContractError.new("execution_store_invalid", "Operation execution agent adapter bindings are inconsistent")
      end
      unless record.fetch("agents").map { |agent| agent.fetch("agent_id") }.uniq.length == record.fetch("agents").length &&
             record.fetch("agents").map { |agent| agent.fetch("node_id") }.uniq.length == record.fetch("agents").length
        raise ContractError.new("execution_store_invalid", "Operation execution agent identities are not unique")
      end
      runtime_ids = record.fetch("agents").flat_map { |agent| Array(agent["runtime_agents"]).map { |item| item.fetch("agent_id") } }
      unless runtime_ids.uniq.length == runtime_ids.length
        raise ContractError.new("execution_store_invalid", "runtime agent identities are not unique across the Operation")
      end
      scan_safe!(record)
      record
    rescue ContractError => error
      raise error if error.code == "execution_store_invalid"

      raise ContractError.new("execution_store_invalid", "Operation execution record is invalid")
    end

    def valid_adapter_descriptor?(value)
      value.is_a?(Hash) && value.keys.sort == %w[configuration_schema execution_capability id observation_capability] &&
        ADAPTER_CONFIGURATIONS[value["id"]] == value["configuration_schema"] &&
        value["execution_capability"] == EXECUTION_CAPABILITY &&
        value["observation_capability"] == OBSERVATION_CAPABILITY
    end

    def validate_authoring_record!(authoring)
      fields = %w[plan_id plan_generation plan_digest plan_token_digest confirmation_digest state]
      expect_object!(authoring, fields, "Operation authoring binding record", code: "execution_store_invalid")
      unless authoring["plan_id"].to_s.match?(/\Aplan-[0-9a-f]{48}\z/) &&
             authoring["plan_generation"].to_s.match?(/\Ageneration-[0-9a-f]{48}\z/) &&
             %w[plan_digest plan_token_digest confirmation_digest].all? { |field| SHA256.match?(authoring[field].to_s) } &&
             authoring["state"] == "confirmed"
        raise ContractError.new("execution_store_invalid", "Operation authoring binding record is invalid")
      end
    end

    def validate_dispatch_record!(dispatch)
      fields = %w[generation plan_digest strategy max_concurrency]
      expect_object!(dispatch, fields, "Operation dispatch binding record", code: "execution_store_invalid")
      unless dispatch["generation"].to_s.match?(/\Adispatch-generation-[0-9a-f]{48}\z/) &&
             SHA256.match?(dispatch["plan_digest"].to_s) && dispatch["strategy"] == "parallel_independent" &&
             dispatch["max_concurrency"].is_a?(Integer) && dispatch["max_concurrency"].between?(1, 8)
        raise ContractError.new("execution_store_invalid", "Operation dispatch binding record is invalid")
      end
    end

    def validate_persisted_agent!(agent, record_version)
      fields = %w[
        agent_id node_id logical_project_key dependencies execution_order authorized_task
        adapter_configuration native_authorization binding observations
      ]
      fields << "start" if [RECORD_VERSION, PREVIOUS_RECORD_VERSION].include?(record_version)
      fields << "runtime_agents" if record_version == RECORD_VERSION
      expect_object!(agent, fields, "Operation execution agent record", code: "execution_store_invalid")
      unless AGENT_ID.match?(agent["agent_id"].to_s) && Support::IDENTIFIER.match?(agent["node_id"].to_s) &&
             Support::IDENTIFIER.match?(agent["logical_project_key"].to_s) && agent["dependencies"].is_a?(Array) &&
             agent["dependencies"].uniq == agent["dependencies"] && agent["dependencies"].all? { |item| Support::IDENTIFIER.match?(item.to_s) } &&
             agent["execution_order"].is_a?(Integer) && agent["execution_order"] >= 0 &&
             agent["observations"].is_a?(Array) && agent["observations"].length <= MAX_OBSERVATIONS
        raise ContractError.new("execution_store_invalid", "Operation execution agent record is invalid")
      end
      safe_text!(agent["authorized_task"], "authorized_task", MAX_TASK_BYTES)
      configuration = agent.fetch("adapter_configuration")
      expect_object!(configuration, %w[adapter_id schema_version requested_model reasoning_effort tool_policy], "adapter configuration", code: "execution_store_invalid")
      unless ADAPTER_CONFIGURATIONS[configuration["adapter_id"]] == configuration["schema_version"] &&
             (configuration["requested_model"].nil? || MODEL.match?(configuration["requested_model"].to_s)) &&
             (configuration["reasoning_effort"].nil? || REASONING_EFFORTS.include?(configuration["reasoning_effort"]))
        raise ContractError.new("execution_store_invalid", "Operation execution adapter configuration is invalid")
      end
      validate_persisted_tool_policy!(configuration.fetch("tool_policy"), agent.dig("native_authorization", "access_mode"))
      validate_native_authorization!(agent.fetch("native_authorization"))
      binding = agent.fetch("binding")
      expect_object!(binding, %w[state generation session_ref_digest idempotency_key_digest request_digest bound_at], "adapter binding record", code: "execution_store_invalid")
      if binding["state"] == "bound"
        unless BINDING_GENERATION.match?(binding["generation"].to_s) &&
               %w[session_ref_digest idempotency_key_digest request_digest].all? { |field| SHA256.match?(binding[field].to_s) }
          raise ContractError.new("execution_store_invalid", "adapter binding record is invalid")
        end
        canonical_time!(binding["bound_at"], "bound_at", code: "execution_store_invalid")
      elsif binding["state"] != "unbound" || binding.reject { |key, _| key == "state" }.values.any?
        raise ContractError.new("execution_store_invalid", "unbound agent contains private binding state")
      end
      sequences = agent.fetch("observations").map { |observation| observation["sequence"] }
      unless sequences == (1..sequences.length).to_a
        raise ContractError.new("execution_store_invalid", "observation sequence is invalid")
      end
      agent.fetch("observations").each { |observation| validate_persisted_observation!(observation) }
      if [RECORD_VERSION, PREVIOUS_RECORD_VERSION].include?(record_version)
        start = agent.fetch("start")
        validate_start_record!(start)
        if (binding["state"] == "bound") != (start["state"] == "bound")
          raise ContractError.new("execution_store_invalid", "Operation execution start and binding states conflict")
        end
        latest = start.fetch("failures").last
        if latest && start["state"] != "bound" &&
           (start["state"] != latest["resulting_state"] || start["retry_generation"] != latest["resulting_retry_generation"])
          raise ContractError.new("execution_store_invalid", "Operation execution start recovery state is stale")
        end
      end
      if record_version == RECORD_VERSION
        runtime_agents = agent.fetch("runtime_agents")
        unless runtime_agents.is_a?(Array) && runtime_agents.length <= MAX_RUNTIME_AGENTS
          raise ContractError.new("execution_store_invalid", "runtime agent history exceeds its bounded contract")
        end
        runtime_agents.each { |item| validate_persisted_runtime_agent!(item, agent) }
        validate_runtime_agent_graph!(runtime_agents, agent.fetch("agent_id"))
      end
    end

    def validate_start_record!(start)
      expect_object!(start, %w[state retry_generation failures], "Operation execution start record", code: "execution_store_invalid")
      unless %w[initial retry_authorized failed bound].include?(start["state"]) && start["failures"].is_a?(Array) &&
             start["failures"].length <= MAX_START_FAILURES
        raise ContractError.new("execution_store_invalid", "Operation execution start record is invalid")
      end
      if start["state"] == "retry_authorized"
        raise ContractError.new("execution_store_invalid", "Operation execution retry generation is invalid") unless RETRY_GENERATION.match?(start["retry_generation"].to_s)
      elsif !start["retry_generation"].nil?
        raise ContractError.new("execution_store_invalid", "Operation execution retry generation is invalid")
      end
      start.fetch("failures").each_with_index do |failure, index|
        fields = %w[
          sequence report_id_digest content_digest attempt_generation failure_code summary retryable failed_at
          resulting_state resulting_retry_generation
        ]
        expect_object!(failure, fields, "Operation execution start failure", code: "execution_store_invalid")
        valid = failure["sequence"] == index + 1 && SHA256.match?(failure["report_id_digest"].to_s) &&
          SHA256.match?(failure["content_digest"].to_s) &&
          (failure["attempt_generation"].nil? || RETRY_GENERATION.match?(failure["attempt_generation"].to_s)) &&
          Support::IDENTIFIER.match?(failure["failure_code"].to_s) && [true, false].include?(failure["retryable"]) &&
          %w[retry_authorized failed].include?(failure["resulting_state"]) &&
          (failure["resulting_retry_generation"].nil? || RETRY_GENERATION.match?(failure["resulting_retry_generation"].to_s))
        raise ContractError.new("execution_store_invalid", "Operation execution start failure is invalid") unless valid
        safe_text!(failure["summary"], "start failure summary", MAX_ACTION_BYTES)
        canonical_time!(failure["failed_at"], "start failure time", code: "execution_store_invalid")
        if failure["retryable"] != !failure["resulting_retry_generation"].nil? ||
           (failure["retryable"] ? failure["resulting_state"] != "retry_authorized" : failure["resulting_state"] != "failed")
          raise ContractError.new("execution_store_invalid", "Operation execution start failure recovery is invalid")
        end
      end
      if start["state"] == "initial" && !start["failures"].empty?
        raise ContractError.new("execution_store_invalid", "Operation execution initial start record has failure history")
      end
    end

    def validate_persisted_tool_policy!(policy, access_mode)
      expect_object!(policy, %w[profile allowed_tool_kinds network_access], "persisted adapter tool policy", code: "execution_store_invalid")
      kinds = policy["allowed_tool_kinds"]
      valid = TOOL_PROFILES.include?(policy["profile"]) && kinds.is_a?(Array) && kinds.uniq == kinds &&
        kinds.length <= TOOL_KINDS.length && kinds.all? { |kind| TOOL_KINDS.include?(kind) } &&
        policy["network_access"] == false && !kinds.include?("network") &&
        (access_mode != "read_only" || policy["profile"] == "read_only")
      raise ContractError.new("execution_store_invalid", "persisted adapter tool policy is invalid") unless valid
    end

    def validate_native_authorization!(authorization)
      fields = %w[
        dispatch_id runtime_project_id project_path_digest host_id authorization_boundary
        execution_mode access_mode work_type
      ]
      expect_object!(authorization, fields, "native authorization record", code: "execution_store_invalid")
      valid = authorization["dispatch_id"].to_s.match?(/\Adispatch-[0-9a-f]{24}\z/) &&
        WorkStore::OPAQUE_RUNTIME_ID.match?(authorization["runtime_project_id"].to_s) &&
        SHA256.match?(authorization["project_path_digest"].to_s) &&
        Support::IDENTIFIER.match?(authorization["host_id"].to_s) &&
        Support::IDENTIFIER.match?(authorization["authorization_boundary"].to_s) &&
        %w[local worktree].include?(authorization["execution_mode"]) &&
        %w[read_only write].include?(authorization["access_mode"]) &&
        Support::IDENTIFIER.match?(authorization["work_type"].to_s)
      raise ContractError.new("execution_store_invalid", "native authorization record is invalid") unless valid
    end

    def validate_persisted_observation!(observation)
      fields = %w[
        sequence lifecycle action_summary tool subagents attention error_code observed_at final_result
        observation_id_digest content_digest
      ]
      expect_object!(observation, fields, "persisted Operation observation", code: "execution_store_invalid")
      unless observation["sequence"].is_a?(Integer) && observation["sequence"].between?(1, MAX_SEQUENCE) &&
             LIFECYCLES.include?(observation["lifecycle"]) &&
             SHA256.match?(observation["observation_id_digest"].to_s) && SHA256.match?(observation["content_digest"].to_s)
        raise ContractError.new("execution_store_invalid", "persisted Operation observation is invalid")
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

      raise ContractError.new("execution_store_invalid", "persisted Operation observation is invalid")
    end

    def validate_persisted_runtime_agent!(agent, owner)
      fields = %w[
        agent_id parent runtime_ref_digest session_ref_digest agent_kind reported_name reported_role source
        project_scope lifecycle activity_summary events structured_yield validations error terminal_result created_at updated_at
      ]
      expect_object!(agent, fields, "persisted runtime agent", code: "execution_store_invalid")
      parent = agent.fetch("parent")
      expect_object!(parent, %w[availability agent_id tool_call_ref_digest], "persisted runtime parent", code: "execution_store_invalid")
      parent_valid = if parent["availability"] == "available"
                       parent["tool_call_ref_digest"].nil? &&
                         (parent["agent_id"] == owner.fetch("agent_id") || RUNTIME_AGENT_ID.match?(parent["agent_id"].to_s))
                     elsif parent["availability"] == "correlated"
                       parent["agent_id"].nil? && SHA256.match?(parent["tool_call_ref_digest"].to_s)
                     elsif parent["availability"] == "unavailable"
                       parent["agent_id"].nil? && parent["tool_call_ref_digest"].nil?
                     else
                       false
                     end
      scope = agent.fetch("project_scope")
      expect_object!(scope, %w[node_id logical_project_key], "persisted runtime project scope", code: "execution_store_invalid")
      valid = RUNTIME_AGENT_ID.match?(agent["agent_id"].to_s) && SHA256.match?(agent["runtime_ref_digest"].to_s) &&
        (agent["session_ref_digest"].nil? || SHA256.match?(agent["session_ref_digest"].to_s)) && parent_valid &&
        RUNTIME_AGENT_KINDS.include?(agent["agent_kind"]) && RUNTIME_AGENT_SOURCES.include?(agent["source"]) &&
        scope == { "node_id" => owner.fetch("node_id"), "logical_project_key" => owner.fetch("logical_project_key") } &&
        LIFECYCLES.include?(agent["lifecycle"]) && agent["events"].is_a?(Array) &&
        agent["events"].length <= MAX_RUNTIME_AGENT_EVENTS
      raise ContractError.new("execution_store_invalid", "persisted runtime agent identity is invalid") unless valid
      safe_text!(agent["reported_name"], "reported_name", 128)
      safe_text!(agent["reported_role"], "reported_role", 128)
      safe_text!(agent["activity_summary"], "activity_summary", MAX_ACTION_BYTES) if agent["activity_summary"]
      canonical_time!(agent["created_at"], "runtime agent created_at", code: "execution_store_invalid")
      canonical_time!(agent["updated_at"], "runtime agent updated_at", code: "execution_store_invalid")
      sequences = agent.fetch("events").map { |event| event["sequence"] }
      unless sequences == (1..sequences.length).to_a &&
             agent.fetch("events").map { |event| event["event_id_digest"] }.uniq.length == agent.fetch("events").length
        raise ContractError.new("execution_store_invalid", "persisted runtime agent event history is invalid")
      end
      agent.fetch("events").each_with_index do |event, index|
        expect_object!(event, %w[sequence kind status summary occurred_at detail event_id_digest], "persisted runtime event", code: "execution_store_invalid")
        raise ContractError.new("execution_store_invalid", "persisted runtime event identity is invalid") unless SHA256.match?(event["event_id_digest"].to_s)
        normalize_runtime_event!(event.reject { |key, _| key == "event_id_digest" }.merge("event_id" => "persisted-event-#{index + 1}"))
      end
      normalize_runtime_yield!(agent["structured_yield"])
      normalize_runtime_validations!(agent.fetch("validations"))
      normalize_runtime_error!(agent["error"])
      normalize_runtime_terminal_result!(agent["terminal_result"], agent.fetch("lifecycle"))
      if agent["lifecycle"] == "runtime_failure" && agent["error"].nil?
        raise ContractError.new("execution_store_invalid", "persisted runtime failure has no error")
      end
    rescue ContractError => error
      raise error if error.code == "execution_store_invalid"

      raise ContractError.new("execution_store_invalid", "persisted runtime agent is invalid")
    end

    def write_record!(record)
      upgrade_record!(record)
      record["record_digest"] = nil
      record["record_digest"] = Digest::SHA256.hexdigest(canonical_json(record))
      validate_record!(record, record.fetch("operation_id"))
      content = "#{JSON.pretty_generate(record)}\n"
      raise ContractError.new("execution_store_invalid", "Operation execution record exceeds its bounded contract") if content.bytesize > MAX_RECORD_BYTES
      FileUtils.mkdir_p(state_dir, mode: 0o700)
      Support.atomic_write(record_path(record.fetch("operation_id")), content)
    rescue SystemCallError, IOError
      raise ContractError.new("unknown_outcome", "Operation execution persistence was interrupted; recover with execution-open")
    end

    def empty_start_record(state: "initial")
      { "state" => state, "retry_generation" => nil, "failures" => [] }
    end

    def start_record(agent)
      agent["start"] || empty_start_record(state: agent.dig("binding", "state") == "bound" ? "bound" : "initial")
    end

    def upgrade_record!(record)
      return record if record["schema_version"] == RECORD_VERSION &&
                       record.fetch("agents").all? { |agent| agent.key?("start") && agent.key?("runtime_agents") }

      record["schema_version"] = RECORD_VERSION
      record.fetch("agents").each do |agent|
        agent["start"] ||= empty_start_record(state: agent.dig("binding", "state") == "bound" ? "bound" : "initial")
        agent["runtime_agents"] ||= []
      end
      record
    end

    def state_dir
      @config.root_path("hub/state/operation-execution", label: "Operation execution state")
    end

    def record_path(operation_id)
      File.join(state_dir, "#{Digest::SHA256.hexdigest(operation_id.to_s)}.json")
    end

    def with_lock(mode)
      FileUtils.mkdir_p(state_dir, mode: 0o700)
      lock_path = File.join(state_dir, ".lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        unless lock.stat.file? && !File.symlink?(lock_path) && lock.flock(mode | File::LOCK_NB)
          raise ContractError.new("execution_store_invalid", "Operation execution state lock is unavailable")
        end
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise ContractError.new("execution_store_invalid", "Operation execution state lock is unavailable")
    end

    def with_existing_lock(mode)
      lock_path = File.join(state_dir, ".lock")
      File.open(lock_path, File::RDWR) do |lock|
        unless lock.stat.file? && !File.symlink?(lock_path) && lock.flock(mode | File::LOCK_NB)
          raise ContractError.new("execution_store_invalid", "Operation execution state lock is unavailable")
        end
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise ContractError.new("not_created", "Operation execution does not exist")
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
          if key.to_s.match?(/(?:secret|password|credential|oauth|raw_prompt|raw_reasoning|system_prompt|tool_schema|environment_variables|adapter_session_ref|omp_session_ref)/i)
            raise ContractError.new("execution_store_invalid", "Operation execution record contains a prohibited field")
          end
          scan_safe!(item, "#{path}.#{key}")
        end
      when Array
        value.each_with_index { |item, index| scan_safe!(item, "#{path}[#{index}]") }
      when String
        if value.bytesize > MAX_TASK_BYTES || value.match?(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/) || value.match?(SECRET_VALUE)
          raise ContractError.new("execution_store_invalid", "Operation execution record contains unsafe text")
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
      ContractError.new(code, "authoritative Work/Operation lifecycle rejected Operation execution: #{error.message}")
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
