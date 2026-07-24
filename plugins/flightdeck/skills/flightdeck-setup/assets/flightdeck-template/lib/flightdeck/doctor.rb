# frozen_string_literal: true

require "digest"
require_relative "bridge_bulk_store"
require_relative "inspections"
require_relative "task_store"

module Flightdeck
  class Doctor
    def initialize(config)
      @config = config
    end

    def run
      issues = configuration_issues
      repositories = @config.repositories.map { |item| GitInspector.new(@config.root).inspect(item) }
      repositories.each { |repository| issues.concat(repository_issues(repository)) }
      compliance = ComplianceChecker.new(@config.root).run
      issues.concat(compliance.delete("issues"))
      issues.concat(HandoffChecker.new(@config.root).run)
      issues.concat(BridgeChecker.new(@config).run)
      declarations, declaration_issues = inspect_declarations
      issues.concat(declaration_issues)
      issues.concat(AutomationChecker.new(@config.root).run)
      tasks, task_issues = inspect_tasks
      issues.concat(task_issues)
      issues = issues.map { |item| identify(item) }.sort_by { |item| [item["severity"], item["code"], item["scope"]] }
      summary = {
        "errors" => issues.count { |item| item["severity"] == "error" },
        "warnings" => issues.count { |item| item["severity"] == "warning" },
        "findings" => issues.length,
        "repositories" => repositories.length,
        "tasks" => tasks.length,
        "compliance_pairs" => compliance.fetch("pairs").length,
        "bridges" => BridgeStore.new(@config).records.length,
        "repository_declarations" => declarations.length
      }
      {
        "schema_version" => "flightdeck.doctor/v1",
        "ok" => summary["errors"].zero?,
        "generated_at" => Time.now.utc.iso8601,
        "no_fetch" => true,
        "summary" => summary,
        "issues" => issues,
        "repositories" => repositories,
        "tasks" => tasks,
        "compliance" => compliance
      }
    end

    private

    def configuration_issues
      issues = []
      @config.workflows.each_key do |type|
        Workflow.from_config(@config, type)
      rescue ValidationError => e
        issues << issue("error", "workflow.invalid", type, e.message)
      end
      @config.providers.each do |name, provider|
        unless provider.is_a?(Hash) && Support.present?(provider["kind"])
          issues << issue("error", "provider.invalid", name, "provider must define kind")
        end
      end
      if File.file?(@config.local_registry_path)
        Support.load_data(@config.local_registry_path)
      else
        issues << issue(
          "warning",
          "registry.missing",
          Support.relative_path(@config.root, @config.local_registry_path),
          "local repository registry does not exist"
        )
      end
      @config.repository_declarations
      @config.project_verifications
      issues
    rescue ValidationError => e
      issues << issue("error", "registry.invalid", "hub/state/repositories.yaml", e.message)
    end

    def inspect_declarations
      plan = BridgeBulkStore.new(@config).plan
      issues = []
      plan.fetch("repositories").each do |item|
        id = item["repository_id"] || "unknown"
        Array(item["blockers"]).each do |message|
          pending = message.include?("missing") || message.include?("not registered")
          issues << issue(
            pending ? "warning" : "error",
            pending ? "repository.declaration_pending" : "repository.declaration_conflict",
            id,
            message
          )
        end
        if item.dig("bridge", "desired_state") == "not_installed" && item["blockers"].to_a.empty?
          issues << issue("warning", "bridge.declaration_pending", id, "declared bridge is not installed")
        end
        project_status = item.dig("project_registration", "status")
        unless project_status == "verified"
          issues << issue(
            project_status == "conflict" ? "error" : "warning",
            project_status == "conflict" ? "project.registration_conflict" : "project.registration_pending",
            id,
            project_status == "conflict" ?
              "saved Codex project verification conflicts with the declared logical key or exact path" :
              "saved Codex project has no opaque runtime ID verified by exact path from the refreshed live project list"
          )
        end
      end
      [plan.fetch("repositories"), issues]
    rescue ValidationError, ConfigurationError => e
      [[], [issue("error", "repository.declarations_invalid", "hub/repositories.yaml", e.message)]]
    end

    def repository_issues(repository)
      scope = "#{repository['workload']}/#{repository['name']}"
      return [issue("error", "repo.unavailable", scope, repository["error"])] if repository["error"]

      output = []
      output << issue("warning", "repo.dirty", scope, "working tree has #{repository['changes'].length} change(s)") if repository["dirty"]
      output << issue("warning", "repo.detached", scope, "HEAD is detached") if repository["detached"]
      output << issue("warning", "repo.no_upstream", scope, "current branch has no upstream") unless repository["detached"] || repository["upstream"]
      output << issue("warning", "repo.ahead", scope, "branch is #{repository['ahead']} commit(s) ahead") if repository["ahead"].to_i.positive?
      output << issue("warning", "repo.behind", scope, "branch is #{repository['behind']} commit(s) behind local tracking ref; Doctor does not fetch") if repository["behind"].to_i.positive?
      instructions = repository["instructions"]
      output << issue("warning", "repo.no_agents", scope, "AGENTS.md is missing") unless instructions["agents"]
      if instructions["override"] && !instructions["override_tracked"] && !instructions["override_ignored"]
        output << issue("error", "repo.override_unprotected", scope, "untracked AGENTS.override.md is not ignored")
      end
      output
    end

    def inspect_tasks
      store = TaskStore.new(@config)
      tasks = store.all
      issues = []
      tasks.each do |task|
        id = task.dig("metadata", "id") || "unknown"
        if task["invalid"]
          issues << issue("error", "task.invalid_yaml", id, task["invalid"])
        else
          store.validate(id).each { |message| issues << issue("error", "task.invalid", id, message) }
        end
      rescue ValidationError => e
        issues << issue("error", "task.invalid", id, e.message)
      end
      [tasks, issues]
    end

    def issue(severity, code, scope, message)
      { "severity" => severity, "code" => code, "scope" => scope, "message" => message }
    end

    def identify(item)
      code = item.fetch("code").to_s
      scope = item.fetch("scope").to_s
      message = item.fetch("message").to_s
      item.merge(
        "fingerprint" => Digest::SHA256.hexdigest([code, scope].join("\0"))[0, 20],
        "signature" => Digest::SHA256.hexdigest([code, scope, message].join("\0"))[0, 20]
      )
    end
  end
end
