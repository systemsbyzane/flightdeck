# frozen_string_literal: true

require "optparse"
require_relative "bridge_bulk_store"
require_relative "doctor"
require_relative "hub_snapshot"
require_relative "operations_snapshot"
require_relative "mission_authoring"
require_relative "mission_objectives"
require_relative "skill_telemetry"
require_relative "operation_authoring"
require_relative "operation_detail"
require_relative "mission_sync"
require_relative "repo_planner"
require_relative "repository_store"
require_relative "route_planner"
require_relative "setup_store"
require_relative "work_store"
require_relative "omp_operation_execution"

module Flightdeck
  class CLI
    def initialize(root:, out: $stdout, err: $stderr)
      @root = root
      @out = out
      @err = err
    end

    def run(argv)
      arguments = argv.dup
      return mission_list(arguments.drop(2)) if arguments.first(2) == %w[mission list]
      return mission_client_snapshot(arguments.drop(2)) if arguments.first(2) == %w[mission client-snapshot]
      return work_list(arguments.drop(2)) if arguments.first(2) == %w[work list]

      command = arguments.shift || "help"
      return help if %w[help -h --help].include?(command)

      config = Config.new(root: @root)
      case command
      when "hub" then hub(arguments)
      when "doctor" then doctor(config, arguments)
      when "status" then status(config, arguments)
      when "setup" then setup(config, arguments)
      when "route" then route(config, arguments)
      when "repo" then repo(config, arguments)
      when "bridge" then bridge(config, arguments)
      when "task" then task(config, arguments)
      when "mission" then mission(config, arguments)
      when "operation" then operation(config, arguments)
      when "work" then work(config, arguments)
      else raise UsageError, "unknown command: #{command}"
      end
    rescue UsageError, OptionParser::ParseError => e
      @err.puts("Error: #{e.message}")
      @err.puts("Run bin/flightdeck help for usage.")
      2
    rescue ConfigurationError, ValidationError => e
      @err.puts("Error: #{e.message}")
      1
    rescue Interrupt
      @err.puts("Interrupted")
      130
    end

    private

    def hub(argv)
      subcommand = argv.shift
      return hub_operations_snapshot(argv) if subcommand == "operations-snapshot"
      raise UsageError, "hub requires snapshot" unless subcommand == "snapshot"

      options = {}
      OptionParser.new do |parser|
        parser.on("--hub-root PATH") { |value| options[:hub_root] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--hub-root is required" unless options[:hub_root]

      selected_root = options[:hub_root].to_s
      unless Pathname.new(selected_root).absolute?
        raise HubSnapshot::SnapshotError.new("invalid_hub_root", "Selected Hub root must be an absolute path.")
      end
      unless File.directory?(selected_root)
        raise HubSnapshot::SnapshotError.new("hub_root_not_found", "Selected Hub root does not exist.")
      end
      config = Config.new(root: selected_root)
      unless config.data["api_version"] == "flightdeck.dev/v1alpha1" &&
             config.data["kind"] == "FlightdeckRegistry" &&
             config.data["schema"] == "hub/schemas/flightdeck.schema.json"
        raise HubSnapshot::SnapshotError.new("invalid_hub_root", "Selected Hub root is not a Flightdeck Hub.")
      end
      json(HubSnapshot.new(config).snapshot)
      0
    rescue HubSnapshot::SnapshotError => e
      emit_hub_snapshot_error(e.code, e.message)
      1
    rescue UsageError, OptionParser::ParseError
      emit_hub_snapshot_error("invalid_request", "Hub snapshot request is invalid.")
      2
    rescue ConfigurationError, ValidationError, SystemCallError
      emit_hub_snapshot_error("invalid_hub_root", "Selected Hub root is not a valid Flightdeck Hub.")
      1
    end

    def hub_operations_snapshot(argv)
      options = {}
      OptionParser.new do |parser|
        parser.on("--hub-root PATH") { |value| options[:hub_root] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--hub-root is required" unless options[:hub_root]
      selected_root = options[:hub_root].to_s
      raise OperationsSnapshot::SnapshotError.new("invalid_hub_root", "Selected Hub root must be an absolute path.") unless Pathname.new(selected_root).absolute?
      raise OperationsSnapshot::SnapshotError.new("hub_root_not_found", "Selected Hub root does not exist.") unless File.directory?(selected_root)
      config = Config.new(root: selected_root)
      unless config.data["api_version"] == "flightdeck.dev/v1alpha1" && config.data["kind"] == "FlightdeckRegistry" && config.data["schema"] == "hub/schemas/flightdeck.schema.json"
        raise OperationsSnapshot::SnapshotError.new("invalid_hub_root", "Selected Hub root is not a Flightdeck Hub.")
      end
      json(OperationsSnapshot.new(config).snapshot)
      0
    rescue OperationsSnapshot::SnapshotError => e
      emit_operations_snapshot_error(e.code, e.message)
      1
    rescue UsageError, OptionParser::ParseError
      emit_operations_snapshot_error("invalid_request", "Operations snapshot request is invalid.")
      2
    rescue ConfigurationError, ValidationError, SystemCallError
      emit_operations_snapshot_error("invalid_hub_root", "Selected Hub root is not a valid Flightdeck Hub.")
      1
    end

    def mission_list(argv)
      options = { limit: MissionStore::LIST_DEFAULT_LIMIT }
      OptionParser.new do |parser|
        parser.on("--hub-root PATH") { |value| options[:hub_root] = value }
        parser.on("--limit N", Integer) { |value| options[:limit] = value }
        parser.on("--cursor CURSOR") { |value| options[:cursor] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--hub-root is required" unless options[:hub_root]

      selected_root = options[:hub_root].to_s
      unless Pathname.new(selected_root).absolute?
        raise MissionStore::ListError.new("invalid_hub_root", "Hub root must be an absolute path.")
      end
      unless File.directory?(selected_root)
        raise MissionStore::ListError.new("hub_root_not_found", "Selected Hub root does not exist.")
      end

      config = Config.new(root: selected_root)
      unless config.data["api_version"] == "flightdeck.dev/v1alpha1" &&
             config.data["kind"] == "FlightdeckRegistry" &&
             config.data["schema"] == "hub/schemas/flightdeck.schema.json"
        raise MissionStore::ListError.new("invalid_hub_root", "Selected Hub root is not a Flightdeck Hub.")
      end
      verify_mission_list_capability!(config)
      json(MissionStore.new(config).list_page(limit: options[:limit], cursor: options[:cursor]))
      0
    rescue MissionStore::ListError => e
      emit_mission_list_error(e.code, e.message, mission_id: e.mission_id)
      e.exit_status
    rescue UsageError, OptionParser::ParseError
      emit_mission_list_error("invalid_request", "Mission list request is invalid.")
      2
    rescue ConfigurationError, ValidationError, SystemCallError
      emit_mission_list_error("invalid_hub_root", "Selected Hub root is not a valid Flightdeck Hub.")
      1
    end

    def verify_mission_list_capability!(config)
      compatibility_path = File.join(config.root, "hub", "compatibility.json")
      schema_path = File.join(config.root, MissionStore::LIST_SCHEMA)
      unless File.file?(compatibility_path) && !File.symlink?(compatibility_path) &&
             File.file?(schema_path) && !File.symlink?(schema_path)
        raise MissionStore::ListError.new(
          "unsupported_hub_contract",
          "Selected Hub does not declare the Mission list v1 contract."
        )
      end
      compatibility = Support.load_data(compatibility_path)
      capability = compatibility.dig("capabilities", "flightdeck.command.mission-list.v1")
      unless compatibility["schema_version"] == "flightdeck.hub-compatibility/v1" &&
             compatibility["product"] == "flightdeck" && capability.is_a?(Hash)
        raise MissionStore::ListError.new(
          "unsupported_hub_contract",
          "Selected Hub does not declare the Mission list v1 contract."
        )
      end
    end

    def mission_client_snapshot(argv)
      options = {}
      OptionParser.new do |parser|
        parser.on("--hub-root PATH") { |value| options[:hub_root] = value }
        parser.on("--mission SLUG") { |value| options[:slug] = value }
        parser.on("--parent-chat-id ID") { |value| options[:parent_chat_id] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--hub-root, --mission, and --parent-chat-id are required" unless options[:hub_root] && options[:slug] && options[:parent_chat_id]

      selected_root = options[:hub_root].to_s
      unless Pathname.new(selected_root).absolute?
        raise MissionStore::ClientSnapshotError.new("invalid_hub_root", "Hub root must be an absolute path.")
      end
      unless File.directory?(selected_root)
        raise MissionStore::ClientSnapshotError.new("hub_root_not_found", "Selected Hub root does not exist.")
      end
      config = Config.new(root: selected_root)
      unless config.data["api_version"] == "flightdeck.dev/v1alpha1" &&
             config.data["kind"] == "FlightdeckRegistry" &&
             config.data["schema"] == "hub/schemas/flightdeck.schema.json"
        raise MissionStore::ClientSnapshotError.new("invalid_hub_root", "Selected Hub root is not a Flightdeck Hub.")
      end
      verify_mission_client_snapshot_capability!(config)
      json(MissionStore.new(config).client_snapshot(slug: options[:slug], parent_chat_id: options[:parent_chat_id]))
      0
    rescue MissionStore::ClientSnapshotError => e
      emit_mission_client_snapshot_error(e.code, e.message)
      e.exit_status
    rescue UsageError, OptionParser::ParseError
      emit_mission_client_snapshot_error("invalid_request", "Mission client snapshot request is invalid.")
      2
    rescue ConfigurationError, ValidationError, SystemCallError
      emit_mission_client_snapshot_error("invalid_hub_root", "Selected Hub root is not a valid Flightdeck Hub.")
      1
    end

    def verify_mission_client_snapshot_capability!(config)
      compatibility_path = File.join(config.root, "hub", "compatibility.json")
      schema_path = File.join(config.root, MissionStore::CLIENT_SNAPSHOT_SCHEMA)
      unless File.file?(compatibility_path) && !File.symlink?(compatibility_path) &&
             File.file?(schema_path) && !File.symlink?(schema_path)
        raise MissionStore::ClientSnapshotError.new(
          "unsupported_hub_contract",
          "Selected Hub does not declare the Mission client snapshot v1 contract."
        )
      end
      compatibility = Support.load_data(compatibility_path)
      capability = compatibility.dig("capabilities", "flightdeck.command.mission-client-snapshot.v1")
      unless compatibility["schema_version"] == "flightdeck.hub-compatibility/v1" &&
             compatibility["product"] == "flightdeck" && capability.is_a?(Hash)
        raise MissionStore::ClientSnapshotError.new(
          "unsupported_hub_contract",
          "Selected Hub does not declare the Mission client snapshot v1 contract."
        )
      end
    end

    def doctor(config, argv)
      options = { json: false, strict: false }
      OptionParser.new do |parser|
        parser.on("--json") { options[:json] = true }
        parser.on("--strict") { options[:strict] = true }
      end.parse!(argv)
      empty!(argv)
      result = Doctor.new(config).run
      options[:json] ? json(result) : print_doctor(result)
      return 1 if result.dig("summary", "errors").positive?
      return 1 if options[:strict] && result.dig("summary", "warnings").positive?

      0
    end

    def status(config, argv)
      options = { json: false, write: false }
      OptionParser.new do |parser|
        parser.on("--json") { options[:json] = true }
        parser.on("--write") { options[:write] = true }
      end.parse!(argv)
      empty!(argv)
      result = Doctor.new(config).run
      if options[:write]
        path = File.join(config.report_dir, "STATUS.md")
        Support.atomic_write(path, status_markdown(result))
        result["report"] = Support.relative_path(config.root, path)
      end
      options[:json] ? json(result) : @out.puts(status_markdown(result))
      0
    end

    def setup(config, argv)
      subcommand = argv.shift
      options = { failure_policy: "continue", json: false }
      OptionParser.new do |parser|
        parser.on("--repositories-root PATH") { |value| options[:repositories_root] = value }
        parser.on("--failure-policy POLICY") { |value| options[:failure_policy] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--repositories-root is required" unless options[:repositories_root]

      json_output = options.delete(:json)
      store = SetupStore.new(config)
      result = case subcommand
               when "plan" then store.plan(**options)
               when "connect" then store.connect(**options)
               else raise UsageError, "setup requires plan or connect"
               end
      if json_output
        json(result)
      elsif subcommand == "plan"
        @out.puts("Repository connection preview")
        @out.puts("Root: #{result['repositories_root']}")
        @out.puts(
          "Discovered: #{result.dig('summary', 'discovered')}; " \
          "ready: #{result.dig('summary', 'ready')}; " \
          "already connected: #{result.dig('summary', 'noop')}; " \
          "blocked: #{result.dig('summary', 'blocked')}"
        )
        result["repositories"].each do |item|
          @out.puts("- #{item['repository_id']}: #{item['status']} (#{item['path']})")
          Array(item["warnings"]).each { |message| @out.puts("  note: #{message}") }
          item.fetch("blockers").each { |message| @out.puts("  blocker: #{message}") }
        end
        @out.puts("No files, repositories, projects, or Git state were changed.")
      else
        @out.puts("Repository connection: #{result['status']}")
        @out.puts(
          "Connected: #{result.dig('summary', 'connected')}; " \
          "blocked: #{result.dig('summary', 'blocked')}; " \
          "Codex projects pending: #{result.dig('summary', 'project_pending')}"
        )
        result["repositories"].each do |item|
          @out.puts("- #{item['repository_id']}: #{item['connection_status']} (#{item['path']})")
          Array(item["warnings"]).each { |message| @out.puts("  note: #{message}") }
          item.fetch("blockers").each { |message| @out.puts("  blocker: #{message}") }
        end
        @out.puts(result["next"])
      end
      subcommand == "connect" && !result["ok"] ? 1 : 0
    end

    def route(config, argv)
      raise UsageError, "route requires plan" unless argv.shift == "plan"

      options = { json: false }
      OptionParser.new do |parser|
        parser.on("--workload NAME") { |value| options[:workload_name] = value }
        parser.on("--work-type TYPE") { |value| options[:work_type] = value }
        parser.on("--repo-id ID") { |value| options[:repository_id] = value }
        parser.on("--project-key KEY") { |value| options[:project_key] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--workload and --work-type are required" unless options[:workload_name] && options[:work_type]

      json_output = options.delete(:json)
      result = RoutePlanner.new(config).plan(**options)
      if json_output
        json(result)
      else
        @out.puts("Read-only routing plan")
        @out.puts("Project: #{result['project_name']} [#{result['project_key']}] (#{result['project_path']})")
        @out.puts("Runtime project ID: #{result['runtime_project_id'] || 'pending exact-path verification'}")
        @out.puts("Mode: #{result['mode']}")
        @out.puts("Dispatch required: #{result['dispatch_required'] ? 'yes' : 'no'}")
        result["steps"].each_with_index { |step, index| @out.puts("#{index + 1}. #{step}") }
        @out.puts("No project, task, repository, or file was changed.")
      end
      0
    end

    def repo(config, argv)
      subcommand = argv.shift
      case subcommand
      when "plan" then repo_plan(config, argv)
      when "onboard" then repo_onboard(config, argv)
      else raise UsageError, "repo requires plan or onboard"
      end
    end

    def repo_plan(config, argv)
      options = { json: false }
      OptionParser.new do |parser|
        parser.on("--workload NAME") { |value| options[:workload_name] = value }
        parser.on("--provider NAME") { |value| options[:provider_name] = value }
        parser.on("--repo LOCATOR") { |value| options[:locator] = value }
        parser.on("--name NAME") { |value| options[:name] = value }
        parser.on("--owner OWNER") { |value| options[:owner] = value }
        parser.on("--default-branch BRANCH") { |value| options[:default_branch] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--workload, --provider, and --repo are required" unless options[:workload_name] && options[:provider_name] && options[:locator]

      json_output = options.delete(:json)
      result = RepoPlanner.new(config).plan(**options)
      if json_output
        json(result)
      else
        @out.puts("Read-only repository plan")
        @out.puts("Target: #{result['target']}")
        result["steps"].each_with_index { |step, index| @out.puts("#{index + 1}. #{step}") }
        @out.puts("No files, remotes, projects, or repositories were changed.")
      end
      0
    end

    def repo_onboard(config, argv)
      options = { bridge_mode: "reference", acknowledge_repo_native: false }
      OptionParser.new do |parser|
        parser.on("--workload NAME") { |value| options[:workload_name] = value }
        parser.on("--provider NAME") { |value| options[:provider_name] = value }
        parser.on("--repo LOCATOR") { |value| options[:locator] = value }
        parser.on("--id ID") { |value| options[:repository_id] = value }
        parser.on("--name NAME") { |value| options[:name] = value }
        parser.on("--url URL") { |value| options[:url] = value }
        parser.on("--owner OWNER") { |value| options[:owner] = value }
        parser.on("--default-branch BRANCH") { |value| options[:default_branch] = value }
        parser.on("--bridge-mode MODE") { |value| options[:bridge_mode] = value }
        parser.on("--bridge-profile PROFILE") { |value| options[:bridge_profile] = value }
        parser.on("--acknowledge-repo-native") { options[:acknowledge_repo_native] = true }
      end.parse!(argv)
      empty!(argv)
      required = %i[workload_name provider_name locator repository_id]
      raise UsageError, required.map { |item| "--#{item.to_s.tr('_', '-')}" }.join(", ") + " are required" unless required.all? { |item| options[item] }

      result = RepositoryStore.new(config).onboard(**options)
      json(result)
      0
    end

    def bridge(config, argv)
      subcommand = argv.shift
      options = {
        mode: nil,
        profile: nil,
        all: false,
        failure_policy: "stop",
        acknowledge_repo_native: false,
        authorize_repo_native: [],
        json: false
      }
      OptionParser.new do |parser|
        parser.on("--repo-id ID") { |value| options[:repository_id] = value }
        parser.on("--mode MODE") { |value| options[:mode] = value }
        parser.on("--profile PROFILE") { |value| options[:profile] = value }
        parser.on("--all") { options[:all] = true }
        parser.on("--failure-policy POLICY") { |value| options[:failure_policy] = value }
        parser.on("--acknowledge-repo-native") { options[:acknowledge_repo_native] = true }
        parser.on("--authorize-repo-native ID") { |value| options[:authorize_repo_native] << value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      if options[:all] == !!options[:repository_id]
        raise UsageError, "choose exactly one of --repo-id or --all"
      end
      if options[:all] && (options[:mode] || options[:profile] || options[:acknowledge_repo_native])
        raise UsageError, "--all reads mode and profile from declarations; use --authorize-repo-native ID per repository"
      end
      json_output = options.delete(:json)
      if options.delete(:all)
        failure_policy = options.delete(:failure_policy)
        authorize = options.delete(:authorize_repo_native)
        result = case subcommand
                 when "plan"
                   BridgeBulkStore.new(config).plan(failure_policy: failure_policy)
                 when "install"
                   BridgeBulkStore.new(config).install_all(
                     failure_policy: failure_policy,
                     authorize_repo_native: authorize
                   )
                 else raise UsageError, "bridge requires plan or install"
                 end
      else
        options.delete(:failure_policy)
        options.delete(:authorize_repo_native)
        options[:mode] ||= "reference"
        result = case subcommand
                 when "plan"
                   options.delete(:acknowledge_repo_native)
                   BridgeStore.new(config).plan(**options)
                 when "install"
                   BridgeStore.new(config).install(**options)
                 else raise UsageError, "bridge requires plan or install"
                 end
      end
      json_output ? json(result) : result.each { |key, value| @out.puts("#{key}: #{value}") }
      result.is_a?(Hash) && result.key?("ok") && !result["ok"] ? 1 : 0
    end

    def task(config, argv)
      subcommand = argv.shift
      store = TaskStore.new(config)
      case subcommand
      when "new"
        type = argv.shift
        slug = argv.shift
        raise UsageError, "task new requires TYPE and SLUG" unless type && slug
        options = {}
        OptionParser.new do |parser|
          parser.on("--title TITLE") { |value| options[:title] = value }
          parser.on("--outcome OUTCOME") { |value| options[:outcome] = value }
          parser.on("--workload NAME") { |value| options[:workload] = value }
        end.parse!(argv)
        empty!(argv)
        raise UsageError, "--title and --outcome are required" unless options[:title] && options[:outcome]
        value = store.create(type: type, slug: slug, **options)
        @out.puts("Created task #{value.dig('metadata', 'id')} in state #{value.dig('status', 'state')}.")
      when "show"
        slug = argv.shift
        raise UsageError, "task show requires SLUG" unless slug
        json(store.fetch(slug))
      when "validate"
        slug = argv.shift
        raise UsageError, "task validate requires SLUG" unless slug
        errors = store.validate(slug)
        errors.each { |message| @err.puts("ERROR #{slug}: #{message}") }
        return errors.empty? ? 0 : 1
      when "transition"
        slug = argv.shift
        state = argv.shift
        raise UsageError, "task transition requires SLUG and STATE" unless slug && state
        options = {}
        OptionParser.new { |parser| parser.on("--note NOTE") { |value| options[:note] = value } }.parse!(argv)
        empty!(argv)
        value = store.transition(slug: slug, state: state, **options)
        @out.puts("Transitioned #{slug} to #{value.dig('status', 'state')}.")
      else
        raise UsageError, "task requires new, show, validate, or transition"
      end
      0
    end

    def mission(config, argv)
      subcommand = argv.shift
      if %w[objective-plan objective-create objective-snapshot].include?(subcommand)
        return mission_objective(config, subcommand, argv)
      end
      if %w[authoring-catalog authoring-plan authoring-create authoring-operation].include?(subcommand)
        return mission_authoring(config, subcommand, argv)
      end
      return mission_skill_telemetry(config, argv) if subcommand == "skill-telemetry"
      store = MissionStore.new(config)
      case subcommand
      when "new"
        slug = required_argument!(argv, "mission new requires SLUG")
        options = { json: false, success_criteria: [], non_goals: [], authorized_targets: [] }
        OptionParser.new do |parser|
          parser.on("--title TITLE") { |value| options[:title] = value }
          parser.on("--outcome OUTCOME") { |value| options[:outcome] = value }
          parser.on("--success-criterion TEXT") { |value| options[:success_criteria] << value }
          parser.on("--non-goal TEXT") { |value| options[:non_goals] << value }
          parser.on("--mode MODE") { |value| options[:mode] = value }
          parser.on("--parent-chat-id ID") { |value| options[:parent_chat_id] = value }
          parser.on("--authorized-target-json JSON") do |value|
            options[:authorized_targets] << parse_json_option!(value, "--authorized-target-json")
          end
          parser.on("--json") { options[:json] = true }
        end.parse!(argv)
        empty!(argv)
        raise UsageError, "--title and --outcome are required" unless options[:title] && options[:outcome]
        selected_mode = (options[:mode] || config.mission_defaults.fetch("default_mode", "dispatch_only")).to_s
        raise UsageError, "unknown mission mode: #{selected_mode}" unless MissionStore::MODES.include?(selected_mode)
        if selected_mode != "dispatch_only" && options[:success_criteria].empty?
          raise UsageError, "at least one --success-criterion is required for #{selected_mode} missions"
        end
        if selected_mode != "dispatch_only" && options[:authorized_targets].empty?
          raise UsageError, "at least one --authorized-target-json is required for #{selected_mode} missions"
        end
        json_output = options.delete(:json)
        emit_mission(store.create(slug: slug, **options), json_output, "Created mission #{slug}.")
      when "show"
        slug, json_output = mission_slug_with_json(argv, "mission show requires SLUG")
        emit_mission(store.snapshot(slug), json_output, "Mission #{slug}.")
      when "status"
        slug, json_output = mission_slug_with_json(argv, "mission status requires SLUG")
        emit_mission(store.status(slug), json_output, "Mission #{slug} status: #{store.status(slug).dig('status', 'state')}.")
      when "operation"
        slug, json_output = mission_slug_with_json(argv, "mission operation requires SLUG")
        raise UsageError, "mission operation requires --json" unless json_output
        json(store.operation_projection(slug))
      when "validate"
        slug, json_output = mission_slug_with_json(argv, "mission validate requires SLUG")
        errors = store.validate(slug)
        value = { "mission_id" => slug, "ok" => errors.empty?, "errors" => errors }
        if json_output
          json(value)
        else
          errors.each { |message| @err.puts("ERROR #{slug}: #{message}") }
          @out.puts("Mission #{slug} is valid.") if errors.empty?
        end
        return errors.empty? ? 0 : 1
      when "add"
        slug = required_argument!(argv, "mission add requires SLUG and NODE")
        node_id = required_argument!(argv, "mission add requires SLUG and NODE")
        options = { required: nil, dependencies: [], accepted_input_types: [], allowed_output_types: [], criterion_ids: nil, json: false }
        OptionParser.new do |parser|
          parser.on("--project-key KEY") { |value| options[:logical_project_key] = value }
          parser.on("--project-path PATH") { |value| options[:project_path] = value }
          parser.on("--project-path-digest SHA256") { |value| options[:project_path_digest] = value }
          parser.on("--runtime-project-id ID") { |value| options[:runtime_project_id] = value }
          parser.on("--host-id ID") { |value| options[:host_id] = value }
          parser.on("--execution-mode MODE") { |value| options[:execution_mode] = value }
          parser.on("--access-mode MODE") { |value| options[:access_mode] = value }
          parser.on("--work-type TYPE") { |value| options[:work_type] = value }
          parser.on("--required") { options[:required] = true }
          parser.on("--optional") { options[:required] = false }
          parser.on("--depends-on NODE") { |value| options[:dependencies] << value }
          parser.on("--accepts TYPE") { |value| options[:accepted_input_types] << value }
          parser.on("--allows-output TYPE") { |value| options[:allowed_output_types] << value }
          parser.on("--criterion-id ID") { |value| (options[:criterion_ids] ||= []) << value }
          parser.on("--artifact-resolver-kind KIND") { |value| options[:artifact_resolver_kind] = value }
          parser.on("--artifact-resolver-id ID") { |value| options[:artifact_resolver_id] = value }
          parser.on("--json") { options[:json] = true }
        end.parse!(argv)
        empty!(argv)
        required = %i[logical_project_key runtime_project_id host_id execution_mode access_mode work_type]
        raise UsageError, "--project-key, --runtime-project-id, --host-id, --execution-mode, --access-mode, and --work-type are required" unless required.all? { |key| options[key] }
        raise UsageError, "choose exactly one of --required or --optional" if options[:required].nil?
        json_output = options.delete(:json)
        emit_mission(store.add_node(slug: slug, node_id: node_id, **options), json_output, "Added mission node #{node_id}.")
      when "record-dispatch"
        slug = required_argument!(argv, "mission record-dispatch requires SLUG and NODE")
        node_id = required_argument!(argv, "mission record-dispatch requires SLUG and NODE")
        options = { dispatch_unknown: false, json: false }
        OptionParser.new do |parser|
          parser.on("--runtime-project-id ID") { |value| options[:runtime_project_id] = value }
          parser.on("--host-id ID") { |value| options[:host_id] = value }
          parser.on("--task-id ID") { |value| options[:task_id] = value }
          parser.on("--pending-client-id ID") { |value| options[:pending_client_id] = value }
          parser.on("--project-path PATH") { |value| options[:project_path] = value }
          parser.on("--project-path-digest SHA256") { |value| options[:project_path_digest] = value }
          parser.on("--dispatch-unknown") { options[:dispatch_unknown] = true }
          parser.on("--json") { options[:json] = true }
        end.parse!(argv)
        empty!(argv)
        raise UsageError, "--runtime-project-id and --host-id are required" unless options[:runtime_project_id] && options[:host_id]
        json_output = options.delete(:json)
        emit_mission(store.record_dispatch(slug: slug, node_id: node_id, **options), json_output, "Recorded dispatch for #{node_id}.")
      when "sync-plan", "sync-apply"
        slug = required_argument!(argv, "mission #{subcommand} requires SLUG")
        options = { json: false }
        OptionParser.new do |parser|
          parser.on("--observations FILE") { |value| options[:observations_path] = value }
          parser.on("--plan-token SHA256") { |value| options[:plan_token] = value }
          parser.on("--json") { options[:json] = true }
        end.parse!(argv)
        empty!(argv)
        raise UsageError, "--observations is required" unless options[:observations_path]
        if subcommand == "sync-apply" && !options[:plan_token]
          raise UsageError, "--plan-token from sync-plan is required for sync-apply"
        end
        options.delete(:plan_token) if subcommand == "sync-plan"
        json_output = options.delete(:json)
        sync = MissionSync.new(store)
        value = subcommand == "sync-plan" ? sync.plan(slug: slug, **options) : sync.apply(slug: slug, **options)
        emit_mission(value, json_output, "Mission #{subcommand} completed for #{slug}.")
      when "checkpoint"
        slug, json_output = mission_slug_with_json(argv, "mission checkpoint requires SLUG")
        emit_mission(store.checkpoint(slug), json_output, "Checkpointed mission #{slug}.")
      when "outbox"
        slug, json_output = mission_slug_with_json(argv, "mission outbox requires SLUG")
        value = { "mission_id" => slug, "actions" => store.outbox_for(slug) }
        emit_mission(value, json_output, "Mission #{slug} outbox has #{value['actions'].length} action(s).")
      when "next-actions"
        slug, json_output = mission_slug_with_json(argv, "mission next-actions requires SLUG")
        value = { "mission_id" => slug, "actions" => store.next_actions(slug) }
        emit_mission(value, json_output, "Mission #{slug} has #{value['actions'].length} next action(s).")
      when "prepare", "acknowledge"
        slug = required_argument!(argv, "mission #{subcommand} requires SLUG and ACTION_ID")
        action_id = required_argument!(argv, "mission #{subcommand} requires SLUG and ACTION_ID")
        _unused, json_output = mission_slug_with_json([slug, *argv], "")
        value = subcommand == "prepare" ? store.prepare_action(slug: slug, action_id: action_id) : store.acknowledge_action(slug: slug, action_id: action_id)
        emit_mission(value, json_output, "Mission action #{action_id} #{subcommand}d.")
      when "fail"
        slug = required_argument!(argv, "mission fail requires SLUG and ACTION_ID")
        action_id = required_argument!(argv, "mission fail requires SLUG and ACTION_ID")
        options = { json: false }
        OptionParser.new do |parser|
          parser.on("--code CODE") { |value| options[:code] = value }
          parser.on("--json") { options[:json] = true }
        end.parse!(argv)
        empty!(argv)
        raise UsageError, "--code is required" unless options[:code]
        json_output = options.delete(:json)
        emit_mission(store.fail_action(slug: slug, action_id: action_id, **options), json_output, "Mission action #{action_id} failed.")
      when "close"
        slug, json_output = mission_slug_with_json(argv, "mission close requires SLUG")
        emit_mission(store.close(slug), json_output, "Explicitly closed mission #{slug}.")
      else
        raise UsageError, "mission requires new, show, validate, status, operation, skill-telemetry, add, record-dispatch, sync-plan, sync-apply, checkpoint, outbox, next-actions, prepare, acknowledge, fail, or close"
      end
      0
    end

    def mission_objective(config, subcommand, argv)
      options = {}
      OptionParser.new do |parser|
        parser.on("--request FILE") { |value| options[:request_path] = value }
        parser.on("--json") { |value| options[:json] = value }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--request is required" unless options[:request_path]

      request = MissionObjectives.load_request(options.fetch(:request_path))
      objectives = MissionObjectives.new(config)
      result = case subcommand
               when "objective-plan" then objectives.plan(request)
               when "objective-create" then objectives.create(request)
               when "objective-snapshot" then objectives.snapshot(request)
               end
      json(result)
      0
    rescue UsageError, ValidationError => e
      json(MissionObjectives.error_result(e))
      1
    rescue StandardError
      json(MissionObjectives.error_result(MissionObjectives::ContractError.new("internal_error", "Mission objective operation failed closed")))
      1
    end

    def mission_skill_telemetry(config, argv)
      operation_id = required_argument!(argv, "mission skill-telemetry requires SLUG")
      options = { limit: SkillTelemetry::DEFAULT_LIMIT }
      OptionParser.new do |parser|
        parser.on("--limit N", Integer) { |value| options[:limit] = value }
        parser.on("--cursor CURSOR") { |value| options[:cursor] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      json(SkillTelemetry.new(config).snapshot(operation_id: operation_id, limit: options[:limit], cursor: options[:cursor]))
      0
    rescue SkillTelemetry::ContractError => e
      error = { "code" => e.code, "message" => e.message }
      error["operation_id"] = e.operation_id if e.operation_id
      json(
        "api_version" => SkillTelemetry::API_VERSION,
        "kind" => "MissionSkillTelemetryError",
        "schema" => SkillTelemetry::SCHEMA,
        "capability" => SkillTelemetry::CAPABILITY,
        "ok" => false,
        "error" => error
      )
      1
    rescue UsageError, OptionParser::ParseError
      json(
        "api_version" => SkillTelemetry::API_VERSION,
        "kind" => "MissionSkillTelemetryError",
        "schema" => SkillTelemetry::SCHEMA,
        "capability" => SkillTelemetry::CAPABILITY,
        "ok" => false,
        "error" => { "code" => "invalid_request", "message" => "Skill telemetry request is invalid." }
      )
      2
    end

    def operation(config, argv)
      subcommand = argv.shift
      names = %w[
        authoring-catalog authoring-plan authoring-launch authoring-guidance authoring-operation detail
        execution-plan execution-bind execution-observe execution-open
      ]
      raise UsageError, "operation requires #{names.join(', ')}" unless names.include?(subcommand)

      options = {}
      OptionParser.new do |parser|
        parser.on("--request FILE") { |value| options[:request_path] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--request is required" unless options[:request_path]

      if subcommand == "detail"
        request = OperationDetail.load_request(options.fetch(:request_path))
        json(OperationDetail.new(config).detail(request))
        return 0
      end

      execution_command = subcommand.to_s.start_with?("execution-")
      request = execution_command ? OmpOperationExecution.load_request(options.fetch(:request_path)) : OperationAuthoring.load_request(options.fetch(:request_path))
      authoring = OperationAuthoring.new(config)
      execution = OmpOperationExecution.new(config)
      result = case subcommand
               when "authoring-catalog" then authoring.catalog(request)
               when "authoring-plan" then authoring.plan(request)
               when "authoring-launch" then authoring.launch(request)
               when "authoring-guidance" then authoring.guidance(request)
               when "authoring-operation" then authoring.operation(request)
               when "execution-plan" then execution.plan(request)
               when "execution-bind" then execution.bind(request)
               when "execution-observe" then execution.observe(request)
               when "execution-open" then execution.open(request)
               end
      json(result)
      0
    rescue UsageError, ValidationError => e
      if subcommand == "detail"
        json(OperationDetail.error_result(e))
      elsif subcommand.to_s.start_with?("execution-")
        json(OmpOperationExecution.error_result(subcommand, e))
      else
        json(OperationAuthoring.error_result(subcommand.to_s.delete_prefix("authoring-"), e))
      end
      1
    rescue StandardError
      if subcommand == "detail"
        json(OperationDetail.error_result(OperationDetail::ContractError.new("internal_error", "Operation detail failed closed")))
        return 1
      end
      if subcommand.to_s.start_with?("execution-")
        error = OmpOperationExecution::ContractError.new("internal_error", "OMP Operation command failed closed")
        json(OmpOperationExecution.error_result(subcommand, error))
      else
        error = OperationAuthoring::ContractError.new(
          "internal_error",
          subcommand == "authoring-launch" ?
            "Operation launch failed closed; recover only with the original operation ID" :
            "Operation authoring failed closed"
        )
        json(OperationAuthoring.error_result(subcommand.to_s.delete_prefix("authoring-"), error))
      end
      1
    end

    def work_list(argv)
      options = { limit: WorkStore::DEFAULT_LIMIT }
      OptionParser.new do |parser|
        parser.on("--hub-root PATH") { |value| options[:hub_root] = value }
        parser.on("--limit N", Integer) { |value| options[:limit] = value }
        parser.on("--cursor CURSOR") { |value| options[:cursor] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      selected_root = options.fetch(:hub_root).to_s
      unless Pathname.new(selected_root).absolute? && File.directory?(selected_root)
        raise WorkStore::ContractError.new("invalid_hub_root", "Selected Hub root is unavailable")
      end
      config = Config.new(root: selected_root)
      unless config.data["api_version"] == "flightdeck.dev/v1alpha1" && config.data["kind"] == "FlightdeckRegistry" &&
             config.data["schema"] == "hub/schemas/flightdeck.schema.json"
        raise WorkStore::ContractError.new("invalid_hub_root", "Selected Hub root is not a Flightdeck Hub")
      end
      json(WorkStore.new(config).list_page(limit: options[:limit], cursor: options[:cursor]))
      0
    rescue KeyError, UsageError, OptionParser::ParseError
      json(WorkStore.error_result("list", WorkStore::ContractError.new("malformed_request", "Work list request is invalid")))
      2
    rescue WorkStore::ContractError => e
      json(WorkStore.error_result("list", e))
      1
    rescue ConfigurationError, ValidationError, SystemCallError
      json(WorkStore.error_result("list", WorkStore::ContractError.new("invalid_hub_root", "Selected Hub root is not a valid Flightdeck Hub")))
      1
    end

    def work(config, argv)
      subcommand = argv.shift
      names = %w[create adapter-bind open coordinate launch decline lifecycle-open dispatch-plan dispatch-report guidance]
      raise UsageError, "work requires #{names.join(', ')}" unless names.include?(subcommand)

      options = {}
      OptionParser.new do |parser|
        parser.on("--request FILE") { |value| options[:request_path] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--request is required" unless options[:request_path]

      request = WorkStore.load_request(options.fetch(:request_path))
      store = WorkStore.new(config)
      result = case subcommand
               when "create" then store.create(request)
               when "adapter-bind" then store.bind_adapter(request)
               when "open" then store.open(request)
               when "coordinate" then store.coordinate(request)
               when "launch" then store.launch(request)
               when "decline" then store.decline(request)
               when "lifecycle-open" then store.lifecycle_open(request)
               when "dispatch-plan" then store.dispatch_plan(request)
               when "dispatch-report" then store.dispatch_report(request)
               when "guidance" then store.guidance(request)
               end
      json(result)
      0
    rescue UsageError, ValidationError => e
      operation = names&.include?(subcommand) ? subcommand : "open"
      json(WorkStore.error_result(operation, e))
      1
    rescue StandardError
      operation = names&.include?(subcommand) ? subcommand : "open"
      json(WorkStore.error_result(operation, WorkStore::ContractError.new("internal_error", "Work operation failed closed")))
      1
    end

    def mission_authoring(config, subcommand, argv)
      options = { json: false }
      OptionParser.new do |parser|
        parser.on("--request FILE") { |value| options[:request_path] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--request is required" unless options[:request_path]

      request = MissionAuthoring.load_request(options.fetch(:request_path))
      authoring = MissionAuthoring.new(config)
      result = case subcommand
               when "authoring-catalog" then authoring.catalog(request)
               when "authoring-plan" then authoring.plan(request)
               when "authoring-create" then authoring.create(request)
               when "authoring-operation" then authoring.operation(request)
               end
      json(result)
      0
    rescue UsageError, ValidationError => e
      json(MissionAuthoring.error_result(subcommand.to_s.delete_prefix("authoring-"), e))
      1
    rescue StandardError
      message = if subcommand == "authoring-create"
                  "Mission authoring create failed closed; recover only with its original operation ID"
                else
                  "Mission authoring #{subcommand.to_s.delete_prefix('authoring-')} failed closed"
                end
      error = MissionAuthoring::ContractError.new(
        "internal_error",
        message
      )
      json(MissionAuthoring.error_result(subcommand.to_s.delete_prefix("authoring-"), error))
      1
    end

    def help
      @out.puts <<~HELP
        Flightdeck command line

        Usage:
          bin/flightdeck help
          bin/flightdeck doctor [--json] [--strict]
          bin/flightdeck status [--json] [--write]
          bin/flightdeck hub snapshot --hub-root ABSOLUTE_PATH [--json]
          bin/flightdeck hub operations-snapshot --hub-root ABSOLUTE_PATH [--json]
          bin/flightdeck work list --hub-root ABSOLUTE_PATH [--limit 1..100] [--cursor CURSOR] [--json]
          bin/flightdeck work create --request FILE [--json]
          bin/flightdeck work adapter-bind --request FILE [--json]
          bin/flightdeck work open --request FILE [--json]
          bin/flightdeck work coordinate --request FILE [--json]
          bin/flightdeck work launch --request FILE [--json]
          bin/flightdeck work decline --request FILE [--json]
          bin/flightdeck work lifecycle-open --request FILE [--json]
          bin/flightdeck work dispatch-plan --request FILE [--json]
          bin/flightdeck work dispatch-report --request FILE [--json]
          bin/flightdeck work guidance --request FILE [--json]
          bin/flightdeck operation detail --request FILE [--json]
          bin/flightdeck mission objective-plan --request FILE [--json]
          bin/flightdeck mission objective-create --request FILE [--json]
          bin/flightdeck mission objective-snapshot --request FILE [--json]
          bin/flightdeck setup plan --repositories-root PATH [--failure-policy stop|continue] [--json]
          bin/flightdeck setup connect --repositories-root PATH [--failure-policy stop|continue] [--json]
          bin/flightdeck route plan --workload NAME --work-type TYPE [--repo-id ID] [--project-key KEY] [--json]
          bin/flightdeck repo plan --workload NAME --provider NAME --repo LOCATOR [--name NAME] [--owner OWNER] [--default-branch BRANCH] [--json]
          bin/flightdeck repo onboard --workload NAME --provider NAME --repo LOCATOR --id ID [--name NAME] [--url URL] [--owner OWNER] [--default-branch BRANCH] [--bridge-mode MODE] [--acknowledge-repo-native]
          bin/flightdeck bridge plan --repo-id ID [--mode MODE] [--profile PROFILE] [--json]
          bin/flightdeck bridge plan --all [--failure-policy stop|continue] [--json]
          bin/flightdeck bridge install --repo-id ID [--mode MODE] [--profile PROFILE] [--acknowledge-repo-native] [--json]
          bin/flightdeck bridge install --all [--failure-policy stop|continue] [--authorize-repo-native ID] [--json]
          bin/flightdeck task new TYPE SLUG --title TITLE --outcome OUTCOME [--workload NAME]
          bin/flightdeck task show SLUG
          bin/flightdeck task validate SLUG
          bin/flightdeck task transition SLUG STATE [--note NOTE]
          bin/flightdeck mission new SLUG --title TITLE --outcome OUTCOME [--success-criterion TEXT] [--non-goal TEXT] [--authorized-target-json JSON] [--mode dispatch_only|watch_only|supervised] [--parent-chat-id OPAQUE_ID] [--json]
          bin/flightdeck mission list --hub-root ABSOLUTE_PATH [--limit 1..100] [--cursor CURSOR] [--json]
          bin/flightdeck mission client-snapshot --hub-root ABSOLUTE_PATH --mission SLUG --parent-chat-id OPAQUE_ID [--json]
          bin/flightdeck mission show SLUG [--json]
          bin/flightdeck mission validate SLUG [--json]
          bin/flightdeck mission status SLUG [--json]
          bin/flightdeck mission operation SLUG --json
          bin/flightdeck mission skill-telemetry SLUG [--limit 1..100] [--cursor CURSOR] [--json]
          bin/flightdeck mission authoring-catalog --request FILE [--json]
          bin/flightdeck mission authoring-plan --request FILE [--json]
          bin/flightdeck mission authoring-create --request FILE [--json]
          bin/flightdeck mission authoring-operation --request FILE [--json]
          bin/flightdeck operation authoring-catalog --request FILE [--json]
          bin/flightdeck operation authoring-plan --request FILE [--json]
          bin/flightdeck operation authoring-launch --request FILE [--json]
          bin/flightdeck operation authoring-guidance --request FILE [--json]
          bin/flightdeck operation authoring-operation --request FILE [--json]
          bin/flightdeck operation execution-plan --request FILE [--json]
          bin/flightdeck operation execution-bind --request FILE [--json]
          bin/flightdeck operation execution-observe --request FILE [--json]
          bin/flightdeck operation execution-open --request FILE [--json]
          bin/flightdeck mission add SLUG NODE --project-key KEY --runtime-project-id ID (--project-path PATH|--project-path-digest SHA256) --host-id HOST --execution-mode local|worktree --access-mode read_only|write --work-type TYPE (--required|--optional) [--criterion-id ID] [--depends-on NODE] [--accepts TYPE] --allows-output TYPE [--artifact-resolver-kind same_host_workspace|external_approved --artifact-resolver-id ID] [--json]
          bin/flightdeck mission record-dispatch SLUG NODE --runtime-project-id ID --host-id HOST [--task-id ID [--pending-client-id ID]|--pending-client-id ID|--dispatch-unknown] [--project-path PATH|--project-path-digest SHA256] [--json]
          bin/flightdeck mission sync-plan SLUG --observations FILE [--json]
          bin/flightdeck mission sync-apply SLUG --observations FILE --plan-token SHA256 [--json]
          bin/flightdeck mission checkpoint SLUG [--json]
          bin/flightdeck mission outbox SLUG [--json]
          bin/flightdeck mission next-actions SLUG [--json]
          bin/flightdeck mission prepare SLUG ACTION_ID [--json]
          bin/flightdeck mission acknowledge SLUG ACTION_ID [--json]
          bin/flightdeck mission fail SLUG ACTION_ID --code CODE [--json]
          bin/flightdeck mission close SLUG [--json]

        doctor, status, hub snapshot, hub operations-snapshot, work list, work open, work lifecycle-open,
        work dispatch-plan, operation detail, setup plan, route plan, repo plan,
        bridge plan, mission list, mission client-snapshot, mission show, mission validate, mission status, mission operation,
        mission skill-telemetry, mission authoring-catalog, mission
        authoring-plan, mission authoring-operation, mission objective-plan, mission objective-snapshot,
        mission sync-plan, mission outbox, mission next-actions, operation authoring-catalog,
        operation authoring-plan, operation authoring-operation, and operation execution-open are read-only.
        status --write, setup connect, repo onboard, bridge install, task new,
        task transition, mission authoring-create, mission objective-create, and other mission mutations use
        explicit state-changing names and write only their documented scope.
        Mission authoring commands accept only their closed versioned JSON request
        schemas and always emit a closed JSON result. Create requires the exact
        current plan identity, generation, digest, token, and one opaque operation ID.
        Never retry an unknown authoring-create result; query authoring-operation
        with the original operation ID.
        Operation authoring uses server-authored Operation IDs and exact catalog target identities.
        It creates a durable planned Operation only; it never dispatches a task or claims task, skill,
        or work success. Never retry an unknown authoring-launch result; query
        operation authoring-operation with the original operation ID.
        OMP Operation execution is a separate post-confirmation runtime boundary. execution-plan
        revalidates the exact launched Work proposal and current dispatch authorization; execution-bind
        binds stable Flightdeck agents to opaque OMP sessions; execution-observe accepts only signed,
        bounded, renderer-safe observations. These commands never replace the Codex conversation adapter.
        Work stores selected-Hub display metadata and normalized event links only. It never stores
        prompts, responses, commands, tool payloads, paths, or renderer-visible runtime project/task IDs.
        work create is the ordinary runtime handoff and requires no classification or extra model turn.
        work adapter-bind returns a native-only secret that must never cross renderer IPC. work coordinate
        accepts only an HMAC-authenticated exact Hub/Work/session/resume-bound adapter observation; logical
        project keys are re-resolved against the exact current Hub catalog and produce a review-only proposal.
        work launch and work decline require the exact stored Operation plan confirmation. A decline is
        durable and never dispatches. Unknown launch outcomes are recovered through work lifecycle-open and
        are never blindly resubmitted. work dispatch-plan authorizes exact targets only after launch and
        requires independent targets to be dispatched concurrently by an independently authorized native
        owner; it does not dispatch. work dispatch-report persists exact deduplicated receipts and partial
        failures. work guidance requires the exact
        active nonterminal Operation ID; an ordinary follow-up is never inferred to be guidance.
        Mission mode defaults to dispatch_only; only watch_only and supervised accept explicit sync.
        watch_only and supervised require explicit --success-criterion and --authorized-target-json.
        dispatch_only derives one success criterion from --outcome when none is supplied.
        Repeat --success-criterion and --non-goal to persist multiple bounded intent entries.
        Authorized target JSON is a closed exact scope for logical/runtime project, path digest,
        host, execution mode, and access mode; core derives the authorization boundary token.
        --parent-chat-id is an operator-only creation-time binding for the read-only Mission
        client snapshot. It is stored only as a SHA-256 digest and cannot be added or changed later.
        Artifact resolver kind and ID are optional as a pair and bind reference resolution only.
        Mission graph nodes may be added only while fully planned. After any dispatch,
        observation, or outbox action, create a new mission for newly discovered owners.
        A recorded pending client is not waitable. Reconcile it with BOTH
        --pending-client-id ORIGINAL and --task-id RESOLVED; task-only reconciliation is rejected.
      HELP
      0
    end

    def print_doctor(result)
      summary = result.fetch("summary")
      @out.puts("Flightdeck doctor: #{summary['errors']} error(s), #{summary['warnings']} warning(s)")
      result.fetch("issues").each do |item|
        @out.puts("#{item['severity'].upcase} [#{item['code']}] #{item['scope']}: #{item['message']}")
      end
      @out.puts("Checked #{summary['repositories']} repositories, #{summary['tasks']} tasks, #{summary['missions']} missions, #{summary['bridges']} bridges, and #{summary['compliance_pairs']} compliance sidecar pairs.")
      @out.puts("Repository ahead/behind values use local tracking refs; Doctor does not fetch.")
    end

    def status_markdown(result)
      summary = result.fetch("summary")
      lines = [
        "# Flightdeck Status",
        "",
        "Generated: #{result['generated_at']}",
        "",
        "- Errors: #{summary['errors']}",
        "- Warnings: #{summary['warnings']}",
        "- Repositories: #{summary['repositories']}",
        "- Tasks: #{summary['tasks']}",
        "- Missions: #{summary['missions']}",
        "- Bridges: #{summary['bridges']}",
        "",
        "Ahead and behind values use local tracking refs; no fetch was performed.",
        "",
        "## Findings",
        ""
      ]
      lines.concat(result["issues"].empty? ? ["None."] : result["issues"].map do |item|
        "- **#{item['severity'].upcase}** `#{item['code']}` #{item['scope']}: #{item['message']}"
      end)
      "#{lines.join("\n")}\n"
    end

    def json(value)
      @out.puts(JSON.pretty_generate(value))
    end

    def empty!(argv)
      raise UsageError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    end

    def required_argument!(argv, message)
      argv.shift || raise(UsageError, message)
    end

    def mission_slug_with_json(argv, message)
      arguments = argv.dup
      slug = required_argument!(arguments, message)
      options = { json: false }
      OptionParser.new { |parser| parser.on("--json") { options[:json] = true } }.parse!(arguments)
      empty!(arguments)
      [slug, options[:json]]
    end

    def emit_mission(value, json_output, message)
      json_output ? json(value) : @out.puts(message)
    end

    def emit_mission_list_error(code, message, mission_id: nil)
      error = { "code" => code, "message" => message }
      error["mission_id"] = mission_id if mission_id
      json(
        "api_version" => MissionStore::LIST_API_VERSION,
        "kind" => "MissionListError",
        "schema" => MissionStore::LIST_SCHEMA,
        "ok" => false,
        "error" => error
      )
    end

    def emit_hub_snapshot_error(code, message)
      json(
        "api_version" => HubSnapshot::API_VERSION,
        "kind" => "HubSnapshotError",
        "schema" => HubSnapshot::SCHEMA,
        "ok" => false,
        "error" => { "code" => code, "message" => message }
      )
    end

    def emit_operations_snapshot_error(code, message)
      json(
        "api_version" => OperationsSnapshot::API_VERSION,
        "kind" => "OperationsSnapshotError",
        "schema" => OperationsSnapshot::SCHEMA,
        "ok" => false,
        "error" => { "code" => code, "message" => message }
      )
    end

    def emit_mission_client_snapshot_error(code, message)
      json(
        "api_version" => MissionStore::CLIENT_SNAPSHOT_API_VERSION,
        "kind" => "MissionClientSnapshotError",
        "schema" => MissionStore::CLIENT_SNAPSHOT_SCHEMA,
        "ok" => false,
        "error" => { "code" => code, "message" => message },
        "recovery" => { "mode" => "manual_recovery_required" }
      )
    end

    def parse_json_option!(value, label)
      parsed = JSON.parse(value)
      raise UsageError, "#{label} must contain one JSON object" unless parsed.is_a?(Hash)

      Support.stringify(parsed)
    rescue JSON::ParserError => e
      raise UsageError, "#{label} is invalid JSON: #{e.message}"
    end
  end
end
