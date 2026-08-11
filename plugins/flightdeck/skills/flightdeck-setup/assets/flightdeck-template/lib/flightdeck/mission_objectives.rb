# frozen_string_literal: true

require "digest"
require "json"
require "fileutils"
require_relative "operation_detail"

module Flightdeck
  # Mission objective records are intentionally separate from execution-graph
  # MissionRecord instances. They contain an ordered set of durable authored
  # Operations and derive display progress from those exact identities.
  class MissionObjectives
    CAPABILITY = "flightdeck.command.mission-objectives.v1"
    PLAN_REQUEST = "flightdeck.mission-objective.plan-request/v1"
    PLAN_RESULT = "flightdeck.mission-objective.plan-result/v1"
    CREATE_REQUEST = "flightdeck.mission-objective.create-request/v1"
    CREATE_RESULT = "flightdeck.mission-objective.create-result/v1"
    SNAPSHOT_REQUEST = "flightdeck.mission-objective.snapshot-request/v1"
    SNAPSHOT_RESULT = "flightdeck.mission-objective.snapshot-result/v1"
    ERROR = "flightdeck.mission-objective.error/v1"
    RECORD = "flightdeck.mission-objective.record/v1"
    MAX_REQUEST_BYTES = 65_536
    MAX_OPERATIONS = 100
    MAX_MISSIONS = 500

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

    def self.error_result(error)
      code = error.respond_to?(:code) ? error.code : (error.is_a?(UsageError) ? "malformed_request" : "internal_error")
      { "schema_version" => ERROR, "schema" => "hub/schemas/mission-objective-error.schema.json", "ok" => false,
        "error" => { "code" => code, "message" => error.message.to_s[0, 512] } }
    end

    def plan(request)
      verify_capability!
      expect_object!(request, %w[schema_version title goal mode operation_ids], "Mission objective plan request")
      raise ContractError.new("malformed_request", "Mission objective plan request has an unsupported schema version") unless request["schema_version"] == PLAN_REQUEST
      title = bounded_text!(request.fetch("title"), 256, "title")
      goal = bounded_text!(request.fetch("goal"), 2048, "goal")
      mode = request.fetch("mode").to_s
      raise ContractError.new("malformed_request", "Mission mode is invalid") unless %w[watch_only supervised].include?(mode)
      operation_ids = Array(request.fetch("operation_ids"))
      unless operation_ids.length.between?(1, MAX_OPERATIONS) && operation_ids.uniq.length == operation_ids.length
        raise ContractError.new("malformed_request", "Mission must contain between 1 and #{MAX_OPERATIONS} unique Operations")
      end
      operations = operation_ids.each_with_index.map { |id, index| operation_summary(id, index + 1) }
      canonical = { "title" => title, "goal" => goal, "mode" => mode, "operation_ids" => operation_ids }
      digest = Digest::SHA256.hexdigest(canonical_json(canonical))
      mission_id = "mission-#{digest[0, 24]}"
      plan_id = "plan-#{digest[0, 48]}"
      token = Digest::SHA256.hexdigest(canonical_json("mission_id" => mission_id, "plan_id" => plan_id, "plan_digest" => digest, "objective" => canonical))
      {
        "schema_version" => PLAN_RESULT,
        "schema" => "hub/schemas/mission-objective-plan-result.schema.json",
        "ok" => true,
        "mission_id" => mission_id,
        "plan_id" => plan_id,
        "plan_digest" => digest,
        "plan_token" => token,
        "mission" => { "title" => title, "goal" => goal, "mode" => mode, "operations" => operations }
      }
    rescue KeyError => e
      raise ContractError.new("malformed_request", "Mission objective plan request is missing #{e.key}")
    end

    def create(request)
      verify_capability!
      expect_object!(request, %w[schema_version plan_request confirmation], "Mission objective create request")
      raise ContractError.new("malformed_request", "Mission objective create request has an unsupported schema version") unless request["schema_version"] == CREATE_REQUEST
      planned = plan(request.fetch("plan_request"))
      confirmation = request.fetch("confirmation")
      fields = %w[mission_id plan_id plan_digest plan_token]
      expect_object!(confirmation, fields, "Mission objective confirmation")
      expected = fields.to_h { |field| [field, planned.fetch(field)] }
      raise ContractError.new("stale_or_mismatched_plan", "Mission confirmation does not match the current Hub-authored plan") unless secure_equal?(confirmation, expected)

      record = {
        "schema_version" => RECORD,
        "mission_id" => planned.fetch("mission_id"),
        "plan_id" => planned.fetch("plan_id"),
        "plan_digest" => planned.fetch("plan_digest"),
        "title" => planned.dig("mission", "title"),
        "goal" => planned.dig("mission", "goal"),
        "mode" => planned.dig("mission", "mode"),
        "operation_ids" => planned.dig("mission", "operations").map { |operation| operation.fetch("operation_id") },
        "created_at" => timestamp,
        "updated_at" => timestamp
      }
      replayed = persist(record)
      { "schema_version" => CREATE_RESULT, "schema" => "hub/schemas/mission-objective-create-result.schema.json", "ok" => true,
        "mission_id" => record.fetch("mission_id"), "outcome" => "created", "replayed" => replayed }
    rescue KeyError => e
      raise ContractError.new("malformed_request", "Mission objective create request is missing #{e.key}")
    end

    def snapshot(request)
      verify_capability!
      expect_object!(request, %w[schema_version mission_id], "Mission objective snapshot request")
      raise ContractError.new("malformed_request", "Mission objective snapshot request has an unsupported schema version") unless request["schema_version"] == SNAPSHOT_REQUEST
      mission_id = request["mission_id"]
      records = if Support.present?(mission_id)
                  Support.validate_slug!(mission_id, label: "Mission objective ID")
                  [load_record(mission_id)]
                else
                  load_all_records
                end
      missions = records.map { |record| snapshot_record(record) }.sort_by { |mission| [mission.fetch("updated_at"), mission.fetch("mission_id")] }.reverse
      { "schema_version" => SNAPSHOT_RESULT, "schema" => "hub/schemas/mission-objective-snapshot-result.schema.json", "ok" => true,
        "missions" => missions }
    rescue UsageError
      raise ContractError.new("malformed_request", "Mission objective ID is invalid")
    end

    private

    def verify_capability!
      schemas = %w[mission-objective.schema.json mission-objective-plan-request.schema.json mission-objective-plan-result.schema.json mission-objective-create-request.schema.json mission-objective-create-result.schema.json mission-objective-snapshot-request.schema.json mission-objective-snapshot-result.schema.json mission-objective-error.schema.json]
      compatibility_path = File.join(@config.root, "hub", "compatibility.json")
      paths = [compatibility_path, File.join(@config.root, "lib", "flightdeck", "mission_objectives.rb")] + schemas.map { |name| File.join(@config.root, "hub", "schemas", name) }
      unless paths.all? { |path| File.file?(path) && !File.symlink?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Mission objectives v1")
      end
      capability = Support.load_data(compatibility_path).dig("capabilities", CAPABILITY)
      managed = ["lib/flightdeck/mission_objectives.rb"] + schemas.map { |name| "hub/schemas/#{name}" }
      unless capability.is_a?(Hash) && capability["kind"] == "command" && capability.dig("probe", "help_contains") == "bin/flightdeck mission objective-plan " && managed.all? { |path| Array(capability["managed_paths"]).include?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Mission objectives v1")
      end
      schemas.each do |name|
        schema = Support.load_data(File.join(@config.root, "hub", "schemas", name))
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Mission objectives v1") unless schema["$id"] == "https://flightdeck.dev/schemas/#{name}"
      end
    rescue SystemCallError, ValidationError
      raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare Mission objectives v1")
    end

    def expect_object!(value, fields, label)
      unless value.is_a?(Hash) && (value.keys - fields).empty? && fields.all? { |field| value.key?(field) }
        raise ContractError.new("malformed_request", "#{label} must contain only #{fields.join(', ')}")
      end
    end

    def operation_summary(operation_id, order)
      detail = OperationDetail.new(@config).detail("schema_version" => OperationDetail::REQUEST, "operation_id" => operation_id)
      operation = detail.fetch("operation")
      { "operation_id" => operation_id, "order" => order, "title" => operation.fetch("title"), "status" => operation.fetch("status"), "goal" => operation.fetch("goal") }
    rescue OperationDetail::ContractError
      raise ContractError.new("operation_unavailable", "Mission references an Operation that is not durably available")
    end

    def snapshot_record(record)
      operations = record.fetch("operation_ids").each_with_index.map { |id, index| operation_summary(id, index + 1) }
      counts = { "total" => operations.length, "complete" => operations.count { |item| item["status"] == "review_ready" },
                 "active" => operations.count { |item| item["status"] == "working" },
                 "waiting" => operations.count { |item| %w[queued waiting].include?(item["status"]) },
                 "attention" => operations.count { |item| %w[approval_required blocked failed_validation reconcile_required].include?(item["status"]) } }
      record.slice("mission_id", "title", "goal", "mode", "created_at", "updated_at").merge(
        "state" => mission_state(operations), "progress" => counts, "operations" => operations
      )
    end

    def mission_state(operations)
      statuses = operations.map { |item| item.fetch("status") }
      return "failed_validation" if statuses.include?("failed_validation")
      return "blocked" if statuses.include?("blocked") || statuses.include?("reconcile_required")
      return "needs_approval" if statuses.include?("approval_required")
      return "complete" if statuses.all? { |state| %w[review_ready cancelled].include?(state) }
      return "working" if statuses.include?("working")
      return "waiting" if statuses.include?("waiting")
      "planned"
    end

    def persist(record)
      ensure_store!
      with_lock(File::LOCK_EX) do
        path = record_path(record.fetch("mission_id"))
        if File.exist?(path)
          existing = load_record(record.fetch("mission_id"))
          same = existing.reject { |key, _| key == "updated_at" } == record.reject { |key, _| key == "updated_at" }
          raise ContractError.new("conflicting_mission", "Mission identity is already bound to different content") unless same
          return true
        end
        directory = File.dirname(path)
        Dir.mkdir(directory, 0o700)
        Support.atomic_yaml(path, record)
        File.chmod(0o600, path)
        false
      rescue StandardError => e
        raise if e.is_a?(ContractError)
        raise ContractError.new("unknown_outcome", "Mission objective persistence outcome requires exact snapshot recovery")
      end
    end

    def load_all_records
      return [] unless Dir.exist?(store_root)
      entries = Dir.children(store_root).reject { |entry| entry == ".lock" }.sort
      raise ContractError.new("mission_limit_exceeded", "Mission objective store exceeds its bounded contract") if entries.length > MAX_MISSIONS
      entries.map { |entry| load_record(entry) }
    end

    def load_record(mission_id)
      path = record_path(mission_id)
      raise ContractError.new("mission_not_found", "Mission objective does not exist") unless File.file?(path) && !File.symlink?(path)
      value = Support.load_data(path)
      required = %w[schema_version mission_id plan_id plan_digest title goal mode operation_ids created_at updated_at]
      unless value.is_a?(Hash) && value.keys.sort == required.sort && value["schema_version"] == RECORD && value["mission_id"] == mission_id && Array(value["operation_ids"]).length.between?(1, MAX_OPERATIONS)
        raise ContractError.new("invalid_hub_state", "Mission objective record is invalid")
      end
      value
    rescue SystemCallError, ValidationError
      raise ContractError.new("invalid_hub_state", "Mission objective record is invalid")
    end

    def ensure_store!
      FileUtils.mkdir_p(store_root, mode: 0o700)
      stat = File.lstat(store_root)
      raise ContractError.new("invalid_hub_state", "Mission objective store boundary is invalid") unless stat.directory? && !stat.symlink?
    end

    def with_lock(mode)
      ensure_store!
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(mode)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    end

    def store_root
      @config.root_path("hub/state/mission-objectives", label: "Mission objective store")
    end

    def lock_path
      File.join(store_root, ".lock")
    end

    def record_path(mission_id)
      Support.validate_slug!(mission_id, label: "Mission objective ID")
      @config.root_path("hub/state/mission-objectives/#{mission_id}/objective.yaml", label: "Mission objective record")
    rescue UsageError
      raise ContractError.new("malformed_request", "Mission objective ID is invalid")
    end

    def bounded_text!(value, max, label)
      text = value.to_s.strip.gsub(/\s+/, " ")
      if text.empty? || text.length > max || text.match?(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/)
        raise ContractError.new("malformed_request", "Mission #{label} is invalid")
      end
      text
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value[key])] }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def secure_equal?(left, right)
      left_json = canonical_json(left)
      right_json = canonical_json(right)
      return false unless left_json.bytesize == right_json.bytesize
      left_json.bytes.zip(right_json.bytes).reduce(0) { |sum, (a, b)| sum | (a ^ b) }.zero?
    end

    def timestamp
      @clock.call.utc.iso8601
    end
  end
end
