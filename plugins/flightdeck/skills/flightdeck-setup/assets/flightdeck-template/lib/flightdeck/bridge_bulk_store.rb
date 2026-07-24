# frozen_string_literal: true

require "json"
require_relative "bridge_store"

module Flightdeck
  class BridgeBulkStore
    FAILURE_POLICIES = %w[stop continue].freeze

    attr_reader :config

    def initialize(config)
      @config = config
    end

    def plan(failure_policy: "stop")
      validate_failure_policy!(failure_policy)
      repositories = config.repository_declarations.map { |item| plan_repository(item) }
      {
        "schema_version" => "flightdeck.bridge-plan/v1",
        "read_only" => true,
        "failure_policy" => failure_policy,
        "declarations" => Support.relative_path(config.root, config.repository_declarations_path),
        "repositories" => repositories,
        "summary" => {
          "total" => repositories.length,
          "ready" => repositories.count { |item| item["status"] == "ready" },
          "noop" => repositories.count { |item| item["status"] == "noop" },
          "blocked" => repositories.count { |item| item["status"] == "blocked" },
          "project_verified" => repositories.count { |item| item.dig("project_registration", "status") == "verified" },
          "project_pending" => repositories.count { |item| item.dig("project_registration", "status") != "verified" }
        }
      }
    end

    def install_all(failure_policy: "stop", authorize_repo_native: [])
      plan_value = plan(failure_policy: failure_policy)
      authorized = Array(authorize_repo_native).map(&:to_s).uniq
      receipts = []
      stopped = false

      plan_value.fetch("repositories").each do |item|
        if stopped
          receipts << receipt_for(item, bridge_status: "not_attempted", errors: ["stopped after earlier repository failure"])
          next
        end

        errors = Array(item["blockers"]).dup
        mode = item.dig("bridge", "mode")
        if mode == "repo-native" && item.dig("bridge", "desired_state") != "valid" &&
           !authorized.include?(item["repository_id"])
          errors << "repo-native mode requires explicit per-repository authorization"
        end

        if errors.empty?
          begin
            bridge = BridgeStore.new(config).install(
              repository_id: item.fetch("repository_id"),
              mode: mode,
              profile: item.dig("bridge", "profile"),
              acknowledge_repo_native: mode != "repo-native" ||
                authorized.include?(item["repository_id"]) ||
                item.dig("bridge", "desired_state") == "valid"
            )
            receipts << receipt_for(
              item,
              bridge_status: bridge.fetch("action"),
              bridge: bridge,
              errors: []
            )
          rescue Error => e
            errors << e.message
            receipts << receipt_for(item, bridge_status: "error", errors: errors)
          end
        else
          receipts << receipt_for(item, bridge_status: "blocked", errors: errors)
        end
        stopped = failure_policy == "stop" && !receipts.last.fetch("errors").empty?
      end

      result = {
        "schema_version" => "flightdeck.bridge-setup-receipt/v1",
        "schema" => "hub/schemas/bridge-setup-receipt.schema.json",
        "generated_at" => Time.now.utc.iso8601,
        "failure_policy" => failure_policy,
        "declarations" => Support.relative_path(config.root, config.repository_declarations_path),
        "receipt_path" => config.workspace.fetch("bridge_setup_receipt", "hub/state/bridge-repos.json"),
        "ok" => receipts.all? { |item| item.fetch("errors").empty? },
        "complete" => receipts.all? { |item| item["complete"] == true },
        "repositories" => receipts,
        "summary" => {
          "total" => receipts.length,
          "installed" => receipts.count { |item| item.dig("bridge", "status") == "installed" },
          "noop" => receipts.count { |item| item.dig("bridge", "status") == "noop" },
          "blocked" => receipts.count { |item| %w[blocked error not_attempted].include?(item.dig("bridge", "status")) },
          "project_verified" => receipts.count { |item| item.dig("project_registration", "status") == "verified" },
          "project_pending" => receipts.count { |item| item.dig("project_registration", "status") != "verified" }
        }
      }
      Support.atomic_write(
        config.bridge_setup_receipt_path,
        "#{JSON.pretty_generate(result)}\n"
      )
      result
    end

    private

    def validate_failure_policy!(value)
      return if FAILURE_POLICIES.include?(value.to_s)

      raise UsageError, "failure policy must be one of: #{FAILURE_POLICIES.join(', ')}"
    end

    def plan_repository(declaration)
      id = declaration.fetch("id")
      expected_root = config.root_path(declaration.fetch("local_path"), label: "declared repository path")
      repository = config.repository(id)
      blockers = []
      registry_changes = []
      checkout = checkout_plan(expected_root, repository)
      blockers << "declared checkout is missing" unless checkout["exists"]
      blockers << "declared checkout is not the exact Git root" if checkout["exists"] && !checkout["git_root_verified"]
      if checkout["branch"] && checkout["branch"] != declaration["default_branch"]
        blockers << "checked-out branch differs from verified default branch"
      end

      if repository
        registered_root = config.root_path(repository.fetch("path"), label: "registered repository path")
        unless File.expand_path(registered_root) == File.expand_path(expected_root)
          blockers << "registered path differs from declaration"
        end
        {
          "provider" => declaration["provider"],
          "owner" => declaration["owner"],
          "default_branch" => declaration["default_branch"],
          "workload" => declaration["workload"],
          "bridge_profile" => declaration.dig("bridge", "profile"),
          "bridge_mode" => declaration.dig("bridge", "mode"),
          "codex_project_key" => declaration.dig("codex_project", "logical_key"),
          "codex_project_expectation" => declaration.dig("codex_project", "expectation")
        }.each do |field, expected|
          actual = field == "workload" ? repository["workload"] : repository[field]
          blockers << "registered #{field} differs from declaration" if Support.present?(actual) && actual != expected
        end
      else
        registry_changes << (Dir.exist?(expected_root) ? "register_existing_checkout" : "clone_and_register_checkout")
        blockers << "repository is not registered"
      end

      bridge_plan = if repository && blockers.empty?
                      BridgeStore.new(config).plan(
                        repository_id: id,
                        mode: declaration.dig("bridge", "mode"),
                        profile: declaration.dig("bridge", "profile")
                      )
                    else
                      absent_bridge_plan(declaration, expected_root)
                    end
      blockers.concat(Array(bridge_plan["blockers"]))
      project = project_plan(declaration, expected_root)
      desired = bridge_plan["desired_state"]
      {
        "repository_id" => id,
        "workload" => declaration["workload"],
        "provider" => declaration["provider"],
        "locator" => declaration["locator"],
        "owner" => declaration["owner"],
        "verified_default_branch" => declaration["default_branch"],
        "git_root" => expected_root,
        "checkout" => checkout,
        "existing_agents_files" => bridge_plan["agents_files"],
        "bridge" => {
          "profile" => declaration.dig("bridge", "profile"),
          "mode" => declaration.dig("bridge", "mode"),
          "targets" => bridge_plan["targets"],
          "existing_targets" => bridge_plan["existing_targets"],
          "desired_state" => desired,
          "overwrite_policy" => "refuse"
        },
        "overwrite_blockers" => Array(bridge_plan["blockers"]),
        "registry_changes" => registry_changes,
        "project_registration" => project,
        "blockers" => blockers.uniq,
        "status" => if blockers.any?
                      "blocked"
                    elsif desired == "valid"
                      "noop"
                    else
                      "ready"
                    end
      }
    rescue Error, KeyError => e
      {
        "repository_id" => id || "unknown",
        "git_root" => expected_root,
        "blockers" => [e.message],
        "status" => "blocked"
      }
    end

    def checkout_plan(path, repository)
      result = {
        "path" => path,
        "exists" => Dir.exist?(path),
        "registered" => !repository.nil?,
        "git_root_verified" => false
      }
      return result unless Dir.exist?(path)

      root, error, status = Support.capture("git", "rev-parse", "--show-toplevel", chdir: path)
      result["git_root_verified"] = status.zero? && File.realpath(root) == File.realpath(path)
      result["error"] = error unless status.zero?
      if result["git_root_verified"]
        branch, _branch_error, branch_status = Support.capture(
          "git", "symbolic-ref", "--quiet", "--short", "HEAD", chdir: path
        )
        sha, _sha_error, sha_status = Support.capture("git", "rev-parse", "HEAD", chdir: path)
        origin, _origin_error, origin_status = Support.capture("git", "remote", "get-url", "origin", chdir: path)
        state, _state_error, state_status = Support.capture("git", "status", "--porcelain=v1", chdir: path)
        result["branch"] = branch if branch_status.zero?
        result["sha"] = sha if sha_status.zero?
        result["origin"] = origin if origin_status.zero?
        result["clean"] = state.empty? if state_status.zero?
        result["changes"] = state.empty? ? [] : state.lines.map(&:rstrip) if state_status.zero?
      end
      result
    rescue Errno::ENOENT, Errno::ELOOP => e
      result.merge("error" => e.message)
    end

    def absent_bridge_plan(declaration, root)
      mode = declaration.dig("bridge", "mode")
      targets = case mode
                when "reference" then ["AGENTS.override.md"]
                when "materialized"
                  manifest = Support.load_data(File.join(config.root, "hub", "bridges", "manifest.yaml"))
                  profile = declaration.dig("bridge", "profile")
                  required = Array(manifest.dig("profiles", profile, "required_docs"))
                  [
                    ".flightdeck/bridge/AGENTS.md",
                    "AGENTS.override.md",
                    *required.map { |path| File.join(".flightdeck/bridge", path) }
                  ]
                when "repo-native" then ["AGENTS.md"]
                else []
                end
      files = if Dir.exist?(root)
                Dir.glob(File.join(root, "**", "{AGENTS.md,AGENTS.override.md}"), File::FNM_DOTMATCH)
                   .reject { |path| path.split(File::SEPARATOR).include?(".git") }
                   .sort
                   .map { |path| { "path" => Support.relative_path(root, path) } }
              else
                []
              end
      existing = targets.select { |path| File.exist?(File.join(root, path)) }
      blockers = if %w[reference materialized].include?(mode)
                   existing.map { |path| "refusing to overwrite unmanaged bridge target: #{path}" }
                 else
                   []
                 end
      {
        "targets" => targets,
        "existing_targets" => existing,
        "agents_files" => files,
        "desired_state" => "not_installed",
        "blockers" => blockers
      }
    end

    def project_plan(declaration, expected_root)
      expected = declaration.fetch("codex_project")
      config.project_verification(
        logical_key: expected.fetch("logical_key"),
        expected_path: expected_root
      )
    end

    def receipt_for(item, bridge_status:, errors:, bridge: nil)
      {
        "repository_id" => item["repository_id"],
        "git_root" => item["git_root"],
        "checkout" => item["checkout"],
        "bridge" => {
          "status" => bridge_status,
          "mode" => item.dig("bridge", "mode"),
          "profile" => item.dig("bridge", "profile"),
          "record" => bridge
        },
        "project_registration" => item["project_registration"],
        "errors" => errors,
        "complete" => errors.empty? &&
          %w[installed noop].include?(bridge_status) &&
          item.dig("project_registration", "status") == "verified"
      }
    end
  end
end
