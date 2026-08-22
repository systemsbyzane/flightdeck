# frozen_string_literal: true

require "optparse"
require_relative "bridge_bulk_store"
require_relative "doctor"
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

        doctor, status, setup plan, route plan, repo plan, and bridge plan are read-only.
        status --write, setup connect, repo onboard, bridge install, task new, and
        task transition have explicit state-changing names and write only their
        documented scope.
      HELP
      0
    end

    def print_doctor(result)
      summary = result.fetch("summary")
      @out.puts("Flightdeck doctor: #{summary['errors']} error(s), #{summary['warnings']} warning(s)")
      result.fetch("issues").each do |item|
        @out.puts("#{item['severity'].upcase} [#{item['code']}] #{item['scope']}: #{item['message']}")
      end
      @out.puts("Checked #{summary['repositories']} repositories, #{summary['tasks']} tasks, #{summary['bridges']} bridges, and #{summary['compliance_pairs']} compliance sidecar pairs.")
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
  end
end
