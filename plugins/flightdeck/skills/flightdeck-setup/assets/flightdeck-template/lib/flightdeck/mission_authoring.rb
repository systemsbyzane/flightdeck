# frozen_string_literal: true

require "digest"
require "json"
require_relative "mission_store"

module Flightdeck
  class MissionAuthoring
    CAPABILITY = "flightdeck.command.mission-authoring.v1"
    CATALOG_REQUEST = "flightdeck.mission-authoring.catalog-request/v1"
    CATALOG_RESULT = "flightdeck.mission-authoring.catalog-result/v1"
    PLAN_REQUEST = "flightdeck.mission-authoring.plan-request/v1"
    PLAN_RESULT = "flightdeck.mission-authoring.plan-result/v1"
    CREATE_REQUEST = "flightdeck.mission-authoring.create-request/v1"
    CREATE_RESULT = "flightdeck.mission-authoring.create-result/v1"
    OPERATION_REQUEST = "flightdeck.mission-authoring.operation-request/v1"
    OPERATION_RESULT = "flightdeck.mission-authoring.operation-result/v1"
    ERROR_RESULT = "flightdeck.mission-authoring.error-result/v1"
    MAX_REQUEST_BYTES = 262_144
    MAX_CATALOG_ITEMS = 1_000
    MAX_ITEMS = 50
    MAX_OPERATION_RECORD_BYTES = 65_536
    OPERATION_ID = /\A[A-Za-z0-9][A-Za-z0-9._~-]{0,127}\z/
    TARGET_FIELDS = %w[
      logical_project_key runtime_project_id project_path_digest host_id execution_mode access_mode
    ].freeze
    NODE_FIELDS = %w[
      id target_id required dependencies accepted_input_types allowed_output_types
    ].freeze
    PLAN_CONFIRMATION_FIELDS = %w[plan_id plan_generation plan_digest plan_token].freeze
    STATIC_NODE_FIELDS = %w[
      id logical_project_key runtime_project_id project_path_digest host_id execution_mode access_mode
      work_type required dependencies accepted_input_types allowed_output_types authorization_boundary criterion_ids
    ].freeze

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
      code = if error.respond_to?(:code)
               error.code
             elsif error.is_a?(UsageError)
               "malformed_request"
             else
               "validation_failed"
             end
      {
        "schema_version" => ERROR_RESULT,
        "schema" => "hub/schemas/mission-authoring-error-result.schema.json",
        "ok" => false,
        "operation" => operation,
        "error" => {
          "code" => code,
          "message" => error.message.to_s[0, 1024]
        }
      }
    end

    def catalog(request)
      verify_capability!
      expect_object!(request, %w[schema_version], "catalog request")
      expect_version!(request, CATALOG_REQUEST)
      target_data = current_targets
      if target_data.fetch("targets").length > MAX_CATALOG_ITEMS ||
         target_data.fetch("warnings").length > MAX_CATALOG_ITEMS
        raise ContractError.new("catalog_invalid", "target catalog exceeds its bounded result contract")
      end
      identities = target_data.fetch("targets").map { |target| target.reject { |key, _| key == "display_label" } }
      generation = "catalog-#{Digest::SHA256.hexdigest(canonical_json(identities))[0, 48]}"
      {
        "schema_version" => CATALOG_RESULT,
        "schema" => "hub/schemas/mission-authoring-catalog-result.schema.json",
        "ok" => true,
        "capability" => CAPABILITY,
        "catalog_generation" => generation,
        "targets" => target_data.fetch("targets"),
        "warnings" => target_data.fetch("warnings")
      }
    end

    def plan(request)
      verify_capability!
      expect_object!(request, %w[schema_version draft], "plan request")
      expect_version!(request, PLAN_REQUEST)
      draft = normalize_draft!(request.fetch("draft"))
      catalog_result = catalog("schema_version" => CATALOG_REQUEST)
      catalog_by_id = catalog_result.fetch("targets").to_h { |target| [target.fetch("target_id"), target] }
      selected = validate_selected_targets!(draft.fetch("selected_targets"), catalog_by_id)
      node_inputs = authoring_nodes(draft, selected)
      draft_digest = Digest::SHA256.hexdigest(canonical_json(draft))
      mission_id = "mission-#{draft_digest[0, 24]}"
      store = MissionStore.new(config, clock: @clock)
      record = store.preview_complete(
        slug: mission_id,
        title: draft.fetch("title"),
        outcome: draft.fetch("outcome"),
        mode: draft.fetch("mode"),
        success_criteria: draft.fetch("success_criteria"),
        non_goals: draft.fetch("non_goals"),
        authorized_targets: selected.map { |target| target.slice(*TARGET_FIELDS) },
        nodes: node_inputs
      )
      target_ids = selected.to_h do |target|
        [canonical_json(target.slice(*TARGET_FIELDS)), target.fetch("target_id")]
      end
      mission = plan_mission_projection(record, target_ids)
      canonical_plan = {
        "capability" => CAPABILITY,
        "catalog_generation" => catalog_result.fetch("catalog_generation"),
        "mission" => mission
      }
      plan_digest = Digest::SHA256.hexdigest(canonical_json(canonical_plan))
      plan_id = "plan-#{plan_digest[0, 48]}"
      plan_generation = "generation-#{catalog_result.fetch('catalog_generation').delete_prefix('catalog-')}"
      plan_token = Digest::SHA256.hexdigest(
        canonical_json(
          "capability" => CAPABILITY,
          "plan_id" => plan_id,
          "plan_generation" => plan_generation,
          "plan_digest" => plan_digest,
          "canonical_plan" => canonical_plan
        )
      )
      warnings = catalog_result.fetch("warnings").dup
      if mission.dig("graph", "nodes").count { |node| node["required"] } > 1
        warnings << {
          "code" => "all_required_nodes_own_all_criteria",
          "message" => "Core assigned every success criterion to every required node; confirmation accepts that exact responsibility."
        }
      end
      {
        "schema_version" => PLAN_RESULT,
        "schema" => "hub/schemas/mission-authoring-plan-result.schema.json",
        "ok" => true,
        "capability" => CAPABILITY,
        "plan_id" => plan_id,
        "plan_generation" => plan_generation,
        "plan_digest" => plan_digest,
        "plan_token" => plan_token,
        "catalog_generation" => catalog_result.fetch("catalog_generation"),
        "mission" => mission,
        "warnings" => warnings
      }
    rescue KeyError => e
      raise ContractError.new("malformed_request", "plan request missing field: #{e.key}")
    end

    def create(request)
      verify_capability!
      expect_object!(request, %w[schema_version operation_id confirmation draft], "create request")
      expect_version!(request, CREATE_REQUEST)
      operation_id = validate_operation_id!(request.fetch("operation_id"))
      confirmation = request.fetch("confirmation")
      expect_object!(confirmation, PLAN_CONFIRMATION_FIELDS, "plan confirmation")
      confirmation.each_value do |value|
        unless value.is_a?(String) && value.bytesize.between?(1, 128) && !value.match?(/[\u0000-\u001f\u007f]/)
          raise ContractError.new("malformed_request", "plan confirmation values must be bounded opaque strings")
        end
      end
      draft = request.fetch("draft")
      request_digest = Digest::SHA256.hexdigest(canonical_json(request))

      with_authoring_lock(File::LOCK_EX) do
        begin
          planned = plan("schema_version" => PLAN_REQUEST, "draft" => draft)
        rescue ContractError => e
          raise unless e.code == "ineligible_target"

          raise ContractError.new(
            "stale_or_mismatched_plan",
            "create target eligibility changed after preview"
          )
        end
        expected = PLAN_CONFIRMATION_FIELDS.to_h { |field| [field, planned.fetch(field)] }
        unless secure_equal_json?(confirmation, expected)
          raise ContractError.new(
            "stale_or_mismatched_plan",
            "create confirmation does not match the current canonical plan"
          )
        end
        records = operation_records
        existing = records.find { |record| record["operation_id"] == operation_id }
        if existing
          code = existing["request_digest"] == request_digest ? "duplicate_operation" : "conflicting_operation"
          message = if code == "duplicate_operation"
                      "operation ID was already submitted; query operation status and never retry it"
                    else
                      "operation ID is already bound to different content"
                    end
          raise ContractError.new(code, message)
        end
        if records.any? do |record|
             record["plan_id"] == planned.fetch("plan_id") && record["state"] != "not_created"
           end
          raise ContractError.new("consumed_plan", "the confirmed one-time plan was already consumed")
        end

        normalized = normalize_draft!(draft)
        selected = validate_selected_targets!(
          normalized.fetch("selected_targets"),
          catalog("schema_version" => CATALOG_REQUEST).fetch("targets").to_h do |target|
            [target.fetch("target_id"), target]
          end
        )
        node_inputs = authoring_nodes(normalized, selected)
        mission_id = planned.dig("mission", "id")
        expected_fingerprint = mission_fingerprint_from_plan(planned.fetch("mission"))
        operation = {
          "schema_version" => "flightdeck.mission-authoring.operation-record/v1",
          "operation_id" => operation_id,
          "operation_digest" => Digest::SHA256.hexdigest(operation_id),
          "request_digest" => request_digest,
          "plan_id" => planned.fetch("plan_id"),
          "plan_generation" => planned.fetch("plan_generation"),
          "plan_digest" => planned.fetch("plan_digest"),
          "plan_token" => planned.fetch("plan_token"),
          "mission_id" => mission_id,
          "mission_fingerprint" => expected_fingerprint,
          "state" => "unresolved",
          "created_at" => timestamp,
          "updated_at" => timestamp
        }
        write_operation!(operation)

        begin
          mission = MissionStore.new(config, clock: @clock).create_complete(
            slug: mission_id,
            title: normalized.fetch("title"),
            outcome: normalized.fetch("outcome"),
            mode: normalized.fetch("mode"),
            success_criteria: normalized.fetch("success_criteria"),
            non_goals: normalized.fetch("non_goals"),
            authorized_targets: selected.map { |target| target.slice(*TARGET_FIELDS) },
            nodes: node_inputs,
            authoring_binding: {
              "operation_digest" => operation.fetch("operation_digest"),
              "plan_id" => planned.fetch("plan_id"),
              "plan_digest" => planned.fetch("plan_digest")
            }
          )
        rescue StandardError => e
          if mission_write_absent?(mission_id)
            operation["state"] = "not_created"
            operation["updated_at"] = timestamp
            write_operation!(operation)
            raise ContractError.new("persistence_failed", "Mission persistence failed closed: #{e.class}")
          end

          raise ContractError.new("unknown_outcome", "create result is unknown; query the original operation ID")
        end

        unless mission_fingerprint_from_record(mission) == expected_fingerprint
          raise ContractError.new("unknown_outcome", "persisted Mission identity requires read-only recovery")
        end
        operation["state"] = "created"
        operation["updated_at"] = timestamp
        begin
          write_operation!(operation)
        rescue StandardError
          raise ContractError.new("unknown_outcome", "create result is unknown; query the original operation ID")
        end
        {
          "schema_version" => CREATE_RESULT,
          "schema" => "hub/schemas/mission-authoring-create-result.schema.json",
          "ok" => true,
          "operation_id" => operation_id,
          "outcome" => "created",
          "mission_id" => mission_id,
          "plan_id" => planned.fetch("plan_id"),
          "plan_generation" => planned.fetch("plan_generation"),
          "plan_digest" => planned.fetch("plan_digest")
        }
      end
    rescue KeyError => e
      raise ContractError.new("malformed_request", "create request missing field: #{e.key}")
    end

    def operation(request)
      verify_capability!
      expect_object!(request, %w[schema_version operation_id], "operation request")
      expect_version!(request, OPERATION_REQUEST)
      operation_id = validate_operation_id!(request.fetch("operation_id"))
      resolved = nil
      locked = try_authoring_lock(File::LOCK_SH) do
        begin
          record = operation_records.find { |candidate| candidate["operation_id"] == operation_id }
          resolved = resolve_operation(operation_id, record)
        rescue ContractError => e
          raise unless e.code == "operation_store_invalid"

          resolved = operation_result(operation_id, "unresolved", nil, nil, "operation_store_invalid")
        end
      end
      return resolved if locked

      operation_result(operation_id, "unresolved", nil, nil, "operation_in_progress")
    rescue KeyError => e
      raise ContractError.new("malformed_request", "operation request missing field: #{e.key}")
    end

    private

    def verify_capability!
      compatibility_path = File.join(config.root, "hub", "compatibility.json")
      required_schemas = %w[
        mission-authoring-catalog-request.schema.json
        mission-authoring-catalog-result.schema.json
        mission-authoring-create-request.schema.json
        mission-authoring-create-result.schema.json
        mission-authoring-error-result.schema.json
        mission-authoring-operation-request.schema.json
        mission-authoring-operation-result.schema.json
        mission-authoring-plan-request.schema.json
        mission-authoring-plan-result.schema.json
        mission-authoring-types.schema.json
      ]
      paths = [compatibility_path, authoring_lock_path] + required_schemas.map do |name|
        File.join(config.root, "hub", "schemas", name)
      end
      unless paths.all? { |path| File.file?(path) && !File.symlink?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Mission authoring v1 contract.")
      end
      compatibility = Support.load_data(compatibility_path)
      capability = compatibility.dig("capabilities", CAPABILITY)
      required_managed_paths = ["hub/.mission-authoring.lock"] + required_schemas.map do |name|
        "hub/schemas/#{name}"
      end
      unless compatibility["schema_version"] == "flightdeck.hub-compatibility/v1" &&
             compatibility["product"] == "flightdeck" && capability.is_a?(Hash) &&
             capability["kind"] == "command" &&
             capability.dig("probe", "help_contains") == "bin/flightdeck mission authoring-catalog " &&
             required_managed_paths.all? { |path| Array(capability["managed_paths"]).include?(path) }
        raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Mission authoring v1 contract.")
      end
      required_schemas.each do |name|
        schema = Support.load_data(File.join(config.root, "hub", "schemas", name))
        unless schema.is_a?(Hash) && schema["$id"] == "https://flightdeck.dev/schemas/#{name}"
          raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Mission authoring v1 contract.")
        end
      end
    rescue SystemCallError, ValidationError
      raise ContractError.new("unsupported_hub_contract", "Selected Hub does not declare the Mission authoring v1 contract.")
    end

    def mission_write_absent?(mission_id)
      path = File.join(config.mission_dir, mission_id.to_s, "mission.yaml")
      !File.exist?(path) && !File.symlink?(path)
    rescue SystemCallError
      false
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
        add_target_candidate(
          candidates,
          warnings,
          logical_key: key,
          expected_path: config.repository_path(repository),
          display_label: declaration["name"] || declaration.fetch("id"),
          execution_modes: %w[local worktree]
        )
      end
      config.codex_projects.each do |key, project|
        next if declared_keys[key] || project["role"] == "coordination"
        unless project["context"] == "local"
          warnings << warning("unsupported_remote_target", key)
          next
        end
        add_target_candidate(
          candidates,
          warnings,
          logical_key: key,
          expected_path: File.expand_path(project.fetch("path")),
          display_label: project["display_name"] || key,
          execution_modes: ["local"]
        )
      end
      { "targets" => candidates.sort_by { |target| target.fetch("target_id") }, "warnings" => warnings.sort_by { |item| item.fetch("code") + item.fetch("message") } }
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
      real_path = File.realpath(expected_path)
      path_digest = Digest::SHA256.hexdigest(real_path)
      execution_modes.each do |execution_mode|
        %w[read_only write].each do |access_mode|
          identity = {
            "logical_project_key" => logical_key.to_s,
            "runtime_project_id" => verification.fetch("runtime_project_id").to_s,
            "project_path_digest" => path_digest,
            "host_id" => "local",
            "execution_mode" => execution_mode,
            "access_mode" => access_mode
          }
          target_id = "target-#{Digest::SHA256.hexdigest(canonical_json(identity))[0, 40]}"
          candidates << { "target_id" => target_id, **identity, "display_label" => safe_label(display_label) }
        end
      end
    rescue Errno::ENOENT, Errno::ELOOP
      warnings << warning("target_path_unavailable", logical_key)
    end

    def warning(code, logical_key)
      {
        "code" => code,
        "message" => "Project #{logical_key} is not eligible for typed Mission authoring."
      }
    end

    def normalize_draft!(value)
      expect_object!(
        value,
        %w[title outcome success_criteria non_goals mode selected_targets nodes],
        "Mission draft"
      )
      draft = Support.stringify(value)
      draft["title"] = bounded_text!(draft["title"], "title", 256)
      draft["outcome"] = bounded_text!(draft["outcome"], "outcome", 2048)
      draft["success_criteria"] = bounded_text_list!(draft["success_criteria"], "success_criteria", min: 1)
      draft["non_goals"] = bounded_text_list!(draft["non_goals"], "non_goals", min: 1)
      unless MissionStore::MODES.include?(draft["mode"].to_s)
        raise ContractError.new("malformed_request", "Mission mode is invalid")
      end
      draft["mode"] = draft["mode"].to_s
      draft["selected_targets"] = bounded_array!(draft["selected_targets"], "selected_targets", min: 1)
      draft["nodes"] = bounded_array!(draft["nodes"], "nodes", min: 1).map.with_index do |node, index|
        normalize_node!(node, index)
      end
      node_ids = draft["nodes"].map { |node| node.fetch("id") }
      unless node_ids.uniq.length == node_ids.length
        raise ContractError.new("malformed_request", "node IDs must be unique")
      end
      known = node_ids.to_h { |id| [id, true] }
      draft["nodes"].each do |node|
        unknown = node.fetch("dependencies").reject { |id| known[id] }
        raise ContractError.new("malformed_request", "node #{node['id']} has unknown dependencies") unless unknown.empty?
        if node.fetch("dependencies").include?(node.fetch("id"))
          raise ContractError.new("malformed_request", "node #{node['id']} cannot depend on itself")
        end
      end
      unless draft["nodes"].any? { |node| node["required"] == true }
        raise ContractError.new("malformed_request", "at least one required node is required")
      end
      draft
    end

    def normalize_node!(node, index)
      expect_object!(node, NODE_FIELDS, "node #{index}")
      value = Support.stringify(node)
      Support.validate_identifier!(value["id"], label: "node ID")
      Support.validate_identifier!(value["target_id"], label: "target ID")
      unless [true, false].include?(value["required"])
        raise ContractError.new("malformed_request", "node #{value['id']} required must be boolean")
      end
      value["dependencies"] = identifier_list!(value["dependencies"], "node dependencies")
      value["accepted_input_types"] = identifier_list!(value["accepted_input_types"], "accepted input types")
      value["allowed_output_types"] = identifier_list!(value["allowed_output_types"], "allowed output types", min: 1)
      if value["dependencies"].any? && value["accepted_input_types"].empty?
        raise ContractError.new("malformed_request", "dependent nodes require accepted input types")
      end
      value
    rescue UsageError => e
      raise ContractError.new("malformed_request", e.message)
    end

    def validate_selected_targets!(targets, catalog_by_id)
      normalized = targets.map.with_index do |target, index|
        expect_object!(target, ["target_id", *TARGET_FIELDS], "selected target #{index}")
        candidate = Support.stringify(target)
        known = catalog_by_id[candidate["target_id"]]
        unless known && secure_equal_json?(candidate, known.reject { |key, _| key == "display_label" })
          raise ContractError.new("ineligible_target", "selected target #{index} is not an exact current catalog choice")
        end
        candidate
      end
      ids = normalized.map { |target| target.fetch("target_id") }
      raise ContractError.new("malformed_request", "selected targets must be unique") unless ids.uniq.length == ids.length
      normalized
    end

    def authoring_nodes(draft, selected)
      by_id = selected.to_h { |target| [target.fetch("target_id"), target] }
      used = {}
      criteria = draft.fetch("success_criteria").each_index.map { |index| format("criterion-%03d", index + 1) }
      nodes = draft.fetch("nodes").map do |node|
        target = by_id[node.fetch("target_id")]
        raise ContractError.new("ineligible_target", "node #{node['id']} target is not selected") unless target
        used[target.fetch("target_id")] = true
        {
          node_id: node.fetch("id"),
          logical_project_key: target.fetch("logical_project_key"),
          runtime_project_id: target.fetch("runtime_project_id"),
          project_path_digest: target.fetch("project_path_digest"),
          host_id: target.fetch("host_id"),
          execution_mode: target.fetch("execution_mode"),
          access_mode: target.fetch("access_mode"),
          work_type: target.fetch("access_mode") == "write" ? "implementation" : "read_only",
          required: node.fetch("required"),
          dependencies: node.fetch("dependencies"),
          accepted_input_types: node.fetch("accepted_input_types"),
          allowed_output_types: node.fetch("allowed_output_types"),
          criterion_ids: node.fetch("required") ? criteria : []
        }
      end
      unused = by_id.keys.reject { |id| used[id] }
      raise ContractError.new("malformed_request", "every selected target must be used by a node") unless unused.empty?
      nodes
    end

    def plan_mission_projection(record, target_ids)
      spec = record.fetch("spec")
      {
        "id" => record.dig("metadata", "id"),
        "title" => record.dig("metadata", "title"),
        "outcome" => spec.fetch("outcome"),
        "mode" => spec.fetch("mode"),
        "success_criteria" => spec.fetch("success_criteria"),
        "non_goals" => spec.fetch("non_goals"),
        "authorized_targets" => spec.fetch("authorized_targets"),
        "authorization_boundary" => spec.fetch("authorization_boundary"),
        "budgets" => spec.fetch("budgets"),
        "graph" => {
          "nodes" => spec.dig("graph", "nodes").map do |node|
            identity = TARGET_FIELDS.to_h { |field| [field, node.fetch(field)] }
            { "target_id" => target_ids.fetch(canonical_json(identity)), **node.slice(*STATIC_NODE_FIELDS) }
          end
        }
      }
    end

    def mission_fingerprint_from_plan(mission)
      projection = Support.stringify(mission)
      projection.dig("graph", "nodes").each { |node| node.delete("target_id") }
      Digest::SHA256.hexdigest(canonical_json(projection))
    end

    def mission_fingerprint_from_record(record)
      spec = record.fetch("spec")
      projection = {
        "id" => record.dig("metadata", "id"),
        "title" => record.dig("metadata", "title"),
        "outcome" => spec.fetch("outcome"),
        "mode" => spec.fetch("mode"),
        "success_criteria" => spec.fetch("success_criteria"),
        "non_goals" => spec.fetch("non_goals"),
        "authorized_targets" => spec.fetch("authorized_targets"),
        "authorization_boundary" => spec.fetch("authorization_boundary"),
        "budgets" => spec.fetch("budgets"),
        "graph" => { "nodes" => spec.dig("graph", "nodes").map { |node| node.slice(*STATIC_NODE_FIELDS) } }
      }
      Digest::SHA256.hexdigest(canonical_json(projection))
    end

    def resolve_operation(operation_id, record)
      return operation_result(operation_id, "not_created", nil, nil, "operation_not_found") unless record

      mission_id = record["mission_id"]
      plan_id = record["plan_id"]
      mission_path = File.join(config.mission_dir, mission_id.to_s, "mission.yaml")
      if File.file?(mission_path)
        begin
          mission = MissionStore.new(config, clock: @clock).snapshot(mission_id)
          binding = mission.dig("metadata", "authoring")
          expected_binding = {
            "operation_digest" => record["operation_digest"],
            "plan_id" => record["plan_id"],
            "plan_digest" => record["plan_digest"]
          }
          if secure_equal_json?(binding, expected_binding) &&
             mission_fingerprint_from_record(mission) == record["mission_fingerprint"]
            return operation_result(operation_id, "created", mission_id, plan_id, nil)
          end
        rescue ValidationError, KeyError
          # Fall through to an unresolved fail-closed result.
        end
        return operation_result(operation_id, "unresolved", mission_id, plan_id, "mission_identity_conflict")
      end
      if record["state"] == "created"
        operation_result(operation_id, "unresolved", mission_id, plan_id, "created_record_missing_mission")
      else
        operation_result(operation_id, "not_created", nil, plan_id, "no_mission_persisted")
      end
    end

    def operation_result(operation_id, outcome, mission_id, plan_id, reason)
      {
        "schema_version" => OPERATION_RESULT,
        "schema" => "hub/schemas/mission-authoring-operation-result.schema.json",
        "ok" => true,
        "operation_id" => operation_id,
        "outcome" => outcome,
        "mission_id" => mission_id,
        "plan_id" => plan_id,
        "reason" => reason
      }
    end

    def operation_records
      directory_stat = begin
        File.lstat(operation_dir)
      rescue Errno::ENOENT
        return []
      end
      unless directory_stat.directory? && !directory_stat.symlink?
        raise ContractError.new("operation_store_invalid", "operation store boundary is invalid")
      end

      entries = Dir.children(operation_dir).sort
      raise ContractError.new("operation_store_invalid", "operation record budget exceeded") if entries.length > 10_000
      unless entries.all? { |entry| entry.match?(/\A[0-9a-f]{64}\.json\z/) }
        raise ContractError.new("operation_store_invalid", "operation store contains an unknown entry")
      end
      paths = entries.map { |entry| File.join(operation_dir, entry) }
      records = paths.map do |path|
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.size <= MAX_OPERATION_RECORD_BYTES
          raise ContractError.new("operation_store_invalid", "operation record boundary is invalid")
        end
        value = Support.load_data(path)
        validate_operation_record!(value)
        unless File.basename(path) == "#{Digest::SHA256.hexdigest(value.fetch('operation_id'))}.json"
          raise ContractError.new("operation_store_invalid", "operation record filename binding is invalid")
        end
        value
      end
      operation_ids = records.map { |record| record.fetch("operation_id") }
      unless operation_ids.uniq.length == operation_ids.length
        raise ContractError.new("operation_store_invalid", "operation store contains conflicting identities")
      end
      records
    rescue SystemCallError, EncodingError, ValidationError
      raise ContractError.new("operation_store_invalid", "operation store is unreadable or malformed")
    end

    def validate_operation_record!(record)
      fields = %w[
        schema_version operation_id operation_digest request_digest plan_id plan_generation plan_digest plan_token
        mission_id mission_fingerprint state created_at updated_at
      ]
      expect_object!(record, fields, "operation record")
      unless record["schema_version"] == "flightdeck.mission-authoring.operation-record/v1"
        raise ContractError.new("operation_store_invalid", "operation record version is unsupported")
      end
      validate_operation_id!(record["operation_id"])
      %w[operation_digest request_digest plan_digest plan_token mission_fingerprint].each do |field|
        unless MissionStore::SHA256.match?(record[field].to_s)
          raise ContractError.new("operation_store_invalid", "operation record digest is invalid")
        end
      end
      unless record["operation_digest"] == Digest::SHA256.hexdigest(record["operation_id"])
        raise ContractError.new("operation_store_invalid", "operation record client identity binding is invalid")
      end
      unless record["plan_id"].to_s.match?(/\Aplan-[0-9a-f]{48}\z/) &&
             record["plan_generation"].to_s.match?(/\Ageneration-[0-9a-f]{48}\z/) &&
             record["mission_id"].to_s.match?(/\Amission-[0-9a-f]{24}\z/)
        raise ContractError.new("operation_store_invalid", "operation record plan or Mission identity is invalid")
      end
      unless %w[unresolved created not_created].include?(record["state"])
        raise ContractError.new("operation_store_invalid", "operation record state is invalid")
      end
      %w[created_at updated_at].each do |field|
        Time.iso8601(record.fetch(field).to_s)
      rescue ArgumentError
        raise ContractError.new("operation_store_invalid", "operation record timestamp is invalid")
      end
    end

    def write_operation!(record)
      FileUtils.mkdir_p(operation_dir, mode: 0o700)
      Support.atomic_write(operation_path(record.fetch("operation_id")), "#{JSON.pretty_generate(record)}\n")
    end

    def operation_dir
      File.join(config.mission_dir, ".authoring-operations")
    end

    def operation_path(operation_id)
      File.join(operation_dir, "#{Digest::SHA256.hexdigest(operation_id)}.json")
    end

    def with_authoring_lock(mode)
      path = authoring_lock_path
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink?
        raise ContractError.new("capability_incomplete", "Mission authoring lock boundary is unavailable")
      end
      File.open(path, File::RDONLY) do |lock|
        unless lock.flock(mode | File::LOCK_NB)
          raise ContractError.new("conflicting_operation", "another Mission authoring operation is active")
        end
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise ContractError.new("capability_incomplete", "Mission authoring lock boundary is unavailable")
    end

    def try_authoring_lock(mode)
      with_authoring_lock(mode) { yield }
      true
    rescue ContractError => e
      raise unless e.code == "conflicting_operation"

      false
    end

    def authoring_lock_path
      config.root_path("hub/.mission-authoring.lock", label: "Mission authoring lock")
    end

    def validate_operation_id!(value)
      unless value.is_a?(String) && OPERATION_ID.match?(value)
        raise ContractError.new("malformed_request", "operation_id must be an opaque bounded client identifier")
      end
      if MissionStore::SECRET_VALUE.match?(value)
        raise ContractError.new("forbidden_content", "operation_id appears to contain a credential")
      end
      value
    end

    def expect_version!(value, expected)
      actual = value["schema_version"]
      return if actual == expected

      code = actual.to_s.start_with?(expected.sub(%r{/v1\z}, "/v")) ? "future_version" : "unsupported_version"
      raise ContractError.new(code, "request schema_version must equal #{expected}")
    end

    def expect_object!(value, fields, label)
      raise ContractError.new("malformed_request", "#{label} must be an object") unless value.is_a?(Hash)
      keys = value.keys.map(&:to_s)
      unknown = keys - fields
      missing = fields - keys
      unless unknown.empty?
        raise ContractError.new("malformed_request", "#{label} contains forbidden fields: #{unknown.sort.join(', ')}")
      end
      unless missing.empty?
        raise ContractError.new("malformed_request", "#{label} missing fields: #{missing.sort.join(', ')}")
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
      if MissionStore::SECRET_VALUE.match?(text)
        raise ContractError.new("forbidden_content", "#{label} appears to contain a credential")
      end
      text
    end

    def bounded_text_list!(value, label, min: 0)
      bounded_array!(value, label, min: min).map.with_index do |item, index|
        bounded_text!(item, "#{label}[#{index}]", 1024)
      end.tap do |items|
        raise ContractError.new("malformed_request", "#{label} entries must be unique") unless items.uniq.length == items.length
      end
    end

    def identifier_list!(value, label, min: 0)
      bounded_array!(value, label, min: min).map do |item|
        Support.validate_identifier!(item, label: label)
        item.to_s
      end.tap do |items|
        raise ContractError.new("malformed_request", "#{label} entries must be unique") unless items.uniq.length == items.length
      end
    rescue UsageError => e
      raise ContractError.new("malformed_request", e.message)
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
      when Array
        value.map { |item| canonical_value(item) }
      else
        value
      end
    end

    def timestamp
      @clock.call.utc.iso8601(6)
    end
  end
end
