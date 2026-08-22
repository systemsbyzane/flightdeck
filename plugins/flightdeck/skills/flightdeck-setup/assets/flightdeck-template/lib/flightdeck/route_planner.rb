# frozen_string_literal: true

require_relative "config"
require_relative "bridge_store"

module Flightdeck
  class RoutePlanner
    WORK_TYPES = %w[read_only implementation compliance artifact runtime_validation coordination].freeze

    def initialize(config)
      @config = config
    end

    def plan(workload_name:, work_type:, repository_id: nil, project_key: nil)
      work_type = work_type.to_s.tr("-", "_")
      raise UsageError, "invalid work type" unless WORK_TYPES.include?(work_type)
      workload = @config.workload(workload_name)
      raise ValidationError, "unknown workload: #{workload_name}" unless workload.is_a?(Hash)

      repository = repository_id ? @config.repository(repository_id) : nil
      raise ValidationError, "unknown repository: #{repository_id}" if repository_id && !repository
      if repository && !repository["workloads"].include?(workload_name)
        raise ValidationError, "repository #{repository_id} does not belong to #{workload_name}"
      end

      resolved_key = project_key || repository&.dig("codex_project_key") ||
                     workload["default_project_key"] ||
                     @config.routing.fetch("default_coordination_project_key")
      project = @config.codex_project(resolved_key)
      project ||= {
        "display_name" => repository_id,
        "path" => @config.repository_path(repository),
        "context" => "local",
        "role" => "implementation",
        "required" => true
      }
      project_path = File.expand_path(project.fetch("path"))
      verification = @config.project_verification(
        logical_key: resolved_key,
        expected_path: project_path
      )
      mode = mode_for(work_type, project)
      coordination_key = @config.routing.fetch("default_coordination_project_key")
      dispatch = resolved_key != coordination_key
      registration_required = dispatch && verification["status"] != "verified"
      bridge_handoff = dispatch && repository ? bridge_handoff_for(repository_id, repository) : nil
      {
        "plan_read_only" => true,
        "action" => registration_required ? "register_then_resume_or_create" : "resume_or_create",
        "dispatch_required" => dispatch,
        "dispatch_ready" => !dispatch || verification["status"] == "verified",
        "stop_after_dispatch" => dispatch,
        "workload" => workload_name,
        "work_type" => work_type,
        "repository_id" => repository_id,
        "project_key" => resolved_key,
        "runtime_project_id" => verification["runtime_project_id"],
        "project_name" => project["display_name"],
        "project_path" => project_path,
        "project_context" => project["context"],
        "project_registration_required" => registration_required,
        "project_verification" => verification.merge(
          "source" => "live_project_list",
          "match" => "exact_normalized_real_path",
          "display_name_match_accepted" => false,
          "native_registration_preferred" => true,
          "fallback" => "supported_open_folder",
          "retries_after_refresh" => 1,
          "manual_action_after_failure" => "In Codex, choose File > Open Folder, select \"#{project_path}\", then reply \"done\"."
        ),
        "mode" => mode,
        "dispatch_gate" => @config.routing.fetch("dispatch_gate"),
        "post_dispatch_policy" => @config.routing.fetch("post_dispatch_policy"),
        "monitoring_policy" => @config.routing.fetch("monitoring_policy"),
        "task_resolution" => {
          "search" => "recent_tasks_in_owning_project",
          "matching_action" => "resume",
          "no_match_action" => "create",
          "persistent" => true
        },
        "bridge_handoff" => bridge_handoff,
        "child_prompt_requirements" => [
          "Read every applicable owning-repository AGENTS.md before the Hub bridge.",
          "Read and verify the route plan's bridge_handoff before the installed bridge and its required Hub documents.",
          "In a Codex Worktree where an ignored reference or materialized bridge is absent, read the verified bridge artifacts from bridge_handoff.original_checkout_path; do not copy them into the Worktree.",
          "State the lead Flightdeck skill and any currently applicable companion skills explicitly; choose them from the requested outcome, not from the owning workload or bridge profile.",
          "Re-evaluate skill applicability when new evidence crosses domains. Read the newly applicable skill before domain-specific mutation; do not preload speculative skills or expand authorization.",
          "Follow repository rules for layout, commands, tests, and implementation mechanics.",
          "Apply the stricter security and authorization rule.",
          "Return evidence and authorization state without claiming unverified success."
        ],
        "dispatch_receipt" => {
          "required" => dispatch,
          "fields" => %w[
            logical_project_key runtime_project_id project_path task_id mode
            authorization_boundary
          ],
          "success_source" => "create_or_resume_response",
          "monitoring_permitted" => false
        },
        "authorization_boundary" => "Explicit approval is required for commit, push, pull requests or comments, publication, deployment, shared environment mutation, external communication, compliance submission, risk acceptance, and closure claims.",
        "steps" => dispatch_steps(project, mode, registration_required)
      }
    end

    private

    def bridge_handoff_for(repository_id, repository)
      store = BridgeStore.new(@config)
      mode = repository.fetch("bridge_mode")
      profile = repository.fetch("bridge_profile")
      bridge_plan = store.plan(repository_id: repository_id, mode: mode, profile: profile)
      unless bridge_plan["desired_state"] == "valid" && bridge_plan.fetch("blockers").empty?
        details = bridge_plan.fetch("blockers")
        details = ["bridge is not installed"] if details.empty?
        raise ValidationError,
              "repository bridge must be installed and verified before dispatch: #{details.join('; ')}"
      end

      record = store.record_for(repository_id)
      repository_root = File.realpath(record.fetch("repository_root"))
      target = Support.contained_path(
        repository_root,
        record.fetch("target"),
        label: "bridge handoff target"
      )
      artifacts = Array(record.fetch("artifacts")).map do |artifact|
        path = Support.contained_path(
          repository_root,
          artifact.fetch("path"),
          label: "bridge handoff artifact"
        )
        {
          "path" => path,
          "relative_path" => artifact.fetch("path"),
          "sha256" => artifact.fetch("sha256")
        }
      end
      {
        "status" => "verified",
        "repository_id" => repository_id,
        "mode" => mode,
        "profile" => profile,
        "version" => record.fetch("version"),
        "original_checkout_path" => repository_root,
        "bridge_target_path" => target,
        "bridge_target_relative_path" => record.fetch("target"),
        "bridge_target_sha256" => record.fetch("sha256"),
        "artifacts" => artifacts,
        "instruction_order" => [
          "Read every applicable AGENTS.md in the active checkout or Worktree first.",
          "Verify the bridge target and required artifacts against these SHA-256 digests.",
          "Read the verified bridge target and required Hub documents second.",
          "Apply repository rules for mechanics and the stricter security or authorization rule."
        ],
        "worktree_policy" => if mode == "repo-native"
                               "read_tracked_repo_native_bridge_in_active_worktree"
                             else
                               "read_verified_bridge_from_original_checkout_when_ignored_target_absent"
                             end,
        "copy_into_worktree" => false
      }
    end

    def mode_for(work_type, project)
      return "remote" if project["context"] == "remote"

      defaults = @config.routing.fetch("mode_defaults")
      key = if project["role"] == "program_workspace" || work_type == "compliance" || work_type == "artifact"
              "program_workspace"
            elsif work_type == "read_only"
              "read_only"
            elsif work_type == "runtime_validation"
              "runtime_validation"
            elsif work_type == "coordination"
              "coordination"
            elsif project["role"] == "implementation"
              "repository_implementation"
            else
              "workload_implementation"
            end
      defaults.fetch(key)
    end

    def dispatch_steps(project, mode, registration)
      return [
        "Keep intake, ownership resolution, sequencing, and approvals in the Hub.",
        "Dispatch as soon as an owning project is resolved."
      ] unless project["role"] != "coordination"

      steps = []
      steps << "Register and verify the exact project path in the live project list." if registration
      steps.concat([
        "Search recent tasks in #{project['display_name']} and resume a matching objective.",
        "Create a #{mode} task only when no matching task exists.",
        "Include the complete verified bridge_handoff in the child prompt. The child reads active-checkout repository instructions first, then the recorded bridge and required Hub docs from the original checkout when an ignored bridge is absent in its Worktree.",
        "Use only the opaque runtime project ID returned by the exact-path live-list match for task search, resume, or create.",
        "Return logical project key, runtime project ID, exact path, task ID, mode, and authorization boundary immediately; do not inspect owner artifacts, poll, wait, or read progress.",
        "Read the result only after a later explicit user request."
      ])
    end
  end
end
