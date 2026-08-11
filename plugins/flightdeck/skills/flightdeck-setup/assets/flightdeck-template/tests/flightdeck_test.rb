# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"
require "yaml"

require "flightdeck/bridge_store"
require "flightdeck/bridge_bulk_store"
require "flightdeck/cli"
require "flightdeck/config"
require "flightdeck/doctor"
require "flightdeck/hub_snapshot"
require "flightdeck/operations_snapshot"
require "flightdeck/operation_detail"
require "flightdeck/omp_operation_execution"
require "flightdeck/work_coordinator"
require "flightdeck/mission_objectives"
require "flightdeck/mission_store"
require "flightdeck/repo_planner"
require "flightdeck/repository_store"
require "flightdeck/route_planner"
require "flightdeck/task_store"

class FlightdeckTest < Minitest::Test
  TEMPLATE_ROOT = File.expand_path("..", __dir__)
  CONTROL_PLANE_ENTRIES = %w[
    .gitignore AGENTS.md Makefile README.md bin docs flightdeck.yaml lib scripts tests
  ].freeze
  HUB_CONTROL_PLANE_ENTRIES = %w[
    .mission-authoring.lock .operation-authoring.lock automations bridges compatibility.json repositories.yaml schemas templates workflows
  ].freeze
  WORKLOAD_ROOTS = %w[charts development environments operations patching research].freeze

  def with_hub
    Dir.mktmpdir("flightdeck-test-") do |directory|
      root = File.join(directory, "hub")
      FileUtils.mkdir_p(root)
      CONTROL_PLANE_ENTRIES.each do |entry|
        FileUtils.cp_r(File.join(TEMPLATE_ROOT, entry), File.join(root, entry))
      end
      FileUtils.mkdir_p(File.join(root, "hub"))
      HUB_CONTROL_PLANE_ENTRIES.each do |entry|
        source = File.join(TEMPLATE_ROOT, "hub", entry)
        FileUtils.cp_r(source, File.join(root, "hub", entry)) if File.exist?(source)
      end
      Flightdeck::Support.atomic_yaml(
        File.join(root, "hub", "repositories.yaml"),
        {
          "api_version" => "flightdeck.dev/v1alpha1",
          "kind" => "RepositoryDeclarations",
          "schema" => "hub/schemas/repository-declarations.schema.json",
          "repositories" => []
        }
      )
      WORKLOAD_ROOTS.each do |workload|
        FileUtils.mkdir_p(File.join(root, workload))
        readme = File.join(TEMPLATE_ROOT, workload, "README.md")
        FileUtils.cp(readme, File.join(root, workload, "README.md")) if File.file?(readme)
      end
      FileUtils.mkdir_p(File.join(root, "compliance"))
      %w[README.md _program-template].each do |entry|
        source = File.join(TEMPLATE_ROOT, "compliance", entry)
        FileUtils.cp_r(source, File.join(root, "compliance", entry)) if File.exist?(source)
      end
      config_path = File.join(root, "flightdeck.yaml")
      File.write(config_path, File.read(config_path).gsub("__FLIGHTDECK_ROOT__", root))
      yield root, Flightdeck::Config.new(root: root)
    end
  end

  def git(*arguments, chdir:)
    output, error, status = Open3.capture3({ "LC_ALL" => "C" }, "git", *arguments, chdir: chdir)
    raise "#{arguments.join(' ')} failed: #{error}" unless status.success?

    output.strip
  end

  def initialize_repository(root, name = "sample")
    path = File.join(root, "development", name)
    FileUtils.mkdir_p(path)
    git("init", "--quiet", "--initial-branch=main", path, chdir: root)
    File.write(File.join(path, "AGENTS.md"), "# Repository policy\n")
    path
  end

  def commit_repository(path)
    git("config", "user.name", "Synthetic Test", chdir: path)
    git("config", "user.email", "test@example.invalid", chdir: path)
    git("add", "AGENTS.md", chdir: path)
    git("commit", "--quiet", "-m", "Synthetic fixture", chdir: path)
  end

  def register_repository(config, id, path, mode: "reference", placement: "managed")
    registry = File.file?(config.local_registry_path) ? Flightdeck::Support.load_data(config.local_registry_path) : {
      "api_version" => "flightdeck.dev/v1alpha1",
      "kind" => "LocalRepositoryRegistry",
      "repositories" => {}
    }
    registry["repositories"][id] = {
      "local_path" => placement == "attached" ? File.realpath(path) : Flightdeck::Support.relative_path(config.root, path),
      "placement" => placement,
      "provider" => "existing-local",
      "locator" => path,
      "owner" => "local",
      "default_branch" => "main",
      "default_branch_verified" => true,
      "workload_ids" => ["development"],
      "bridge_profile" => "application",
      "bridge_mode" => mode,
      "codex_project_key" => id,
      "codex_project_expectation" => "saved_exact_path"
    }
    Flightdeck::Support.atomic_yaml(config.local_registry_path, registry)
    Flightdeck::Config.new(root: config.root)
  end

  def write_declarations(config, entries)
    Flightdeck::Support.atomic_yaml(
      config.repository_declarations_path,
      {
        "api_version" => "flightdeck.dev/v1alpha1",
        "kind" => "RepositoryDeclarations",
        "schema" => "hub/schemas/repository-declarations.schema.json",
        "repositories" => entries
      }
    )
    Flightdeck::Config.new(root: config.root)
  end

  def declaration(id, path, mode: "reference", placement: "managed")
    value = {
      "id" => id,
      "placement" => placement,
      "workload" => "development",
      "provider" => "existing-local",
      "locator" => File.join("development", File.basename(path)),
      "owner" => "local",
      "default_branch" => "main",
      "default_branch_verified" => true,
      "bridge" => {
        "profile" => "application",
        "mode" => mode
      },
      "codex_project" => {
        "expectation" => "saved_exact_path",
        "logical_key" => id
      }
    }
    value["local_path"] = File.join("development", File.basename(path)) if placement == "managed"
    value
  end

  def write_project_verifications(config, records)
    Flightdeck::Support.atomic_yaml(
      config.project_registry_path,
      {
        "api_version" => "flightdeck.dev/v1alpha1",
        "kind" => "CodexProjectVerifications",
        "projects" => records
      }
    )
  end

  def verified_project(key, path, runtime_id: "opaque-runtime-#{key}")
    {
      "logical_key" => key,
      "runtime_project_id" => runtime_id,
      "path" => path,
      "verified" => true,
      "verification_source" => "live_project_list_exact_path",
      "verified_at" => "2026-08-08T00:00:00Z"
    }
  end

  def snapshot_hub(root, config, ids: %w[zulu alpha])
    registry = Flightdeck::Support.load_data(File.join(root, "flightdeck.yaml"))
    registry.fetch("workspace")["root"] = root
    registry.fetch("codex_projects").fetch("flightdeck")["path"] = root
    Flightdeck::Support.atomic_yaml(File.join(root, "flightdeck.yaml"), registry)
    config = Flightdeck::Config.new(root: root)
    records = {
      "flightdeck" => verified_project("flightdeck", root, runtime_id: "opaque-runtime-hub")
    }
    declarations = ids.map do |id|
      repository = initialize_repository(root, id)
      config = register_repository(config, id, repository)
      records[id] = verified_project(id, repository, runtime_id: "opaque-runtime-#{id}")
      declaration(id, repository)
    end
    write_project_verifications(config, records)
    config = Flightdeck::Config.new(root: root)
    write_declarations(config, declarations)
    config = Flightdeck::Config.new(root: root)
    ids.each do |id|
      Flightdeck::BridgeStore.new(config).install(repository_id: id, mode: "reference", profile: "application")
    end
    Flightdeck::Config.new(root: root)
  end

  def test_workflows_and_providers_are_loadable
    with_hub do |_root, config|
      assert_equal %w[bitbucket existing-local git github gitlab remote-validation], config.providers.keys.sort
      config.workflows.each_key do |type|
        assert_equal type, Flightdeck::Workflow.from_config(config, type).type
      end
    end
  end

  def test_read_only_plans_do_not_write
    with_hub do |root, config|
      before = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort
      route = Flightdeck::RoutePlanner.new(config).plan(
        workload_name: "development", work_type: "implementation"
      )
      repo = Flightdeck::RepoPlanner.new(config).plan(
        workload_name: "development", provider_name: "github", locator: "example/service"
      )
      after = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort
      assert route["plan_read_only"]
      assert repo["plan_read_only"]
      assert_equal before, after
    end
  end

  def test_remote_validation_plan_is_non_cloning
    with_hub do |_root, config|
      plan = Flightdeck::RepoPlanner.new(config).plan(
        workload_name: "environments",
        provider_name: "remote-validation",
        locator: "configured-runtime-project"
      )
      assert plan["plan_read_only"]
      assert_equal "configured-runtime-project", plan["target"]
      refute plan["steps"].any? { |step| step.downcase.include?("clone") }
      assert_raises(Flightdeck::ValidationError) do
        Flightdeck::RepositoryStore.new(config).onboard(
          workload_name: "environments",
          provider_name: "remote-validation",
          locator: "configured-runtime-project",
          repository_id: "runtime"
        )
      end
    end
  end

  def test_remote_project_routes_in_remote_mode
    with_hub do |root, _config|
      value = Flightdeck::Support.load_data(File.join(root, "flightdeck.yaml"))
      value["codex_projects"]["runtime"] = {
        "display_name" => "Runtime Validation",
        "context" => "remote",
        "path" => File.join(root, "environments"),
        "role" => "runtime_validation",
        "workload_id" => "environments",
        "required" => false
      }
      Flightdeck::Support.atomic_yaml(File.join(root, "flightdeck.yaml"), value)
      config = Flightdeck::Config.new(root: root)
      Flightdeck::Support.atomic_yaml(
        config.project_registry_path,
        {
          "api_version" => "flightdeck.dev/v1alpha1",
          "kind" => "CodexProjectVerifications",
          "projects" => {
            "runtime" => {
              "logical_key" => "runtime",
              "runtime_project_id" => "opaque-runtime-project-42",
              "path" => File.join(root, "environments"),
              "verified" => true,
              "verification_source" => "live_project_list_exact_path",
              "verified_at" => "2026-01-01T00:00:00Z"
            }
          }
        }
      )
      plan = Flightdeck::RoutePlanner.new(Flightdeck::Config.new(root: root)).plan(
        workload_name: "environments",
        work_type: "runtime_validation",
        project_key: "runtime"
      )
      assert_equal "remote", plan["mode"]
      assert_equal "runtime", plan["project_key"]
      assert_equal "opaque-runtime-project-42", plan["runtime_project_id"]
      assert plan["dispatch_ready"]
      assert plan["dispatch_required"]
      assert plan["stop_after_dispatch"]
    end
  end

  def test_hub_snapshot_is_deterministic_and_redacts_local_runtime_details
    with_hub do |root, config|
      snapshot_hub(root, config)
      output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new)

      assert_equal 0, cli.run(["hub", "snapshot", "--hub-root", root, "--json"])
      snapshot = JSON.parse(output.string)
      assert_equal "flightdeck.hub-snapshot/v1", snapshot["api_version"]
      assert_equal "HubSnapshot", snapshot["kind"]
      assert_equal true, snapshot["ok"]
      assert_equal %w[flightdeck alpha zulu], snapshot.fetch("projects").map { |item| item["logical_project_key"] }
      coordinator = snapshot.fetch("projects").first
      assert_equal "hub_coordinator", coordinator["destination"]
      assert_equal "coordinate_and_route", coordinator["routing_capability"]
      repository = snapshot.fetch("projects").find { |item| item["logical_project_key"] == "alpha" }
      assert_equal "repository_routing_hint", repository["destination"]
      assert_equal "healthy", repository["bridge_health"]
      assert_equal ["model", "reasoning_effort"], snapshot.dig("runtime_capabilities", "adapters", "codex", "optional_controls")
      assert_equal "codex", snapshot.dig("runtime_capabilities", "conversation", "adapter")
      assert_equal "omp", snapshot.dig("runtime_capabilities", "operation_execution", "adapter")
      assert_equal true, snapshot.dig("runtime_capabilities", "adapters", "omp", "available")

      rendered = output.string
      refute_includes rendered, root
      refute_includes rendered, "opaque-runtime-hub"
      refute_includes rendered, "opaque-runtime-alpha"
      refute_includes rendered, "bridge_handoff"
      snapshot.fetch("projects").each do |project|
        assert_equal %w[availability bridge_health destination display_label logical_project_key routing_capability workload], project.keys.sort
      end
    end
  end

  def test_hub_snapshot_fails_closed_for_missing_verification_and_invalid_registry
    with_hub do |root, config|
      config = snapshot_hub(root, config, ids: ["sample"])
      project_state = Flightdeck::Support.load_data(config.project_registry_path)
      project_state.fetch("projects").delete("sample")
      Flightdeck::Support.atomic_yaml(config.project_registry_path, project_state)
      output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new)

      assert_equal 1, cli.run(["hub", "snapshot", "--hub-root", root, "--json"])
      missing = JSON.parse(output.string)
      assert_equal "project_verification_missing", missing.dig("error", "code")
      refute missing.key?("projects")
      refute_includes output.string, root

      Flightdeck::Support.atomic_yaml(config.project_registry_path, { "projects" => {} })
      output.truncate(0)
      output.rewind
      assert_equal 1, cli.run(["hub", "snapshot", "--hub-root", root, "--json"])
      invalid = JSON.parse(output.string)
      assert_equal "registry_invalid", invalid.dig("error", "code")
      refute invalid.key?("projects")
    end
  end

  def test_hub_snapshot_requires_its_capability_and_preserves_existing_commands
    with_hub do |root, config|
      snapshot_hub(root, config, ids: [])
      compatibility_path = File.join(root, "hub", "compatibility.json")
      compatibility = JSON.parse(File.read(compatibility_path))
      compatibility.fetch("capabilities").delete("flightdeck.command.hub-snapshot.v1")
      File.write(compatibility_path, JSON.pretty_generate(compatibility))
      output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new)

      assert_equal 1, cli.run(["hub", "snapshot", "--hub-root", root, "--json"])
      assert_equal "unsupported_hub_contract", JSON.parse(output.string).dig("error", "code")

      output.truncate(0)
      output.rewind
      assert_equal 0, cli.run(["mission", "list", "--hub-root", root, "--json"])
      assert_equal "MissionList", JSON.parse(output.string)["kind"]
    end
  end

  def test_operations_snapshot_projects_only_durable_hub_state_and_redacts_mission_identity
    with_hub do |root, config|
      store = Flightdeck::MissionStore.new(config)
      raw_project_path = "/private/operations/source"
      target = {
        "logical_project_key" => "rap-backend",
        "runtime_project_id" => "opaque-runtime-operations-42",
        "project_path_digest" => Digest::SHA256.hexdigest(raw_project_path),
        "host_id" => "opaque-host-operations-42",
        "execution_mode" => "worktree",
        "access_mode" => "write"
      }
      store.create(
        slug: "operations-mission", title: "RAP Backend operation", outcome: "Do not expose raw prompts.",
        mode: "supervised", success_criteria: ["Validate the bounded result."], authorized_targets: [target]
      )
      store.add_node(
        slug: "operations-mission", node_id: "backend", logical_project_key: "rap-backend",
        runtime_project_id: target.fetch("runtime_project_id"), host_id: target.fetch("host_id"),
        project_path: raw_project_path, execution_mode: "worktree", access_mode: "write",
        work_type: "implementation", required: true, criterion_ids: ["criterion-001"], allowed_output_types: ["patch_ref"]
      )
      output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new)

      assert_equal 0, cli.run(["hub", "operations-snapshot", "--hub-root", root, "--json"]), output.string
      snapshot = JSON.parse(output.string)
      assert_equal "flightdeck.operations-snapshot/v1", snapshot["api_version"]
      assert_equal "OperationsSnapshot", snapshot["kind"]
      assert_equal true, snapshot.dig("runtime_capabilities", "adapters", "omp", "available")
      assert_equal "codex", snapshot.dig("runtime_capabilities", "conversation", "adapter")
      assert_equal "omp", snapshot.dig("runtime_capabilities", "operation_execution", "adapter")
      operation = snapshot.fetch("operations").fetch(0)
      assert_equal "mission:operations-mission", operation["operation_id"]
      assert_equal "queued", operation["status"]
      child = operation.fetch("children").fetch(0)
      assert_equal "rap-backend", child["logical_project_key"]
      assert_equal "Hub Agent — rap-backend", child["role_name"]
      assert_equal({ "state" => "absent", "items" => [] }, child["skills"])
      refute_includes output.string, "opaque-runtime-operations-42"
      refute_includes output.string, "opaque-host-operations-42"
      refute_includes output.string, raw_project_path
      refute_includes output.string, "Do not expose raw prompts."
    end
  end

  def test_operations_snapshot_returns_an_empty_hub_projection_without_global_recents
    with_hub do |root, _config|
      output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new)
      assert_equal 0, cli.run(["hub", "operations-snapshot", "--hub-root", root, "--json"])
      snapshot = JSON.parse(output.string)
      assert_equal [], snapshot.fetch("operations")
      assert_equal [], snapshot.dig("summary", "alerts")
      assert snapshot.dig("summary", "counts").values.all?(&:zero?)
    end
  end

  def test_operations_snapshot_maps_every_status_and_never_infers_skills
    with_hub do |root, config|
      repository = initialize_repository(root, "rap-backend")
      config = register_repository(config, "rap-backend", repository)
      config = write_declarations(config, [declaration("rap-backend", repository)])
      snapshot = Flightdeck::OperationsSnapshot.new(config)
      expected = {
        "intake" => "queued", "scoped" => "queued", "designed" => "queued", "authorized" => "queued", "planned" => "queued", "dispatch_pending" => "queued",
        "executing" => "working", "running" => "working", "validating" => "working", "integration_ready" => "waiting", "validation_ready" => "waiting", "awaiting_handoff" => "waiting",
        "needs_approval" => "approval_required", "approval_required" => "approval_required", "blocked" => "blocked", "review_ready" => "review_ready", "closed" => "review_ready", "complete" => "review_ready",
        "failed_validation" => "failed_validation", "runtime_failure" => "failed_validation", "cancelled" => "cancelled", "dispatch_unknown" => "reconcile_required", "stale" => "reconcile_required", "rollback_required" => "reconcile_required", "unknown" => "reconcile_required"
      }
      expected.each { |source, projected| assert_equal projected, snapshot.send(:map_state, source) }
      operation = snapshot.send(:operation, "task", "empty", "Empty", "intake", "2026-08-08T00:00:00Z", "2026-08-08T00:00:00Z", { "workload" => "development" }, [])
      assert_equal({ "state" => "unavailable", "items" => [] }, operation.fetch("skills"))
      assert_equal "Development Agent — rap-backend", snapshot.send(:project_info, "rap-backend", nil).fetch("role_name")
    end
  end

  def test_operations_snapshot_rejects_invalid_state_and_missing_capability_without_partial_operations
    with_hub do |root, config|
      directory = File.join(config.mission_dir, "invalid-record")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "mission.yaml"), "not: a-valid-mission\n")
      output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new)
      assert_equal 1, cli.run(["hub", "operations-snapshot", "--hub-root", root, "--json"])
      invalid = JSON.parse(output.string)
      assert_equal "invalid_hub_state", invalid.dig("error", "code")
      refute invalid.key?("operations")

      FileUtils.rm_rf(directory)
      compatibility_path = File.join(root, "hub", "compatibility.json")
      compatibility = JSON.parse(File.read(compatibility_path))
      compatibility.fetch("capabilities").delete("flightdeck.command.operations-snapshot.v1")
      File.write(compatibility_path, JSON.pretty_generate(compatibility))
      output.truncate(0)
      output.rewind
      assert_equal 1, cli.run(["hub", "operations-snapshot", "--hub-root", root, "--json"])
      denied = JSON.parse(output.string)
      assert_equal "unsupported_hub_contract", denied.dig("error", "code")
      refute denied.key?("operations")
    end
  end

  def test_operations_snapshot_contract_is_declared_and_closed
    schema = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "schemas", "operations-snapshot.schema.json")))
    assert_equal "https://flightdeck.dev/schemas/operations-snapshot.schema.json", schema["$id"]
    assert_equal false, schema.dig("$defs", "success", "additionalProperties")
    assert_equal false, schema.dig("$defs", "error", "additionalProperties")
    assert_equal false, schema.dig("$defs", "skills", "additionalProperties")
    assert_equal ["queued", "working", "waiting", "approval_required", "blocked", "review_ready", "failed_validation", "cancelled", "reconcile_required"], schema.dig("$defs", "status", "enum")
    compatibility = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "compatibility.json")))
    capability = compatibility.dig("capabilities", "flightdeck.command.operations-snapshot.v1")
    assert_equal "command", capability["kind"]
    assert_includes capability["managed_paths"], "hub/schemas/operations-snapshot.schema.json"
  end

  def test_task_creation_is_non_destructive_and_transitions_are_gated
    with_hub do |_root, config|
      store = Flightdeck::TaskStore.new(config)
      task = store.create(
        type: "development",
        slug: "safe-change",
        title: "Safe change",
        outcome: "Preserve behavior",
        workload: "development"
      )
      assert_equal "intake", task.dig("status", "state")
      assert_raises(Flightdeck::ValidationError) { store.create(type: "development", slug: "safe-change", title: "Duplicate", outcome: "No", workload: "development") }
      assert_raises(Flightdeck::ValidationError) { store.transition(slug: "safe-change", state: "scoped") }

      task["spec"]["scope"]["targets"] = [{ "kind" => "repository", "name" => "service" }]
      task["spec"]["outcome"]["success_criteria"] = ["Owner receives a validated change"]
      Flightdeck::Support.atomic_yaml(store.task_path("safe-change"), task)
      assert_equal "scoped", store.transition(slug: "safe-change", state: "scoped").dig("status", "state")
      assert_raises(Flightdeck::ValidationError) { store.transition(slug: "safe-change", state: "executing") }
    end
  end

  def test_contained_paths_reject_escape
    with_hub do |root, config|
      assert_raises(Flightdeck::ConfigurationError) { config.root_path("../outside") }
      Dir.mktmpdir("outside-hub-") do |outside|
        link = File.join(root, "development", "outside-link")
        File.symlink(outside, link)
        assert_raises(Flightdeck::ConfigurationError) do
          config.root_path("development/outside-link/new-repository")
        end
      end
    end
  end

  def test_bridge_modes_record_integrity_and_idempotent_noop
    with_hub do |root, config|
      repository = initialize_repository(root)
      config = register_repository(config, "sample", repository)
      store = Flightdeck::BridgeStore.new(config)
      plan = store.plan(repository_id: "sample", mode: "reference", profile: "application")
      assert plan["read_only"]
      record = store.install(repository_id: "sample", mode: "reference", profile: "application")
      assert_equal Digest::SHA256.file(File.join(repository, record["target"])).hexdigest, record["sha256"]
      second = store.install(repository_id: "sample", mode: "reference", profile: "application")
      assert_equal "noop", second["action"]
      assert_equal true, second["verified"]
    end
  end

  def test_materialized_bridge_is_local_and_repo_native_requires_acknowledgement
    with_hub do |root, config|
      repository = initialize_repository(root)
      config = register_repository(config, "sample", repository)
      store = Flightdeck::BridgeStore.new(config)
      record = store.install(repository_id: "sample", mode: "materialized", profile: "application")
      assert_equal ".flightdeck/bridge/AGENTS.md", record["target"]
      policy = File.read(File.join(repository, record["target"]))
      assert_includes policy, "Bridge mode: `materialized`"
      refute_includes policy, root
      refute_includes policy, repository
      assert_equal true, record["portable"]
      assert record["artifacts"].any? { |item| item["path"] == ".flightdeck/bridge/docs/workflows/operations.md" }
      assert_raises(Flightdeck::UsageError) do
        store.install(repository_id: "sample", mode: "repo-native", profile: "application")
      end
    end
  end

  def test_worktree_route_hands_off_verified_ignored_bridge_from_original_checkout
    with_hub do |root, config|
      repository = initialize_repository(root, "worktree-handoff")
      commit_repository(repository)
      config = register_repository(config, "worktree-handoff", repository, mode: "materialized")
      config = write_declarations(
        config,
        [declaration("worktree-handoff", repository, mode: "materialized")]
      )
      record = Flightdeck::BridgeStore.new(config).install(
        repository_id: "worktree-handoff",
        mode: "materialized",
        profile: "application"
      )
      Flightdeck::Support.atomic_yaml(
        config.project_registry_path,
        {
          "api_version" => "flightdeck.dev/v1alpha1",
          "kind" => "CodexProjectVerifications",
          "projects" => {
            "worktree-handoff" => {
              "logical_key" => "worktree-handoff",
              "runtime_project_id" => "opaque-runtime-worktree-42",
              "path" => repository,
              "verified" => true,
              "verification_source" => "live_project_list_exact_path",
              "verified_at" => "2026-01-01T00:00:00Z"
            }
          }
        }
      )

      plan = Flightdeck::RoutePlanner.new(Flightdeck::Config.new(root: root)).plan(
        workload_name: "development",
        work_type: "implementation",
        repository_id: "worktree-handoff"
      )
      handoff = plan.fetch("bridge_handoff")
      assert_equal "verified", handoff["status"]
      assert_equal "materialized", handoff["mode"]
      assert_equal File.realpath(repository), handoff["original_checkout_path"]
      assert_equal File.realpath(File.join(repository, record["target"])), handoff["bridge_target_path"]
      assert_equal record["sha256"], handoff["bridge_target_sha256"]
      assert_equal(
        "read_verified_bridge_from_original_checkout_when_ignored_target_absent",
        handoff["worktree_policy"]
      )
      assert_equal false, handoff["copy_into_worktree"]
      assert handoff["artifacts"].all? { |artifact| File.absolute_path(artifact["path"]) == artifact["path"] }
      assert handoff["artifacts"].any? do |artifact|
        artifact["relative_path"] == ".flightdeck/bridge/docs/workflows/operations.md"
      end
      assert_includes plan["child_prompt_requirements"].join(" "), "original_checkout_path"
    end
  end

  def test_repository_route_refuses_missing_bridge
    with_hub do |root, config|
      repository = initialize_repository(root, "missing-bridge")
      commit_repository(repository)
      config = register_repository(config, "missing-bridge", repository)
      config = write_declarations(config, [declaration("missing-bridge", repository)])

      error = assert_raises(Flightdeck::ValidationError) do
        Flightdeck::RoutePlanner.new(config).plan(
          workload_name: "development",
          work_type: "implementation",
          repository_id: "missing-bridge"
        )
      end
      assert_includes error.message, "bridge must be installed and verified"
    end
  end

  def test_repo_native_bridge_preserves_existing_instructions
    with_hub do |root, config|
      repository = initialize_repository(root)
      commit_repository(repository)
      original = File.read(File.join(repository, "AGENTS.md"))
      config = register_repository(config, "sample", repository)
      record = Flightdeck::BridgeStore.new(config).install(
        repository_id: "sample",
        mode: "repo-native",
        profile: "application",
        acknowledge_repo_native: true
      )
      updated = File.read(File.join(repository, "AGENTS.md"))
      assert updated.start_with?(original.rstrip)
      assert_includes updated, "<!-- flightdeck-bridge:1.0.0 -->"
      assert_includes updated, "Bridge mode: `repo-native`"
      refute_includes updated, root
      refute_includes updated, repository
      assert_includes updated, "Repository rules own"
      assert_equal true, record["portable"]
      assert_equal "AGENTS.md", record["target"]
    end
  end

  def test_doctor_detects_absolute_path_in_portable_bridge
    with_hub do |root, config|
      repository = initialize_repository(root)
      commit_repository(repository)
      config = register_repository(config, "sample", repository)
      record = Flightdeck::BridgeStore.new(config).install(
        repository_id: "sample",
        mode: "repo-native",
        profile: "application",
        acknowledge_repo_native: true
      )
      path = File.join(repository, record["target"])
      File.write(path, "#{File.read(path)}\nMachine path: /Users/example/private/hub\n")
      result = Flightdeck::Doctor.new(Flightdeck::Config.new(root: root)).run
      assert_includes result["issues"].map { |item| item["code"] }, "bridge.absolute_path_leak"
    end
  end

  def test_existing_local_onboarding_preserves_dirty_state
    with_hub do |root, config|
      repository = initialize_repository(root)
      commit_repository(repository)
      File.write(File.join(repository, "local-note.txt"), "preserve me\n")
      result = Flightdeck::RepositoryStore.new(config).onboard(
        workload_name: "development",
        provider_name: "existing-local",
        locator: repository,
        repository_id: "sample",
        bridge_mode: "reference",
        bridge_profile: "application"
      )
      assert_equal false, result.dig("verification", "clean")
      assert_includes result.dig("verification", "changes"), "?? local-note.txt"
      assert_equal "preserve me\n", File.read(File.join(repository, "local-note.txt"))
      registered = Flightdeck::Config.new(root: root).repository("sample")
      assert_equal "local", registered["owner"]
      assert_equal result.dig("verification", "branch"), registered["default_branch"]
      assert_equal false, result.dig("project_registration", "verified")
    end
  end

  def test_doctor_detects_bridge_drift
    with_hub do |root, config|
      repository = initialize_repository(root)
      config = register_repository(config, "sample", repository)
      record = Flightdeck::BridgeStore.new(config).install(
        repository_id: "sample", mode: "reference", profile: "application"
      )
      File.write(File.join(repository, record["target"]), "changed\n")
      result = Flightdeck::Doctor.new(Flightdeck::Config.new(root: root)).run
      assert_includes result["issues"].map { |item| item["code"] }, "bridge.drift"
      assert result["no_fetch"]
    end
  end

  def test_doctor_reports_missing_registered_repository_without_crashing
    with_hub do |root, config|
      repository = initialize_repository(root)
      config = register_repository(config, "sample", repository)
      Flightdeck::BridgeStore.new(config).install(
        repository_id: "sample", mode: "reference", profile: "application"
      )
      FileUtils.rm_rf(repository)

      result = Flightdeck::Doctor.new(Flightdeck::Config.new(root: root)).run

      refute result["ok"]
      assert_includes result["issues"].map { |item| item["code"] }, "repo.unavailable"
      assert_includes result["issues"].map { |item| item["code"] }, "bridge.repository_unavailable"
    end
  end

  def test_compliance_sidecars_require_semantic_parity
    with_hub do |root, config|
      directory = File.join(root, "compliance", "example", "control-assessments")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "control.json"), JSON.pretty_generate({ "status" => "not_assessed" }))
      File.write(File.join(directory, "control.yaml"), YAML.dump({ "status" => "not_assessed" }))
      first = Flightdeck::Doctor.new(config).run
      assert_equal true, first.dig("compliance", "pairs", 0, "equivalent")

      File.write(File.join(directory, "control.yaml"), YAML.dump({ "status" => "satisfied" }))
      second = Flightdeck::Doctor.new(config).run
      assert_includes second["issues"].map { |item| item["code"] }, "compliance.sidecar_mismatch"
    end
  end

  def test_doctor_reports_handoff_placeholders
    with_hub do |root, config|
      handoff = File.join(root, "handoffs", "sample.md")
      FileUtils.mkdir_p(File.dirname(handoff))
      File.write(handoff, "# Handoff\n\nOwner: TBD\n")
      result = Flightdeck::Doctor.new(config).run
      issue = result["issues"].find { |item| item["code"] == "handoff.placeholder" }
      refute_nil issue
      assert_equal "warning", issue["severity"]
      assert_equal "handoffs/sample.md", issue["scope"]
      assert_match(/\A[0-9a-f]{20}\z/, issue["fingerprint"])
    end
  end

  def test_all_automation_templates_are_disabled
    with_hub do |root, _config|
      Dir.glob(File.join(root, "hub", "automations", "*.yaml")).each do |path|
        value = YAML.safe_load(File.read(path), aliases: false)
        assert_equal false, value["enabled"], path
        assert_equal "explicit_user_enablement", value.dig("activation", "policy"), path
      end
    end
  end

  def test_cli_help_documents_read_only_and_state_changing_surfaces
    with_hub do |root, _config|
      output = StringIO.new
      status = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new).run(["help"])
      assert_equal 0, status
      assert_includes output.string, "route plan"
      assert_includes output.string, "repo onboard"
      assert_includes output.string, "explicit state-changing names"
    end
  end

  def test_repo_plan_json_is_machine_readable
    with_hub do |root, _config|
      output = StringIO.new
      status = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new).run(
        %w[repo plan --workload development --provider github --repo example/service --json]
      )
      assert_equal 0, status
      value = JSON.parse(output.string)
      assert_equal true, value["plan_read_only"]
      assert_equal "github", value["provider"]
      assert_equal "example", value["owner"]
      assert_equal ["default_branch"], value["resolution_required"]
    end
  end

  def test_provider_adapters_build_safe_urls_without_credentials
    with_hub do |_root, config|
      store = Flightdeck::RepositoryStore.new(config)
      {
        "github" => "https://github.com/example/service.git",
        "gitlab" => "https://gitlab.com/example/service.git",
        "bitbucket" => "https://bitbucket.org/example/service.git"
      }.each do |provider_name, expected|
        actual = store.send(
          :resolve_url, config.provider(provider_name), "example/service", nil
        )
        assert_equal expected, actual
      end
      assert_equal(
        "file:///tmp/synthetic-repository",
        store.send(
          :resolve_url,
          config.provider("git"),
          "file:///tmp/synthetic-repository",
          nil
        )
      )
      assert_raises(Flightdeck::ValidationError) do
        store.send(
          :resolve_url,
          config.provider("git"),
          "https://user:secret@example.invalid/service.git",
          nil
        )
      end
      assert_raises(Flightdeck::ValidationError) do
        store.send(
          :resolve_url,
          config.provider("git"),
          "http://example.invalid/service.git",
          nil
        )
      end
    end
  end

  def test_bulk_bridge_plan_is_read_only_and_reports_exact_inputs
    with_hub do |root, config|
      repository = initialize_repository(root, "bulk-plan")
      commit_repository(repository)
      config = register_repository(config, "bulk-plan", repository)
      config = write_declarations(config, [declaration("bulk-plan", repository)])
      before = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.to_h do |path|
        [path, File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil]
      end

      plan = Flightdeck::BridgeBulkStore.new(config).plan

      after = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.to_h do |path|
        [path, File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil]
      end
      assert_equal before, after
      assert_equal true, plan["read_only"]
      item = plan.fetch("repositories").first
      assert_equal repository, item["git_root"]
      assert_equal "AGENTS.md", item.fetch("existing_agents_files").first["path"]
      assert_equal "reference", item.dig("bridge", "mode")
      assert_equal ["AGENTS.override.md"], item.dig("bridge", "targets")
      assert_equal "pending", item.dig("project_registration", "status")
    end
  end

  def test_bulk_bridge_install_is_safe_idempotent_and_writes_per_repo_receipts
    with_hub do |root, config|
      reference = initialize_repository(root, "bulk-reference")
      materialized = initialize_repository(root, "bulk-materialized")
      [reference, materialized].each { |path| commit_repository(path) }
      config = register_repository(config, "bulk-reference", reference)
      config = register_repository(config, "bulk-materialized", materialized, mode: "materialized")
      config = write_declarations(
        config,
        [
          declaration("bulk-reference", reference),
          declaration("bulk-materialized", materialized, mode: "materialized")
        ]
      )
      store = Flightdeck::BridgeBulkStore.new(config)
      first = store.install_all(failure_policy: "continue")
      assert_equal true, first["ok"], first.inspect
      assert_equal false, first["complete"]
      assert_equal 2, first.dig("summary", "installed")
      assert_equal %w[installed installed], first["repositories"].map { |item| item.dig("bridge", "status") }
      assert first["repositories"].all? { |item| item["project_registration"]["status"] == "pending" }
      assert File.file?(config.bridge_setup_receipt_path)
      bridge_registry = File.read(config.bridge_registry_path)

      second = store.install_all(failure_policy: "continue")
      assert_equal true, second["ok"]
      assert_equal 2, second.dig("summary", "noop")
      assert_equal bridge_registry, File.read(config.bridge_registry_path)
      materialized_policy = File.read(File.join(materialized, ".flightdeck", "bridge", "AGENTS.md"))
      refute_includes materialized_policy, root
      refute_includes materialized_policy, materialized
    end
  end

  def test_bulk_bridge_conflict_refuses_overwrite_and_continue_policy_is_explicit
    with_hub do |root, config|
      conflict = initialize_repository(root, "a-conflict")
      safe = initialize_repository(root, "b-safe")
      [conflict, safe].each { |path| commit_repository(path) }
      File.write(File.join(conflict, "AGENTS.override.md"), "unmanaged instructions\n")
      config = register_repository(config, "a-conflict", conflict)
      config = register_repository(config, "b-safe", safe)
      config = write_declarations(
        config,
        [declaration("a-conflict", conflict), declaration("b-safe", safe)]
      )
      store = Flightdeck::BridgeBulkStore.new(config)
      plan = store.plan(failure_policy: "continue")
      assert_equal "blocked", plan["repositories"].first["status"]
      assert_includes(
        plan["repositories"].first["overwrite_blockers"].join(" "),
        "refusing to overwrite",
        plan["repositories"].first.inspect
      )

      stopped = store.install_all(failure_policy: "stop")
      assert_equal false, stopped["ok"]
      assert_equal "blocked", stopped["repositories"][0].dig("bridge", "status")
      assert_equal "not_attempted", stopped["repositories"][1].dig("bridge", "status")

      receipt = store.install_all(failure_policy: "continue")
      assert_equal false, receipt["ok"]
      assert_equal "blocked", receipt["repositories"][0].dig("bridge", "status")
      assert_equal "installed", receipt["repositories"][1].dig("bridge", "status")
      assert_equal "unmanaged instructions\n", File.read(File.join(conflict, "AGENTS.override.md"))
    end
  end

  def test_bulk_bridge_project_registration_requires_exact_verified_path
    with_hub do |root, config|
      verified = initialize_repository(root, "project-verified")
      pending = initialize_repository(root, "project-pending")
      [verified, pending].each { |path| commit_repository(path) }
      config = register_repository(config, "project-verified", verified)
      config = register_repository(config, "project-pending", pending)
      config = write_declarations(
        config,
        [declaration("project-verified", verified), declaration("project-pending", pending)]
      )
      Flightdeck::Support.atomic_yaml(
        config.project_registry_path,
        {
          "api_version" => "flightdeck.dev/v1alpha1",
          "kind" => "CodexProjectVerifications",
          "projects" => {
            "project-verified" => {
              "logical_key" => "project-verified",
              "runtime_project_id" => "opaque-runtime-project-verified",
              "path" => verified,
              "verified" => true,
              "verification_source" => "live_project_list_exact_path",
              "verified_at" => "2026-01-01T00:00:00Z"
            }
          }
        }
      )

      plan = Flightdeck::BridgeBulkStore.new(Flightdeck::Config.new(root: root)).plan
      states = plan["repositories"].to_h do |item|
        [item["repository_id"], item.dig("project_registration", "status")]
      end
      assert_equal "verified", states["project-verified"]
      assert_equal "pending", states["project-pending"]
      verified_item = plan["repositories"].find { |item| item["repository_id"] == "project-verified" }
      assert_equal "project-verified", verified_item.dig("project_registration", "logical_key")
      assert_equal "opaque-runtime-project-verified",
                   verified_item.dig("project_registration", "runtime_project_id")
      refute_equal verified_item.dig("project_registration", "logical_key"),
                   verified_item.dig("project_registration", "runtime_project_id")
      Flightdeck::BridgeStore.new(Flightdeck::Config.new(root: root)).install(
        repository_id: "project-verified",
        mode: "reference",
        profile: "application"
      )
      route = Flightdeck::RoutePlanner.new(Flightdeck::Config.new(root: root)).plan(
        workload_name: "development",
        work_type: "implementation",
        repository_id: "project-verified"
      )
      assert_equal "project-verified", route["project_key"]
      assert_equal "opaque-runtime-project-verified", route["runtime_project_id"]
      assert route["dispatch_ready"]

      project_state = Flightdeck::Support.load_data(config.project_registry_path)
      project_state["projects"]["project-pending"] = {
        "logical_key" => "project-pending",
        "runtime_project_id" => "opaque-runtime-project-pending",
        "path" => verified,
        "verified" => true,
        "verification_source" => "live_project_list_exact_path",
        "verified_at" => "2026-01-01T00:00:00Z"
      }
      Flightdeck::Support.atomic_yaml(config.project_registry_path, project_state)
      conflict_config = Flightdeck::Config.new(root: root)
      conflict = Flightdeck::BridgeBulkStore.new(conflict_config).plan
      pending_item = conflict["repositories"].find { |item| item["repository_id"] == "project-pending" }
      assert_equal "conflict", pending_item.dig("project_registration", "status")
      doctor = Flightdeck::Doctor.new(conflict_config).run
      assert_includes doctor["issues"].map { |item| item["code"] }, "project.registration_conflict"

      route = Flightdeck::RoutePlanner.new(Flightdeck::Config.new(root: root)).plan(
        workload_name: "development",
        work_type: "implementation",
        repository_id: "project-verified"
      )
      assert_equal "project-verified", route["project_key"]
      assert_equal "opaque-runtime-project-verified", route["runtime_project_id"]
      assert route["dispatch_ready"]
      assert_equal "reference", route.dig("bridge_handoff", "mode")
    end
  end

  def test_legacy_logical_key_runtime_id_self_equality_record_is_rejected
    with_hub do |root, config|
      repository = initialize_repository(root, "legacy-self-equality")
      commit_repository(repository)
      config = register_repository(config, "legacy-self-equality", repository)
      write_declarations(config, [declaration("legacy-self-equality", repository)])
      Flightdeck::Support.atomic_yaml(
        config.project_registry_path,
        {
          "api_version" => "flightdeck.dev/v1alpha1",
          "kind" => "CodexProjectVerifications",
          "projects" => {
            "legacy-self-equality" => {
              "project_id" => "legacy-self-equality",
              "path" => repository,
              "verified" => true
            }
          }
        }
      )

      error = assert_raises(Flightdeck::ConfigurationError) do
        Flightdeck::Config.new(root: root).project_verifications
      end
      assert_includes error.message, "runtime_project_id"
    end
  end

  def test_repository_declarations_refuse_credentials_and_absolute_paths
    with_hub do |root, config|
      repository = initialize_repository(root, "declaration-safety")
      commit_repository(repository)
      unsafe = declaration("declaration-safety", repository)
      unsafe["provider"] = "git"
      unsafe["locator"] = "https://user:secret@example.invalid/repository.git"
      config = write_declarations(config, [unsafe])
      assert_raises(Flightdeck::ConfigurationError) { config.repository_declarations }

      unsafe["locator"] = "https://example.invalid/repository.git"
      unsafe["local_path"] = repository
      config = write_declarations(config, [unsafe])
      assert_raises(Flightdeck::ConfigurationError) { config.repository_declarations }
    end
  end

  def test_attached_repository_resolves_only_from_ignored_local_state
    with_hub do |root, config|
      repository = initialize_repository(File.dirname(root), "attached-service")
      commit_repository(repository)
      config = register_repository(
        config,
        "attached-service",
        repository,
        placement: "attached"
      )
      config = write_declarations(
        config,
        [declaration("attached-service", repository, placement: "attached")]
      )

      registered = config.repository("attached-service")
      assert_equal "attached", registered["placement"]
      assert_equal File.realpath(repository), config.repository_path(registered)
      declaration_value = config.repository_declarations.find do |entry|
        entry["id"] == "attached-service"
      end
      refute declaration_value.key?("local_path")

      plan = Flightdeck::BridgeBulkStore.new(config).plan
      item = plan.fetch("repositories").find { |entry| entry["repository_id"] == "attached-service" }
      assert_equal File.realpath(repository), item["git_root"]
      assert_equal true, item.dig("checkout", "git_root_verified")
      assert_empty item["blockers"]
      assert_equal "ready", item["status"]

      unsafe = declaration("attached-service", repository, placement: "attached")
      unsafe["local_path"] = repository
      unsafe_config = write_declarations(config, [unsafe])
      error = assert_raises(Flightdeck::ConfigurationError) do
        unsafe_config.repository_declarations
      end
      assert_includes error.message, "must not store a machine-local path"
    end
  end

  def test_mission_client_snapshot_requires_an_exact_immutable_parent_binding
    with_hub do |root, config|
      store = Flightdeck::MissionStore.new(config)
      store.create(
        slug: "bound-snapshot", title: "Bound snapshot", outcome: "Exercise a snapshot.",
        mode: "dispatch_only", parent_chat_id: "operator-parent-a"
      )
      record_path = File.join(config.mission_dir, "bound-snapshot", "mission.yaml")
      record_before = File.binread(record_path)
      refute_includes record_before, "operator-parent-a"

      output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new)
      assert_equal 0, cli.run([
        "mission", "client-snapshot", "--hub-root", root, "--mission", "bound-snapshot",
        "--parent-chat-id", "operator-parent-a", "--json"
      ])
      snapshot = JSON.parse(output.string)
      assert_equal "flightdeck.mission-client-snapshot/v1", snapshot["api_version"]
      assert_equal "MissionClientSnapshot", snapshot["kind"]
      assert_equal true, snapshot["ok"]
      assert_equal "operator-parent-a", snapshot.dig("provenance", "parent_chat_id")
      assert_equal [], snapshot.fetch("nodes")
      assert_equal [], snapshot.fetch("task_events")
      assert_equal({ "mode" => "none" }, snapshot.fetch("recovery"))
      assert_equal record_before, File.binread(record_path)

      output.truncate(0)
      output.rewind
      assert_equal 1, cli.run([
        "mission", "client-snapshot", "--hub-root", root, "--mission", "bound-snapshot",
        "--parent-chat-id", "operator-parent-b", "--json"
      ])
      denied = JSON.parse(output.string)
      assert_equal "identity_unresolved", denied.dig("error", "code")
      refute denied.key?("provenance")
      refute denied.key?("nodes")
      refute denied.key?("task_events")
    end
  end

  def test_mission_client_snapshot_rejects_unknown_and_cross_hub_callers
    with_hub do |first_root, first_config|
      Flightdeck::MissionStore.new(first_config).create(
        slug: "shared-snapshot", title: "First snapshot", outcome: "Exercise a snapshot.",
        mode: "dispatch_only", parent_chat_id: "first-parent"
      )
      with_hub do |second_root, second_config|
        Flightdeck::MissionStore.new(second_config).create(
          slug: "shared-snapshot", title: "Second snapshot", outcome: "Exercise a snapshot.",
          mode: "dispatch_only", parent_chat_id: "second-parent"
        )
        output = StringIO.new
        cli = Flightdeck::CLI.new(root: first_root, out: output, err: StringIO.new)

        assert_equal 1, cli.run([
          "mission", "client-snapshot", "--hub-root", File.join(first_root, "unknown"),
          "--mission", "shared-snapshot", "--parent-chat-id", "first-parent", "--json"
        ])
        unknown = JSON.parse(output.string)
        assert_equal "hub_root_not_found", unknown.dig("error", "code")
        refute unknown.key?("provenance")

        output.truncate(0)
        output.rewind
        assert_equal 1, cli.run([
          "mission", "client-snapshot", "--hub-root", second_root, "--mission", "shared-snapshot",
          "--parent-chat-id", "first-parent", "--json"
        ])
        cross_hub = JSON.parse(output.string)
        assert_equal "identity_unresolved", cross_hub.dig("error", "code")
        refute cross_hub.key?("provenance")
        refute_includes output.string, "second-parent"
      end
    end
  end

  def test_mission_client_snapshot_contract_is_declared_and_closed
    schema = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "schemas", "mission-client-snapshot.schema.json")))
    assert_equal "https://flightdeck.dev/schemas/mission-client-snapshot.schema.json", schema["$id"]
    assert_equal false, schema.dig("$defs", "success", "additionalProperties")
    assert_equal false, schema.dig("$defs", "error", "additionalProperties")
    assert_includes schema.dig("$defs", "error", "properties", "error", "properties", "code", "enum"), "identity_unresolved"

    compatibility = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "compatibility.json")))
    assert_equal "1.8.0", compatibility["template_version"]
    capability = compatibility.dig("capabilities", "flightdeck.command.mission-client-snapshot.v1")
    assert_equal "command", capability["kind"]
    assert_includes capability["managed_paths"], "hub/schemas/mission-client-snapshot.schema.json"

    compatibility_schema = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "schemas", "hub-compatibility.schema.json")))
    assert_includes compatibility_schema.fetch("required"), "runtime_capabilities"
    assert_equal false, compatibility_schema.dig("properties", "runtime_capabilities", "additionalProperties")

    mission_schema = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "schemas", "mission.schema.json")))
    binding = mission_schema.dig("properties", "metadata", "properties", "client_snapshot_binding")
    assert_equal false, binding["additionalProperties"]
    assert_equal "flightdeck.mission-client-binding/v1", binding.dig("properties", "binding_version", "const")
  end

  def test_work_coordinator_returns_runtime_boundary_or_review_only_exact_operation_proposal
    with_hub do |root, config|
      client = initialize_repository(root, "flightdeck-client")
      plugin = initialize_repository(root, "flightdeck-plugin")
      config = register_repository(config, "flightdeck-client", client)
      config = register_repository(config, "flightdeck-plugin", plugin)
      config = write_declarations(config, [declaration("flightdeck-client", client), declaration("flightdeck-plugin", plugin)])
      write_project_verifications(config, {
        "flightdeck-client" => verified_project("flightdeck-client", client),
        "flightdeck-plugin" => verified_project("flightdeck-plugin", plugin)
      })
      coordinator = Flightdeck::WorkCoordinator.new(config)

      ordinary = coordinator.coordinate(
        "schema_version" => Flightdeck::WorkCoordinator::REQUEST,
        "message" => "Explain the purpose of this Hub.",
        "active_operation_id" => nil
      )
      assert_equal "runtime_delegate", ordinary["disposition"]
      assert_equal "codex", ordinary.dig("runtime", "adapter")
      assert_equal true, ordinary.dig("runtime", "available")
      assert_nil ordinary["proposal"]
      refute Dir.exist?(config.mission_dir)

      coordinated = coordinator.coordinate(
        "schema_version" => Flightdeck::WorkCoordinator::REQUEST,
        "message" => "Compare flightdeck-client and flightdeck-plugin across the release boundary.",
        "active_operation_id" => nil
      )
      assert_equal "operation_proposal", coordinated["disposition"]
      proposal = coordinated.fetch("proposal")
      assert_equal %w[flightdeck-client flightdeck-plugin], proposal.dig("proposal", "selected_targets").map { |target| target.fetch("logical_project_key") }
      assert_match(/^operation-[0-9a-f]{24}$/, proposal.fetch("operation_id"))
      refute Dir.exist?(config.mission_dir), "reviewing a proposal must not launch an Operation"
    end
  end

  def test_operation_detail_and_work_guidance_are_bound_to_the_exact_created_operation
    with_hub do |root, config|
      client = initialize_repository(root, "flightdeck-client")
      plugin = initialize_repository(root, "flightdeck-plugin")
      config = register_repository(config, "flightdeck-client", client)
      config = register_repository(config, "flightdeck-plugin", plugin)
      config = write_declarations(config, [declaration("flightdeck-client", client), declaration("flightdeck-plugin", plugin)])
      write_project_verifications(config, {
        "flightdeck-client" => verified_project("flightdeck-client", client),
        "flightdeck-plugin" => verified_project("flightdeck-plugin", plugin)
      })
      coordinator = Flightdeck::WorkCoordinator.new(config)
      coordinated = coordinator.coordinate(
        "schema_version" => Flightdeck::WorkCoordinator::REQUEST,
        "message" => "Review flightdeck-client and flightdeck-plugin together.",
        "active_operation_id" => nil
      )
      proposal = coordinated.fetch("proposal")
      confirmation = %w[operation_id plan_id plan_generation plan_digest plan_token].to_h { |field| [field, proposal.fetch(field)] }
      launched = Flightdeck::OperationAuthoring.new(config).launch(
        "schema_version" => Flightdeck::OperationAuthoring::LAUNCH_REQUEST,
        "operation_id" => proposal.fetch("operation_id"),
        "confirmation" => confirmation,
        "proposal" => proposal.fetch("proposal")
      )
      assert_equal "created", launched["outcome"]

      detail = Flightdeck::OperationDetail.new(config).detail(
        "schema_version" => Flightdeck::OperationDetail::REQUEST,
        "operation_id" => launched.fetch("operation_id")
      ).fetch("operation")
      assert_equal "work", detail["origin"]
      assert_equal "Review flightdeck-client and flightdeck-plugin together.", detail["goal"]
      assert_equal ["Flightdeck Client Agent", "Flightdeck Plugin Agent"], detail.fetch("agents").map { |agent| agent.fetch("name") }
      assert_equal({ "state" => "unavailable", "items" => [] }, detail["skills"])
      assert_equal false, detail.dig("authorization", "external_actions_authorized")

      guidance = coordinator.coordinate(
        "schema_version" => Flightdeck::WorkCoordinator::REQUEST,
        "message" => "Also verify the compatibility schemas.",
        "active_operation_id" => launched.fetch("operation_id")
      )
      assert_equal "guidance_attached", guidance["disposition"]
      assert_equal launched.fetch("operation_id"), guidance.dig("guidance", "operation_id")
    end
  end

  def test_mission_objective_preserves_ordered_operation_membership_and_requires_exact_confirmation
    with_hub do |root, config|
      client = initialize_repository(root, "flightdeck-client")
      plugin = initialize_repository(root, "flightdeck-plugin")
      config = register_repository(config, "flightdeck-client", client)
      config = register_repository(config, "flightdeck-plugin", plugin)
      config = write_declarations(config, [declaration("flightdeck-client", client), declaration("flightdeck-plugin", plugin)])
      write_project_verifications(config, {
        "flightdeck-client" => verified_project("flightdeck-client", client),
        "flightdeck-plugin" => verified_project("flightdeck-plugin", plugin)
      })
      coordinator = Flightdeck::WorkCoordinator.new(config)
      authoring = Flightdeck::OperationAuthoring.new(config)
      launch = lambda do |message|
        coordinated = coordinator.coordinate(
          "schema_version" => Flightdeck::WorkCoordinator::REQUEST,
          "message" => message,
          "active_operation_id" => nil
        )
        proposal = coordinated.fetch("proposal")
        confirmation = %w[operation_id plan_id plan_generation plan_digest plan_token].to_h { |field| [field, proposal.fetch(field)] }
        authoring.launch(
          "schema_version" => Flightdeck::OperationAuthoring::LAUNCH_REQUEST,
          "operation_id" => proposal.fetch("operation_id"),
          "confirmation" => confirmation,
          "proposal" => proposal.fetch("proposal")
        ).fetch("operation_id")
      end
      first = launch.call("Review flightdeck-client and flightdeck-plugin for compatibility.")
      second = launch.call("Compare flightdeck-plugin and flightdeck-client validation behavior.")
      objectives = Flightdeck::MissionObjectives.new(config)
      plan_request = {
        "schema_version" => Flightdeck::MissionObjectives::PLAN_REQUEST,
        "title" => "Flightdeck release mission",
        "goal" => "Deliver one supervised release decision.",
        "mode" => "supervised",
        "operation_ids" => [second, first]
      }
      plan = objectives.plan(plan_request)
      bad = %w[mission_id plan_id plan_digest plan_token].to_h { |field| [field, plan.fetch(field)] }
      bad["plan_token"] = "0" * 64
      assert_raises(Flightdeck::MissionObjectives::ContractError) do
        objectives.create("schema_version" => Flightdeck::MissionObjectives::CREATE_REQUEST, "plan_request" => plan_request, "confirmation" => bad)
      end

      confirmation = %w[mission_id plan_id plan_digest plan_token].to_h { |field| [field, plan.fetch(field)] }
      created = objectives.create("schema_version" => Flightdeck::MissionObjectives::CREATE_REQUEST, "plan_request" => plan_request, "confirmation" => confirmation)
      assert_equal false, created["replayed"]
      mission = objectives.snapshot("schema_version" => Flightdeck::MissionObjectives::SNAPSHOT_REQUEST, "mission_id" => created.fetch("mission_id")).fetch("missions").fetch(0)
      assert_equal [second, first], mission.fetch("operations").map { |operation| operation.fetch("operation_id") }
      assert_equal [1, 2], mission.fetch("operations").map { |operation| operation.fetch("order") }
      assert_equal "planned", mission["state"]
    end
  end

  def mission_observation(config, slug:, node_id:, state:, revision:, event_id: nil,
                          validation: nil, output_declarations: nil, cursor: nil, include_outcome: nil,
                          status_code: nil, criterion_results: nil, skill_events: nil)
    mission = Flightdeck::MissionStore.new(config).snapshot(slug)
    node = mission.dig("spec", "graph", "nodes").find { |item| item["id"] == node_id }
    validation ||= state == "failed_validation" ? "failed" : (state == "review_ready" ? "passed" : "not_applicable")
    output_declarations ||= state == "review_ready" ? [
      { "type" => node.fetch("allowed_output_types").first, "codex_task" => true }
    ] : []
    observation = {
      "node_id" => node_id,
      "logical_project_key" => node["logical_project_key"],
      "runtime_project_id" => node["runtime_project_id"],
      "project_path_digest" => node["project_path_digest"],
      "host_id" => node["host_id"],
      "task_id" => node["task_id"],
      "cursor" => cursor || "cursor-#{node_id}-#{revision}",
      "revision" => revision,
      "event_id" => event_id || "event-#{node_id}-#{revision}",
      "observed_state" => state,
      "status_code" => status_code || (state == "notLoaded" ? "not_loaded" : state),
      "observed_at" => (Time.now.utc + revision).iso8601,
      "worktree_ready" => true
    }
    observation["skill_events"] = skill_events if skill_events
    include_outcome = %w[review_ready failed_validation].include?(state) if include_outcome.nil?
    if include_outcome
      observation["outcome"] = {
        "schema_version" => "flightdeck.child-outcome/v1",
        "code" => observation["status_code"],
        "validation" => validation,
        "output_declarations" => output_declarations,
        "criterion_results" => criterion_results || node.fetch("criterion_ids").each_with_index.map do |criterion_id, index|
          passed = state == "review_ready" || index.positive?
          {
            "criterion_id" => criterion_id,
            "disposition" => passed ? "passed" : "failed",
            "status_code" => passed ? "criterion_passed" : "criterion_failed"
          }
        end
      }
    end
    observation
  end

  def skill_event(skill_id:, status:, evidence_id:, observed_at:, version: nil,
                  source: "codex_task_skill_event")
    {
      "schema_version" => "flightdeck.skill-invocation-event/v1",
      "skill_id" => skill_id,
      "skill_version" => version,
      "lifecycle_status" => status,
      "observed_at" => observed_at,
      "evidence_id" => evidence_id,
      "evidence_source" => source
    }
  end

  def write_mission_observations(root, slug, observations, name: "observations.json")
    path = File.join(root, name)
    File.write(
      path,
      JSON.pretty_generate(
        {
          "api_version" => "flightdeck.dev/v1alpha1",
          "kind" => "MissionObservationBatch",
          "schema" => "hub/schemas/mission-observation.schema.json",
          "mission_id" => slug,
          "observed_at" => Time.now.utc.iso8601,
          "observations" => observations
        }
      )
    )
    path
  end

  def apply_mission_sync(sync, slug:, observations_path:)
    plan = sync.plan(slug: slug, observations_path: observations_path)
    sync.apply(slug: slug, observations_path: observations_path, plan_token: plan.fetch("plan_token"))
  end

  def with_authoring_fixture
    with_hub do |root, config|
      project_path = initialize_repository(root, "authoring-project")
      config = register_repository(config, "authoring-project", project_path)
      config = write_declarations(config, [declaration("authoring-project", project_path)])
      write_project_verifications(
        config,
        "authoring-project" => verified_project(
          "authoring-project", project_path, runtime_id: "runtime-project-authoring"
        )
      )
      config = Flightdeck::Config.new(root: root)
      authoring = Flightdeck::MissionAuthoring.new(
        config,
        clock: -> { Time.iso8601("2026-08-06T12:00:00Z") }
      )
      catalog = authoring.catalog(
        "schema_version" => Flightdeck::MissionAuthoring::CATALOG_REQUEST
      )
      target = catalog.fetch("targets").find do |candidate|
        candidate["logical_project_key"] == "authoring-project" &&
          candidate["execution_mode"] == "worktree" && candidate["access_mode"] == "write"
      end
      yield root, config, authoring, catalog, target
    end
  end

  def with_operation_authoring_fixture
    with_authoring_fixture do |root, config, _mission_authoring, _catalog, _target|
      authoring = Flightdeck::OperationAuthoring.new(
        config,
        clock: -> { Time.iso8601("2026-08-08T12:00:00Z") }
      )
      catalog = authoring.catalog("schema_version" => Flightdeck::OperationAuthoring::CATALOG_REQUEST)
      target = catalog.fetch("targets").find do |candidate|
        candidate["logical_project_key"] == "authoring-project" &&
          candidate["execution_mode"] == "worktree" && candidate["access_mode"] == "write"
      end
      yield root, config, authoring, catalog, target
    end
  end

  def operation_proposal(target, title: "Client Operation")
    {
      "title" => title,
      "work_intent" => "Produce one durable planned Operation without dispatching work.",
      "success_criteria" => ["The Operation has an exact validated target binding."],
      "non_goals" => ["Do not dispatch, infer task state, claim skill use, or claim success."],
      "mode" => "supervised",
      "selected_targets" => [target.reject { |key, _| key == "display_label" }]
    }
  end

  def operation_plan(authoring, proposal)
    authoring.plan("schema_version" => Flightdeck::OperationAuthoring::PLAN_REQUEST, "proposal" => proposal)
  end

  def operation_launch_request(plan, proposal)
    {
      "schema_version" => Flightdeck::OperationAuthoring::LAUNCH_REQUEST,
      "operation_id" => plan.fetch("operation_id"),
      "confirmation" => %w[operation_id plan_id plan_generation plan_digest plan_token].to_h do |field|
        [field, plan.fetch(field)]
      end,
      "proposal" => proposal
    }
  end

  def bind_work_adapter(store, created, session_id: "codex-thread-session-0001", request_id: "adapter-binding-request-0001")
    store.bind_adapter(
      "schema_version" => Flightdeck::WorkStore::ADAPTER_BIND_REQUEST,
      "work_id" => created.dig("work", "work_id"),
      "resume_generation" => created.dig("resume", "generation"),
      "adapter" => "codex",
      "adapter_session_id" => session_id,
      "binding_request_id" => request_id,
      "structured_channel" => Flightdeck::WorkStore::STRUCTURED_CHANNEL
    )
  end

  def signed_work_observation(store, binding_result, session_id:, observation_id:, observed_at:, recommendation: nil,
                              observation_type: "managed_recommendation", resume_generation: nil)
    binding = binding_result.fetch("binding")
    observation = {
      "schema_version" => Flightdeck::WorkStore::OBSERVATION_VERSION,
      "hub_binding_id" => binding.fetch("hub_binding_id"),
      "work_id" => binding.fetch("work_id"),
      "binding_id" => binding.fetch("binding_id"),
      "adapter" => binding.fetch("adapter"),
      "adapter_session_id" => session_id,
      "session_generation" => binding.fetch("session_generation"),
      "resume_generation" => resume_generation || binding.fetch("resume_generation"),
      "structured_channel" => binding.fetch("structured_channel"),
      "observation_id" => observation_id,
      "observation_type" => observation_type,
      "observed_at" => observed_at
    }
    observation["recommendation"] = recommendation if recommendation
    canonical = store.send(:canonical_json, observation)
    observation["signature"] = OpenSSL::HMAC.hexdigest("SHA256", binding.fetch("shared_secret"), canonical)
    observation
  end

  def propose_work_operation(store, suffix:, project_keys:, observed_at: "2026-08-09T12:00:00Z")
    created = store.create(
      "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
      "request_key" => "request-work-lifecycle-#{suffix}",
      "title_hint" => "Lifecycle #{suffix}"
    )
    session_id = "codex-thread-lifecycle-#{suffix}"
    binding = bind_work_adapter(
      store, created, session_id: session_id, request_id: "adapter-binding-lifecycle-#{suffix}"
    )
    recommendation = {
      "schema_version" => Flightdeck::WorkStore::RECOMMENDATION_VERSION,
      "recommendation_id" => "runtime-operation-lifecycle-#{suffix}",
      "disposition" => "operation",
      "observed_at" => observed_at,
      "title" => "Lifecycle #{suffix}",
      "work_intent" => "Exercise the exact persisted Work to Operation lifecycle.",
      "target_project_keys" => project_keys,
      "access_mode" => "write",
      "execution_mode" => "worktree",
      "success_criteria" => ["Every exact lifecycle transition is persisted and recoverable."],
      "non_goals" => ["Do not perform unconfirmed or live dispatch."]
    }
    coordinated = store.coordinate(
      "schema_version" => Flightdeck::WorkStore::COORDINATE_REQUEST,
      "work_id" => created.dig("work", "work_id"),
      "observation" => signed_work_observation(
        store, binding, session_id: session_id,
        observation_id: "adapter-observation-lifecycle-#{suffix}",
        observed_at: observed_at, recommendation: recommendation
      )
    )
    proposal = coordinated.fetch("proposal")
    confirmation = Flightdeck::OperationAuthoring::CONFIRMATION_FIELDS.to_h do |field|
      [field, proposal.fetch(field)]
    end
    {
      "work" => created,
      "binding" => binding,
      "coordinated" => coordinated,
      "proposal" => proposal,
      "confirmation" => confirmation
    }
  end

  def omp_execution_request(store, fixture, suffix: "0001")
    work_id = fixture.dig("work", "work", "work_id")
    operation_id = fixture.dig("proposal", "operation_id")
    store.launch(
      "schema_version" => Flightdeck::WorkStore::LAUNCH_REQUEST,
      "work_id" => work_id,
      "operation_id" => operation_id,
      "confirmation" => fixture.fetch("confirmation")
    )
    dispatch = store.dispatch_plan(
      "schema_version" => Flightdeck::WorkStore::DISPATCH_PLAN_REQUEST,
      "work_id" => work_id,
      "operation_id" => operation_id
    )
    request = {
      "schema_version" => Flightdeck::OmpOperationExecution::PLAN_REQUEST,
      "work_id" => work_id,
      "operation_id" => operation_id,
      "confirmation" => fixture.fetch("confirmation"),
      "dispatch_generation" => dispatch.fetch("dispatch_generation"),
      "dispatch_plan_digest" => dispatch.fetch("dispatch_plan_digest"),
      "idempotency_key" => "omp-execution-plan-#{suffix}",
      "agents" => dispatch.fetch("targets").map do |target|
        {
          "node_id" => target.fetch("node_id"),
          "authorized_task" => "Implement only the confirmed bounded Operation scope for #{target.fetch('logical_project_key')}.",
          "requested_model" => "gpt-5",
          "reasoning_effort" => "high",
          "tool_policy" => {
            "profile" => target.fetch("access_mode") == "write" ? "workspace_write" : "read_only",
            "allowed_tool_kinds" => %w[filesystem lsp shell subagent],
            "network_access" => false
          }
        }
      end
    }
    [request, dispatch]
  end

  def signed_omp_observation(execution, plan, binding, session_ref:, sequence:, lifecycle:, observed_at:, suffix:)
    request = {
      "schema_version" => Flightdeck::OmpOperationExecution::OBSERVE_REQUEST,
      "work_id" => plan.fetch("work_id"),
      "operation_id" => plan.fetch("operation_id"),
      "execution_id" => plan.dig("execution", "execution_id"),
      "execution_generation" => plan.dig("execution", "execution_generation"),
      "execution_digest" => plan.dig("execution", "execution_digest"),
      "agent_id" => binding.fetch("agent_id"),
      "binding_generation" => binding.dig("binding", "generation"),
      "observation_id" => "omp-observation-#{suffix}",
      "sequence" => sequence,
      "lifecycle" => lifecycle,
      "action_summary" => lifecycle == "review_ready" ? "Prepared bounded review evidence." : "Working within the confirmed Operation scope.",
      "tool" => { "kind" => "lsp", "status" => lifecycle == "review_ready" ? "succeeded" : "running" },
      "subagents" => { "active" => 0, "completed" => 0, "failed" => 0, "blocked" => 0 },
      "attention" => { "required" => false, "code" => nil },
      "error_code" => nil,
      "observed_at" => observed_at,
      "final_result" => lifecycle == "review_ready" ? {
        "summary" => "Confirmed Operation work is ready for Flightdeck review.",
        "evidence_refs" => ["omp-evidence-#{'a' * 48}"]
      } : nil,
      "omp_session_ref" => session_ref,
      "signature" => ""
    }
    payload = request.reject { |key, _| %w[omp_session_ref signature].include?(key) }
    request["signature"] = OpenSSL::HMAC.hexdigest("SHA256", session_ref, execution.send(:canonical_json, payload))
    request
  end

  def test_work_create_list_open_restart_and_ordinary_runtime_boundary_are_display_safe
    with_hub do |root, config|
      clock = -> { Time.iso8601("2026-08-09T12:00:00Z") }
      sequence = 0
      random = lambda do |_bytes|
        sequence += 1
        format("%024x", sequence)
      end
      store = Flightdeck::WorkStore.new(config, clock: clock, random_hex: random)
      first = store.create(
        "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
        "request_key" => "request-work-create-0001",
        "title_hint" => "Explain authentication"
      )
      replay = store.create(
        "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
        "request_key" => "request-work-create-0001",
        "title_hint" => "Explain authentication"
      )
      assert_equal first.dig("work", "work_id"), replay.dig("work", "work_id")
      assert_equal true, replay["replayed"]

      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.create(
          "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
          "request_key" => "request-work-create-0001",
          "title_hint" => "Conflicting title"
        )
      end
      assert_equal "duplicate_request_conflict", error.code

      assert_equal true, first.dig("runtime", "available")
      assert_equal "binding_required", first.dig("resume", "state")
      refute Dir.exist?(config.mission_dir)

      restarted = Flightdeck::WorkStore.new(Flightdeck::Config.new(root: root), clock: clock)
      opened = restarted.open(
        "schema_version" => Flightdeck::WorkStore::OPEN_REQUEST,
        "work_id" => first.dig("work", "work_id")
      )
      assert_equal %w[work_created], opened.fetch("events").map { |event| event.fetch("type") }
      assert_equal "binding_required", opened.dig("resume", "state")
      list = restarted.list_page(limit: 1)
      assert_equal [first.dig("work", "work_id")], list.fetch("works").map { |work| work.fetch("work_id") }

      rendered = JSON.generate(opened)
      refute_includes rendered, "shared_secret"
      refute_includes rendered, "hub_binding_id"
      refute_includes rendered, "session_generation"
      refute_includes rendered, root
      refute_includes rendered, "runtime_project_id"
      refute_includes rendered, "task_id"
      refute_includes File.read(Dir.glob(File.join(root, "hub/state/work/*.json")).first), "Explain how"
    end
  end

  def test_work_list_is_read_only_when_state_is_absent
    with_hub do |root, config|
      work_dir = File.join(root, "hub", "state", "work")
      refute File.exist?(work_dir)

      result = Flightdeck::WorkStore.new(config).list_page(limit: 1)

      assert_equal true, result["ok"]
      assert_empty result["works"]
      refute File.exist?(work_dir)
    end
  end

  def test_work_operation_recommendation_is_catalog_validated_review_only_and_explicitly_launched
    with_hub do |root, config|
      client = initialize_repository(root, "flightdeck-client")
      plugin = initialize_repository(root, "flightdeck-plugin")
      config = register_repository(config, "flightdeck-client", client)
      config = register_repository(config, "flightdeck-plugin", plugin)
      config = write_declarations(config, [declaration("flightdeck-client", client), declaration("flightdeck-plugin", plugin)])
      write_project_verifications(config, {
        "flightdeck-client" => verified_project("flightdeck-client", client),
        "flightdeck-plugin" => verified_project("flightdeck-plugin", plugin)
      })
      clock = -> { Time.iso8601("2026-08-09T12:00:00Z") }
      store = Flightdeck::WorkStore.new(config, clock: clock, random_hex: ->(_bytes) { "b" * 24 })
      work = store.create(
        "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
        "request_key" => "request-work-operation-0001",
        "title_hint" => "Hub management"
      )
      work_id = work.dig("work", "work_id")
      session_id = "codex-thread-hub-management-0001"
      binding = bind_work_adapter(store, work, session_id: session_id, request_id: "adapter-binding-hub-management-0001")
      recommendation = {
        "schema_version" => Flightdeck::WorkStore::RECOMMENDATION_VERSION,
        "recommendation_id" => "runtime-operation-recommendation-0001",
        "disposition" => "operation",
        "observed_at" => "2026-08-09T12:00:00Z",
        "title" => "Implement Hub management",
        "work_intent" => "Implement and validate the declared Hub management contract.",
        "target_project_keys" => %w[flightdeck-client flightdeck-plugin],
        "access_mode" => "write",
        "execution_mode" => "worktree",
        "success_criteria" => ["The declared contract is validated in every exact owner."],
        "non_goals" => ["Do not commit, push, publish, deploy, or communicate externally."]
      }

      observation = signed_work_observation(
        store, binding, session_id: session_id, observation_id: "adapter-observation-hub-management-0001",
        observed_at: recommendation.fetch("observed_at"), recommendation: recommendation
      )
      proposal_result = store.coordinate(
        "schema_version" => Flightdeck::WorkStore::COORDINATE_REQUEST,
        "work_id" => work_id,
        "observation" => observation
      )
      assert_equal "operation_proposal", proposal_result["disposition"]
      assert_equal %w[flightdeck-client flightdeck-plugin], proposal_result.dig("proposal", "targets").map { |target| target.fetch("logical_project_key") }
      refute Dir.exist?(config.mission_dir), "a Work proposal must not launch"
      rendered = JSON.generate(proposal_result)
      refute_includes rendered, root
      refute_includes rendered, "opaque-runtime"
      refute_includes rendered, "project_path_digest"

      replay = Flightdeck::WorkStore.new(config, clock: clock).coordinate(
        "schema_version" => Flightdeck::WorkStore::COORDINATE_REQUEST,
        "work_id" => work_id,
        "observation" => observation
      )
      assert_equal true, replay["replayed"]
      assert_equal proposal_result["proposal"], replay["proposal"]

      unknown = recommendation.merge(
        "recommendation_id" => "runtime-operation-recommendation-unknown",
        "target_project_keys" => ["unknown-owner"]
      )
      unknown_observation = signed_work_observation(
        store, binding, session_id: session_id, observation_id: "adapter-observation-unknown-owner-0001",
        observed_at: unknown.fetch("observed_at"), recommendation: unknown,
        resume_generation: binding.dig("binding", "resume_generation")
      )
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.coordinate("schema_version" => Flightdeck::WorkStore::COORDINATE_REQUEST, "work_id" => work_id, "observation" => unknown_observation)
      end
      assert_equal "unknown_target", error.code

      proposal = proposal_result.fetch("proposal")
      confirmation = %w[operation_id plan_id plan_generation plan_digest plan_token].to_h { |field| [field, proposal.fetch(field)] }
      stale = Marshal.load(Marshal.dump(confirmation))
      stale["plan_digest"] = "0" * 64
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.launch(
          "schema_version" => Flightdeck::WorkStore::LAUNCH_REQUEST,
          "work_id" => work_id,
          "operation_id" => proposal.fetch("operation_id"),
          "confirmation" => stale
        )
      end
      assert_equal "stale_or_mismatched_plan", error.code
      refute Dir.exist?(config.mission_dir)

      launched = store.launch(
        "schema_version" => Flightdeck::WorkStore::LAUNCH_REQUEST,
        "work_id" => work_id,
        "operation_id" => proposal.fetch("operation_id"),
        "confirmation" => confirmation
      )
      assert_equal "created", launched.dig("operation", "outcome")
      assert_equal proposal.fetch("operation_id"), launched.dig("work", "active_operation_id")
      opened = store.open("schema_version" => Flightdeck::WorkStore::OPEN_REQUEST, "work_id" => work_id)
      assert_equal "in_progress", opened.dig("operation_links", 0, "result_state")
      assert_equal opened.fetch("events").map { |event| event.fetch("event_id") }.uniq.length, opened.fetch("events").length

      mismatch = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.guidance(
          "schema_version" => Flightdeck::WorkStore::GUIDANCE_REQUEST,
          "work_id" => work_id,
          "operation_id" => "operation-#{'0' * 24}",
          "request_key" => "request-guidance-mismatch-0001",
          "guidance" => "Keep the contract exact."
        )
      end
      assert_equal "operation_identity_conflict", mismatch.code

      guidance_request = {
        "schema_version" => Flightdeck::WorkStore::GUIDANCE_REQUEST,
        "work_id" => work_id,
        "operation_id" => proposal.fetch("operation_id"),
        "request_key" => "request-guidance-exact-0001",
        "guidance" => "Keep the contract exact."
      }
      guidance = store.guidance(guidance_request)
      assert_equal proposal.fetch("operation_id"), guidance["operation_id"]
      assert_equal true, store.guidance(guidance_request)["replayed"]
      conflicting_guidance = guidance_request.merge("guidance" => "Different guidance.")
      error = assert_raises(Flightdeck::WorkStore::ContractError) { store.guidance(conflicting_guidance) }
      assert_equal "duplicate_request_conflict", error.code

      mission = Flightdeck::MissionStore.new(config).snapshot(proposal.fetch("operation_id"))
      mission.dig("spec", "graph", "nodes").each do |node|
        Flightdeck::MissionStore.new(config).record_dispatch(
          slug: proposal.fetch("operation_id"), node_id: node.fetch("id"),
          runtime_project_id: node.fetch("runtime_project_id"), host_id: node.fetch("host_id"),
          task_id: "task-#{node.fetch('id')}"
        )
      end
      observations = mission.dig("spec", "graph", "nodes").each_with_index.map do |node, index|
        mission_observation(config, slug: proposal.fetch("operation_id"), node_id: node.fetch("id"), state: "review_ready", revision: index + 1)
      end
      path = write_mission_observations(root, proposal.fetch("operation_id"), observations, name: "work-operation-final.json")
      apply_mission_sync(Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)), slug: proposal.fetch("operation_id"), observations_path: path)

      completed = Flightdeck::WorkStore.new(config, clock: clock).open(
        "schema_version" => Flightdeck::WorkStore::OPEN_REQUEST,
        "work_id" => work_id
      )
      assert_equal "result_ready", completed.dig("work", "status")
      assert_equal "available", completed.dig("operation_links", 0, "result_state")
      assert_equal 1, completed.fetch("events").count { |event| event["type"] == "operation_result" }
      repeated = Flightdeck::WorkStore.new(config, clock: clock).open(
        "schema_version" => Flightdeck::WorkStore::OPEN_REQUEST,
        "work_id" => work_id
      )
      assert_equal completed.fetch("events"), repeated.fetch("events")
      error = assert_raises(Flightdeck::WorkStore::ContractError) { store.guidance(guidance_request.merge("request_key" => "request-guidance-terminal-0001")) }
      assert_equal "terminal_operation", error.code
    end
  end

  def test_work_fails_closed_for_adapter_absence_symlink_malformed_identity_and_stale_pagination
    with_hub do |root, config|
      compatibility_path = File.join(root, "hub", "compatibility.json")
      compatibility = JSON.parse(File.read(compatibility_path))
      compatibility.dig("runtime_capabilities", "adapters", "codex")["available"] = false
      Flightdeck::Support.atomic_write(compatibility_path, "#{JSON.pretty_generate(compatibility)}\n")
      store = Flightdeck::WorkStore.new(config, random_hex: ->(_bytes) { "c" * 24 })
      created = store.create(
        "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
        "request_key" => "request-adapter-unavailable-0001",
        "title_hint" => "Unavailable adapter"
      )
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        bind_work_adapter(store, created, session_id: "codex-thread-unavailable-0001", request_id: "adapter-binding-unavailable-0001")
      end
      assert_equal "adapter_unavailable", error.code
      assert_equal "unavailable", created.dig("resume", "state")

      malformed = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.open("schema_version" => Flightdeck::WorkStore::OPEN_REQUEST, "work_id" => "work-not-valid")
      end
      assert_equal "malformed_request", malformed.code
      unsafe = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.create(
          "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
          "request_key" => "request-unsafe-title-0001",
          "title_hint" => "Open /Users/example/private"
        )
      end
      assert_equal "malformed_request", unsafe.code

      store = Flightdeck::WorkStore.new(config, random_hex: ->(_bytes) { "d" * 24 })
      store.create(
        "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
        "request_key" => "request-pagination-change-0001",
        "title_hint" => "Second Work"
      )
      first_page = store.list_page(limit: 1)
      refute_nil first_page.dig("page", "next_cursor")
      store = Flightdeck::WorkStore.new(config, random_hex: ->(_bytes) { "e" * 24 })
      store.create(
        "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
        "request_key" => "request-pagination-change-0002",
        "title_hint" => "Third Work"
      )
      stale = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.list_page(limit: 1, cursor: first_page.dig("page", "next_cursor"))
      end
      assert_equal "stale_cursor", stale.code

      record = File.join(root, "hub/state/work", "#{Digest::SHA256.hexdigest(created.dig('work', 'work_id'))}.json")
      original = File.read(record)
      oversized = JSON.parse(original)
      seed_event = oversized.fetch("events").first
      oversized["events"] = 201.times.map do |index|
        seed_event.merge(
          "event_id" => "work-event-#{format('%024x', index)}",
          "evidence_id" => Digest::SHA256.hexdigest("evidence-#{index}"),
          "payload_digest" => Digest::SHA256.hexdigest("payload-#{index}")
        )
      end
      Flightdeck::Support.atomic_write(record, "#{JSON.pretty_generate(oversized)}\n")
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.open("schema_version" => Flightdeck::WorkStore::OPEN_REQUEST, "work_id" => created.dig("work", "work_id"))
      end
      assert_equal "work_store_invalid", error.code
      Flightdeck::Support.atomic_write(record, original)

      backup = "#{record}.backup"
      FileUtils.mv(record, backup)
      File.symlink(backup, record)
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.open("schema_version" => Flightdeck::WorkStore::OPEN_REQUEST, "work_id" => created.dig("work", "work_id"))
      end
      assert_equal "work_store_invalid", error.code
    end
  end

  def test_work_unknown_launch_is_non_retryable_and_recovers_by_exact_open
    with_hub do |root, config|
      project = initialize_repository(root, "work-unknown-owner")
      config = register_repository(config, "work-unknown-owner", project)
      config = write_declarations(config, [declaration("work-unknown-owner", project)])
      write_project_verifications(config, "work-unknown-owner" => verified_project("work-unknown-owner", project))
      clock = -> { Time.iso8601("2026-08-09T12:00:00Z") }
      store = Flightdeck::WorkStore.new(config, clock: clock, random_hex: ->(_bytes) { "f" * 24 })
      work = store.create(
        "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
        "request_key" => "request-work-unknown-0001",
        "title_hint" => "Unknown launch recovery"
      )
      session_id = "codex-thread-unknown-launch-0001"
      binding = bind_work_adapter(store, work, session_id: session_id, request_id: "adapter-binding-unknown-launch-0001")
      recommendation = {
        "schema_version" => Flightdeck::WorkStore::RECOMMENDATION_VERSION,
        "recommendation_id" => "runtime-work-unknown-0001",
        "disposition" => "operation",
        "observed_at" => "2026-08-09T12:00:00Z",
        "title" => "Recover unknown launch",
        "work_intent" => "Create one exact durable Operation and recover its launch outcome.",
        "target_project_keys" => ["work-unknown-owner"],
        "access_mode" => "write",
        "execution_mode" => "worktree",
        "success_criteria" => ["The exact launch outcome is recoverable."],
        "non_goals" => ["Do not retry an unknown launch."]
      }
      coordinated = store.coordinate(
        "schema_version" => Flightdeck::WorkStore::COORDINATE_REQUEST,
        "work_id" => work.dig("work", "work_id"),
        "observation" => signed_work_observation(
          store, binding, session_id: session_id, observation_id: "adapter-observation-unknown-launch-0001",
          observed_at: recommendation.fetch("observed_at"), recommendation: recommendation
        )
      )
      proposal = coordinated.fetch("proposal")
      request = {
        "schema_version" => Flightdeck::WorkStore::LAUNCH_REQUEST,
        "work_id" => work.dig("work", "work_id"),
        "operation_id" => proposal.fetch("operation_id"),
        "confirmation" => %w[operation_id plan_id plan_generation plan_digest plan_token].to_h { |field| [field, proposal.fetch(field)] }
      }
      authoring = store.instance_variable_get(:@authoring)
      original = authoring.method(:write_operation!)
      authoring.define_singleton_method(:write_operation!) do |record|
        raise IOError, "synthetic response loss" if record["state"] == "created"

        original.call(record)
      end
      error = assert_raises(Flightdeck::WorkStore::ContractError) { store.launch(request) }
      assert_equal "unknown_outcome", error.code
      error = assert_raises(Flightdeck::WorkStore::ContractError) { store.launch(request) }
      assert_equal "unknown_outcome", error.code
      assert_equal 1, Flightdeck::MissionStore.new(config).list_page.fetch("missions").length
      authoring.define_singleton_method(:write_operation!, original)

      recovered = Flightdeck::WorkStore.new(Flightdeck::Config.new(root: root), clock: clock).open(
        "schema_version" => Flightdeck::WorkStore::OPEN_REQUEST,
        "work_id" => work.dig("work", "work_id")
      )
      assert_equal "operation_active", recovered.dig("work", "status")
      assert_equal "created", recovered.dig("operation_links", 0, "authoring_outcome")
      assert_equal 1, recovered.fetch("events").count { |event| event["type"] == "operation_launch_unknown" }
    ensure
      authoring.define_singleton_method(:write_operation!, original) if authoring && original
    end
  end

  def test_work_adapter_binding_is_signed_exact_restart_safe_and_fail_closed
    with_hub do |root, config|
      sequence = 0
      random = lambda do |_bytes|
        sequence += 1
        format("%024x", sequence)
      end
      store = Flightdeck::WorkStore.new(config, clock: -> { Time.iso8601("2026-08-09T13:00:00Z") }, random_hex: random)
      first = store.create(
        "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
        "request_key" => "request-adapter-auth-first-0001",
        "title_hint" => "First adapter Work"
      )
      second = store.create(
        "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
        "request_key" => "request-adapter-auth-second-0001",
        "title_hint" => "Second adapter Work"
      )

      unbound = {
        "schema_version" => Flightdeck::WorkStore::OBSERVATION_VERSION,
        "hub_binding_id" => "hub-binding-#{'0' * 24}",
        "work_id" => first.dig("work", "work_id"),
        "binding_id" => "adapter-binding-#{'0' * 24}",
        "adapter" => "codex",
        "adapter_session_id" => "codex-thread-unbound-0001",
        "session_generation" => "adapter-session-#{'0' * 48}",
        "resume_generation" => first.dig("resume", "generation"),
        "structured_channel" => Flightdeck::WorkStore::STRUCTURED_CHANNEL,
        "observation_id" => "adapter-observation-unbound-0001",
        "observation_type" => "runtime_disconnected",
        "observed_at" => "2026-08-09T13:00:00Z",
        "signature" => "0" * 64
      }
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.coordinate("schema_version" => Flightdeck::WorkStore::COORDINATE_REQUEST, "work_id" => first.dig("work", "work_id"), "observation" => unbound)
      end
      assert_equal "binding_absent", error.code

      first_session = "codex-thread-first-0001"
      first_binding = bind_work_adapter(store, first, session_id: first_session, request_id: "adapter-binding-first-0001")
      restarted = Flightdeck::WorkStore.new(config, clock: -> { Time.iso8601("2026-08-09T13:00:00Z") })
      replay = bind_work_adapter(restarted, first, session_id: first_session, request_id: "adapter-binding-first-0001")
      assert_equal true, replay["replayed"]
      assert_equal first_binding.fetch("binding"), replay.fetch("binding")

      stale_request = {
        "schema_version" => Flightdeck::WorkStore::ADAPTER_BIND_REQUEST,
        "work_id" => first.dig("work", "work_id"),
        "resume_generation" => first.dig("resume", "generation"),
        "adapter" => "codex",
        "adapter_session_id" => "codex-thread-stale-0001",
        "binding_request_id" => "adapter-binding-stale-0001",
        "structured_channel" => Flightdeck::WorkStore::STRUCTURED_CHANNEL
      }
      error = assert_raises(Flightdeck::WorkStore::ContractError) { restarted.bind_adapter(stale_request) }
      assert_equal "stale_binding", error.code
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        restarted.bind_adapter(stale_request.merge(
          "resume_generation" => first_binding.dig("binding", "resume_generation"),
          "binding_request_id" => "adapter-binding-channel-0001",
          "structured_channel" => "flightdeck.runtime.unsupported/v1"
        ))
      end
      assert_equal "unsupported_structured_channel", error.code

      second_session = "codex-thread-second-0001"
      second_binding = bind_work_adapter(store, second, session_id: second_session, request_id: "adapter-binding-second-0001")
      cross_work = signed_work_observation(
        store, first_binding, session_id: first_session, observation_id: "adapter-observation-cross-work-0001",
        observed_at: "2026-08-09T13:00:01Z", observation_type: "runtime_disconnected"
      )
      cross_work["work_id"] = second.dig("work", "work_id")
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.coordinate("schema_version" => Flightdeck::WorkStore::COORDINATE_REQUEST, "work_id" => second.dig("work", "work_id"), "observation" => cross_work)
      end
      assert_equal "binding_mismatch", error.code

      invalid_signature = signed_work_observation(
        store, first_binding, session_id: first_session, observation_id: "adapter-observation-bad-signature-0001",
        observed_at: "2026-08-09T13:00:01Z", observation_type: "runtime_disconnected"
      ).merge("signature" => "0" * 64)
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.coordinate("schema_version" => Flightdeck::WorkStore::COORDINATE_REQUEST, "work_id" => first.dig("work", "work_id"), "observation" => invalid_signature)
      end
      assert_equal "adapter_authentication_failed", error.code

      stale_observation = signed_work_observation(
        store, first_binding, session_id: first_session, observation_id: "adapter-observation-stale-0001",
        observed_at: "2026-08-09T13:00:01Z", observation_type: "runtime_disconnected",
        resume_generation: "resume-#{'0' * 48}"
      )
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.coordinate("schema_version" => Flightdeck::WorkStore::COORDINATE_REQUEST, "work_id" => first.dig("work", "work_id"), "observation" => stale_observation)
      end
      assert_equal "stale_binding", error.code

      malformed_recommendation = {
        "schema_version" => Flightdeck::WorkStore::RECOMMENDATION_VERSION,
        "recommendation_id" => "adapter-recommendation-ordinary-0001",
        "disposition" => "ordinary",
        "observed_at" => "2026-08-09T13:00:01Z"
      }
      malformed_observation = signed_work_observation(
        store, first_binding, session_id: first_session, observation_id: "adapter-observation-malformed-0001",
        observed_at: malformed_recommendation.fetch("observed_at"), recommendation: malformed_recommendation
      )
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.coordinate("schema_version" => Flightdeck::WorkStore::COORDINATE_REQUEST, "work_id" => first.dig("work", "work_id"), "observation" => malformed_observation)
      end
      assert_equal "malformed_request", error.code

      disconnected = signed_work_observation(
        store, first_binding, session_id: first_session, observation_id: "adapter-observation-disconnected-0001",
        observed_at: "2026-08-09T13:00:02Z", observation_type: "runtime_disconnected"
      )
      result = store.coordinate(
        "schema_version" => Flightdeck::WorkStore::COORDINATE_REQUEST,
        "work_id" => first.dig("work", "work_id"),
        "observation" => disconnected
      )
      assert_equal "runtime_unavailable", result["disposition"]
      assert_equal "disconnected", result.dig("resume", "state")
      assert_equal true, store.coordinate(
        "schema_version" => Flightdeck::WorkStore::COORDINATE_REQUEST,
        "work_id" => first.dig("work", "work_id"),
        "observation" => disconnected
      )["replayed"]

      after_disconnect = {
        "schema_version" => Flightdeck::WorkStore::RECOMMENDATION_VERSION,
        "recommendation_id" => "adapter-recommendation-after-disconnect-0001",
        "disposition" => "operation",
        "observed_at" => "2026-08-09T13:00:03Z",
        "title" => "Do not accept disconnected evidence",
        "work_intent" => "Prove that a disconnected adapter cannot recommend managed work.",
        "target_project_keys" => ["unknown-owner"],
        "access_mode" => "read_only",
        "execution_mode" => "local",
        "success_criteria" => ["The disconnected binding fails closed."],
        "non_goals" => ["Do not create an Operation."]
      }
      disconnected_observation = signed_work_observation(
        store, first_binding, session_id: first_session, observation_id: "adapter-observation-after-disconnect-0001",
        observed_at: after_disconnect.fetch("observed_at"), recommendation: after_disconnect,
        resume_generation: result.dig("resume", "generation")
      )
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.coordinate("schema_version" => Flightdeck::WorkStore::COORDINATE_REQUEST, "work_id" => first.dig("work", "work_id"), "observation" => disconnected_observation)
      end
      assert_equal "runtime_disconnected", error.code

      opened = store.open("schema_version" => Flightdeck::WorkStore::OPEN_REQUEST, "work_id" => first.dig("work", "work_id"))
      rendered = JSON.generate(opened)
      refute_includes rendered, first_binding.dig("binding", "shared_secret")
      refute_includes rendered, first_session
      assert_equal "disconnected", opened.dig("resume", "state")
      refute_nil second_binding
      refute_includes File.read(Dir.glob(File.join(root, "hub/state/work/*.json")).first), "codex-thread-first-0001"
    end
  end

  def test_work_operation_lifecycle_decline_is_persisted_idempotent_and_dispatch_free
    with_hub do |root, config|
      project = initialize_repository(root, "lifecycle-decline-owner")
      config = register_repository(config, "lifecycle-decline-owner", project)
      config = write_declarations(config, [declaration("lifecycle-decline-owner", project)])
      write_project_verifications(config, "lifecycle-decline-owner" => verified_project("lifecycle-decline-owner", project))
      sequence = 0
      store = Flightdeck::WorkStore.new(
        Flightdeck::Config.new(root: root),
        clock: -> { Time.iso8601("2026-08-09T14:00:00Z") },
        random_hex: ->(_bytes) { sequence += 1; format("%024x", sequence) }
      )
      fixture = propose_work_operation(store, suffix: "decline-0001", project_keys: ["lifecycle-decline-owner"])
      work_id = fixture.dig("work", "work", "work_id")
      operation_id = fixture.dig("proposal", "operation_id")
      confirmation = fixture.fetch("confirmation")

      opened = store.lifecycle_open(
        "schema_version" => Flightdeck::WorkStore::LIFECYCLE_OPEN_REQUEST,
        "work_id" => work_id
      )
      assert_equal "not_started", opened.dig("proposals", 0, "state")
      assert_equal({ "confirm_and_launch" => true, "decline" => true }, opened.dig("proposals", 0, "actions"))
      refute Dir.exist?(config.mission_dir), "proposal recovery must not create an Operation"

      tampered = Marshal.load(Marshal.dump(confirmation))
      tampered["plan_token"] = "0" * 64
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.decline(
          "schema_version" => Flightdeck::WorkStore::DECLINE_REQUEST,
          "work_id" => work_id, "operation_id" => operation_id, "confirmation" => tampered
        )
      end
      assert_equal "stale_or_mismatched_plan", error.code

      foreign = store.create(
        "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
        "request_key" => "request-work-lifecycle-foreign-0001",
        "title_hint" => "Foreign lifecycle"
      )
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.decline(
          "schema_version" => Flightdeck::WorkStore::DECLINE_REQUEST,
          "work_id" => foreign.dig("work", "work_id"), "operation_id" => operation_id,
          "confirmation" => confirmation
        )
      end
      assert_equal "operation_not_found", error.code

      request = {
        "schema_version" => Flightdeck::WorkStore::DECLINE_REQUEST,
        "work_id" => work_id, "operation_id" => operation_id, "confirmation" => confirmation
      }
      declined = store.decline(request)
      assert_equal "declined", declined["proposal_state"]
      assert_equal false, declined["replayed"]
      assert_equal true, store.decline(request)["replayed"]
      refute Dir.exist?(config.mission_dir), "decline must not create or dispatch an Operation"

      restarted = Flightdeck::WorkStore.new(Flightdeck::Config.new(root: root))
      recovered = restarted.lifecycle_open(
        "schema_version" => Flightdeck::WorkStore::LIFECYCLE_OPEN_REQUEST,
        "work_id" => work_id
      )
      assert_equal "declined", recovered.dig("proposals", 0, "state")
      assert_equal({ "confirm_and_launch" => false, "decline" => false }, recovered.dig("proposals", 0, "actions"))
      assert_empty recovered.dig("proposals", 0, "dispatches")
      ordinary_open = restarted.open(
        "schema_version" => Flightdeck::WorkStore::OPEN_REQUEST,
        "work_id" => work_id
      )
      assert_equal "open", ordinary_open.dig("work", "status")
      assert_equal "historical", ordinary_open.dig("operation_links", 0, "relation")
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        restarted.launch(
          "schema_version" => Flightdeck::WorkStore::LAUNCH_REQUEST,
          "work_id" => work_id, "operation_id" => operation_id, "confirmation" => confirmation
        )
      end
      assert_equal "proposal_declined", error.code
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        restarted.dispatch_plan(
          "schema_version" => Flightdeck::WorkStore::DISPATCH_PLAN_REQUEST,
          "work_id" => work_id, "operation_id" => operation_id
        )
      end
      assert_equal "not_created", error.code
    end
  end

  def test_work_operation_lifecycle_launch_dispatch_receipts_partial_failure_and_recovery_are_exact
    with_hub do |root, config|
      projects = %w[lifecycle-client lifecycle-plugin].to_h do |key|
        [key, initialize_repository(root, key)]
      end
      projects.each { |key, path| config = register_repository(config, key, path) }
      config = write_declarations(config, projects.map { |key, path| declaration(key, path) })
      write_project_verifications(
        config,
        projects.to_h { |key, path| [key, verified_project(key, path)] }
      )
      projects.each_key do |key|
        Flightdeck::BridgeStore.new(config).install(repository_id: key, mode: "reference", profile: "application")
      end
      config = Flightdeck::Config.new(root: root)
      sequence = 0
      clock = -> { Time.iso8601("2026-08-09T15:00:00Z") }
      store = Flightdeck::WorkStore.new(
        config, clock: clock,
        random_hex: ->(_bytes) { sequence += 1; format("%024x", sequence) }
      )
      fixture = propose_work_operation(store, suffix: "dispatch-0001", project_keys: projects.keys.sort)
      work_id = fixture.dig("work", "work", "work_id")
      operation_id = fixture.dig("proposal", "operation_id")
      launch_request = {
        "schema_version" => Flightdeck::WorkStore::LAUNCH_REQUEST,
        "work_id" => work_id, "operation_id" => operation_id,
        "confirmation" => fixture.fetch("confirmation")
      }
      launched = store.launch(launch_request)
      assert_equal false, launched.dig("operation", "replayed")
      replayed = Flightdeck::WorkStore.new(config, clock: clock).launch(launch_request)
      assert_equal true, replayed.dig("operation", "replayed")
      assert_equal 1, Flightdeck::MissionStore.new(config).list_page.fetch("missions").length

      plan = store.dispatch_plan(
        "schema_version" => Flightdeck::WorkStore::DISPATCH_PLAN_REQUEST,
        "work_id" => work_id, "operation_id" => operation_id
      )
      assert_equal "parallel_independent", plan.dig("policy", "strategy")
      assert_equal 2, plan.dig("policy", "max_concurrency")
      assert_equal true, plan.dig("policy", "requires_all_receipts")
      assert_equal projects.keys.sort, plan.fetch("targets").map { |target| target.fetch("logical_project_key") }.sort
      plan.fetch("targets").each do |target|
        route = target.fetch("route")
        assert_equal target["logical_project_key"], route["project_key"]
        assert_equal target["runtime_project_id"], route["runtime_project_id"]
        assert_equal target["project_path_digest"], Digest::SHA256.hexdigest(File.realpath(route.fetch("project_path")))
        assert_match(/\Ascope-[0-9a-f]{48}\z/, target.fetch("authorization_boundary"))
        assert_equal "verified", route.dig("bridge_handoff", "status")
        assert_equal false, route.dig("bridge_handoff", "copy_into_worktree")
      end

      receipt = lambda do |target, attempt:, outcome:, task_id: nil, pending_client_id: nil, error_code: nil|
        {
          "dispatch_id" => target.fetch("dispatch_id"),
          "node_id" => target.fetch("node_id"),
          "attempt_key" => attempt,
          "outcome" => outcome,
          "runtime_project_id" => target.fetch("runtime_project_id"),
          "host_id" => target.fetch("host_id"),
          "project_path_digest" => target.fetch("project_path_digest"),
          "task_id" => task_id,
          "pending_client_id" => pending_client_id,
          "error_code" => error_code
        }
      end
      first_target, second_target = plan.fetch("targets")
      pending_id = "pending-client-lifecycle-0001"
      first_report = {
        "schema_version" => Flightdeck::WorkStore::DISPATCH_REPORT_REQUEST,
        "work_id" => work_id,
        "operation_id" => operation_id,
        "dispatch_generation" => plan.fetch("dispatch_generation"),
        "dispatch_plan_digest" => plan.fetch("dispatch_plan_digest"),
        "report_id" => "dispatch-report-lifecycle-0001",
        "results" => [
          receipt.call(first_target, attempt: "dispatch-attempt-lifecycle-0001", outcome: "pending", pending_client_id: pending_id),
          receipt.call(second_target, attempt: "dispatch-attempt-lifecycle-0002", outcome: "failed", error_code: "native-dispatch-failed")
        ]
      }
      original_write = store.method(:write_record!)
      write_count = 0
      store.define_singleton_method(:write_record!) do |record|
        write_count += 1
        raise IOError, "synthetic Work receipt write interruption" if write_count == 2

        original_write.call(record)
      end
      interruption = assert_raises(Flightdeck::WorkStore::ContractError) { store.dispatch_report(first_report) }
      assert_equal "unknown_outcome", interruption.code
      store.define_singleton_method(:write_record!, original_write)
      journal = JSON.parse(File.read(Dir.glob(File.join(root, "hub/state/work/*.json")).find do |path|
        JSON.parse(File.read(path))["work_id"] == work_id
      end))
      assert_equal "applying", journal.dig("dispatch_reports", 0, "state")
      interrupted_node = Flightdeck::MissionStore.new(config).snapshot(operation_id).dig("spec", "graph", "nodes").find do |node|
        node["id"] == first_target["node_id"]
      end
      assert_equal "dispatch_pending", interrupted_node["observed_state"]
      competing_report = first_report.merge("report_id" => "dispatch-report-lifecycle-competing")
      error = assert_raises(Flightdeck::WorkStore::ContractError) { store.dispatch_report(competing_report) }
      assert_equal "unknown_outcome", error.code

      partial = Flightdeck::WorkStore.new(config, clock: clock).dispatch_report(first_report)
      assert_equal true, partial["replayed"]
      assert_equal %w[dispatch_pending failed], partial.fetch("dispatches").map { |item| item.fetch("state") }.sort
      assert_equal true, store.dispatch_report(first_report)["replayed"]
      conflicting_report = Marshal.load(Marshal.dump(first_report))
      conflicting_report.dig("results", 1)["error_code"] = "different-failure"
      error = assert_raises(Flightdeck::WorkStore::ContractError) { store.dispatch_report(conflicting_report) }
      assert_equal "duplicate_request_conflict", error.code

      terminal_report = first_report.merge(
        "report_id" => "dispatch-report-lifecycle-terminal-interruption",
        "results" => [receipt.call(
          second_target, attempt: "dispatch-attempt-lifecycle-terminal-interruption",
          outcome: "failed", error_code: "native-dispatch-still-failed"
        )]
      )
      write_count = 0
      store.define_singleton_method(:write_record!) do |record|
        write_count += 1
        raise IOError, "synthetic Work terminal journal interruption" if write_count == 3

        original_write.call(record)
      end
      terminal_interruption = assert_raises(Flightdeck::WorkStore::ContractError) do
        store.dispatch_report(terminal_report)
      end
      assert_equal "unknown_outcome", terminal_interruption.code
      store.define_singleton_method(:write_record!, original_write)
      terminal_journal = JSON.parse(File.read(Dir.glob(File.join(root, "hub/state/work/*.json")).find do |path|
        JSON.parse(File.read(path))["work_id"] == work_id
      end))
      assert_equal "applying", terminal_journal.dig("dispatch_reports", 1, "state")
      assert_equal true, store.dispatch_report(terminal_report)["replayed"]

      recovered_partial = Flightdeck::WorkStore.new(config, clock: clock).lifecycle_open(
        "schema_version" => Flightdeck::WorkStore::LIFECYCLE_OPEN_REQUEST,
        "work_id" => work_id
      )
      assert_equal %w[dispatch_pending failed], recovered_partial.dig("proposals", 0, "dispatches").map { |item| item.fetch("state") }.sort
      assert_equal operation_id, recovered_partial.dig("active_operation", "operation_id")

      second_report = first_report.merge(
        "report_id" => "dispatch-report-lifecycle-0002",
        "results" => [
          receipt.call(
            first_target, attempt: "dispatch-attempt-lifecycle-0003", outcome: "created",
            task_id: "codex-task-lifecycle-0001", pending_client_id: pending_id
          ),
          receipt.call(
            second_target, attempt: "dispatch-attempt-lifecycle-0004", outcome: "created",
            task_id: "codex-task-lifecycle-0002"
          )
        ]
      )
      mission_record_dispatch = Flightdeck::MissionStore.instance_method(:record_dispatch)
      dispatch_calls = 0
      Flightdeck::MissionStore.define_method(:record_dispatch) do |**arguments|
        dispatch_calls += 1
        raise Flightdeck::ValidationError, "synthetic later receipt rejection" if dispatch_calls == 2

        mission_record_dispatch.bind_call(self, **arguments)
      end
      rejected = assert_raises(Flightdeck::WorkStore::ContractError) { store.dispatch_report(second_report) }
      assert_equal "operation_identity_conflict", rejected.code
      rejected_journal = JSON.parse(File.read(Dir.glob(File.join(root, "hub/state/work/*.json")).find do |path|
        JSON.parse(File.read(path))["work_id"] == work_id
      end))
      assert_equal "rejected", rejected_journal.dig("dispatch_reports", 2, "state")
      assert_equal "operation_identity_conflict", rejected_journal.dig("dispatch_reports", 2, "error_code")
      replay_rejected = assert_raises(Flightdeck::WorkStore::ContractError) { store.dispatch_report(second_report) }
      assert_equal "operation_identity_conflict", replay_rejected.code
      Flightdeck::MissionStore.define_method(:record_dispatch, mission_record_dispatch)

      recovery_report = second_report.merge(
        "report_id" => "dispatch-report-lifecycle-0003",
        "results" => [receipt.call(
          second_target, attempt: "dispatch-attempt-lifecycle-0005", outcome: "created",
          task_id: "codex-task-lifecycle-0002"
        )]
      )
      completed_dispatch = store.dispatch_report(recovery_report)
      assert_equal %w[running running], completed_dispatch.fetch("dispatches").map { |item| item.fetch("state") }
      assert_equal true, store.dispatch_report(recovery_report)["replayed"]
      mission = Flightdeck::MissionStore.new(config).snapshot(operation_id)
      assert_equal %w[codex-task-lifecycle-0001 codex-task-lifecycle-0002], mission.dig("spec", "graph", "nodes").map { |node| node.fetch("task_id") }.sort
      operation_projection = Flightdeck::MissionStore.new(config).operation_projection(operation_id)
      assert_equal operation_id, operation_projection.dig("operation", "operation_id")
      assert_equal %w[resolved resolved], operation_projection.dig("operation", "children").map { |child| child.dig("session", "state") }
      safe_lifecycle = JSON.generate(store.lifecycle_open(
        "schema_version" => Flightdeck::WorkStore::LIFECYCLE_OPEN_REQUEST,
        "work_id" => work_id
      ))
      refute_includes safe_lifecycle, root
      refute_includes safe_lifecycle, "runtime_project_id"
      refute_includes safe_lifecycle, "codex-task-lifecycle"
      persisted_work = File.read(Dir.glob(File.join(root, "hub/state/work/*.json")).find do |path|
        JSON.parse(File.read(path))["work_id"] == work_id
      end)
      refute_includes persisted_work, root
      refute_includes persisted_work, "opaque-runtime"
      refute_includes persisted_work, "codex-task-lifecycle"
      refute_includes persisted_work, pending_id

      foreign_plan = Marshal.load(Marshal.dump(second_report))
      foreign_plan["report_id"] = "dispatch-report-lifecycle-foreign"
      foreign_plan["dispatch_plan_digest"] = "0" * 64
      error = assert_raises(Flightdeck::WorkStore::ContractError) { store.dispatch_report(foreign_plan) }
      assert_equal "stale_or_mismatched_plan", error.code
      duplicate_child = second_report.merge(
        "report_id" => "dispatch-report-lifecycle-duplicate",
        "results" => [receipt.call(
          first_target, attempt: "dispatch-attempt-lifecycle-duplicate", outcome: "created",
          task_id: "codex-task-lifecycle-other"
        )]
      )
      error = assert_raises(Flightdeck::WorkStore::ContractError) { store.dispatch_report(duplicate_child) }
      assert_equal "conflicting_operation", error.code
    ensure
      store.define_singleton_method(:write_record!, original_write) if store && original_write
      Flightdeck::MissionStore.define_method(:record_dispatch, mission_record_dispatch) if mission_record_dispatch
    end
  end

  def test_work_operation_lifecycle_reads_legacy_v1_and_preserves_accepted_binding_generation
    with_hub do |root, config|
      project = initialize_repository(root, "lifecycle-legacy-owner")
      config = register_repository(config, "lifecycle-legacy-owner", project)
      config = write_declarations(config, [declaration("lifecycle-legacy-owner", project)])
      write_project_verifications(config, "lifecycle-legacy-owner" => verified_project("lifecycle-legacy-owner", project))
      sequence = 0
      store = Flightdeck::WorkStore.new(
        Flightdeck::Config.new(root: root),
        random_hex: ->(_bytes) { sequence += 1; format("%024x", sequence) }
      )
      fixture = propose_work_operation(store, suffix: "legacy-0001", project_keys: ["lifecycle-legacy-owner"])
      assert_equal fixture.dig("work", "resume", "generation"), fixture.dig("binding", "binding", "resume_generation")
      work_id = fixture.dig("work", "work", "work_id")
      record_path = Dir.glob(File.join(root, "hub/state/work/*.json")).find do |path|
        JSON.parse(File.read(path))["work_id"] == work_id
      end
      record = JSON.parse(File.read(record_path))
      record["schema_version"] = Flightdeck::WorkStore::LEGACY_RECORD_VERSION
      record.delete("dispatch_reports")
      record.fetch("proposals").each do |proposal|
        next unless proposal["kind"] == "operation_proposal"

        %w[lifecycle_state state_observed_at decline_digest declined_at launched_at dispatches].each { |field| proposal.delete(field) }
      end
      File.write(record_path, JSON.generate(record))

      restarted = Flightdeck::WorkStore.new(Flightdeck::Config.new(root: root))
      recovered = restarted.lifecycle_open(
        "schema_version" => Flightdeck::WorkStore::LIFECYCLE_OPEN_REQUEST,
        "work_id" => work_id
      )
      assert_equal "not_started", recovered.dig("proposals", 0, "state")
      declined = restarted.decline(
        "schema_version" => Flightdeck::WorkStore::DECLINE_REQUEST,
        "work_id" => work_id,
        "operation_id" => fixture.dig("proposal", "operation_id"),
        "confirmation" => fixture.fetch("confirmation")
      )
      assert_equal "declined", declined["proposal_state"]
      migrated = JSON.parse(File.read(record_path))
      assert_equal Flightdeck::WorkStore::RECORD_VERSION, migrated["schema_version"]
      assert_equal [], migrated["dispatch_reports"]
    end
  end

  def test_omp_operation_execution_is_post_confirmation_exact_once_authenticated_and_renderer_safe
    with_hub do |root, config|
      project = initialize_repository(root, "omp-operation-owner")
      config = register_repository(config, "omp-operation-owner", project)
      config = write_declarations(config, [declaration("omp-operation-owner", project)])
      write_project_verifications(config, "omp-operation-owner" => verified_project("omp-operation-owner", project))
      Flightdeck::BridgeStore.new(config).install(repository_id: "omp-operation-owner", mode: "reference", profile: "application")
      config = Flightdeck::Config.new(root: root)
      sequence = 0
      clock = -> { Time.iso8601("2026-08-10T16:00:00Z") }
      work = Flightdeck::WorkStore.new(
        config, clock: clock,
        random_hex: ->(_bytes) { sequence += 1; format("%024x", sequence) }
      )
      fixture = propose_work_operation(work, suffix: "omp-0001", project_keys: ["omp-operation-owner"])
      error = assert_raises(Flightdeck::WorkStore::ContractError) do
        work.bind_adapter(
          "schema_version" => Flightdeck::WorkStore::ADAPTER_BIND_REQUEST,
          "work_id" => fixture.dig("work", "work", "work_id"),
          "resume_generation" => fixture.dig("binding", "binding", "resume_generation"),
          "adapter" => "omp",
          "adapter_session_id" => "omp-conversation-substitution-0001",
          "binding_request_id" => "omp-conversation-substitution-0001",
          "structured_channel" => Flightdeck::WorkStore::STRUCTURED_CHANNEL
        )
      end
      assert_equal "adapter_unavailable", error.code
      request, _dispatch = omp_execution_request(work, fixture, suffix: "omp-0001")
      execution = Flightdeck::OmpOperationExecution.new(config, clock: clock, random_hex: ->(_bytes) { "1" * 32 })

      plan = execution.plan(request)
      assert_equal Flightdeck::OmpOperationExecution::EXECUTION_CAPABILITY, plan["capability"]
      assert_equal({ "conversation" => "codex", "operation_execution" => "omp" }, plan["runtime_boundary"])
      assert_equal "confirmed", plan.dig("authorization", "state")
      assert_equal fixture.dig("confirmation", "plan_digest"), plan.dig("authorization", "plan_digest")
      assert_equal Digest::SHA256.hexdigest(fixture.dig("confirmation", "plan_token")), plan.dig("authorization", "plan_token_digest")
      assert_equal "parallel_independent", plan.dig("policy", "strategy")
      assert_equal true, execution.plan(request)["replayed"]
      assert_equal plan.dig("execution", "execution_id"), execution.plan(request).dig("execution", "execution_id")
      assert_match(/\Aflightdeck-agent-[0-9a-f]{48}\z/, plan.dig("agents", 0, "agent_id"))
      refute plan.dig("agents", 0, "native_authorization").key?("project_path")

      conflict = Marshal.load(Marshal.dump(request))
      conflict.dig("agents", 0)["authorized_task"] = "Conflicting task content."
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) { execution.plan(conflict) }
      assert_equal "duplicate_request_conflict", error.code

      session_ref = "omp-session-operation-owner-0001"
      agent = plan.fetch("agents").first
      bind_request = {
        "schema_version" => Flightdeck::OmpOperationExecution::BIND_REQUEST,
        "work_id" => plan.fetch("work_id"),
        "operation_id" => plan.fetch("operation_id"),
        "execution_id" => plan.dig("execution", "execution_id"),
        "execution_generation" => plan.dig("execution", "execution_generation"),
        "execution_digest" => plan.dig("execution", "execution_digest"),
        "agent_id" => agent.fetch("agent_id"),
        "binding_idempotency_key" => "omp-binding-operation-owner-0001",
        "omp_session_ref" => session_ref
      }
      binding = execution.bind(bind_request)
      assert_equal "bound", binding.dig("binding", "state")
      assert_equal true, execution.bind(bind_request)["replayed"]
      assert_equal "bound", execution.plan(request).dig("agents", 0, "binding_state")
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) do
        execution.bind(bind_request.merge("omp_session_ref" => "omp-session-operation-owner-foreign"))
      end
      assert_equal "duplicate_request_conflict", error.code

      running = signed_omp_observation(
        execution, plan, binding, session_ref: session_ref, sequence: 1, lifecycle: "running",
        observed_at: "2026-08-10T16:00:01Z", suffix: "operation-owner-0001"
      )
      observed = execution.observe(running)
      assert_equal "running", observed.dig("agent", "observation", "lifecycle")
      assert_equal true, execution.observe(running)["replayed"]

      out_of_order = signed_omp_observation(
        execution, plan, binding, session_ref: session_ref, sequence: 3, lifecycle: "running",
        observed_at: "2026-08-10T16:00:02Z", suffix: "operation-owner-0003"
      )
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) { execution.observe(out_of_order) }
      assert_equal "out_of_order_observation", error.code
      stale = signed_omp_observation(
        execution, plan, binding, session_ref: session_ref, sequence: 2, lifecycle: "running",
        observed_at: "2026-08-10T16:00:02Z", suffix: "operation-owner-stale"
      )
      stale["binding_generation"] = "omp-binding-generation-#{'0' * 48}"
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) { execution.observe(stale) }
      assert_equal "stale_binding", error.code
      bad_signature = signed_omp_observation(
        execution, plan, binding, session_ref: session_ref, sequence: 2, lifecycle: "running",
        observed_at: "2026-08-10T16:00:02Z", suffix: "operation-owner-auth"
      ).merge("signature" => "0" * 64)
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) { execution.observe(bad_signature) }
      assert_equal "authentication_failed", error.code

      final = signed_omp_observation(
        execution, plan, binding, session_ref: session_ref, sequence: 2, lifecycle: "review_ready",
        observed_at: "2026-08-10T16:00:02Z", suffix: "operation-owner-0002"
      )
      assert_equal "review_ready", execution.observe(final).fetch("execution_state")
      assert_equal true, execution.observe(final)["replayed"]
      after_terminal = signed_omp_observation(
        execution, plan, binding, session_ref: session_ref, sequence: 3, lifecycle: "running",
        observed_at: "2026-08-10T16:00:03Z", suffix: "operation-owner-after-terminal"
      )
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) { execution.observe(after_terminal) }
      assert_equal "out_of_order_observation", error.code
      opened = Flightdeck::OmpOperationExecution.new(config, clock: clock).open(
        "schema_version" => Flightdeck::OmpOperationExecution::OPEN_REQUEST,
        "work_id" => plan.fetch("work_id"), "operation_id" => plan.fetch("operation_id"),
        "execution_id" => plan.dig("execution", "execution_id")
      )
      assert_equal 1, opened.dig("progress", "terminal")
      assert_equal "review_ready", opened.dig("agents", 0, "observation", "lifecycle")
      open_path = File.join(root, "omp-operation-open.json")
      File.write(open_path, JSON.generate(
        "schema_version" => Flightdeck::OmpOperationExecution::OPEN_REQUEST,
        "work_id" => plan.fetch("work_id"), "operation_id" => plan.fetch("operation_id"),
        "execution_id" => plan.dig("execution", "execution_id")
      ))
      cli_output = StringIO.new
      assert_equal 0, Flightdeck::CLI.new(root: root, out: cli_output, err: StringIO.new).run(
        ["operation", "execution-open", "--request", open_path, "--json"]
      )
      assert_equal Flightdeck::OmpOperationExecution::OPEN_RESULT, JSON.parse(cli_output.string)["schema_version"]
      rendered = JSON.generate(opened)
      refute_includes rendered, session_ref
      refute_includes rendered, "runtime_project_id"
      refute_includes rendered, "authorized_task"
      refute_includes rendered, project

      operation = Flightdeck::MissionStore.new(config).operation_projection(plan.fetch("operation_id"))
      child = operation.dig("operation", "children", 0)
      assert_equal "omp_bound", child.dig("session", "state")
      assert_equal agent.fetch("agent_id"), child.dig("session", "agent_id")
      assert_equal "review_ready", child.dig("execution", "observation", "lifecycle")
      assert_equal "review_ready", operation.dig("operation", "state")
      work_projection = work.open(
        "schema_version" => Flightdeck::WorkStore::OPEN_REQUEST,
        "work_id" => plan.fetch("work_id")
      )
      assert_equal "result_ready", work_projection.dig("work", "status")
      assert_equal "available", work_projection.dig("operation_links", 0, "result_state")
      assert_equal "2026-08-10T16:00:02Z", work_projection.dig("operation_links", 0, "observed_at")
      snapshot = Flightdeck::OperationsSnapshot.new(config).snapshot
      snapshot_operation = snapshot.fetch("operations").find { |item| item.dig("detail", "operation_id") == plan.fetch("operation_id") }
      assert_equal "mission:#{plan.fetch('operation_id')}", snapshot_operation.fetch("operation_id")
      assert_equal plan.fetch("operation_id"), snapshot_operation.dig("detail", "operation_id")
      assert_equal "review_ready", snapshot_operation.dig("children", 0, "execution", "observation", "lifecycle")

      persisted = File.read(Dir.glob(File.join(root, "hub/state/omp-operation-execution/*.json")).first)
      refute_includes persisted, session_ref
      refute_includes persisted, "signature"
      refute_includes persisted, "system_prompt"
      refute_includes persisted, project
      record_path = Dir.glob(File.join(root, "hub/state/omp-operation-execution/*.json")).first
      tampered_record = JSON.parse(File.read(record_path))
      tampered_record["operation_id"] = "operation-#{'f' * 24}"
      tampered_record["record_digest"] = nil
      tampered_record["record_digest"] = Digest::SHA256.hexdigest(execution.send(:canonical_json, tampered_record))
      Flightdeck::Support.atomic_write(record_path, "#{JSON.pretty_generate(tampered_record)}\n")
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) do
        Flightdeck::OmpOperationExecution.new(config).open(
          "schema_version" => Flightdeck::OmpOperationExecution::OPEN_REQUEST,
          "work_id" => plan.fetch("work_id"), "operation_id" => plan.fetch("operation_id"),
          "execution_id" => plan.dig("execution", "execution_id")
        )
      end
      assert_equal "execution_store_invalid", error.code
    end
  end

  def test_omp_operation_execution_rejects_proposal_only_declined_tampered_foreign_and_untrusted_input
    with_hub do |root, config|
      project = initialize_repository(root, "omp-denied-owner")
      config = register_repository(config, "omp-denied-owner", project)
      config = write_declarations(config, [declaration("omp-denied-owner", project)])
      write_project_verifications(config, "omp-denied-owner" => verified_project("omp-denied-owner", project))
      Flightdeck::BridgeStore.new(config).install(repository_id: "omp-denied-owner", mode: "reference", profile: "application")
      config = Flightdeck::Config.new(root: root)
      work = Flightdeck::WorkStore.new(config, random_hex: ->(_bytes) { "2" * 24 })
      proposed = propose_work_operation(work, suffix: "omp-denied-0001", project_keys: ["omp-denied-owner"])
      fake = {
        "schema_version" => Flightdeck::OmpOperationExecution::PLAN_REQUEST,
        "work_id" => proposed.dig("work", "work", "work_id"),
        "operation_id" => proposed.dig("proposal", "operation_id"),
        "confirmation" => proposed.fetch("confirmation"),
        "dispatch_generation" => "dispatch-generation-#{'0' * 48}",
        "dispatch_plan_digest" => "0" * 64,
        "idempotency_key" => "omp-execution-denied-0001",
        "agents" => []
      }
      execution = Flightdeck::OmpOperationExecution.new(config)
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) { execution.plan(fake) }
      assert_equal "proposal_not_launched", error.code
      work.decline(
        "schema_version" => Flightdeck::WorkStore::DECLINE_REQUEST,
        "work_id" => fake.fetch("work_id"), "operation_id" => fake.fetch("operation_id"),
        "confirmation" => fake.fetch("confirmation")
      )
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) { execution.plan(fake) }
      assert_equal "proposal_not_launched", error.code
    end

    with_hub do |root, config|
      project = initialize_repository(root, "omp-tamper-owner")
      config = register_repository(config, "omp-tamper-owner", project)
      config = write_declarations(config, [declaration("omp-tamper-owner", project)])
      write_project_verifications(config, "omp-tamper-owner" => verified_project("omp-tamper-owner", project))
      Flightdeck::BridgeStore.new(config).install(repository_id: "omp-tamper-owner", mode: "reference", profile: "application")
      config = Flightdeck::Config.new(root: root)
      work = Flightdeck::WorkStore.new(config, random_hex: ->(_bytes) { "3" * 24 })
      fixture = propose_work_operation(work, suffix: "omp-tamper-0001", project_keys: ["omp-tamper-owner"])
      request, = omp_execution_request(work, fixture, suffix: "omp-tamper-0001")
      execution = Flightdeck::OmpOperationExecution.new(config)
      tampered = Marshal.load(Marshal.dump(request))
      tampered.fetch("confirmation")["plan_digest"] = "f" * 64
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) { execution.plan(tampered) }
      assert_equal "stale_or_tampered_confirmation", error.code
      foreign = Marshal.load(Marshal.dump(request))
      foreign["work_id"] = "work-#{'f' * 24}"
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) { execution.plan(foreign) }
      assert_equal "operation_identity_conflict", error.code
      untrusted = Marshal.load(Marshal.dump(request))
      untrusted.dig("agents", 0)["authorized_task"] = "Bearer #{'a' * 32}"
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) { execution.plan(untrusted) }
      assert_equal "untrusted_payload", error.code
      oversized = Marshal.load(Marshal.dump(request))
      oversized.dig("agents", 0)["authorized_task"] = "x" * (Flightdeck::OmpOperationExecution::MAX_TASK_BYTES + 1)
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) { execution.plan(oversized) }
      assert_equal "untrusted_payload", error.code
      malformed = Marshal.load(Marshal.dump(request))
      malformed["unexpected"] = true
      error = assert_raises(Flightdeck::OmpOperationExecution::ContractError) { execution.plan(malformed) }
      assert_equal "malformed_request", error.code
      assert_empty Dir.glob(File.join(root, "hub/state/omp-operation-execution/*.json"))
    end
  end

  def test_omp_operation_contract_schemas_cli_and_runtime_compatibility_are_closed
    compatibility = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "compatibility.json")))
    assert_equal "1.8.0", compatibility["template_version"]
    assert_equal "codex", compatibility.dig("runtime_capabilities", "conversation", "adapter")
    assert_equal "omp", compatibility.dig("runtime_capabilities", "operation_execution", "adapter")
    assert_equal true, compatibility.dig("runtime_capabilities", "adapters", "omp", "available")
    execution = compatibility.dig("capabilities", Flightdeck::OmpOperationExecution::EXECUTION_CAPABILITY)
    observation = compatibility.dig("capabilities", Flightdeck::OmpOperationExecution::OBSERVATION_CAPABILITY)
    assert_equal true, execution["declaration_required"]
    assert_equal true, observation["declaration_required"]
    assert_equal({ "mode" => "stop_and_plan_migration" }, execution["fallback"])
    assert_equal({ "mode" => "stop_and_plan_migration" }, observation["fallback"])
    Flightdeck::OmpOperationExecution::SCHEMAS.each do |name|
      schema = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "schemas", name)))
      assert_equal "https://flightdeck.dev/schemas/#{name}", schema["$id"]
      assert_includes execution["managed_paths"] + observation["managed_paths"], "hub/schemas/#{name}"
    end
    help = StringIO.new
    assert_equal 0, Flightdeck::CLI.new(root: TEMPLATE_ROOT, out: help, err: StringIO.new).run(["help"])
    %w[execution-plan execution-bind execution-observe execution-open].each do |name|
      assert_includes help.string, "bin/flightdeck operation #{name} --request FILE"
    end
  end

  def test_omp_operation_plan_keeps_independent_agents_concurrent_without_creating_tasks
    with_hub do |root, config|
      projects = %w[omp-concurrent-a omp-concurrent-b].to_h { |key| [key, initialize_repository(root, key)] }
      projects.each { |key, path| config = register_repository(config, key, path) }
      config = write_declarations(config, projects.map { |key, path| declaration(key, path) })
      write_project_verifications(config, projects.to_h { |key, path| [key, verified_project(key, path)] })
      projects.each_key do |key|
        Flightdeck::BridgeStore.new(config).install(repository_id: key, mode: "reference", profile: "application")
      end
      config = Flightdeck::Config.new(root: root)
      sequence = 0
      work = Flightdeck::WorkStore.new(
        config, random_hex: ->(_bytes) { sequence += 1; format("%024x", sequence) }
      )
      fixture = propose_work_operation(work, suffix: "omp-concurrent-0001", project_keys: projects.keys.sort)
      request, = omp_execution_request(work, fixture, suffix: "omp-concurrent-0001")
      plan = Flightdeck::OmpOperationExecution.new(config).plan(request)
      assert_equal 2, plan.dig("policy", "max_concurrency")
      assert_equal [0, 0], plan.fetch("agents").map { |agent| agent.fetch("execution_order") }
      assert_equal [[], []], plan.fetch("agents").map { |agent| agent.fetch("dependencies") }
      mission = Flightdeck::MissionStore.new(config).snapshot(plan.fetch("operation_id"))
      assert_equal [nil, nil], mission.dig("spec", "graph", "nodes").map { |node| node["task_id"] }
      assert_equal [nil, nil], mission.dig("spec", "graph", "nodes").map { |node| node["pending_client_id"] }
    end
  end

  def test_omp_projection_stays_off_the_mission_read_path_without_an_execution_record
    with_operation_authoring_fixture do |_root, config, authoring, _catalog, target|
      proposal = operation_proposal(target, title: "No OMP execution record")
      plan = operation_plan(authoring, proposal)
      authoring.launch(operation_launch_request(plan, proposal))
      original = Flightdeck::OmpOperationExecution.instance_method(:verify_capabilities!)
      Flightdeck::OmpOperationExecution.define_method(:verify_capabilities!) do
        raise "OMP capability validation must not run for a non-OMP Mission"
      end
      status = Flightdeck::MissionStore.new(config).status(plan.fetch("operation_id"))
      assert_equal "planned", status.dig("status", "state")
      assert_nil status.dig("spec", "graph", "nodes", 0, "omp_execution")
    ensure
      Flightdeck::OmpOperationExecution.define_method(:verify_capabilities!, original) if original
    end
  end

  def test_work_contract_schemas_cli_and_compatibility_are_closed
    compatibility = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "compatibility.json")))
    capability = compatibility.dig("capabilities", Flightdeck::WorkStore::CAPABILITY)
    lifecycle = compatibility.dig("capabilities", Flightdeck::WorkStore::LIFECYCLE_CAPABILITY)
    assert_equal "1.8.0", compatibility["template_version"]
    assert_equal({ "mode" => "stop_and_plan_migration" }, capability["fallback"])
    assert_includes capability["managed_paths"], "lib/flightdeck/work_store.rb"
    assert_equal "bin/flightdeck work lifecycle-open ", lifecycle.dig("probe", "help_contains")
    assert_equal({ "mode" => "stop_and_plan_migration" }, lifecycle["fallback"])
    assert_includes lifecycle["managed_paths"], "lib/flightdeck/work_store.rb"
    assert_includes lifecycle["managed_paths"], "lib/flightdeck/bridge_store.rb"
    assert_includes compatibility.dig("capabilities", "flightdeck.command.route-plan.v1", "managed_paths"),
                    "lib/flightdeck/bridge_store.rb"
    Flightdeck::WorkStore::SCHEMAS.each do |name|
      schema = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "schemas", name)))
      assert_equal "https://flightdeck.dev/schemas/#{name}", schema["$id"]
    end
    Flightdeck::WorkStore::LIFECYCLE_SCHEMAS.each do |name|
      schema = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "schemas", name)))
      assert_equal "https://flightdeck.dev/schemas/#{name}", schema["$id"]
      assert_equal false, schema["additionalProperties"]
      assert_includes lifecycle["managed_paths"], "hub/schemas/#{name}"
    end
    help = StringIO.new
    assert_equal 0, Flightdeck::CLI.new(root: TEMPLATE_ROOT, out: help, err: StringIO.new).run(["help"])
    %w[decline lifecycle-open dispatch-plan dispatch-report].each do |name|
      assert_includes help.string, "bin/flightdeck work #{name} --request FILE"
    end

    with_hub do |root, _config|
      request_path = File.join(root, "work-create.json")
      File.write(request_path, JSON.generate(
        "schema_version" => Flightdeck::WorkStore::CREATE_REQUEST,
        "request_key" => "request-cli-work-create-0001",
        "title_hint" => "CLI Work"
      ))
      output = StringIO.new
      status = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new).run(["work", "create", "--request", request_path, "--json"])
      assert_equal 0, status
      created = JSON.parse(output.string)
      assert_equal Flightdeck::WorkStore::CREATE_RESULT, created["schema_version"]

      bind_path = File.join(root, "work-adapter-bind.json")
      File.write(bind_path, JSON.generate(
        "schema_version" => Flightdeck::WorkStore::ADAPTER_BIND_REQUEST,
        "work_id" => created.dig("work", "work_id"),
        "resume_generation" => created.dig("resume", "generation"),
        "adapter" => "codex",
        "adapter_session_id" => "codex-thread-cli-work-0001",
        "binding_request_id" => "adapter-binding-cli-work-0001",
        "structured_channel" => Flightdeck::WorkStore::STRUCTURED_CHANNEL
      ))
      bind_output = StringIO.new
      status = Flightdeck::CLI.new(root: root, out: bind_output, err: StringIO.new).run(["work", "adapter-bind", "--request", bind_path, "--json"])
      assert_equal 0, status
      assert_equal Flightdeck::WorkStore::ADAPTER_BIND_RESULT, JSON.parse(bind_output.string)["schema_version"]

      lifecycle_path = File.join(root, "work-lifecycle-open.json")
      File.write(lifecycle_path, JSON.generate(
        "schema_version" => Flightdeck::WorkStore::LIFECYCLE_OPEN_REQUEST,
        "work_id" => created.dig("work", "work_id")
      ))
      lifecycle_output = StringIO.new
      status = Flightdeck::CLI.new(root: root, out: lifecycle_output, err: StringIO.new).run(
        ["work", "lifecycle-open", "--request", lifecycle_path, "--json"]
      )
      assert_equal 0, status
      assert_equal Flightdeck::WorkStore::LIFECYCLE_OPEN_RESULT, JSON.parse(lifecycle_output.string)["schema_version"]

      list_output = StringIO.new
      status = Flightdeck::CLI.new(root: root, out: list_output, err: StringIO.new).run(["work", "list", "--hub-root", root, "--json"])
      assert_equal 0, status
      assert_equal Flightdeck::WorkStore::LIST_RESULT, JSON.parse(list_output.string)["schema_version"]
    end
  end
end
