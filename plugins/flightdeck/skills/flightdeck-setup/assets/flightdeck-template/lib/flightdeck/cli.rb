# frozen_string_literal: true

require "optparse"
require_relative "bridge_bulk_store"
require_relative "doctor"
require_relative "mission_authoring"
require_relative "mission_sync"
require_relative "repo_planner"
require_relative "repository_store"
require_relative "route_planner"
require_relative "setup_store"

module Flightdeck
  class CLI
    def initialize(root:, out: $stdout, err: $stderr)
      @root = root
      @out = out
      @err = err
    end

    def run(argv)
      arguments = argv.dup
      command = arguments.shift || "help"
      return help if %w[help -h --help].include?(command)

      config = Config.new(root: @root)
      case command
      when "doctor" then doctor(config, arguments)
      when "status" then status(config, arguments)
      when "setup" then setup(config, arguments)
      when "route" then route(config, arguments)
      when "repo" then repo(config, arguments)
      when "bridge" then bridge(config, arguments)
      when "task" then task(config, arguments)
      when "mission" then mission(config, arguments)
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
      if %w[authoring-catalog authoring-plan authoring-create authoring-operation].include?(subcommand)
        return mission_authoring(config, subcommand, argv)
      end
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
        raise UsageError, "mission requires new, show, validate, status, add, record-dispatch, sync-plan, sync-apply, checkpoint, outbox, next-actions, prepare, acknowledge, fail, or close"
      end
      0
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
      error = MissionAuthoring::ContractError.new(
        "internal_error",
        "Mission authoring failed closed; recover a create only with its original operation ID"
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
          bin/flightdeck mission new SLUG --title TITLE --outcome OUTCOME [--success-criterion TEXT] [--non-goal TEXT] [--authorized-target-json JSON] [--mode dispatch_only|watch_only|supervised] [--json]
          bin/flightdeck mission show SLUG [--json]
          bin/flightdeck mission validate SLUG [--json]
          bin/flightdeck mission status SLUG [--json]
          bin/flightdeck mission authoring-catalog --request FILE [--json]
          bin/flightdeck mission authoring-plan --request FILE [--json]
          bin/flightdeck mission authoring-create --request FILE [--json]
          bin/flightdeck mission authoring-operation --request FILE [--json]
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

        doctor, status, setup plan, route plan, repo plan, bridge plan, mission show,
        mission validate, mission status, mission authoring-catalog, mission
        authoring-plan, mission authoring-operation, mission sync-plan, mission
        outbox, and mission next-actions are read-only.
        status --write, setup connect, repo onboard, bridge install, task new,
        task transition, mission authoring-create, and other mission mutations use
        explicit state-changing names and write only their documented scope.
        Mission authoring commands accept only their closed versioned JSON request
        schemas and always emit a closed JSON result. Create requires the exact
        current plan identity, generation, digest, token, and one opaque operation ID.
        Never retry an unknown authoring-create result; query authoring-operation
        with the original operation ID.
        Mission mode defaults to dispatch_only; only watch_only and supervised accept explicit sync.
        watch_only and supervised require explicit --success-criterion and --authorized-target-json.
        dispatch_only derives one success criterion from --outcome when none is supplied.
        Repeat --success-criterion and --non-goal to persist multiple bounded intent entries.
        Authorized target JSON is a closed exact scope for logical/runtime project, path digest,
        host, execution mode, and access mode; core derives the authorization boundary token.
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

    def parse_json_option!(value, label)
      parsed = JSON.parse(value)
      raise UsageError, "#{label} must contain one JSON object" unless parsed.is_a?(Hash)

      Support.stringify(parsed)
    rescue JSON::ParserError => e
      raise UsageError, "#{label} is invalid JSON: #{e.message}"
    end
  end
end
