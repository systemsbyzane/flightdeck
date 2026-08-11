# frozen_string_literal: true

require "json"
require_relative "operation_authoring"

module Flightdeck
  # Hub-owned Work intake. Until a conversational runtime is configured it
  # only performs deterministic, review-only coordination decisions from the
  # exact Hub catalog. It never dispatches an Operation implicitly.
  class WorkCoordinator
    CAPABILITY = "flightdeck.command.work-coordinator.v1"
    REQUEST = "flightdeck.work.coordinate-request/v1"
    RESULT = "flightdeck.work.coordinate-result/v1"
    ERROR = "flightdeck.work.coordinate-error/v1"
    MAX_REQUEST_BYTES = 65_536
    MAX_MESSAGE_BYTES = 8_192
    IMPLEMENTATION_WORDS = /\b(?:build|change|fix|implement|migrate|refactor|release|update)\b/i
    READ_ONLY_WORDS = /\b(?:analy[sz]e|audit|check|compare|explain|inspect|investigate|review|research)\b/i
    ALL_PROJECTS = /\b(?:all|every)\s+(?:attached\s+|connected\s+)?(?:projects?|repos(?:itories)?)\b/i

    class ContractError < ValidationError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    def initialize(config)
      @config = config
      @authoring = OperationAuthoring.new(config)
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
        "schema" => "hub/schemas/work-coordinate-error.schema.json",
        "ok" => false,
        "error" => { "code" => code, "message" => error.message.to_s[0, 512] }
      }
    end

    def coordinate(request)
      verify_capability!
      expect_object!(request, %w[schema_version message active_operation_id], "Work coordinate request")
      raise ContractError.new("malformed_request", "Work coordinate request has an unsupported schema version") unless request["schema_version"] == REQUEST

      message = normalize_message!(request.fetch("message"))
      active_operation_id = request["active_operation_id"]
      return attach_guidance(active_operation_id, message) if Support.present?(active_operation_id)

      catalog = @authoring.catalog("schema_version" => OperationAuthoring::CATALOG_REQUEST)
      selected = select_targets(message, catalog.fetch("targets"))
      return proposal_result(message, selected, catalog.fetch("warnings")) if selected.length >= 2

      runtime = runtime_projection
      {
        "schema_version" => RESULT,
        "schema" => "hub/schemas/work-coordinate-result.schema.json",
        "ok" => true,
        "disposition" => runtime.fetch("available") ? "runtime_delegate" : "runtime_unavailable",
        "message" => runtime.fetch("available") ? "Continue this Work conversation through the Hub-selected runtime adapter." : "A Hub-native conversational runtime is not configured. No Operation was created.",
        "runtime" => runtime,
        "proposal" => nil,
        "guidance" => nil
      }
    rescue KeyError => e
      raise ContractError.new("malformed_request", "Work coordinate request is missing #{e.key}")
    end

    private

    def verify_capability!
      compatibility_path = File.join(@config.root, "hub", "compatibility.json")
      schemas = %w[work-coordinate-request.schema.json work-coordinate-result.schema.json work-coordinate-error.schema.json]
      paths = [compatibility_path, File.join(@config.root, "lib", "flightdeck", "work_coordinator.rb")] + schemas.map { |name| File.join(@config.root, "hub", "schemas", name) }
      unless paths.all? { |path| File.file?(path) && !File.symlink?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Work coordinator v1 contract")
      end

      compatibility = Support.load_data(compatibility_path)
      capability = compatibility.dig("capabilities", CAPABILITY)
      managed = ["lib/flightdeck/work_coordinator.rb"] + schemas.map { |name| "hub/schemas/#{name}" }
      unless compatibility["product"] == "flightdeck" && capability.is_a?(Hash) && capability["kind"] == "command" &&
             capability.dig("probe", "help_contains") == "bin/flightdeck work coordinate " &&
             managed.all? { |path| Array(capability["managed_paths"]).include?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Work coordinator v1 contract")
      end
      schemas.each do |name|
        schema = Support.load_data(File.join(@config.root, "hub", "schemas", name))
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Work coordinator v1 contract") unless schema["$id"] == "https://flightdeck.dev/schemas/#{name}"
      end
    rescue SystemCallError, ValidationError
      raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Work coordinator v1 contract")
    end

    def expect_object!(value, fields, label)
      unless value.is_a?(Hash) && (value.keys - fields).empty? && fields.all? { |field| value.key?(field) }
        raise ContractError.new("malformed_request", "#{label} must contain only #{fields.join(', ')}")
      end
    end

    def normalize_message!(value)
      text = value.to_s.strip
      if text.empty? || text.bytesize > MAX_MESSAGE_BYTES || text.match?(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/)
        raise ContractError.new("malformed_request", "Work message is invalid")
      end
      text
    end

    def select_targets(message, targets)
      by_project = Array(targets).group_by { |target| target.fetch("logical_project_key") }
      selected_keys = if message.match?(ALL_PROJECTS)
                        by_project.keys
                      else
                        by_project.keys.select do |key|
                          labels = by_project.fetch(key).map { |target| target.fetch("display_label") }
                          ([key, key.tr("-", " ")] + labels).uniq.any? { |label| phrase_present?(message, label) }
                        end
                      end
      access_mode = message.match?(IMPLEMENTATION_WORDS) && !message.match?(READ_ONLY_WORDS) ? "write" : "read_only"
      execution_mode = access_mode == "write" ? "worktree" : "local"
      selected_keys.sort.filter_map do |key|
        candidates = by_project.fetch(key)
        candidates.find { |item| item["access_mode"] == access_mode && item["execution_mode"] == execution_mode } ||
          candidates.find { |item| item["access_mode"] == access_mode } || candidates.first
      end
    end

    def phrase_present?(message, phrase)
      normalized_message = message.downcase.gsub(/[^a-z0-9]+/, " ").strip
      normalized_phrase = phrase.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip
      !normalized_phrase.empty? && " #{normalized_message} ".include?(" #{normalized_phrase} ")
    end

    def proposal_result(message, selected, warnings)
      title = message.gsub(/\s+/, " ").strip[0, 96]
      title = "Coordinate work across #{selected.length} projects" if title.empty?
      exact_targets = selected.map { |target| target.reject { |key, _| key == "display_label" } }
      proposal = {
        "title" => title,
        "work_intent" => message,
        "mode" => "supervised",
        "success_criteria" => ["Return one validated consolidated result for the requested outcome."],
        "non_goals" => ["Do not commit, push, publish, deploy, or contact external systems without separate authorization."],
        "selected_targets" => exact_targets
      }
      planned = @authoring.plan("schema_version" => OperationAuthoring::PLAN_REQUEST, "proposal" => proposal)
      {
        "schema_version" => RESULT,
        "schema" => "hub/schemas/work-coordinate-result.schema.json",
        "ok" => true,
        "disposition" => "operation_proposal",
        "message" => "Review the exact Hub-authored Operation proposal before launch.",
        "runtime" => runtime_projection,
        "proposal" => {
          "proposal" => proposal,
          "operation_id" => planned.fetch("operation_id"),
          "plan_id" => planned.fetch("plan_id"),
          "plan_generation" => planned.fetch("plan_generation"),
          "plan_digest" => planned.fetch("plan_digest"),
          "plan_token" => planned.fetch("plan_token"),
          "operation" => planned.fetch("operation"),
          "warnings" => warnings
        },
        "guidance" => nil
      }
    end

    def attach_guidance(operation_id, message)
      result = @authoring.guidance(
        "schema_version" => OperationAuthoring::GUIDANCE_REQUEST,
        "operation_id" => operation_id,
        "guidance" => message
      )
      {
        "schema_version" => RESULT,
        "schema" => "hub/schemas/work-coordinate-result.schema.json",
        "ok" => true,
        "disposition" => "guidance_attached",
        "message" => "Guidance was attached to the exact active Operation.",
        "runtime" => runtime_projection,
        "proposal" => nil,
        "guidance" => result
      }
    end

    def runtime_projection
      value = Support.load_data(File.join(@config.root, "hub", "compatibility.json")).fetch("runtime_capabilities")
      adapter = value.fetch("primary_runtime").to_s
      available = value.dig("adapters", adapter, "available") == true
      controls = Array(value.dig("adapters", adapter, "optional_controls"))
      unless %w[codex omp].include?(adapter) && controls.uniq == controls && controls.all? { |item| %w[model reasoning_effort].include?(item) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub runtime metadata is invalid")
      end
      { "adapter" => adapter, "available" => available, "optional_controls" => controls }
    rescue KeyError, ValidationError
      raise ContractError.new("unsupported_hub_contract", "Selected Hub runtime metadata is invalid")
    end
  end
end
