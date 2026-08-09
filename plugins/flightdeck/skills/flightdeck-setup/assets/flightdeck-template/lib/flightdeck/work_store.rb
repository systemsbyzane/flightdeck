# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "openssl"
require "securerandom"
require_relative "operation_authoring"

module Flightdeck
  # Durable, display-safe Work metadata and the private adapter seam. Work
  # stores no prompt, response, command, path, runtime project/task identity,
  # or evidence body. Exact target identity remains inside OperationAuthoring.
  class WorkStore
    CAPABILITY = "flightdeck.command.work-control.v1"
    CREATE_REQUEST = "flightdeck.work.create-request/v1"
    CREATE_RESULT = "flightdeck.work.create-result/v1"
    ADAPTER_BIND_REQUEST = "flightdeck.work.adapter-bind-request/v1"
    ADAPTER_BIND_RESULT = "flightdeck.work.adapter-bind-result/v1"
    COORDINATE_REQUEST = "flightdeck.work.coordinate-request/v1"
    COORDINATE_RESULT = "flightdeck.work.coordinate-result/v1"
    OPEN_REQUEST = "flightdeck.work.open-request/v1"
    OPEN_RESULT = "flightdeck.work.open-result/v1"
    LAUNCH_REQUEST = "flightdeck.work.launch-request/v1"
    LAUNCH_RESULT = "flightdeck.work.launch-result/v1"
    GUIDANCE_REQUEST = "flightdeck.work.guidance-request/v1"
    GUIDANCE_RESULT = "flightdeck.work.guidance-result/v1"
    LIST_RESULT = "flightdeck.work.list/v1"
    ERROR_RESULT = "flightdeck.work.error-result/v1"
    RECORD_VERSION = "flightdeck.work.record/v1"
    RECOMMENDATION_VERSION = "flightdeck.runtime.work-recommendation/v1"
    OBSERVATION_VERSION = "flightdeck.runtime.work-observation/v1"
    STRUCTURED_CHANNEL = "flightdeck.runtime.work-recommendation/v1"
    MAX_REQUEST_BYTES = 65_536
    MAX_WORK_RECORDS = 10_000
    MAX_RECORD_BYTES = 262_144
    MAX_EVENTS = 200
    MAX_OPERATIONS = 50
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100
    WORK_ID = /\Awork-[0-9a-f]{24}\z/
    REQUEST_KEY = /\A[a-zA-Z0-9][a-zA-Z0-9._:-]{7,127}\z/
    RECOMMENDATION_ID = /\A[a-zA-Z0-9][a-zA-Z0-9._:-]{7,127}\z/
    OPAQUE_RUNTIME_ID = /\A[a-zA-Z0-9][a-zA-Z0-9._:-]{7,255}\z/
    SHA256 = /\A[0-9a-f]{64}\z/
    OPERATION_ID = /\Aoperation-[0-9a-f]{24}\z/
    TERMINAL_STATES = %w[review_ready failed_validation runtime_failure cancelled complete].freeze
    RESULT_STATES = %w[review_ready complete].freeze
    FAILURE_STATES = %w[failed_validation runtime_failure cancelled].freeze
    SCHEMAS = %w[
      work-types.schema.json work-create-request.schema.json work-create-result.schema.json
      work-adapter-bind-request.schema.json work-adapter-bind-result.schema.json
      work-coordinate-request.schema.json work-coordinate-result.schema.json
      work-open-request.schema.json work-open-result.schema.json
      work-launch-request.schema.json work-launch-result.schema.json
      work-guidance-request.schema.json work-guidance-result.schema.json
      work-list.schema.json work-error-result.schema.json
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
      @authoring = OperationAuthoring.new(config, clock: clock)
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
        "schema" => "hub/schemas/work-error-result.schema.json",
        "ok" => false,
        "operation" => operation,
        "error" => { "code" => code, "message" => error.message.to_s[0, 512] }
      }
    end

    def create(request)
      verify_capability!
      expect_object!(request, %w[schema_version request_key title_hint], "Work create request")
      expect_version!(request, CREATE_REQUEST)
      request_key = bounded_id!(request.fetch("request_key"), REQUEST_KEY, "request_key")
      title = display_title(request.fetch("title_hint"))
      request_key_digest = Digest::SHA256.hexdigest(request_key)
      request_digest = Digest::SHA256.hexdigest(canonical_json("title" => title))

      with_lock(File::LOCK_EX) do
        records = work_records
        replay = records.find { |record| record["request_key_digest"] == request_key_digest }
        if replay
          unless replay["request_digest"] == request_digest
            raise ContractError.new("duplicate_request_conflict", "request_key is already bound to different Work content")
          end
          return create_result(replay, replayed: true)
        end
        raise ContractError.new("work_limit_exceeded", "Work record limit is exhausted") if records.length >= MAX_WORK_RECORDS

        now = timestamp
        work_id = unique_work_id(records)
        record = {
          "schema_version" => RECORD_VERSION,
          "work_id" => work_id,
          "request_key_digest" => request_key_digest,
          "request_digest" => request_digest,
          "title" => title,
          "status" => "open",
          "runtime_binding" => runtime_binding(work_id, now),
          "proposals" => [],
          "operation_ids" => [],
          "active_operation_id" => nil,
          "events" => [event(work_id, "work_created", "completed", now, nil, request_key_digest)],
          "created_at" => now,
          "updated_at" => now
        }
        write_record!(record)
        create_result(record, replayed: false)
      end
    end

    def bind_adapter(request)
      verify_capability!
      fields = %w[schema_version work_id resume_generation adapter adapter_session_id binding_request_id structured_channel]
      expect_object!(request, fields, "Work adapter bind request")
      expect_version!(request, ADAPTER_BIND_REQUEST)
      work_id = validate_work_id!(request.fetch("work_id"))
      adapter = bounded_id!(request.fetch("adapter"), /\A(?:codex|omp)\z/, "adapter")
      session_id = bounded_id!(request.fetch("adapter_session_id"), OPAQUE_RUNTIME_ID, "adapter_session_id")
      request_id = bounded_id!(request.fetch("binding_request_id"), REQUEST_KEY, "binding_request_id")
      resume_generation = bounded_id!(request.fetch("resume_generation"), /\Aresume-[0-9a-f]{48}\z/, "resume_generation")
      channel = request.fetch("structured_channel")
      raise ContractError.new("unsupported_structured_channel", "runtime adapter structured channel is unsupported") unless channel == STRUCTURED_CHANNEL

      with_lock(File::LOCK_EX) do
        record = find_record!(work_id)
        runtime = runtime_projection
        unless runtime["available"] && runtime["adapter"] == adapter
          raise ContractError.new("adapter_unavailable", "selected Hub runtime adapter is unavailable")
        end
        binding = record.fetch("runtime_binding")
        request_digest = Digest::SHA256.hexdigest(request_id)
        payload_digest = Digest::SHA256.hexdigest(canonical_json(request))
        if binding["binding_request_digest"] == request_digest
          unless binding["binding_payload_digest"] == payload_digest
            raise ContractError.new("duplicate_request_conflict", "binding_request_id is already bound to different content")
          end
          return adapter_bind_result(record, replayed: true)
        end
        unless resume_metadata(record).fetch("generation") == resume_generation
          raise ContractError.new("stale_binding", "adapter bind request does not match the current Work resume generation")
        end

        now = timestamp
        secret = Digest::SHA256.hexdigest(@random_hex.call(32))
        session_digest = Digest::SHA256.hexdigest(session_id)
        identity = Digest::SHA256.hexdigest(canonical_json([binding.fetch("hub_binding_id"), work_id, adapter, session_digest, secret]))
        binding.merge!(
          "state" => "bound",
          "binding_id" => "adapter-binding-#{identity[0, 24]}",
          "shared_secret" => secret,
          "session_id_digest" => session_digest,
          "session_generation" => "adapter-session-#{identity[0, 48]}",
          "resume_generation" => resume_generation,
          "binding_request_digest" => request_digest,
          "binding_payload_digest" => payload_digest,
          "structured_channel" => channel,
          "updated_at" => now
        )
        append_event!(record, event(work_id, "runtime_delegated", "started", now, nil, identity))
        record["status"] = "open"
        write_record!(record)
        adapter_bind_result(record, replayed: false)
      end
    end

    def coordinate(request)
      verify_capability!
      expect_object!(request, %w[schema_version work_id observation], "Work coordinate request")
      expect_version!(request, COORDINATE_REQUEST)
      work_id = validate_work_id!(request.fetch("work_id"))
      observation = normalize_observation!(request.fetch("observation"), work_id)

      with_lock(File::LOCK_EX) do
        record = find_record!(work_id)
        runtime = runtime_projection
        raise ContractError.new("adapter_unavailable", "selected Hub runtime adapter is unavailable") unless runtime.fetch("available")
        authenticate_observation!(record, observation)
        observation_key_digest = Digest::SHA256.hexdigest(observation.fetch("observation_id"))
        observation_digest = Digest::SHA256.hexdigest(canonical_json(observation.reject { |key, _| key == "signature" }))
        replay = record["proposals"].find { |item| item["observation_key_digest"] == observation_key_digest }
        if replay
          unless replay["observation_digest"] == observation_digest
            raise ContractError.new("duplicate_request_conflict", "observation_id is already bound to different content")
          end
          return coordinate_result(record, replay, replayed: true)
        end
        unless resume_metadata(record).fetch("generation") == observation.fetch("resume_generation")
          raise ContractError.new("stale_binding", "runtime observation does not match the current Work resume generation")
        end

        if observation.fetch("observation_type") == "runtime_disconnected"
          item = adapter_provenance(observation, observation_key_digest, observation_digest).merge(
            "kind" => "runtime_boundary", "runtime_available" => false
          )
          append_proposal!(record, item)
          append_event!(record, event(work_id, "runtime_disconnected", "blocked", observation.fetch("observed_at"), nil, observation_digest))
          record.dig("runtime_binding")["state"] = "disconnected"
          record.dig("runtime_binding")["updated_at"] = observation.fetch("observed_at")
          record["status"] = "blocked"
          write_record!(record)
          return coordinate_result(record, item, replayed: false)
        end

        recommendation = observation.fetch("recommendation")
        recommendation_digest = Digest::SHA256.hexdigest(canonical_json(recommendation))
        recommendation_replay = record["proposals"].find do |item|
          item["recommendation_key_digest"] == recommendation_key_digest(recommendation)
        end
        if recommendation_replay
          unless recommendation_replay["recommendation_digest"] == recommendation_digest &&
                 recommendation_replay["observation_digest"] == observation_digest
            raise ContractError.new("duplicate_request_conflict", "recommendation_id is already bound to different adapter evidence")
          end
          return coordinate_result(record, recommendation_replay, replayed: true)
        end

        selected, display_targets = resolve_recommended_targets!(recommendation)
        proposal = operation_proposal(recommendation, selected)
        planned = @authoring.plan("schema_version" => OperationAuthoring::PLAN_REQUEST, "proposal" => proposal)
        item = adapter_provenance(observation, observation_key_digest, observation_digest).merge(
          "kind" => "operation_proposal",
          "recommendation_key_digest" => recommendation_key_digest(recommendation),
          "recommendation_digest" => recommendation_digest,
          "recommendation" => recommendation.reject { |key, _| key == "recommendation_id" },
          "operation_id" => planned.fetch("operation_id"),
          "plan_id" => planned.fetch("plan_id"),
          "plan_generation" => planned.fetch("plan_generation"),
          "plan_digest" => planned.fetch("plan_digest"),
          "plan_token" => planned.fetch("plan_token"),
          "catalog_generation" => planned.fetch("catalog_generation"),
          "targets" => display_targets
        )
        append_proposal!(record, item)
        add_operation_id!(record, item.fetch("operation_id"))
        append_event!(record, event(work_id, "operation_proposed", "completed", observation.fetch("observed_at"), item.fetch("operation_id"), planned.fetch("plan_digest")))
        record["status"] = "operation_proposed"
        write_record!(record)
        coordinate_result(record, item, replayed: false)
      end
    end

    def launch(request)
      verify_capability!
      expect_object!(request, %w[schema_version work_id operation_id confirmation], "Work launch request")
      expect_version!(request, LAUNCH_REQUEST)
      work_id = validate_work_id!(request.fetch("work_id"))
      operation_id = validate_operation_id!(request.fetch("operation_id"))
      confirmation = request.fetch("confirmation")
      confirmation_fields = OperationAuthoring::CONFIRMATION_FIELDS
      expect_object!(confirmation, confirmation_fields, "Work launch confirmation")

      with_lock(File::LOCK_EX) do
        record = find_record!(work_id)
        item = record["proposals"].find { |candidate| candidate["kind"] == "operation_proposal" && candidate["operation_id"] == operation_id }
        raise ContractError.new("operation_not_found", "Work has no exact matching Operation proposal") unless item
        if record["status"] == "unknown_outcome" && record["active_operation_id"] == operation_id
          raise ContractError.new("unknown_outcome", "launch outcome is unknown; recover only by opening the original Work")
        end

        expected = confirmation_fields.to_h { |field| [field, item.fetch(field)] }
        unless secure_equal_json?(confirmation, expected)
          raise ContractError.new("stale_or_mismatched_plan", "launch confirmation does not match the stored Hub-authored plan")
        end
        proposal = rebuild_operation_proposal!(item)
        result = @authoring.launch(
          "schema_version" => OperationAuthoring::LAUNCH_REQUEST,
          "operation_id" => operation_id,
          "confirmation" => confirmation,
          "proposal" => proposal
        )
        now = timestamp
        record["active_operation_id"] = operation_id
        record["status"] = "operation_active"
        append_event!(record, event(work_id, "operation_launched", "completed", now, operation_id, result.fetch("plan_digest")))
        write_record!(record)
        {
          "schema_version" => LAUNCH_RESULT,
          "schema" => "hub/schemas/work-launch-result.schema.json",
          "ok" => true,
          "work" => work_summary(record),
          "operation" => safe_launch_result(result),
          "resume" => resume_metadata(record)
        }
      rescue OperationAuthoring::ContractError => e
        if e.code == "unknown_outcome"
          append_event!(record, event(work_id, "operation_launch_unknown", "unknown_outcome", timestamp, operation_id, item.fetch("plan_digest")))
          record["active_operation_id"] = operation_id
          record["status"] = "unknown_outcome"
          write_record!(record)
        end
        raise translate_authoring_error(e)
      end
    end

    def guidance(request)
      verify_capability!
      expect_object!(request, %w[schema_version work_id operation_id request_key guidance], "Work guidance request")
      expect_version!(request, GUIDANCE_REQUEST)
      work_id = validate_work_id!(request.fetch("work_id"))
      operation_id = validate_operation_id!(request.fetch("operation_id"))
      request_key = bounded_id!(request.fetch("request_key"), REQUEST_KEY, "request_key")

      with_lock(File::LOCK_EX) do
        record = find_record!(work_id)
        unless record["active_operation_id"] == operation_id
          raise ContractError.new("operation_identity_conflict", "guidance must name the exact active Operation for this Work")
        end
        request_key_digest = Digest::SHA256.hexdigest(request_key)
        payload_digest = Digest::SHA256.hexdigest(canonical_json("operation_id" => operation_id, "guidance" => request.fetch("guidance")))
        replay_event = record["events"].find { |item| item["type"] == "guidance_attached" && item["evidence_id"] == request_key_digest }
        if replay_event
          unless replay_event["payload_digest"] == payload_digest
            raise ContractError.new("duplicate_request_conflict", "request_key is already bound to different guidance")
          end
          return guidance_result(record, operation_id, replay_event, replayed: true)
        end

        result = @authoring.guidance(
          "schema_version" => OperationAuthoring::GUIDANCE_REQUEST,
          "operation_id" => operation_id,
          "guidance" => request.fetch("guidance")
        )
        linked = event(work_id, "guidance_attached", "completed", result.fetch("attached_at"), operation_id, request_key_digest,
                       payload_digest: payload_digest)
        append_event!(record, linked)
        write_record!(record)
        guidance_result(record, operation_id, linked, replayed: result.fetch("replayed"))
      rescue OperationAuthoring::ContractError => e
        raise translate_authoring_error(e)
      end
    end

    def open(request)
      verify_capability!
      expect_object!(request, %w[schema_version work_id], "Work open request")
      expect_version!(request, OPEN_REQUEST)
      work_id = validate_work_id!(request.fetch("work_id"))
      with_lock(File::LOCK_EX) do
        record = find_record!(work_id)
        result = open_result(record)
        derived = result.dig("work", "status")
        if record["status"] != derived && %w[operation_active result_ready failed unknown_outcome].include?(derived)
          record["status"] = derived
          latest_link = result.fetch("operation_links").map { |link| link.fetch("observed_at") }.max_by { |value| Time.iso8601(value) }
          record["updated_at"] = latest_timestamp(record.fetch("updated_at"), latest_link)
          write_record!(record)
          result = open_result(record)
        end
        result
      end
    end

    def list_page(limit: DEFAULT_LIMIT, cursor: nil)
      verify_capability!
      limit = Integer(limit)
      raise ContractError.new("malformed_request", "limit must be between 1 and #{MAX_LIMIT}") unless limit.between?(1, MAX_LIMIT)

      begin
        stat = File.lstat(work_dir)
      rescue Errno::ENOENT
        return list_result([], limit, cursor)
      end
      raise ContractError.new("work_store_invalid", "Work state root is invalid") unless stat.directory? && !stat.symlink?

      with_existing_lock(File::LOCK_SH) { list_result(work_records, limit, cursor) }
    rescue ArgumentError, TypeError
      raise ContractError.new("malformed_request", "limit must be an integer")
    end

    private

    def list_result(records, limit, cursor)
      ordered = records.sort_by { |record| [record.fetch("updated_at"), record.fetch("work_id")] }.reverse
      generation = "generation-#{Digest::SHA256.hexdigest(canonical_json(ordered.map { |record| [record["work_id"], record["updated_at"]] }))[0, 48]}"
      offset = decode_cursor(cursor, generation)
      page = ordered.slice(offset, limit) || []
      next_offset = offset + page.length
      {
        "schema_version" => LIST_RESULT,
        "schema" => "hub/schemas/work-list.schema.json",
        "ok" => true,
        "capability" => CAPABILITY,
        "generation" => generation,
        "works" => page.map { |record| work_summary(record) },
        "page" => {
          "limit" => limit,
          "returned" => page.length,
          "next_cursor" => next_offset < ordered.length ? encode_cursor(generation, next_offset) : nil
        }
      }
    end

    def verify_capability!
      compatibility_path = File.join(@config.root, "hub", "compatibility.json")
      paths = [compatibility_path, File.join(@config.root, "lib", "flightdeck", "work_store.rb")] +
        SCHEMAS.map { |name| File.join(@config.root, "hub", "schemas", name) }
      unless paths.all? { |path| File.file?(path) && !File.symlink?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Work control v1 contract")
      end
      compatibility = Support.load_data(compatibility_path)
      capability = compatibility.dig("capabilities", CAPABILITY)
      managed = ["lib/flightdeck/work_store.rb"] + SCHEMAS.map { |name| "hub/schemas/#{name}" }
      unless compatibility["schema_version"] == "flightdeck.hub-compatibility/v1" && compatibility["product"] == "flightdeck" &&
             capability.is_a?(Hash) && capability["kind"] == "command" &&
             capability.dig("probe", "help_contains") == "bin/flightdeck work list " &&
             managed.all? { |path| Array(capability["managed_paths"]).include?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Work control v1 contract")
      end
      SCHEMAS.each do |name|
        schema = Support.load_data(File.join(@config.root, "hub", "schemas", name))
        unless schema["$id"] == "https://flightdeck.dev/schemas/#{name}"
          raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Work control v1 contract")
        end
      end
    rescue SystemCallError, ValidationError
      raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Work control v1 contract")
    end

    def runtime_projection
      compatibility = Support.load_data(File.join(@config.root, "hub", "compatibility.json"))
      runtime = compatibility.fetch("runtime_capabilities")
      adapter = runtime.fetch("primary_runtime").to_s
      details = runtime.fetch("adapters").fetch(adapter)
      controls = Array(details["optional_controls"])
      channels = Array(details["structured_channels"])
      unless %w[codex omp].include?(adapter) && [true, false].include?(details["available"]) && controls.uniq == controls &&
             controls.all? { |item| %w[model reasoning_effort].include?(item) } && channels.uniq == channels &&
             (!details["available"] || channels.include?(STRUCTURED_CHANNEL))
        raise ContractError.new("unsupported_hub_contract", "Selected Hub runtime adapter metadata is invalid")
      end
      { "adapter" => adapter, "available" => details.fetch("available"), "optional_controls" => controls }
    rescue KeyError, ValidationError
      raise ContractError.new("unsupported_hub_contract", "Selected Hub runtime adapter metadata is invalid")
    end

    def runtime_binding(work_id, observed_at)
      runtime = runtime_projection
      seed = Digest::SHA256.hexdigest(@random_hex.call(32))
      {
        "adapter" => runtime.fetch("adapter"),
        "state" => runtime.fetch("available") ? "unbound" : "unavailable",
        "hub_binding_id" => "hub-binding-#{Digest::SHA256.hexdigest(canonical_json([work_id, seed]))[0, 24]}",
        "binding_id" => nil,
        "shared_secret" => nil,
        "session_id_digest" => nil,
        "session_generation" => nil,
        "resume_generation" => nil,
        "binding_request_digest" => nil,
        "binding_payload_digest" => nil,
        "structured_channel" => nil,
        "updated_at" => observed_at
      }
    end

    def normalize_recommendation!(value)
      raise ContractError.new("malformed_request", "recommendation must be one object") unless value.is_a?(Hash)
      recommendation = Support.stringify(value)
      base = %w[schema_version recommendation_id disposition observed_at]
      disposition = recommendation["disposition"]
      fields = base + %w[title work_intent target_project_keys access_mode execution_mode success_criteria non_goals]
      expect_object!(recommendation, fields, "runtime recommendation")
      unless recommendation["schema_version"] == RECOMMENDATION_VERSION && disposition == "operation"
        raise ContractError.new("malformed_request", "runtime recommendation is incompatible")
      end
      bounded_id!(recommendation["recommendation_id"], RECOMMENDATION_ID, "recommendation_id")
      parse_time!(recommendation["observed_at"], "observed_at")
      recommendation["title"] = safe_structured_text!(recommendation["title"], "title", 256)
      recommendation["work_intent"] = safe_structured_text!(recommendation["work_intent"], "work_intent", 2048)
      recommendation["success_criteria"] = safe_text_list!(recommendation["success_criteria"], "success_criteria", min: 1)
      recommendation["non_goals"] = safe_text_list!(recommendation["non_goals"], "non_goals", min: 1)
      unless %w[read_only write].include?(recommendation["access_mode"]) && %w[local worktree].include?(recommendation["execution_mode"])
        raise ContractError.new("malformed_request", "runtime recommendation has an invalid target mode")
      end
      keys = recommendation["target_project_keys"]
      unless keys.is_a?(Array) && keys.length.between?(1, OperationAuthoring::MAX_ITEMS) && keys.uniq == keys &&
             keys.all? { |key| key.is_a?(String) && Support::IDENTIFIER.match?(key) }
        raise ContractError.new("malformed_request", "target_project_keys must be unique bounded logical project keys")
      end
      recommendation
    end

    def normalize_observation!(value, work_id)
      raise ContractError.new("malformed_request", "observation must be one object") unless value.is_a?(Hash)

      observation = Support.stringify(value)
      base = %w[
        schema_version hub_binding_id work_id binding_id adapter adapter_session_id session_generation
        resume_generation structured_channel observation_id observation_type observed_at signature
      ]
      fields = observation["observation_type"] == "managed_recommendation" ? base + %w[recommendation] : base
      expect_object!(observation, fields, "runtime adapter observation")
      unless observation["schema_version"] == OBSERVATION_VERSION &&
             %w[managed_recommendation runtime_disconnected].include?(observation["observation_type"])
        raise ContractError.new("malformed_request", "runtime adapter observation is incompatible")
      end
      raise ContractError.new("binding_mismatch", "runtime observation names a different Work") unless observation["work_id"] == work_id
      bounded_id!(observation["hub_binding_id"], /\Ahub-binding-[0-9a-f]{24}\z/, "hub_binding_id")
      bounded_id!(observation["binding_id"], /\Aadapter-binding-[0-9a-f]{24}\z/, "binding_id")
      bounded_id!(observation["adapter"], /\A(?:codex|omp)\z/, "adapter")
      bounded_id!(observation["adapter_session_id"], OPAQUE_RUNTIME_ID, "adapter_session_id")
      bounded_id!(observation["session_generation"], /\Aadapter-session-[0-9a-f]{48}\z/, "session_generation")
      bounded_id!(observation["resume_generation"], /\Aresume-[0-9a-f]{48}\z/, "resume_generation")
      bounded_id!(observation["observation_id"], RECOMMENDATION_ID, "observation_id")
      parse_time!(observation["observed_at"], "observed_at")
      raise ContractError.new("unsupported_structured_channel", "runtime adapter structured channel is unsupported") unless observation["structured_channel"] == STRUCTURED_CHANNEL
      raise ContractError.new("malformed_request", "runtime adapter signature is invalid") unless SHA256.match?(observation["signature"].to_s)
      if observation["observation_type"] == "managed_recommendation"
        observation["recommendation"] = normalize_recommendation!(observation.fetch("recommendation"))
        unless observation.dig("recommendation", "observed_at") == observation["observed_at"]
          raise ContractError.new("malformed_request", "runtime recommendation timestamp does not match its adapter observation")
        end
      end
      observation
    end

    def authenticate_observation!(record, observation)
      binding = record.fetch("runtime_binding")
      case binding["state"]
      when "unavailable" then raise ContractError.new("adapter_unavailable", "selected Hub runtime adapter is unavailable")
      when "unbound" then raise ContractError.new("binding_absent", "Work has no authenticated runtime adapter binding")
      end
      expected = {
        "hub_binding_id" => binding["hub_binding_id"],
        "binding_id" => binding["binding_id"],
        "adapter" => binding["adapter"],
        "session_generation" => binding["session_generation"],
        "structured_channel" => binding["structured_channel"]
      }
      actual = expected.keys.to_h { |key| [key, observation[key]] }
      unless secure_equal_json?(actual, expected) &&
             secure_equal?(Digest::SHA256.hexdigest(observation.fetch("adapter_session_id")), binding["session_id_digest"].to_s)
        raise ContractError.new("binding_mismatch", "runtime observation does not match the exact Hub, Work, or adapter session binding")
      end
      payload = canonical_json(observation.reject { |key, _| key == "signature" })
      signature = OpenSSL::HMAC.hexdigest("SHA256", binding.fetch("shared_secret"), payload)
      unless secure_equal?(signature, observation.fetch("signature"))
        raise ContractError.new("adapter_authentication_failed", "runtime observation signature is invalid")
      end
      if binding["state"] == "disconnected" && observation["observation_type"] != "runtime_disconnected"
        raise ContractError.new("runtime_disconnected", "runtime adapter is disconnected; create a fresh exact binding before continuing")
      end
    end

    def adapter_provenance(observation, observation_key_digest, observation_digest)
      {
        "observation_key_digest" => observation_key_digest,
        "observation_digest" => observation_digest,
        "binding_id" => observation.fetch("binding_id"),
        "session_generation" => observation.fetch("session_generation"),
        "resume_generation" => observation.fetch("resume_generation"),
        "observed_at" => observation.fetch("observed_at")
      }
    end

    def resolve_recommended_targets!(recommendation)
      catalog = @authoring.catalog("schema_version" => OperationAuthoring::CATALOG_REQUEST)
      by_key = catalog.fetch("targets").group_by { |target| target.fetch("logical_project_key") }
      selected = recommendation.fetch("target_project_keys").map do |key|
        candidates = by_key[key]
        raise ContractError.new("unknown_target", "runtime recommendation named an unknown logical project") unless candidates
        target = candidates.find do |candidate|
          candidate["access_mode"] == recommendation["access_mode"] && candidate["execution_mode"] == recommendation["execution_mode"]
        end
        raise ContractError.new("ineligible_target", "runtime recommendation named an ineligible project mode") unless target
        target
      end
      display = selected.map { |target| { "logical_project_key" => target.fetch("logical_project_key"), "display_label" => target.fetch("display_label") } }
      [selected, display]
    end

    def operation_proposal(recommendation, selected)
      {
        "title" => recommendation.fetch("title"),
        "work_intent" => recommendation.fetch("work_intent"),
        "success_criteria" => recommendation.fetch("success_criteria"),
        "non_goals" => recommendation.fetch("non_goals"),
        "mode" => "supervised",
        "selected_targets" => selected.map { |target| target.reject { |key, _| key == "display_label" } }
      }
    end

    def rebuild_operation_proposal!(item)
      recommendation = item.fetch("recommendation").merge(
        "schema_version" => RECOMMENDATION_VERSION,
        "recommendation_id" => "recovery-#{item.fetch('recommendation_digest')[0, 24]}"
      )
      selected, = resolve_recommended_targets!(recommendation)
      proposal = operation_proposal(recommendation, selected)
      planned = @authoring.plan("schema_version" => OperationAuthoring::PLAN_REQUEST, "proposal" => proposal)
      %w[operation_id plan_id plan_generation plan_digest plan_token catalog_generation].each do |field|
        unless planned[field] == item[field]
          raise ContractError.new("stale_or_mismatched_plan", "stored Work proposal no longer matches the exact Hub catalog")
        end
      end
      proposal
    end

    def adapter_bind_result(record, replayed:)
      binding = record.fetch("runtime_binding")
      {
        "schema_version" => ADAPTER_BIND_RESULT,
        "schema" => "hub/schemas/work-adapter-bind-result.schema.json",
        "ok" => true,
        "binding" => {
          "hub_binding_id" => binding.fetch("hub_binding_id"),
          "work_id" => record.fetch("work_id"),
          "adapter" => binding.fetch("adapter"),
          "binding_id" => binding.fetch("binding_id"),
          "session_generation" => binding.fetch("session_generation"),
          "resume_generation" => resume_metadata(record).fetch("generation"),
          "structured_channel" => binding.fetch("structured_channel"),
          "shared_secret" => binding.fetch("shared_secret")
        },
        "replayed" => replayed
      }
    end

    def coordinate_result(record, item, replayed:)
      runtime = runtime_projection
      if item["kind"] == "runtime_boundary"
        return {
          "schema_version" => COORDINATE_RESULT,
          "schema" => "hub/schemas/work-coordinate-result.schema.json",
          "ok" => true,
          "disposition" => item["runtime_available"] ? "runtime_delegate" : "runtime_unavailable",
          "work" => work_summary(record),
          "runtime" => runtime_boundary(record, item),
          "proposal" => nil,
          "resume" => resume_metadata(record),
          "replayed" => replayed
        }
      end
      {
        "schema_version" => COORDINATE_RESULT,
        "schema" => "hub/schemas/work-coordinate-result.schema.json",
        "ok" => true,
        "disposition" => "operation_proposal",
        "work" => work_summary(record),
        "runtime" => runtime_boundary(record, item),
        "proposal" => proposal_projection(item),
        "resume" => resume_metadata(record),
        "replayed" => replayed
      }
    end

    def proposal_projection(item)
      {
        "operation_id" => item.fetch("operation_id"),
        "plan_id" => item.fetch("plan_id"),
        "plan_generation" => item.fetch("plan_generation"),
        "plan_digest" => item.fetch("plan_digest"),
        "plan_token" => item.fetch("plan_token"),
        "title" => item.dig("recommendation", "title"),
        "mode" => "supervised",
        "targets" => item.fetch("targets"),
        "authorization" => {
          "access_mode" => item.dig("recommendation", "access_mode"),
          "execution_mode" => item.dig("recommendation", "execution_mode"),
          "external_actions_authorized" => false
        }
      }
    end

    def create_result(record, replayed:)
      {
        "schema_version" => CREATE_RESULT,
        "schema" => "hub/schemas/work-create-result.schema.json",
        "ok" => true,
        "work" => work_summary(record),
        "runtime" => runtime_projection,
        "resume" => resume_metadata(record),
        "replayed" => replayed
      }
    end

    def guidance_result(record, operation_id, linked_event, replayed:)
      {
        "schema_version" => GUIDANCE_RESULT,
        "schema" => "hub/schemas/work-guidance-result.schema.json",
        "ok" => true,
        "work" => work_summary(record),
        "operation_id" => operation_id,
        "event_id" => linked_event.fetch("event_id"),
        "attached_at" => linked_event.fetch("observed_at"),
        "replayed" => replayed,
        "resume" => resume_metadata(record)
      }
    end

    def open_result(record)
      links = operation_links(record)
      derived_events = links.map { |link| operation_event(record.fetch("work_id"), link) }
      events = (record.fetch("events") + derived_events).uniq { |item| item.fetch("event_id") }
        .sort_by { |item| [item.fetch("observed_at"), item.fetch("event_id")] }
      status = derived_work_status(record, links)
      {
        "schema_version" => OPEN_RESULT,
        "schema" => "hub/schemas/work-open-result.schema.json",
        "ok" => true,
        "work" => work_summary(record).merge("status" => status),
        "events" => events,
        "operation_links" => links,
        "resume" => resume_metadata(record),
        "runtime" => runtime_projection
      }
    end

    def operation_links(record)
      record.fetch("operation_ids").map do |operation_id|
        recovery = @authoring.operation("schema_version" => OperationAuthoring::OPERATION_REQUEST, "operation_id" => operation_id)
        state = updated_at = nil
        if recovery["outcome"] == "created"
          mission = MissionStore.new(@config, clock: @clock).status(recovery.fetch("mission_id"))
          state = mission.dig("status", "state")
          updated_at = mission.dig("metadata", "updated_at")
        end
        relation = if record["active_operation_id"] == operation_id
                     "active"
                   elsif recovery["outcome"] == "created"
                     "historical"
                   else
                     "proposed"
                   end
        result_state = if recovery["outcome"] == "unresolved"
                         "unknown_outcome"
                       elsif RESULT_STATES.include?(state)
                         "available"
                       elsif FAILURE_STATES.include?(state)
                         "failed"
                       elsif recovery["outcome"] == "created"
                         "in_progress"
                       else
                         "not_created"
                       end
        observed_at = updated_at || record.fetch("updated_at")
        evidence = Digest::SHA256.hexdigest(canonical_json([operation_id, recovery["outcome"], state, observed_at, result_state]))
        {
          "link_id" => "operation-link-#{evidence[0, 24]}",
          "operation_id" => operation_id,
          "relation" => relation,
          "authoring_outcome" => recovery.fetch("outcome"),
          "state" => state,
          "result_state" => result_state,
          "observed_at" => observed_at,
          "evidence_id" => evidence,
          "source" => {
            "capability" => state ? "flightdeck.command.mission-status.v1" : OperationAuthoring::CAPABILITY,
            "schema" => state ? "hub/schemas/mission.schema.json" : "hub/schemas/operation-authoring-operation-result.schema.json"
          }
        }
      rescue OperationAuthoring::ContractError, ValidationError
        evidence = Digest::SHA256.hexdigest(canonical_json([operation_id, "unresolved", record.fetch("updated_at")]))
        {
          "link_id" => "operation-link-#{evidence[0, 24]}", "operation_id" => operation_id, "relation" => "proposed",
          "authoring_outcome" => "unresolved", "state" => nil, "result_state" => "unknown_outcome",
          "observed_at" => record.fetch("updated_at"), "evidence_id" => evidence,
          "source" => { "capability" => OperationAuthoring::CAPABILITY, "schema" => "hub/schemas/operation-authoring-operation-result.schema.json" }
        }
      end.sort_by { |link| [link.fetch("observed_at"), link.fetch("operation_id")] }
    end

    def operation_event(work_id, link)
      type = %w[available failed].include?(link["result_state"]) ? "operation_result" : "operation_progress"
      event(work_id, type, link.fetch("result_state"), link.fetch("observed_at"), link.fetch("operation_id"), link.fetch("evidence_id"),
            source: link.fetch("source"))
    end

    def derived_work_status(record, links)
      active = links.find { |link| link["operation_id"] == record["active_operation_id"] }
      return "result_ready" if active && active["result_state"] == "available"
      return "failed" if active && active["result_state"] == "failed"
      return "unknown_outcome" if links.any? { |link| link["result_state"] == "unknown_outcome" }
      return "operation_active" if active
      return "operation_proposed" unless links.empty?

      record.fetch("status")
    end

    def safe_launch_result(result)
      result.slice("operation_id", "outcome", "plan_id", "plan_generation", "plan_digest", "replayed")
    end

    def runtime_boundary(record, item)
      runtime = runtime_projection
      {
        "adapter" => runtime.fetch("adapter"),
        "available" => item["kind"] == "runtime_boundary" ? item.fetch("runtime_available") : runtime.fetch("available"),
        "turn_id" => "turn-#{item.fetch('observation_digest')[0, 24]}",
        "binding_state" => record.dig("runtime_binding", "state"),
        "optional_controls" => runtime.fetch("optional_controls")
      }
    end

    def resume_metadata(record)
      binding = record.fetch("runtime_binding")
      digest = Digest::SHA256.hexdigest(canonical_json([record["work_id"], record["updated_at"], binding["hub_binding_id"], binding["binding_id"]]))
      {
        "state" => { "bound" => "available", "unbound" => "binding_required", "disconnected" => "disconnected", "unavailable" => "unavailable" }.fetch(binding.fetch("state")),
        "adapter" => binding.fetch("adapter"),
        "work_id" => record.fetch("work_id"),
        "generation" => "resume-#{digest[0, 48]}",
        "last_event_id" => record.fetch("events").last&.fetch("event_id", nil),
        "active_operation_id" => record["active_operation_id"]
      }
    end

    def work_summary(record)
      {
        "work_id" => record.fetch("work_id"),
        "title" => record.fetch("title"),
        "status" => record.fetch("status"),
        "created_at" => record.fetch("created_at"),
        "updated_at" => record.fetch("updated_at"),
        "operation_count" => record.fetch("operation_ids").length,
        "active_operation_id" => record["active_operation_id"]
      }
    end

    def event(work_id, type, status, observed_at, operation_id, evidence_id, payload_digest: nil, source: nil)
      evidence = SHA256.match?(evidence_id.to_s) ? evidence_id : Digest::SHA256.hexdigest(evidence_id.to_s)
      payload = payload_digest || evidence
      identity = Digest::SHA256.hexdigest(canonical_json([work_id, type, status, observed_at, operation_id, evidence]))
      {
        "event_id" => "work-event-#{identity[0, 24]}",
        "type" => type,
        "status" => status,
        "observed_at" => observed_at,
        "operation_id" => operation_id,
        "evidence_id" => evidence,
        "payload_digest" => payload,
        "source" => source || { "capability" => CAPABILITY, "schema" => "hub/schemas/work-types.schema.json" }
      }
    end

    def append_event!(record, item)
      return if record.fetch("events").any? { |event_item| event_item["event_id"] == item["event_id"] }
      raise ContractError.new("event_limit_exceeded", "Work event limit is exhausted") if record.fetch("events").length >= MAX_EVENTS

      record["events"] << item
      record["events"].sort_by! { |event_item| [event_item.fetch("observed_at"), event_item.fetch("event_id")] }
      record["updated_at"] = latest_timestamp(record.fetch("updated_at"), item.fetch("observed_at"))
    end

    def append_proposal!(record, item)
      raise ContractError.new("event_limit_exceeded", "Work recommendation limit is exhausted") if record.fetch("proposals").length >= MAX_EVENTS
      record["proposals"] << item
    end

    def add_operation_id!(record, operation_id)
      return if record.fetch("operation_ids").include?(operation_id)
      raise ContractError.new("event_limit_exceeded", "Work Operation link limit is exhausted") if record.fetch("operation_ids").length >= MAX_OPERATIONS
      record["operation_ids"] << operation_id
    end

    def work_records
      return [] unless Dir.exist?(work_dir)
      stat = File.lstat(work_dir)
      raise ContractError.new("work_store_invalid", "Work state root is invalid") unless stat.directory? && !stat.symlink?

      entries = Dir.children(work_dir).reject { |entry| entry == ".lock" }.sort
      raise ContractError.new("work_store_invalid", "Work record limit is exceeded") if entries.length > MAX_WORK_RECORDS
      unless entries.all? { |entry| entry.match?(/\A[0-9a-f]{64}\.json\z/) }
        raise ContractError.new("work_store_invalid", "Work state contains an unknown entry")
      end
      records = entries.map do |entry|
        path = File.join(work_dir, entry)
        item_stat = File.lstat(path)
        unless item_stat.file? && !item_stat.symlink? && item_stat.size <= MAX_RECORD_BYTES
          raise ContractError.new("work_store_invalid", "Work record boundary is invalid")
        end
        record = Support.load_data(path)
        validate_record!(record)
        unless entry == "#{Digest::SHA256.hexdigest(record.fetch('work_id'))}.json"
          raise ContractError.new("work_store_invalid", "Work record filename binding is invalid")
        end
        record
      end
      ids = records.map { |record| record.fetch("work_id") }
      keys = records.map { |record| record.fetch("request_key_digest") }
      unless ids.uniq.length == ids.length && keys.uniq.length == keys.length
        raise ContractError.new("work_store_invalid", "Work state contains conflicting identities")
      end
      records
    rescue SystemCallError, EncodingError, ValidationError
      raise ContractError.new("work_store_invalid", "Work state is unreadable or malformed")
    end

    def find_record!(work_id)
      work_records.find { |record| record["work_id"] == work_id } || raise(ContractError.new("work_not_found", "Work identity was not found"))
    end

    def validate_record!(record)
      fields = %w[schema_version work_id request_key_digest request_digest title status runtime_binding proposals operation_ids active_operation_id events created_at updated_at]
      expect_object!(record, fields, "Work record")
      unless record["schema_version"] == RECORD_VERSION && WORK_ID.match?(record["work_id"].to_s) &&
             SHA256.match?(record["request_key_digest"].to_s) && SHA256.match?(record["request_digest"].to_s) &&
             %w[open blocked operation_proposed operation_active unknown_outcome result_ready failed].include?(record["status"])
        raise ContractError.new("work_store_invalid", "Work record identity or state is invalid")
      end
      display_title(record.fetch("title"))
      binding = record.fetch("runtime_binding")
      binding_fields = %w[
        adapter state hub_binding_id binding_id shared_secret session_id_digest session_generation resume_generation
        binding_request_digest binding_payload_digest structured_channel updated_at
      ]
      expect_object!(binding, binding_fields, "Work runtime binding")
      unless %w[codex omp].include?(binding["adapter"]) && %w[unbound bound disconnected unavailable].include?(binding["state"]) &&
             binding["hub_binding_id"].to_s.match?(/\Ahub-binding-[0-9a-f]{24}\z/)
        raise ContractError.new("work_store_invalid", "Work runtime binding is invalid")
      end
      parse_time!(binding["updated_at"], "runtime_binding.updated_at")
      private_fields = %w[binding_id shared_secret session_id_digest session_generation resume_generation binding_request_digest binding_payload_digest structured_channel]
      if %w[bound disconnected].include?(binding["state"])
        valid_private = binding["binding_id"].to_s.match?(/\Aadapter-binding-[0-9a-f]{24}\z/) &&
          SHA256.match?(binding["shared_secret"].to_s) && SHA256.match?(binding["session_id_digest"].to_s) &&
          binding["session_generation"].to_s.match?(/\Aadapter-session-[0-9a-f]{48}\z/) &&
          binding["resume_generation"].to_s.match?(/\Aresume-[0-9a-f]{48}\z/) &&
          SHA256.match?(binding["binding_request_digest"].to_s) && SHA256.match?(binding["binding_payload_digest"].to_s) &&
          binding["structured_channel"] == STRUCTURED_CHANNEL
        raise ContractError.new("work_store_invalid", "Work runtime binding is invalid") unless valid_private
      elsif private_fields.any? { |field| !binding[field].nil? }
        raise ContractError.new("work_store_invalid", "unbound Work runtime binding contains private session state")
      end
      unless record["proposals"].is_a?(Array) && record["proposals"].length <= MAX_EVENTS &&
             record["operation_ids"].is_a?(Array) && record["operation_ids"].length <= MAX_OPERATIONS && record["operation_ids"].uniq == record["operation_ids"] &&
             record["operation_ids"].all? { |id| OPERATION_ID.match?(id.to_s) } &&
             (record["active_operation_id"].nil? || record["operation_ids"].include?(record["active_operation_id"])) &&
             record["events"].is_a?(Array) && record["events"].length.between?(1, MAX_EVENTS)
        raise ContractError.new("work_store_invalid", "Work record collections are invalid")
      end
      record["proposals"].each { |item| validate_proposal_record!(item) }
      record["events"].each { |item| validate_event!(item) }
      ids = record["events"].map { |item| item["event_id"] }
      raise ContractError.new("work_store_invalid", "Work event identities conflict") unless ids.uniq.length == ids.length
      parse_time!(record["created_at"], "created_at")
      parse_time!(record["updated_at"], "updated_at")
      latest_event = record["events"].map { |item| item.fetch("observed_at") }.max_by { |value| Time.iso8601(value) }
      if Time.iso8601(record["updated_at"]) < Time.iso8601(record["created_at"]) ||
         Time.iso8601(record["updated_at"]) < Time.iso8601(latest_event)
        raise ContractError.new("work_store_invalid", "Work record timestamps are inconsistent")
      end
    end

    def validate_proposal_record!(item)
      provenance = %w[observation_key_digest observation_digest binding_id session_generation resume_generation observed_at]
      recommendation = %w[recommendation_key_digest recommendation_digest]
      fields = if item["kind"] == "operation_proposal"
                 provenance + recommendation + %w[kind recommendation operation_id plan_id plan_generation plan_digest plan_token catalog_generation targets]
               else
                 provenance + %w[kind runtime_available]
               end
      expect_object!(item, fields, "Work recommendation record")
      unless %w[runtime_boundary operation_proposal].include?(item["kind"]) &&
             SHA256.match?(item["observation_key_digest"].to_s) && SHA256.match?(item["observation_digest"].to_s) &&
             item["binding_id"].to_s.match?(/\Aadapter-binding-[0-9a-f]{24}\z/) &&
             item["session_generation"].to_s.match?(/\Aadapter-session-[0-9a-f]{48}\z/) &&
             item["resume_generation"].to_s.match?(/\Aresume-[0-9a-f]{48}\z/)
        raise ContractError.new("work_store_invalid", "Work recommendation record is invalid")
      end
      parse_time!(item["observed_at"], "observed_at")
      return if item["kind"] == "runtime_boundary" && [true, false].include?(item["runtime_available"])
      raise ContractError.new("work_store_invalid", "Work proposal record is invalid") unless item["kind"] == "operation_proposal"
      unless SHA256.match?(item["recommendation_key_digest"].to_s) && SHA256.match?(item["recommendation_digest"].to_s)
        raise ContractError.new("work_store_invalid", "Work recommendation record is invalid")
      end
      stored_recommendation = item.fetch("recommendation").merge(
        "recommendation_id" => "recovery-#{item.fetch('recommendation_digest')[0, 24]}"
      )
      normalize_recommendation!(stored_recommendation)
      validate_operation_id!(item["operation_id"])
      %w[plan_digest plan_token].each { |field| raise ContractError.new("work_store_invalid", "Work proposal digest is invalid") unless SHA256.match?(item[field].to_s) }
      unless item["plan_id"].to_s.match?(/\Aplan-[0-9a-f]{48}\z/) && item["plan_generation"].to_s.match?(/\Ageneration-[0-9a-f]{48}\z/) &&
             item["catalog_generation"].to_s.match?(/\Acatalog-[0-9a-f]{48}\z/) && item["targets"].is_a?(Array) &&
             item["targets"].length.between?(1, OperationAuthoring::MAX_ITEMS) && item["targets"].all? do |target|
               target.is_a?(Hash) && target.keys.sort == %w[display_label logical_project_key] &&
                 Support::IDENTIFIER.match?(target["logical_project_key"].to_s) && display_title(target["display_label"]) == target["display_label"]
             end
        raise ContractError.new("work_store_invalid", "Work proposal identity is invalid")
      end
    end

    def validate_event!(item)
      expect_object!(item, %w[event_id type status observed_at operation_id evidence_id payload_digest source], "Work event")
      source = item.fetch("source")
      expect_object!(source, %w[capability schema], "Work event source")
      unless item["event_id"].to_s.match?(/\Awork-event-[0-9a-f]{24}\z/) && Support::IDENTIFIER.match?(item["type"].to_s) &&
             Support::IDENTIFIER.match?(item["status"].to_s) && SHA256.match?(item["evidence_id"].to_s) && SHA256.match?(item["payload_digest"].to_s) &&
             (item["operation_id"].nil? || OPERATION_ID.match?(item["operation_id"].to_s)) && source.values.all? { |value| value.is_a?(String) && !value.empty? && value.bytesize <= 256 }
        raise ContractError.new("work_store_invalid", "Work event is invalid")
      end
      parse_time!(item["observed_at"], "observed_at")
    end

    def write_record!(record)
      validate_record!(record)
      content = "#{JSON.pretty_generate(record)}\n"
      raise ContractError.new("work_store_invalid", "Work record exceeds its bounded contract") if content.bytesize > MAX_RECORD_BYTES
      FileUtils.mkdir_p(work_dir, mode: 0o700)
      Support.atomic_write(record_path(record.fetch("work_id")), content)
    end

    def with_lock(mode)
      FileUtils.mkdir_p(work_dir, mode: 0o700)
      File.open(File.join(work_dir, ".lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        unless lock.stat.file? && !File.symlink?(File.join(work_dir, ".lock")) && lock.flock(mode | File::LOCK_NB)
          raise ContractError.new("work_store_invalid", "Work state lock is unavailable")
        end
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise ContractError.new("work_store_invalid", "Work state lock is unavailable")
    end

    def with_existing_lock(mode)
      lock_path = File.join(work_dir, ".lock")
      File.open(lock_path, File::RDWR) do |lock|
        unless lock.stat.file? && !File.symlink?(lock_path) && lock.flock(mode | File::LOCK_NB)
          raise ContractError.new("work_store_invalid", "Work state lock is unavailable")
        end
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise ContractError.new("work_store_invalid", "Work state lock is unavailable")
    end

    def work_dir
      @config.root_path("hub/state/work", label: "Work state")
    end

    def record_path(work_id)
      File.join(work_dir, "#{Digest::SHA256.hexdigest(work_id)}.json")
    end

    def unique_work_id(records)
      16.times do
        candidate = "work-#{@random_hex.call(12)}"
        return candidate if WORK_ID.match?(candidate) && records.none? { |record| record["work_id"] == candidate }
      end
      raise ContractError.new("work_identity_conflict", "could not allocate a unique Work identity")
    end

    def recommendation_key_digest(recommendation)
      Digest::SHA256.hexdigest(recommendation.fetch("recommendation_id"))
    end

    def display_title(value)
      raise ContractError.new("malformed_request", "title_hint must be text") unless value.is_a?(String)
      return "New Work" if value.strip.empty?

      safe_structured_text!(value, "title_hint", 128)
    end

    def safe_text_list!(value, label, min: 0)
      unless value.is_a?(Array) && value.length.between?(min, OperationAuthoring::MAX_ITEMS)
        raise ContractError.new("malformed_request", "#{label} is outside its bounded contract")
      end
      items = value.map { |item| safe_structured_text!(item, label, 1024) }
      raise ContractError.new("malformed_request", "#{label} must be unique") unless items.uniq == items
      items
    end

    def safe_structured_text!(value, label, maximum)
      raise ContractError.new("malformed_request", "#{label} must be text") unless value.is_a?(String)
      text = value.strip.gsub(/\s+/, " ")
      if text.empty? || text.bytesize > maximum || text.match?(/[\u0000-\u001f\u007f]/) ||
         text.match?(%r{(?:\A|\s)(?:/Users/|/home/|[A-Za-z]:\\)}) ||
         text.match?(/\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/i) ||
         text.match?(/\A[\[{].*[\]}]\z/) ||
         text.match?(/\b(?:secret|password|credential|access[_-]?token)\s*[:=]\s*\S+/i)
        raise ContractError.new("malformed_request", "#{label} is not display-safe bounded text")
      end
      text
    end

    def expect_object!(value, fields, label)
      unless value.is_a?(Hash) && (value.keys - fields).empty? && fields.all? { |field| value.key?(field) }
        raise ContractError.new("malformed_request", "#{label} must contain only #{fields.join(', ')}")
      end
    end

    def expect_version!(request, version)
      raise ContractError.new("malformed_request", "request has an unsupported schema version") unless request["schema_version"] == version
    end

    def bounded_id!(value, pattern, label)
      raise ContractError.new("malformed_request", "#{label} is invalid") unless value.is_a?(String) && pattern.match?(value)
      value
    end

    def validate_work_id!(value)
      bounded_id!(value, WORK_ID, "work_id")
    end

    def validate_operation_id!(value)
      bounded_id!(value, OPERATION_ID, "operation_id")
    end

    def parse_time!(value, label)
      parsed = Time.iso8601(value.to_s)
      raise ArgumentError unless value.is_a?(String) && value.end_with?("Z") && parsed.utc_offset.zero?
      value
    rescue ArgumentError
      raise ContractError.new("malformed_request", "#{label} must be a canonical UTC timestamp")
    end

    def timestamp
      @clock.call.utc.iso8601
    end

    def latest_timestamp(*values)
      values.compact.max_by { |value| Time.iso8601(value) }
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
      left_json = canonical_json(Support.stringify(left))
      right_json = canonical_json(Support.stringify(right))
      secure_equal?(left_json, right_json)
    end

    def secure_equal?(left, right)
      left = left.to_s
      right = right.to_s
      left.bytesize == right.bytesize && left.bytes.zip(right.bytes).all? { |a, b| a == b }
    end

    def encode_cursor(generation, offset)
      Base64.urlsafe_encode64(JSON.generate("generation" => generation, "offset" => offset), padding: false)
    end

    def decode_cursor(cursor, generation)
      return 0 unless Support.present?(cursor)
      value = JSON.parse(Base64.urlsafe_decode64(cursor.to_s))
      unless value.is_a?(Hash) && value.keys.sort == %w[generation offset] && value["generation"] == generation &&
             value["offset"].is_a?(Integer) && value["offset"].between?(0, MAX_WORK_RECORDS)
        raise ContractError.new("stale_cursor", "Work list cursor is stale or malformed")
      end
      value["offset"]
    rescue ArgumentError, JSON::ParserError
      raise ContractError.new("stale_cursor", "Work list cursor is stale or malformed")
    end

    def translate_authoring_error(error)
      allowed = %w[unknown_outcome operation_not_found operation_identity_conflict terminal_operation guidance_limit_exceeded stale_or_mismatched_plan conflicting_operation not_created]
      code = allowed.include?(error.code) ? error.code : "internal_error"
      ContractError.new(code, error.message)
    end
  end
end
