# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require_relative "operation_authoring"
require_relative "mission_store"

module Flightdeck
  # Explicit operator acknowledgement and reversible visibility for authored
  # Operations. This store never deletes an Operation or changes its execution
  # evidence. Completion remains owned by MissionStore's exact close gate.
  class OperationLifecycle
    CAPABILITY = "flightdeck.command.operation-lifecycle.v1"
    REQUEST = "flightdeck.operation-lifecycle.request/v1"
    RESULT = "flightdeck.operation-lifecycle.result/v1"
    ERROR = "flightdeck.operation-lifecycle.error/v1"
    RECORD_VERSION = "flightdeck.operation-lifecycle.record/v1"
    ACTIONS = %w[close archive restore].freeze
    ARCHIVABLE_STATES = %w[complete failed_validation runtime_failure cancelled].freeze
    REQUEST_ID = /\A[a-zA-Z0-9][a-zA-Z0-9._:-]{7,127}\z/
    OPERATION_ID = /\Aoperation-[0-9a-f]{24}\z/
    MAX_REQUESTS = 100
    MAX_REQUEST_BYTES = 16_384
    MAX_RECORD_BYTES = 65_536

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
      @authoring = OperationAuthoring.new(config, clock: clock)
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
      {
        "schema_version" => ERROR,
        "schema" => "hub/schemas/operation-lifecycle-error.schema.json",
        "ok" => false,
        "error" => { "code" => code, "message" => error.message.to_s[0, 512] }
      }
    end

    def apply(request)
      verify_capability!
      request = Support.stringify(request)
      expected = %w[action operation_id request_id schema_version]
      unless request.is_a?(Hash) && request.keys.sort == expected && request["schema_version"] == REQUEST
        raise ContractError.new("malformed_request", "Operation lifecycle request is invalid")
      end
      action = request.fetch("action").to_s
      operation_id = request.fetch("operation_id").to_s
      request_id = request.fetch("request_id").to_s
      raise ContractError.new("malformed_request", "Operation lifecycle action is invalid") unless ACTIONS.include?(action)
      raise ContractError.new("malformed_request", "Operation identity is invalid") unless OPERATION_ID.match?(operation_id)
      raise ContractError.new("malformed_request", "Operation lifecycle request identity is invalid") unless REQUEST_ID.match?(request_id)

      with_lock(File::LOCK_EX) do
        binding = @authoring.operation(
          "schema_version" => OperationAuthoring::OPERATION_REQUEST,
          "operation_id" => operation_id
        )
        unless binding["outcome"] == "created" && binding["mission_id"] == operation_id
          raise ContractError.new("operation_unavailable", "Operation is not bound to an exact durable record")
        end

        record = load_record(operation_id)
        request_digest = Digest::SHA256.hexdigest(request_id)
        payload_digest = Digest::SHA256.hexdigest(JSON.generate(request.sort.to_h))
        replay = record.fetch("requests").find { |item| item["request_digest"] == request_digest }
        if replay
          unless replay["payload_digest"] == payload_digest
            raise ContractError.new("duplicate_request_conflict", "request_id is already bound to a different lifecycle action")
          end
          return result(record, mission_state(operation_id), replayed: true)
        end
        raise ContractError.new("request_limit_exceeded", "Operation lifecycle request limit is exhausted") if record.fetch("requests").length >= MAX_REQUESTS

        state = mission_state(operation_id)
        case action
        when "close"
          if state != "complete"
            raise ContractError.new("operation_not_review_ready", "Only a review-ready Operation can be acknowledged as complete") unless state == "review_ready"
            MissionStore.new(@config, clock: @clock).close(operation_id)
            state = "complete"
          end
          record["completed_at"] ||= timestamp
        when "archive"
          raise ContractError.new("operation_not_terminal", "Complete or terminal Operations may be archived") unless ARCHIVABLE_STATES.include?(state)
          record["archived_at"] ||= timestamp
        when "restore"
          raise ContractError.new("operation_not_archived", "Only an archived Operation can be restored") unless record["archived_at"]
          record["archived_at"] = nil
        end

        observed_at = timestamp
        record["requests"] << {
          "request_digest" => request_digest,
          "payload_digest" => payload_digest,
          "action" => action,
          "observed_at" => observed_at
        }
        record["updated_at"] = observed_at
        write_record!(record)
        result(record, state, replayed: false)
      end
    rescue OperationAuthoring::ContractError => e
      raise ContractError.new(e.code, e.message)
    rescue KeyError
      raise ContractError.new("malformed_request", "Operation lifecycle request is incomplete")
    end

    def metadata
      verify_capability!
      return {} unless Dir.exist?(record_dir)
      stat = File.lstat(record_dir)
      raise ContractError.new("lifecycle_store_invalid", "Operation lifecycle store is invalid") unless stat.directory? && !stat.symlink?

      Dir.children(record_dir).sort.each_with_object({}) do |entry, values|
        unless entry.match?(/\A[0-9a-f]{64}\.json\z/)
          raise ContractError.new("lifecycle_store_invalid", "Operation lifecycle store contains an unknown entry")
        end
        record = read_record(File.join(record_dir, entry))
        unless entry == "#{Digest::SHA256.hexdigest(record.fetch('operation_id'))}.json"
          raise ContractError.new("lifecycle_store_invalid", "Operation lifecycle record identity is invalid")
        end
        values[record.fetch("operation_id")] = {
          "archived" => !record["archived_at"].nil?,
          "archived_at" => record["archived_at"],
          "completed_at" => record["completed_at"]
        }
      end
    rescue SystemCallError, JSON::ParserError, KeyError
      raise ContractError.new("lifecycle_store_invalid", "Operation lifecycle store is unreadable")
    end

    private

    def verify_capability!
      compatibility_path = File.join(@config.root, "hub", "compatibility.json")
      schemas = %w[operation-lifecycle-request.schema.json operation-lifecycle-result.schema.json operation-lifecycle-error.schema.json]
      paths = [compatibility_path, lock_path, File.join(@config.root, "lib", "flightdeck", "operation_lifecycle.rb")] +
        schemas.map { |name| File.join(@config.root, "hub", "schemas", name) }
      unless paths.all? { |path| File.file?(path) && !File.symlink?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Operation lifecycle v1")
      end
      capability = Support.load_data(compatibility_path).dig("capabilities", CAPABILITY)
      managed = ["hub/.operation-lifecycle.lock", "lib/flightdeck/operation_lifecycle.rb"] + schemas.map { |name| "hub/schemas/#{name}" }
      unless capability.is_a?(Hash) && capability["kind"] == "command" &&
             capability.dig("probe", "help_contains") == "bin/flightdeck operation lifecycle " &&
             managed.all? { |path| Array(capability["managed_paths"]).include?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Operation lifecycle v1")
      end
      schemas.each do |name|
        schema = Support.load_data(File.join(@config.root, "hub", "schemas", name))
        unless schema["$id"] == "https://flightdeck.dev/schemas/#{name}"
          raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Operation lifecycle v1")
        end
      end
    rescue SystemCallError, ValidationError
      raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Operation lifecycle v1")
    end

    def mission_state(operation_id)
      # Lifecycle mutations are gated by the durable Mission record. The
      # read-only status projection may overlay adapter recovery state and must
      # not replace the exact explicit-close precondition.
      MissionStore.new(@config, clock: @clock).snapshot(operation_id).dig("status", "state").to_s
    rescue ValidationError, KeyError
      raise ContractError.new("operation_unavailable", "Operation durable state is unavailable")
    end

    def load_record(operation_id)
      path = record_path(operation_id)
      return {
        "schema_version" => RECORD_VERSION,
        "operation_id" => operation_id,
        "completed_at" => nil,
        "archived_at" => nil,
        "requests" => [],
        "updated_at" => timestamp
      } unless File.exist?(path)
      read_record(path)
    end

    def read_record(path)
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.size <= MAX_RECORD_BYTES
        raise ContractError.new("lifecycle_store_invalid", "Operation lifecycle record boundary is invalid")
      end
      record = Support.stringify(JSON.parse(File.read(path, MAX_RECORD_BYTES + 1, encoding: "UTF-8")))
      expected = %w[archived_at completed_at operation_id requests schema_version updated_at]
      unless record.keys.sort == expected && record["schema_version"] == RECORD_VERSION && OPERATION_ID.match?(record["operation_id"].to_s) &&
             record["requests"].is_a?(Array) && record["requests"].length <= MAX_REQUESTS
        raise ContractError.new("lifecycle_store_invalid", "Operation lifecycle record is invalid")
      end
      [record["completed_at"], record["archived_at"], record["updated_at"]].compact.each { |value| Time.iso8601(value.to_s) }
      record["requests"].each do |item|
        unless item.is_a?(Hash) && item.keys.sort == %w[action observed_at payload_digest request_digest] && ACTIONS.include?(item["action"]) &&
               MissionStore::SHA256.match?(item["request_digest"].to_s) && MissionStore::SHA256.match?(item["payload_digest"].to_s)
          raise ContractError.new("lifecycle_store_invalid", "Operation lifecycle request record is invalid")
        end
        Time.iso8601(item["observed_at"].to_s)
      end
      record
    rescue ArgumentError
      raise ContractError.new("lifecycle_store_invalid", "Operation lifecycle record timestamp is invalid")
    end

    def write_record!(record)
      content = "#{JSON.pretty_generate(record)}\n"
      raise ContractError.new("lifecycle_store_invalid", "Operation lifecycle record exceeds its bounded contract") if content.bytesize > MAX_RECORD_BYTES
      FileUtils.mkdir_p(record_dir, mode: 0o700)
      Support.atomic_write(record_path(record.fetch("operation_id")), content)
    end

    def result(record, state, replayed:)
      {
        "schema_version" => RESULT,
        "schema" => "hub/schemas/operation-lifecycle-result.schema.json",
        "ok" => true,
        "operation_id" => record.fetch("operation_id"),
        "state" => state == "complete" ? "completed" : state,
        "archived" => !record["archived_at"].nil?,
        "completed_at" => record["completed_at"],
        "archived_at" => record["archived_at"],
        "replayed" => replayed
      }
    end

    def timestamp
      @clock.call.utc.iso8601
    end

    def record_dir
      @config.root_path("hub/state/operation-lifecycle", label: "Operation lifecycle state")
    end

    def record_path(operation_id)
      File.join(record_dir, "#{Digest::SHA256.hexdigest(operation_id)}.json")
    end

    def lock_path
      @config.root_path("hub/.operation-lifecycle.lock", label: "Operation lifecycle lock")
    end

    def with_lock(mode)
      stat = File.lstat(lock_path)
      raise ContractError.new("capability_incomplete", "Operation lifecycle lock is unavailable") unless stat.file? && !stat.symlink?
      File.open(lock_path, File::RDONLY) do |lock|
        raise ContractError.new("conflicting_operation", "another Operation lifecycle action is active") unless lock.flock(mode | File::LOCK_NB)
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise ContractError.new("capability_incomplete", "Operation lifecycle lock is unavailable")
    end
  end
end
