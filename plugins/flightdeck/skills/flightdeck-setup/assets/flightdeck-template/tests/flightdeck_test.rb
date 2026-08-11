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
      assert_equal false, snapshot.dig("runtime_capabilities", "adapters", "omp", "available")

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
      assert_equal false, snapshot.dig("runtime_capabilities", "adapters", "omp", "available")
      operation = snapshot.fetch("operations").fetch(0)
      assert_equal "mission:operations-mission", operation["operation_id"]
      assert_equal "queued", operation["status"]
      child = operation.fetch("children").fetch(0)
      assert_equal "rap-backend", child["logical_project_key"]
      assert_equal "Hub Agent — rap-backend", child["role_name"]
      assert_equal({ "state" => "unavailable", "items" => [] }, child["skills"])
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
    assert_equal "1.2.2", compatibility["template_version"]
    capability = compatibility.dig("capabilities", "flightdeck.command.mission-client-snapshot.v1")
    assert_equal "command", capability["kind"]
    assert_includes capability["managed_paths"], "hub/schemas/mission-client-snapshot.schema.json"

    compatibility_schema = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "schemas", "hub-compatibility.schema.json")))
    refute_includes compatibility_schema.fetch("required"), "runtime_capabilities"
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
end
