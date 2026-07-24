# frozen_string_literal: true

require_relative "config"

module Flightdeck
  class RepoPlanner
    LOCATOR = /\A[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)+\z/

    def initialize(config)
      @config = config
    end

    def plan(workload_name:, provider_name:, locator:, name: nil, owner: nil, default_branch: nil)
      workload = @config.workload(workload_name)
      raise ValidationError, "unknown workload: #{workload_name}" unless workload.is_a?(Hash)
      provider = @config.provider(provider_name)
      raise ValidationError, "unknown provider: #{provider_name}" unless provider.is_a?(Hash)

      if provider["kind"] == "remote_validation"
        return {
          "plan_read_only" => true,
          "workload" => workload_name,
          "provider" => provider_name,
          "locator" => locator,
          "owner" => owner,
          "default_branch" => default_branch,
          "resolution_required" => [],
          "target" => locator,
          "target_exists" => false,
          "steps" => [
            "Resolve the configured remote Codex project and exact remote working directory.",
            "Refresh the live project list and verify the matching remote project.",
            "Search for a matching persistent task and create one only when needed.",
            "Return the remote task ID and mode immediately; do not poll, wait, or monitor it."
          ]
        }
      end

      local_name = name || locator.to_s.split("/").last.sub(/\.git\z/, "")
      Support.validate_directory!(local_name, label: "local repository name")
      inferred_owner = if %w[github gitlab bitbucket].include?(provider["kind"]) && LOCATOR.match?(locator.to_s)
                         locator.to_s.split("/")[0...-1].join("/")
                       end
      resolved_owner = Support.present?(owner) ? owner : inferred_owner
      resolution_required = []
      resolution_required << "owner" unless Support.present?(resolved_owner) || provider["kind"] == "existing_local"
      resolution_required << "default_branch" unless Support.present?(default_branch) || provider["kind"] == "existing_local"
      clone_root = workload.dig("dynamic_repositories", "clone_root") || workload.fetch("path")
      target = Support.contained_path(@config.root_path(clone_root), local_name, label: "repository target")
      {
        "plan_read_only" => true,
        "workload" => workload_name,
        "provider" => provider_name,
        "locator" => locator,
        "owner" => resolved_owner,
        "default_branch" => default_branch,
        "resolution_required" => resolution_required,
        "target" => Support.relative_path(@config.root, target),
        "target_exists" => File.exist?(target),
        "steps" => [
          "Resolve provider ownership, canonical URL, and default branch without storing credentials.",
          "Clone with an argument array under the configured workload root, or verify the existing-local Git root.",
          "Verify remotes, branch, SHA, and clean status.",
          "Install the selected bridge without overwriting instructions and record its digest.",
          "Atomically update the ignored local repository registry.",
          "Register the exact checkout as a Codex project and verify it in the refreshed live project list.",
          "Search for a matching task, create one only when needed, return its ID, and stop without monitoring."
        ]
      }
    end
  end
end
