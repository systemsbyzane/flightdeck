# frozen_string_literal: true

require "digest"
require "json"
require_relative "mission_store"

module Flightdeck
  # Typed, client-safe creation of a planned Mission-backed Operation. This
  # class deliberately does not dispatch or create Codex tasks.
  class OperationAuthoring
    CAPABILITY = "flightdeck.command.operation-authoring.v1"
    CATALOG_REQUEST = "flightdeck.operation-authoring.catalog-request/v1"
    CATALOG_RESULT = "flightdeck.operation-authoring.catalog-result/v1"
    PLAN_REQUEST = "flightdeck.operation-authoring.plan-request/v1"
    PLAN_RESULT = "flightdeck.operation-authoring.plan-result/v1"
    LAUNCH_REQUEST = "flightdeck.operation-authoring.launch-request/v1"
    LAUNCH_RESULT = "flightdeck.operation-authoring.launch-result/v1"
    GUIDANCE_REQUEST = "flightdeck.operation-authoring.guidance-request/v1"
    GUIDANCE_RESULT = "flightdeck.operation-authoring.guidance-result/v1"
    OPERATION_REQUEST = "flightdeck.operation-authoring.operation-request/v1"
    OPERATION_RESULT = "flightdeck.operation-authoring.operation-result/v1"
    ERROR_RESULT = "flightdeck.operation-authoring.error-result/v1"
    MAX_REQUEST_BYTES = 262_144
    MAX_CATALOG_ITEMS = 1_000
    MAX_ITEMS = 50
    MAX_GUIDANCE = 100
    MAX_OPERATION_RECORDS = 10_000
    MAX_OPERATION_RECORD_BYTES = 65_536
    GUIDANCE_ID_PREFIX = "guidance-"
    TARGET_FIELDS = %w[logical_project_key runtime_project_id project_path_digest host_id execution_mode access_mode].freeze
    CONFIRMATION_FIELDS = %w[operation_id plan_id plan_generation plan_digest plan_token].freeze
    RECORD_STATES = %w[unresolved created not_created].freeze
    TERMINAL_STATES = %w[review_ready failed_validation runtime_failure cancelled complete].freeze

    class ContractError < ValidationError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    attr_reader :config

    def initialize(config, clock: -> { Time.now.utc })
      @config = config
      @clock = clock
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
        "schema" => "hub/schemas/operation-authoring-error-result.schema.json",
        "ok" => false,
        "operation" => operation,
        "error" => { "code" => code, "message" => error.message.to_s[0, 1024] }
      }
    end

    def catalog(request)
      verify_capability!
      expect_object!(request, ["schema_version"], "catalog request")
      expect_version!(request, CATALOG_REQUEST)
      data = current_targets
      if data.fetch("targets").length > MAX_CATALOG_ITEMS || data.fetch("warnings").length > MAX_CATALOG_ITEMS
        raise ContractError.new("catalog_invalid", "target catalog exceeds its bounded result contract")
      end
      identities = data.fetch("targets").map { |target| target.reject { |key, _| key == "display_label" } }
      {
        "schema_version" => CATALOG_RESULT,
        "schema" => "hub/schemas/operation-authoring-catalog-result.schema.json",
        "ok" => true,
        "capability" => CAPABILITY,
        "catalog_generation" => "catalog-#{Digest::SHA256.hexdigest(canonical_json(identities))[0, 48]}",
        "targets" => data.fetch("targets"),
        "warnings" => data.fetch("warnings")
      }
    end

    def plan(request)
      verify_capability!
      expect_object!(request, %w[schema_version proposal], "plan request")
      expect_version!(request, PLAN_REQUEST)
      proposal = normalize_proposal!(request.fetch("proposal"))
      catalog_result = catalog("schema_version" => CATALOG_REQUEST)
      catalog_by_id = catalog_result.fetch("targets").to_h { |target| [target.fetch("target_id"), target] }
      selected = validate_selected_targets!(proposal.fetch("selected_targets"), catalog_by_id)
      canonical_proposal = proposal.merge("selected_targets" => selected.sort_by { |target| target.fetch("target_id") })
      proposal_digest = Digest::SHA256.hexdigest(canonical_json(canonical_proposal))
      operation_id = "operation-#{proposal_digest[0, 24]}"
      mission_id = "operation-#{proposal_digest[0, 24]}"
      store = MissionStore.new(config, clock: @clock)
      mission = store.preview_complete(
        slug: mission_id,
        title: canonical_proposal.fetch("title"),
        outcome: canonical_proposal.fetch("work_intent"),
        mode: canonical_proposal.fetch("mode"),
        success_criteria: canonical_proposal.fetch("success_criteria"),
        non_goals: canonical_proposal.fetch("non_goals"),
        authorized_targets: selected.map { |target| target.slice(*TARGET_FIELDS) },
        nodes: operation_nodes(selected, canonical_proposal.fetch("success_criteria"))
      )
      planned = planned_operation(mission, selected)
      canonical_plan = {
        "capability" => CAPABILITY,
        "catalog_generation" => catalog_result.fetch("catalog_generation"),
        "operation_id" => operation_id,
        "operation" => planned
      }
      plan_digest = Digest::SHA256.hexdigest(canonical_json(canonical_plan))
      plan_id = "plan-#{plan_digest[0, 48]}"
      plan_generation = "generation-#{catalog_result.fetch('catalog_generation').delete_prefix('catalog-')}"
      plan_token = Digest::SHA256.hexdigest(canonical_json(
        "capability" => CAPABILITY,
        "operation_id" => operation_id,
        "plan_id" => plan_id,
        "plan_generation" => plan_generation,
        "plan_digest" => plan_digest,
        "canonical_plan" => canonical_plan
      ))
      {
        "schema_version" => PLAN_RESULT,
        "schema" => "hub/schemas/operation-authoring-plan-result.schema.json",
        "ok" => true,
        "capability" => CAPABILITY,
        "operation_id" => operation_id,
        "plan_id" => plan_id,
        "plan_generation" => plan_generation,
        "plan_digest" => plan_digest,
        "plan_token" => plan_token,
        "catalog_generation" => catalog_result.fetch("catalog_generation"),
        "operation" => planned,
        "warnings" => catalog_result.fetch("warnings")
      }
    rescue KeyError => e
      raise ContractError.new("malformed_request", "plan request missing field: #{e.key}")
    end

    def launch(request)
      verify_capability!
      expect_object!(request, %w[schema_version operation_id confirmation proposal], "launch request")
      expect_version!(request, LAUNCH_REQUEST)
      operation_id = validate_operation_id!(request.fetch("operation_id"))
      confirmation = request.fetch("confirmation")
      expect_object!(confirmation, CONFIRMATION_FIELDS, "plan confirmation")
      request_digest = Digest::SHA256.hexdigest(canonical_json(request))

      with_authoring_lock(File::LOCK_EX) do
        planned = plan("schema_version" => PLAN_REQUEST, "proposal" => request.fetch("proposal"))
        expected = CONFIRMATION_FIELDS.to_h { |field| [field, planned.fetch(field)] }
        unless operation_id == planned.fetch("operation_id") && secure_equal_json?(confirmation, expected)
          raise ContractError.new("stale_or_mismatched_plan", "launch confirmation does not match the current server-authored plan")
        end

        records = operation_records
        existing = records.find { |record| record["operation_id"] == operation_id }
        if existing
          unless existing["request_digest"] == request_digest
            raise ContractError.new("conflicting_operation", "operation identity is bound to different launch content")
          end
          case existing.fetch("state")
          when "created"
            return launch_result(existing, replayed: true)
          when "unresolved"
            raise ContractError.new("unknown_outcome", "launch outcome is unknown; recover only with the original operation ID")
          else
            raise ContractError.new("not_created", "operation was recorded as not created; request a fresh plan")
          end
        end

        mission_id = planned.dig("operation", "mission_id")
        record = {
          "schema_version" => "flightdeck.operation-authoring.operation-record/v1",
          "operation_id" => operation_id,
          "operation_digest" => Digest::SHA256.hexdigest(operation_id),
          "request_digest" => request_digest,
          "plan_id" => planned.fetch("plan_id"),
          "plan_generation" => planned.fetch("plan_generation"),
          "plan_digest" => planned.fetch("plan_digest"),
          "plan_token" => planned.fetch("plan_token"),
          "mission_id" => mission_id,
          "mission_fingerprint" => mission_fingerprint_from_plan(planned.fetch("operation")),
          "state" => "unresolved",
          "guidance" => [],
          "created_at" => timestamp,
          "updated_at" => timestamp
        }
        write_operation!(record)

        begin
          created = MissionStore.new(config, clock: @clock).create_complete(
            slug: mission_id,
            title: planned.dig("operation", "title"),
            outcome: planned.dig("operation", "work_intent"),
            mode: planned.dig("operation", "mode"),
            success_criteria: planned.dig("operation", "success_criteria").map { |criterion| criterion.fetch("text") },
            non_goals: planned.dig("operation", "non_goals"),
            authorized_targets: planned.dig("operation", "authorized_targets"),
            nodes: operation_nodes_from_plan(planned.fetch("operation")),
            operation_authoring_binding: {
              "operation_digest" => record.fetch("operation_digest"),
              "plan_id" => record.fetch("plan_id"),
              "plan_digest" => record.fetch("plan_digest")
            }
          )
        rescue StandardError => e
          if mission_write_absent?(mission_id)
            record["state"] = "not_created"
            record["updated_at"] = timestamp
            write_operation!(record)
            raise ContractError.new("persistence_failed", "Operation persistence failed closed: #{e.class}")
          end
          raise ContractError.new("unknown_outcome", "launch result is unknown; recover only with the original operation ID")
        end

        unless mission_fingerprint_from_record(created) == record.fetch("mission_fingerprint") && operation_binding_matches?(created, record)
          raise ContractError.new("unknown_outcome", "persisted Operation identity requires recovery")
        end
        record["state"] = "created"
        record["updated_at"] = timestamp
        begin
          write_operation!(record)
        rescue StandardError
          raise ContractError.new("unknown_outcome", "launch result is unknown; recover only with the original operation ID")
        end
        launch_result(record, replayed: false)
      end
    rescue KeyError => e
      raise ContractError.new("malformed_request", "launch request missing field: #{e.key}")
    end

    def guidance(request)
      verify_capability!
      expect_object!(request, %w[schema_version operation_id guidance], "guidance request")
      expect_version!(request, GUIDANCE_REQUEST)
      operation_id = validate_operation_id!(request.fetch("operation_id"))
      guidance = redact_guidance!(request.fetch("guidance"))
      with_authoring_lock(File::LOCK_EX) do
        record = operation_records.find { |candidate| candidate["operation_id"] == operation_id }
        raise ContractError.new("operation_not_found", "operation identity is not persisted") unless record
        raise ContractError.new("unknown_outcome", "operation launch requires recovery before guidance") unless record["state"] == "created"

        resolved = resolve_operation(record)
        unless resolved.fetch("outcome") == "created"
          raise ContractError.new("operation_identity_conflict", "operation identity cannot be bound safely")
        end
        mission = MissionStore.new(config, clock: @clock).snapshot(record.fetch("mission_id"))
        if TERMINAL_STATES.include?(mission.dig("status", "state"))
          raise ContractError.new("terminal_operation", "follow-up guidance is not allowed for a terminal operation")
        end

        digest = Digest::SHA256.hexdigest(canonical_json("operation_id" => operation_id, "guidance" => guidance.fetch("text")))
        existing = record.fetch("guidance").find { |item| item["guidance_digest"] == digest }
        if existing
          return guidance_result(operation_id, existing, replayed: true)
        end
        raise ContractError.new("guidance_limit_exceeded", "operation guidance exceeds its bounded contract") if record.fetch("guidance").length >= MAX_GUIDANCE

        item = {
          "guidance_id" => "#{GUIDANCE_ID_PREFIX}#{digest[0, 24]}",
          "guidance_digest" => digest,
          "text" => guidance.fetch("text"),
          "redacted" => guidance.fetch("redacted"),
          "attached_at" => timestamp
        }
        record["guidance"] << item
        record["updated_at"] = timestamp
        write_operation!(record)
        guidance_result(operation_id, item, replayed: false)
      end
    rescue KeyError => e
      raise ContractError.new("malformed_request", "guidance request missing field: #{e.key}")
    end

    def operation(request)
      verify_capability!
      expect_object!(request, %w[schema_version operation_id], "operation request")
      expect_version!(request, OPERATION_REQUEST)
      operation_id = validate_operation_id!(request.fetch("operation_id"))
      with_authoring_lock(File::LOCK_EX) do
        record = operation_records.find { |candidate| candidate["operation_id"] == operation_id }
        return operation_result(operation_id, "not_created", nil, nil, "operation_not_found") unless record

        result = resolve_operation(record)
        if result.fetch("outcome") == "created" && record.fetch("state") == "unresolved"
          record["state"] = "created"
          record["updated_at"] = timestamp
          write_operation!(record)
        end
        result
      end
    rescue ContractError => e
      raise unless e.code == "operation_store_invalid"

      operation_result(operation_id, "unresolved", nil, nil, "operation_store_invalid")
    rescue KeyError => e
      raise ContractError.new("malformed_request", "operation request missing field: #{e.key}")
    end

    private

    def verify_capability!
      schemas = %w[
        mission.schema.json operation-authoring-types.schema.json
        operation-authoring-catalog-request.schema.json operation-authoring-catalog-result.schema.json
        operation-authoring-plan-request.schema.json operation-authoring-plan-result.schema.json
        operation-authoring-launch-request.schema.json operation-authoring-launch-result.schema.json
        operation-authoring-guidance-request.schema.json operation-authoring-guidance-result.schema.json
        operation-authoring-operation-request.schema.json operation-authoring-operation-result.schema.json
        operation-authoring-error-result.schema.json
      ]
      compatibility_path = File.join(config.root, "hub", "compatibility.json")
      paths = [compatibility_path] + schemas.map { |name| File.join(config.root, "hub", "schemas", name) }
      unless paths.all? { |path| File.file?(path) && !File.symlink?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Operation authoring v1 contract.")
      end
      compatibility = Support.load_data(compatibility_path)
      capability = compatibility.dig("capabilities", CAPABILITY)
      managed = ["lib/flightdeck/operation_authoring.rb"] + schemas.map { |name| "hub/schemas/#{name}" }
      unless compatibility["schema_version"] == "flightdeck.hub-compatibility/v1" &&
             compatibility["product"] == "flightdeck" && capability.is_a?(Hash) && capability["kind"] == "command" &&
             capability.dig("probe", "help_contains") == "bin/flightdeck operation authoring-catalog " &&
             managed.all? { |path| Array(capability["managed_paths"]).include?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Operation authoring v1 contract.")
      end
      schemas.each do |name|
        schema = Support.load_data(File.join(config.root, "hub", "schemas", name))
        unless schema.is_a?(Hash) && schema["$id"] == "https://flightdeck.dev/schemas/#{name}"
          raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Operation authoring v1 contract.")
        end
      end
    rescue SystemCallError, ValidationError
      raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Operation authoring v1 contract.")
    end

    def current_targets
      candidates = []
      warnings = []
      declared_keys = {}
      config.repository_declarations.each do |declaration|
        key = declaration.dig("codex_project", "logical_key")
        declared_keys[key] = true
        repository = config.repository(declaration.fetch("id"))
        unless repository
          warnings << warning("target_not_registered", key)
          next
        end
        add_target_candidate(candidates, warnings, logical_key: key, expected_path: config.repository_path(repository),
                             display_label: declaration["name"] || declaration.fetch("id"), execution_modes: %w[local worktree])
      end
      config.codex_projects.each do |key, project|
        next if declared_keys[key] || project["role"] == "coordination"
        unless project["context"] == "local"
          warnings << warning("unsupported_remote_target", key)
          next
        end
        add_target_candidate(candidates, warnings, logical_key: key, expected_path: File.expand_path(project.fetch("path")),
                             display_label: project["display_name"] || key, execution_modes: ["local"])
      end
      { "targets" => candidates.sort_by { |target| target.fetch("target_id") }, "warnings" => warnings.sort_by { |item| [item.fetch("code"), item.fetch("message")] } }
    rescue KeyError, ConfigurationError => e
      raise ContractError.new("catalog_invalid", "target catalog is not safely resolvable: #{e.class}")
    end

    def add_target_candidate(candidates, warnings, logical_key:, expected_path:, display_label:, execution_modes:)
      unless File.directory?(expected_path)
        warnings << warning("target_path_unavailable", logical_key)
        return
      end
      verification = config.project_verification(logical_key: logical_key, expected_path: expected_path)
      unless verification["status"] == "verified"
        warnings << warning("target_exact_path_unverified", logical_key)
        return
      end
      path_digest = Digest::SHA256.hexdigest(File.realpath(expected_path))
      execution_modes.each do |execution_mode|
        %w[read_only write].each do |access_mode|
          identity = {
            "logical_project_key" => logical_key.to_s, "runtime_project_id" => verification.fetch("runtime_project_id").to_s,
            "project_path_digest" => path_digest, "host_id" => "local", "execution_mode" => execution_mode, "access_mode" => access_mode
          }
          candidates << { "target_id" => "target-#{Digest::SHA256.hexdigest(canonical_json(identity))[0, 40]}", **identity, "display_label" => safe_label(display_label) }
        end
      end
    rescue Errno::ENOENT, Errno::ELOOP
      warnings << warning("target_path_unavailable", logical_key)
    end

    def normalize_proposal!(value)
      expect_object!(value, %w[title work_intent success_criteria non_goals mode selected_targets], "Operation proposal")
      proposal = Support.stringify(value)
      proposal["title"] = bounded_text!(proposal["title"], "title", 256)
      proposal["work_intent"] = bounded_text!(proposal["work_intent"], "work_intent", 2048)
      proposal["success_criteria"] = bounded_text_list!(proposal["success_criteria"], "success_criteria", min: 1)
      proposal["non_goals"] = bounded_text_list!(proposal["non_goals"], "non_goals", min: 1)
      unless MissionStore::MODES.include?(proposal["mode"].to_s)
        raise ContractError.new("malformed_request", "Operation mode is invalid")
      end
      proposal["mode"] = proposal["mode"].to_s
      proposal["selected_targets"] = bounded_array!(proposal["selected_targets"], "selected_targets", min: 1)
      proposal
    end

    def validate_selected_targets!(targets, catalog_by_id)
      selected = targets.map.with_index do |target, index|
        expect_object!(target, ["target_id", *TARGET_FIELDS], "selected target #{index}")
        value = Support.stringify(target)
        known = catalog_by_id[value["target_id"]]
        unless known && secure_equal_json?(value, known.reject { |key, _| key == "display_label" })
          raise ContractError.new("ineligible_target", "selected target #{index} is not an exact current catalog choice")
        end
        value
      end
      ids = selected.map { |target| target.fetch("target_id") }
      raise ContractError.new("malformed_request", "selected targets must be unique") unless ids.uniq.length == ids.length

      selected
    end

    def operation_nodes(selected, criteria)
      criterion_ids = criteria.each_index.map { |index| format("criterion-%03d", index + 1) }
      selected.sort_by { |target| target.fetch("target_id") }.each_with_index.map do |target, index|
        {
          node_id: format("target-%03d", index + 1), logical_project_key: target.fetch("logical_project_key"),
          runtime_project_id: target.fetch("runtime_project_id"), project_path_digest: target.fetch("project_path_digest"),
          host_id: target.fetch("host_id"), execution_mode: target.fetch("execution_mode"), access_mode: target.fetch("access_mode"),
          work_type: target.fetch("access_mode") == "write" ? "implementation" : "read_only", required: true,
          dependencies: [], accepted_input_types: [], allowed_output_types: ["operation_result"], criterion_ids: criterion_ids
        }
      end
    end

    def planned_operation(mission, selected)
      spec = mission.fetch("spec")
      {
        "mission_id" => mission.dig("metadata", "id"),
        "snapshot_operation_id" => "mission:#{mission.dig('metadata', 'id')}",
        "title" => mission.dig("metadata", "title"),
        "work_intent" => spec.fetch("outcome"),
        "mode" => spec.fetch("mode"),
        "success_criteria" => spec.fetch("success_criteria"),
        "non_goals" => spec.fetch("non_goals"),
        "authorized_targets" => selected.map { |target| target.slice(*TARGET_FIELDS) }.sort_by { |target| canonical_json(target) },
        "authorization_boundary" => spec.fetch("authorization_boundary"),
        "nodes" => spec.dig("graph", "nodes").map { |node| node.slice("id", *TARGET_FIELDS, "work_type", "required", "criterion_ids") }
      }
    end

    def operation_nodes_from_plan(operation)
      operation.fetch("nodes").map do |node|
        {
          node_id: node.fetch("id"), logical_project_key: node.fetch("logical_project_key"), runtime_project_id: node.fetch("runtime_project_id"),
          project_path_digest: node.fetch("project_path_digest"), host_id: node.fetch("host_id"), execution_mode: node.fetch("execution_mode"),
          access_mode: node.fetch("access_mode"), work_type: node.fetch("work_type"), required: node.fetch("required"),
          dependencies: [], accepted_input_types: [], allowed_output_types: ["operation_result"], criterion_ids: node.fetch("criterion_ids")
        }
      end
    end

    def mission_fingerprint_from_plan(operation)
      Digest::SHA256.hexdigest(canonical_json(operation.reject { |key, _| key == "snapshot_operation_id" }))
    end

    def mission_fingerprint_from_record(mission)
      spec = mission.fetch("spec")
      projection = {
        "mission_id" => mission.dig("metadata", "id"), "title" => mission.dig("metadata", "title"), "work_intent" => spec.fetch("outcome"),
        "mode" => spec.fetch("mode"), "success_criteria" => spec.fetch("success_criteria"), "non_goals" => spec.fetch("non_goals"),
        "authorized_targets" => spec.fetch("authorized_targets").sort_by { |target| canonical_json(target) },
        "authorization_boundary" => spec.fetch("authorization_boundary"),
        "nodes" => spec.dig("graph", "nodes").map { |node| node.slice("id", *TARGET_FIELDS, "work_type", "required", "criterion_ids") }
      }
      Digest::SHA256.hexdigest(canonical_json(projection))
    end

    def operation_binding_matches?(mission, record)
      expected = { "operation_digest" => record["operation_digest"], "plan_id" => record["plan_id"], "plan_digest" => record["plan_digest"] }
      secure_equal_json?(mission.dig("metadata", "operation_authoring"), expected)
    end

    def resolve_operation(record)
      mission_id = record.fetch("mission_id")
      path = File.join(config.mission_dir, mission_id, "mission.yaml")
      unless File.file?(path) && !File.symlink?(path)
        return operation_result(record.fetch("operation_id"), record["state"] == "not_created" ? "not_created" : "unresolved", nil, record["plan_id"], "no_operation_persisted")
      end
      mission = MissionStore.new(config, clock: @clock).snapshot(mission_id)
      if operation_binding_matches?(mission, record) && mission_fingerprint_from_record(mission) == record.fetch("mission_fingerprint")
        operation_result(record.fetch("operation_id"), "created", mission_id, record["plan_id"], nil)
      else
        operation_result(record.fetch("operation_id"), "unresolved", mission_id, record["plan_id"], "operation_identity_conflict")
      end
    rescue ValidationError, KeyError
      operation_result(record.fetch("operation_id"), "unresolved", mission_id, record["plan_id"], "operation_identity_conflict")
    end

    def launch_result(record, replayed:)
      {
        "schema_version" => LAUNCH_RESULT,
        "schema" => "hub/schemas/operation-authoring-launch-result.schema.json",
        "ok" => true,
        "operation_id" => record.fetch("operation_id"),
        "outcome" => "created",
        "mission_id" => record.fetch("mission_id"),
        "snapshot_operation_id" => "mission:#{record.fetch('mission_id')}",
        "plan_id" => record.fetch("plan_id"),
        "plan_generation" => record.fetch("plan_generation"),
        "plan_digest" => record.fetch("plan_digest"),
        "replayed" => replayed
      }
    end

    def guidance_result(operation_id, item, replayed:)
      {
        "schema_version" => GUIDANCE_RESULT,
        "schema" => "hub/schemas/operation-authoring-guidance-result.schema.json",
        "ok" => true,
        "operation_id" => operation_id,
        "guidance_id" => item.fetch("guidance_id"),
        "attached_at" => item.fetch("attached_at"),
        "redacted" => item.fetch("redacted"),
        "replayed" => replayed
      }
    end

    def operation_result(operation_id, outcome, mission_id, plan_id, reason)
      {
        "schema_version" => OPERATION_RESULT,
        "schema" => "hub/schemas/operation-authoring-operation-result.schema.json",
        "ok" => true,
        "operation_id" => operation_id,
        "outcome" => outcome,
        "mission_id" => mission_id,
        "snapshot_operation_id" => mission_id ? "mission:#{mission_id}" : nil,
        "plan_id" => plan_id,
        "reason" => reason
      }
    end

    def operation_records
      return [] unless Dir.exist?(operation_dir)
      stat = File.lstat(operation_dir)
      unless stat.directory? && !stat.symlink?
        raise ContractError.new("operation_store_invalid", "operation store boundary is invalid")
      end
      entries = Dir.children(operation_dir).reject { |entry| entry == ".lock" }.sort
      raise ContractError.new("operation_store_invalid", "operation record budget exceeded") if entries.length > MAX_OPERATION_RECORDS
      unless entries.all? { |entry| entry.match?(/\A[0-9a-f]{64}\.json\z/) }
        raise ContractError.new("operation_store_invalid", "operation store contains an unknown entry")
      end
      records = entries.map do |entry|
        path = File.join(operation_dir, entry)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.size <= MAX_OPERATION_RECORD_BYTES
          raise ContractError.new("operation_store_invalid", "operation record boundary is invalid")
        end
        record = Support.load_data(path)
        validate_operation_record!(record)
        unless File.basename(path) == "#{Digest::SHA256.hexdigest(record.fetch('operation_id'))}.json"
          raise ContractError.new("operation_store_invalid", "operation record filename binding is invalid")
        end
        record
      end
      ids = records.map { |record| record.fetch("operation_id") }
      raise ContractError.new("operation_store_invalid", "operation store contains conflicting identities") unless ids.uniq.length == ids.length

      records
    rescue SystemCallError, EncodingError, ValidationError
      raise ContractError.new("operation_store_invalid", "operation store is unreadable or malformed")
    end

    def validate_operation_record!(record)
      fields = %w[schema_version operation_id operation_digest request_digest plan_id plan_generation plan_digest plan_token mission_id mission_fingerprint state guidance created_at updated_at]
      expect_object!(record, fields, "operation record")
      unless record["schema_version"] == "flightdeck.operation-authoring.operation-record/v1"
        raise ContractError.new("operation_store_invalid", "operation record version is unsupported")
      end
      validate_operation_id!(record["operation_id"])
      %w[operation_digest request_digest plan_digest plan_token mission_fingerprint].each do |field|
        raise ContractError.new("operation_store_invalid", "operation record digest is invalid") unless MissionStore::SHA256.match?(record[field].to_s)
      end
      unless record["operation_digest"] == Digest::SHA256.hexdigest(record["operation_id"]) &&
             record["plan_id"].to_s.match?(/\Aplan-[0-9a-f]{48}\z/) && record["plan_generation"].to_s.match?(/\Ageneration-[0-9a-f]{48}\z/) &&
             record["mission_id"].to_s.match?(/\Aoperation-[0-9a-f]{24}\z/) && RECORD_STATES.include?(record["state"])
        raise ContractError.new("operation_store_invalid", "operation record identity is invalid")
      end
      unless record["guidance"].is_a?(Array) && record["guidance"].length <= MAX_GUIDANCE
        raise ContractError.new("operation_store_invalid", "operation guidance is invalid")
      end
      record["guidance"].each { |item| validate_guidance_record!(item) }
      %w[created_at updated_at].each { |field| Time.iso8601(record.fetch(field).to_s) }
    rescue ArgumentError
      raise ContractError.new("operation_store_invalid", "operation record timestamp is invalid")
    end

    def validate_guidance_record!(item)
      expect_object!(item, %w[guidance_id guidance_digest text redacted attached_at], "guidance record")
      unless item["guidance_id"].to_s.match?(/\A#{Regexp.escape(GUIDANCE_ID_PREFIX)}[0-9a-f]{24}\z/) && MissionStore::SHA256.match?(item["guidance_digest"].to_s) &&
             [true, false].include?(item["redacted"])
        raise ContractError.new("operation_store_invalid", "guidance identity is invalid")
      end
      bounded_text!(item["text"], "guidance text", 1024)
      Time.iso8601(item.fetch("attached_at").to_s)
    rescue ArgumentError
      raise ContractError.new("operation_store_invalid", "guidance timestamp is invalid")
    end

    def write_operation!(record)
      content = "#{JSON.pretty_generate(record)}\n"
      raise ContractError.new("operation_store_invalid", "operation record exceeds its bounded contract") if content.bytesize > MAX_OPERATION_RECORD_BYTES

      FileUtils.mkdir_p(operation_dir, mode: 0o700)
      Support.atomic_write(operation_path(record.fetch("operation_id")), content)
    end

    def operation_dir
      config.root_path("hub/state/operation-authoring", label: "Operation authoring state")
    end

    def operation_path(operation_id)
      File.join(operation_dir, "#{Digest::SHA256.hexdigest(operation_id)}.json")
    end

    def authoring_lock_path
      File.join(operation_dir, ".lock")
    end

    def with_authoring_lock(mode)
      FileUtils.mkdir_p(operation_dir, mode: 0o700)
      File.open(authoring_lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        stat = lock.stat
        unless stat.file? && !File.symlink?(authoring_lock_path)
          raise ContractError.new("capability_incomplete", "Operation authoring lock boundary is unavailable")
        end
        unless lock.flock(mode | File::LOCK_NB)
          raise ContractError.new("conflicting_operation", "another Operation authoring request is active")
        end
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise ContractError.new("capability_incomplete", "Operation authoring lock boundary is unavailable")
    end

    def mission_write_absent?(mission_id)
      path = File.join(config.mission_dir, mission_id.to_s, "mission.yaml")
      !File.exist?(path) && !File.symlink?(path)
    rescue SystemCallError
      false
    end

    def redact_guidance!(value)
      unless value.is_a?(String)
        raise ContractError.new("malformed_request", "guidance must be a string")
      end
      text = value.strip
      if text.empty? || text.bytesize > 1024 || text.match?(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/)
        raise ContractError.new("malformed_request", "guidance must be bounded non-control text")
      end
      redacted = false
      patterns = [MissionStore::SECRET_VALUE, /\b(?:secret|password|credential|access[_-]?token)\s*[:=]\s*\S+/i]
      patterns.each do |pattern|
        next unless text.match?(pattern)

        text = text.gsub(pattern, "[REDACTED]")
        redacted = true
      end
      text = bounded_text!(text, "guidance", 1024)
      { "text" => text, "redacted" => redacted }
    end

    def warning(code, logical_key)
      { "code" => code, "message" => "Project #{logical_key} is not eligible for typed Operation authoring." }
    end

    def validate_operation_id!(value)
      unless value.is_a?(String) && value.match?(/\Aoperation-[0-9a-f]{24}\z/)
        raise ContractError.new("malformed_request", "operation_id must be the server-authored opaque operation identity")
      end
      value
    end

    def expect_version!(value, expected)
      return if value["schema_version"] == expected

      code = value["schema_version"].to_s.start_with?(expected.sub(%r{/v1\z}, "/v")) ? "future_version" : "unsupported_version"
      raise ContractError.new(code, "request schema_version must equal #{expected}")
    end

    def expect_object!(value, fields, label)
      raise ContractError.new("malformed_request", "#{label} must be an object") unless value.is_a?(Hash)
      keys = value.keys.map(&:to_s)
      unknown = keys - fields
      missing = fields - keys
      unless unknown.empty? && missing.empty?
        detail = unknown.empty? ? "missing fields: #{missing.sort.join(', ')}" : "contains forbidden fields: #{unknown.sort.join(', ')}"
        raise ContractError.new("malformed_request", "#{label} #{detail}")
      end
    end

    def bounded_text!(value, label, maximum)
      unless value.is_a?(String)
        raise ContractError.new("malformed_request", "#{label} must be a string")
      end
      text = value.strip
      if text.empty? || text.bytesize > maximum || text.match?(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/)
        raise ContractError.new("malformed_request", "#{label} must be bounded non-control text")
      end
      raise ContractError.new("forbidden_content", "#{label} appears to contain a credential") if MissionStore::SECRET_VALUE.match?(text)

      text
    end

    def bounded_text_list!(value, label, min: 0)
      bounded_array!(value, label, min: min).map.with_index { |item, index| bounded_text!(item, "#{label}[#{index}]", 1024) }.tap do |items|
        raise ContractError.new("malformed_request", "#{label} entries must be unique") unless items.uniq.length == items.length
      end
    end

    def bounded_array!(value, label, min: 0)
      unless value.is_a?(Array) && value.length.between?(min, MAX_ITEMS)
        raise ContractError.new("malformed_request", "#{label} must contain #{min} to #{MAX_ITEMS} items")
      end
      value
    end

    def safe_label(value)
      bounded_text!(value.to_s, "display label", 256)
    rescue ContractError
      "Eligible Flightdeck project"
    end

    def secure_equal_json?(left, right)
      left_json = canonical_json(left)
      right_json = canonical_json(right)
      return false unless left_json.bytesize == right_json.bytesize

      left_json.bytes.zip(right_json.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
    end

    def canonical_json(value)
      JSON.generate(canonical_value(value))
    end

    def canonical_value(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.to_h { |key| [key, canonical_value(value[key])] }
      when Array then value.map { |item| canonical_value(item) }
      else value
      end
    end

    def timestamp
      @clock.call.utc.iso8601(6)
    end
  end
end
