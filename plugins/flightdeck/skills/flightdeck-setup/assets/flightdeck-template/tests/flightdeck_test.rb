# frozen_string_literal: true

require "digest"
require "base64"
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
require "flightdeck/mission_graph"
require "flightdeck/mission_authoring"
require "flightdeck/mission_store"
require "flightdeck/mission_sync"
require "flightdeck/repo_planner"
require "flightdeck/repository_store"
require "flightdeck/route_planner"
require "flightdeck/setup_store"
require "flightdeck/task_store"

class FlightdeckTest < Minitest::Test
  TEMPLATE_ROOT = File.expand_path("..", __dir__)
  CONTROL_PLANE_ENTRIES = %w[
    .gitignore AGENTS.md Makefile README.md bin docs flightdeck.yaml lib scripts tests
  ].freeze
  HUB_CONTROL_PLANE_ENTRIES = %w[
    .mission-authoring.lock automations bridges compatibility.json repositories.yaml schemas templates workflows
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

  def register_repository(config, id, path, mode: "reference")
    registry = File.file?(config.local_registry_path) ? Flightdeck::Support.load_data(config.local_registry_path) : {
      "api_version" => "flightdeck.dev/v1alpha1",
      "kind" => "LocalRepositoryRegistry",
      "repositories" => {}
    }
    registry["repositories"][id] = {
      "local_path" => Flightdeck::Support.relative_path(config.root, path),
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

  def declaration(id, path, mode: "reference")
    {
      "id" => id,
      "workload" => "development",
      "provider" => "existing-local",
      "locator" => File.join("development", File.basename(path)),
      "local_path" => File.join("development", File.basename(path)),
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
  end

  def mission_authorized_target(config, node_id: "unit-a", project_path: nil, host_id: "host-local",
                                execution_mode: "local", access_mode: "read_only")
    project_path ||= File.join(config.root, "development", node_id)
    {
      "logical_project_key" => "project-#{node_id}",
      "runtime_project_id" => "runtime-#{node_id}",
      "project_path_digest" => Digest::SHA256.hexdigest(File.expand_path(project_path)),
      "host_id" => host_id,
      "execution_mode" => execution_mode,
      "access_mode" => access_mode
    }
  end

  def with_authoring_fixture
    with_hub do |root, config|
      project_path = initialize_repository(root, "authoring-project")
      config = register_repository(config, "authoring-project", project_path)
      config = write_declarations(config, [declaration("authoring-project", project_path)])
      FileUtils.mkdir_p(File.dirname(config.project_registry_path))
      Flightdeck::Support.atomic_yaml(
        config.project_registry_path,
        {
          "api_version" => "flightdeck.dev/v1alpha1",
          "kind" => "CodexProjectVerifications",
          "projects" => {
            "authoring-project" => {
              "logical_key" => "authoring-project",
              "runtime_project_id" => "runtime-project-authoring",
              "path" => File.realpath(project_path),
              "verified" => true,
              "verification_source" => "live_project_list_exact_path",
              "verified_at" => "2026-08-06T12:00:00Z"
            }
          }
        }
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

  def authoring_draft(target, title: "Typed client mission", nodes: nil)
    selected = target.reject { |key, _| key == "display_label" }
    {
      "title" => title,
      "outcome" => "Produce the declared validated outputs.",
      "success_criteria" => ["Every required node returns its declared validated output."],
      "non_goals" => ["Do not dispatch, commit, publish, deploy, or close."],
      "mode" => "supervised",
      "selected_targets" => [selected],
      "nodes" => nodes || [
        {
          "id" => "implementation",
          "target_id" => target.fetch("target_id"),
          "required" => true,
          "dependencies" => [],
          "accepted_input_types" => [],
          "allowed_output_types" => ["validation_ref"]
        }
      ]
    }
  end

  def authoring_plan(authoring, draft)
    authoring.plan(
      "schema_version" => Flightdeck::MissionAuthoring::PLAN_REQUEST,
      "draft" => draft
    )
  end

  def authoring_create_request(plan, draft, operation_id)
    {
      "schema_version" => Flightdeck::MissionAuthoring::CREATE_REQUEST,
      "operation_id" => operation_id,
      "confirmation" => %w[plan_id plan_generation plan_digest plan_token].to_h do |field|
        [field, plan.fetch(field)]
      end,
      "draft" => draft
    }
  end

  def create_mission(config, slug: "sample-mission", mode: "supervised", authorized_targets: nil)
    authorized_targets ||= [mission_authorized_target(config)]
    Flightdeck::MissionStore.new(config).create(
      slug: slug,
      title: "Synthetic mission",
      outcome: "Produce validated typed outputs.",
      mode: mode,
      success_criteria: ["All required nodes provide validated typed outputs."],
      non_goals: ["Do not expand the declared mission graph after execution."],
      authorized_targets: authorized_targets
    )
  end

  def add_mission_node(config, slug: "sample-mission", node_id: "unit-a", required: true,
                       dependencies: [], execution_mode: "local", access_mode: "read_only",
                       accepted: [], outputs: ["validation_result"], project_path: nil,
                       host_id: "host-local", artifact_resolver_kind: nil, artifact_resolver_id: nil,
                       criterion_ids: nil)
    project_path ||= File.join(config.root, "development", node_id)
    mission = Flightdeck::MissionStore.new(config).snapshot(slug)
    Flightdeck::MissionStore.new(config).add_node(
      slug: slug,
      node_id: node_id,
      logical_project_key: "project-#{node_id}",
      runtime_project_id: "runtime-#{node_id}",
      project_path: project_path,
      host_id: host_id,
      execution_mode: execution_mode,
      access_mode: access_mode,
      work_type: "validation",
      required: required,
      dependencies: dependencies,
      accepted_input_types: accepted,
      allowed_output_types: outputs,
      artifact_resolver_kind: artifact_resolver_kind,
      artifact_resolver_id: artifact_resolver_id,
      criterion_ids: criterion_ids || (required ? mission.dig("spec", "success_criteria").map { |criterion| criterion["id"] } : [])
    )
  end

  def dispatch_mission_node(config, slug: "sample-mission", node_id: "unit-a", host_id: "host-local")
    Flightdeck::MissionStore.new(config).record_dispatch(
      slug: slug,
      node_id: node_id,
      runtime_project_id: "runtime-#{node_id}",
      host_id: host_id,
      task_id: "task-#{node_id}"
    )
  end

  def mission_observation(config, slug:, node_id:, state:, revision:, event_id: nil,
                          validation: nil, output_declarations: nil, cursor: nil, include_outcome: nil,
                          status_code: nil, criterion_results: nil)
    mission = Flightdeck::MissionStore.new(config).snapshot(slug)
    node = mission.dig("spec", "graph", "nodes").find { |item| item["id"] == node_id }
    validation ||= state == "failed_validation" ? "failed" : (state == "review_ready" ? "passed" : "not_applicable")
    output_declarations ||= state == "review_ready" ? [
      {
        "type" => node.fetch("allowed_output_types").first,
        "codex_task" => true
      }
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
      prompt_requirements = plan.fetch("child_prompt_requirements").join(" ")
      assert_includes prompt_requirements, "lead Flightdeck skill"
      assert_includes prompt_requirements, "owning workload"
      assert_includes prompt_requirements, "new evidence crosses domains"
      assert_includes prompt_requirements, "before domain-specific mutation"
    end
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

  def test_setup_plan_discovers_attached_repository_without_writing
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "attached-service")
      commit_repository(repository)
      File.write(File.join(repository, "local-note.txt"), "preserve me\n")
      declarations_before = File.read(config.repository_declarations_path)

      result = Flightdeck::SetupStore.new(config).plan(
        repositories_root: repositories_root
      )

      assert_equal true, result["read_only"]
      assert_equal 1, result.dig("summary", "discovered")
      assert_equal 1, result.dig("summary", "ready")
      item = result.fetch("repositories").first
      assert_equal "attached", item["placement"]
      assert_equal "reference", item.dig("bridge", "mode")
      assert_equal false, item["clean"]
      assert_equal "existing-local", item["provider"]
      assert_equal "attached", item.dig("proposed_declaration", "placement")
      refute item.fetch("proposed_declaration").key?("local_path")
      assert_equal declarations_before, File.read(config.repository_declarations_path)
      refute File.exist?(config.local_registry_path)
      refute File.exist?(File.join(repository, "AGENTS.override.md"))
    end
  end

  def test_setup_plan_normalizes_hosted_origin_without_network_access
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "hosted-service")
      commit_repository(repository)
      git(
        "remote", "add", "origin",
        "https://github.com/example-company/hosted-service.git",
        chdir: repository
      )

      item = Flightdeck::SetupStore.new(config).plan(
        repositories_root: repositories_root
      ).fetch("repositories").first

      assert_equal "github", item["provider"]
      assert_equal "example-company/hosted-service", item["locator"]
      assert_equal "example-company", item["owner"]
      assert_equal "main", item["verified_default_branch"]
      assert_equal "checked_out_branch_fallback", item["default_branch_source"]
      assert_equal false, item["default_branch_verified"]
      assert_includes item.fetch("warnings").join(" "), "unverified fallback"

      git("update-ref", "refs/remotes/origin/main", "HEAD", chdir: repository)
      git(
        "symbolic-ref",
        "refs/remotes/origin/HEAD",
        "refs/remotes/origin/main",
        chdir: repository
      )
      verified = Flightdeck::SetupStore.new(config).plan(
        repositories_root: repositories_root
      ).fetch("repositories").first
      assert_equal "origin_head", verified["default_branch_source"]
      assert_equal true, verified["default_branch_verified"]
    end
  end

  def test_setup_plan_blocks_and_redacts_credential_bearing_origin
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "credential-service")
      commit_repository(repository)
      git(
        "remote", "add", "origin",
        "https://synthetic-user:synthetic-secret@example.invalid/service.git",
        chdir: repository
      )

      result = Flightdeck::SetupStore.new(config).plan(
        repositories_root: repositories_root
      )
      item = result.fetch("repositories").first
      serialized = JSON.generate(result)

      assert_equal "blocked", item["status"]
      assert_includes item.fetch("blockers").join(" "), "embedded credentials"
      refute_includes serialized, "synthetic-user"
      refute_includes serialized, "synthetic-secret"
    end
  end

  def test_setup_connect_keeps_unverified_remote_default_branch_truthful
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "branch-fallback-service")
      commit_repository(repository)
      git(
        "remote", "add", "origin",
        "https://github.com/example-company/branch-fallback-service.git",
        chdir: repository
      )

      result = Flightdeck::SetupStore.new(config).connect(
        repositories_root: repositories_root
      )

      assert_equal true, result["ok"], result.inspect
      declaration = Flightdeck::Config.new(root: root).repository_declarations.first
      assert_equal false, declaration["default_branch_verified"]
      assert_equal "main", declaration["default_branch"]
      doctor = Flightdeck::Doctor.new(Flightdeck::Config.new(root: root)).run
      assert_equal 0, doctor.dig("summary", "errors"), doctor.inspect
      assert_includes(
        doctor["issues"].map { |item| item["code"] },
        "repository.default_branch_pending"
      )
    end
  end

  def test_setup_connect_never_persists_local_file_origin_in_portable_declaration
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "local-origin-service")
      commit_repository(repository)
      local_origin = File.join(File.dirname(root), "synthetic-origin.git")
      git("remote", "add", "origin", "file://#{local_origin}", chdir: repository)

      result = Flightdeck::SetupStore.new(config).connect(
        repositories_root: repositories_root
      )

      assert_equal true, result["ok"], result.inspect
      declaration = Flightdeck::Config.new(root: root).repository_declarations.first
      assert_equal "existing-local", declaration["provider"]
      assert_equal "local-origin-service", declaration["locator"]
      serialized = File.read(config.repository_declarations_path)
      refute_includes serialized, local_origin
      refute_includes serialized, File.dirname(root)
    end
  end

  def test_setup_connect_attaches_in_place_and_installs_safe_reference_bridge
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "attached-service")
      commit_repository(repository)
      agents_before = File.read(File.join(repository, "AGENTS.md"))

      result = Flightdeck::SetupStore.new(config).connect(
        repositories_root: repositories_root
      )

      assert_equal true, result["ok"], result.inspect
      assert_equal "connected_projects_pending", result["status"]
      assert_equal 1, result.dig("summary", "connected")
      assert_equal 1, result.dig("summary", "project_pending")
      declaration = Flightdeck::Config.new(root: root).repository_declarations.first
      assert_equal "attached", declaration["placement"]
      refute declaration.key?("local_path")
      refute_includes File.read(config.repository_declarations_path), repository
      registered = Flightdeck::Config.new(root: root).repository("attached-service")
      assert_equal File.realpath(repository), File.realpath(registered["path"])
      assert_equal "attached", registered["placement"]
      assert File.file?(File.join(repository, "AGENTS.override.md"))
      _ignored, _error, ignored_status = Flightdeck::Support.capture(
        "git", "check-ignore", "-q", "--", "AGENTS.override.md", chdir: repository
      )
      assert_equal 0, ignored_status
      assert_equal agents_before, File.read(File.join(repository, "AGENTS.md"))
      doctor = Flightdeck::Doctor.new(Flightdeck::Config.new(root: root)).run
      assert_equal 0, doctor.dig("summary", "errors"), doctor.inspect
      bridge_registry = File.read(config.bridge_registry_path)
      second = Flightdeck::SetupStore.new(Flightdeck::Config.new(root: root)).connect(
        repositories_root: repositories_root
      )
      assert_equal true, second["ok"], second.inspect
      assert_equal false, second["changed"]
      assert_equal "noop", second.dig("bridge_receipt", "repositories", 0, "bridge", "status")
      assert_equal bridge_registry, File.read(config.bridge_registry_path)
    end
  end

  def test_setup_connect_skips_unmanaged_override_without_writing_state
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "conflict-service")
      commit_repository(repository)
      File.write(File.join(repository, "AGENTS.override.md"), "unmanaged\n")
      declarations_before = File.read(config.repository_declarations_path)

      result = Flightdeck::SetupStore.new(config).connect(
        repositories_root: repositories_root
      )

      assert_equal false, result["ok"]
      assert_equal false, result["changed"]
      assert_equal "connected_with_blockers", result["status"]
      assert_includes(
        result.fetch("repositories").first.fetch("blockers").join(" "),
        "refusing to overwrite"
      )
      assert_equal declarations_before, File.read(config.repository_declarations_path)
      refute File.exist?(config.local_registry_path)
      assert_equal "unmanaged\n", File.read(File.join(repository, "AGENTS.override.md"))

      stopped = Flightdeck::SetupStore.new(config).connect(
        repositories_root: repositories_root,
        failure_policy: "stop"
      )
      assert_equal "stopped_before_changes", stopped["status"]
      assert_equal 0, stopped.dig("summary", "project_verified")
    end
  end

  def test_setup_connect_blocks_portable_and_local_identity_conflict_before_mutation
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "flightdeck-client")
      commit_repository(repository)
      initial = Flightdeck::SetupStore.new(config).connect(repositories_root: repositories_root)
      assert_equal true, initial["ok"], initial.inspect
      config = Flightdeck::Config.new(root: root)
      git("remote", "add", "origin", "https://github.com/example/flightdeck-client.git", chdir: repository)
      git("update-ref", "refs/remotes/origin/main", "HEAD", chdir: repository)
      git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main", chdir: repository)
      config = write_declarations(
        config,
        [
          {
            "id" => "flightdeck-client", "placement" => "attached", "workload" => "development",
            "provider" => "github", "locator" => "example/flightdeck-client", "owner" => "example",
            "default_branch" => "main", "default_branch_verified" => false,
            "bridge" => { "profile" => "application", "mode" => "reference" },
            "codex_project" => { "expectation" => "saved_exact_path", "logical_key" => "flightdeck-client" }
          }
        ]
      )
      declarations_before = File.binread(config.repository_declarations_path)
      registry_before = File.binread(config.local_registry_path)
      bridge_before = File.binread(File.join(repository, "AGENTS.override.md"))
      doctor_before = Flightdeck::Doctor.new(config).run.dig("summary", "errors")

      plan = Flightdeck::SetupStore.new(config).plan(repositories_root: repositories_root)
      item = plan.fetch("repositories").first
      assert_equal "blocked", item["status"]
      assert_includes item.fetch("blockers").join(" "), "existing local registration provider differs"
      assert_includes item.fetch("blockers").join(" "), "existing local registration default_branch_verified differs"

      result = Flightdeck::SetupStore.new(config).connect(repositories_root: repositories_root)
      assert_equal false, result["changed"]
      assert_equal "connected_with_blockers", result["status"]
      assert_equal declarations_before, File.binread(config.repository_declarations_path)
      assert_equal registry_before, File.binread(config.local_registry_path)
      assert_equal bridge_before, File.binread(File.join(repository, "AGENTS.override.md"))
      assert_equal doctor_before, Flightdeck::Doctor.new(Flightdeck::Config.new(root: root)).run.dig("summary", "errors")
    end
  end

  def test_setup_connect_reports_empty_authorized_root_without_claiming_ready
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "empty-repositories")
      FileUtils.mkdir_p(repositories_root)

      result = Flightdeck::SetupStore.new(config).connect(
        repositories_root: repositories_root
      )

      assert_equal true, result["ok"]
      assert_equal false, result["complete"]
      assert_equal "no_repositories_found", result["status"]
      assert_equal 0, result.dig("summary", "connected")
      assert_equal false, result["changed"]
    end
  end

  def test_setup_connect_continues_independent_safe_repositories
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      safe = initialize_repository(repositories_root, "a-safe-service")
      blocked = initialize_repository(repositories_root, "b-blocked-service")
      [safe, blocked].each { |repository| commit_repository(repository) }
      File.write(File.join(blocked, "AGENTS.override.md"), "unmanaged\n")

      result = Flightdeck::SetupStore.new(config).connect(
        repositories_root: repositories_root,
        failure_policy: "continue"
      )

      assert_equal false, result["ok"]
      assert_equal 1, result.dig("summary", "connected")
      assert_equal 1, result.dig("summary", "blocked")
      assert File.file?(File.join(safe, "AGENTS.override.md"))
      assert_equal "unmanaged\n", File.read(File.join(blocked, "AGENTS.override.md"))
      declarations = Flightdeck::Config.new(root: root).repository_declarations
      assert_equal ["a-safe-service"], declarations.map { |item| item["id"] }
      doctor = Flightdeck::Doctor.new(Flightdeck::Config.new(root: root)).run
      assert_equal 0, doctor.dig("summary", "errors"), doctor.inspect
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

  def test_doctor_and_status_report_missing_registered_repository_with_bridge
    with_hub do |root, config|
      repository = initialize_repository(root, "missing-bridged-service")
      commit_repository(repository)
      config = register_repository(config, "missing-bridged-service", repository)
      Flightdeck::BridgeStore.new(config).install(
        repository_id: "missing-bridged-service",
        mode: "reference",
        profile: "application"
      )
      FileUtils.rm_rf(repository)
      config = Flightdeck::Config.new(root: root)

      result = Flightdeck::Doctor.new(config).run
      codes = result.fetch("issues").map { |item| item.fetch("code") }
      assert_includes codes, "repo.unavailable"
      assert_includes codes, "bridge.repository_unavailable"

      doctor_output = StringIO.new
      doctor_status = Flightdeck::CLI.new(
        root: root,
        out: doctor_output,
        err: StringIO.new
      ).run(["doctor", "--json"])
      assert_equal 1, doctor_status
      doctor_result = JSON.parse(doctor_output.string)
      assert_includes doctor_result.fetch("issues").map { |item| item.fetch("code") }, "repo.unavailable"
      assert_includes doctor_result.fetch("issues").map { |item| item.fetch("code") }, "bridge.repository_unavailable"

      status_output = StringIO.new
      status_status = Flightdeck::CLI.new(
        root: root,
        out: status_output,
        err: StringIO.new
      ).run(["status", "--json"])
      assert_equal 0, status_status
      status_result = JSON.parse(status_output.string)
      assert_includes status_result.fetch("issues").map { |item| item.fetch("code") }, "repo.unavailable"
      assert_includes status_result.fetch("issues").map { |item| item.fetch("code") }, "bridge.repository_unavailable"
    end
  end

  def test_command_capture_normalizes_missing_working_directory
    with_hub do |root, _config|
      missing = File.join(root, "missing-working-directory")

      output, error, status = Flightdeck::Support.capture(
        "git", "status", chdir: missing
      )

      assert_equal "", output
      assert_equal "working directory is unavailable", error
      assert_equal 127, status
    end
  end

  def test_compliance_working_records_require_semantic_parity
    with_hub do |root, config|
      directory = File.join(root, "compliance", "example", "working-records")
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

  def test_compliance_sidecars_accept_safe_yaml_aliases
    with_hub do |root, config|
      directory = File.join(root, "compliance", "example", "control-assessments")
      FileUtils.mkdir_p(directory)
      value = {
        "controls" => [
          { "id" => "AC-1", "status" => "satisfied" },
          { "id" => "AC-1", "status" => "satisfied" }
        ]
      }
      File.write(File.join(directory, "control.json"), JSON.pretty_generate(value))
      File.write(
        File.join(directory, "control.yaml"),
        "---\ncontrols:\n- &control\n  id: AC-1\n  status: satisfied\n- *control\n"
      )

      result = Flightdeck::Doctor.new(config).run
      assert_equal true, result.dig("compliance", "pairs", 0, "equivalent")
      refute_includes result["issues"].map { |item| item["code"] }, "compliance.invalid_yaml"
      refute_includes result["issues"].map { |item| item["code"] }, "compliance.sidecar_mismatch"
    end
  end

  def test_compliance_parse_failure_does_not_duplicate_mismatch
    with_hub do |root, config|
      directory = File.join(root, "compliance", "example", "control-assessments")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "control.json"), JSON.pretty_generate({ "status" => "satisfied" }))
      File.write(File.join(directory, "control.yaml"), "status: [\n")

      result = Flightdeck::Doctor.new(config).run
      codes = result["issues"].map { |item| item["code"] }
      assert_includes codes, "compliance.invalid_yaml"
      refute_includes codes, "compliance.sidecar_mismatch"
      assert_nil result.dig("compliance", "pairs", 0, "equivalent")
    end
  end

  def test_compliance_rejects_recursive_yaml_aliases_without_crashing
    with_hub do |root, config|
      directory = File.join(root, "compliance", "example", "control-assessments")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "control.json"), JSON.pretty_generate({ "status" => "satisfied" }))
      File.write(
        File.join(directory, "control.yaml"),
        "---\ncycle: &cycle\n  self: *cycle\n"
      )

      result = Flightdeck::Doctor.new(config).run
      codes = result["issues"].map { |item| item["code"] }
      assert_includes codes, "compliance.invalid_yaml"
      refute_includes codes, "compliance.sidecar_mismatch"
    end
  end

  def test_compliance_allows_standalone_cyclonedx_json
    with_hub do |root, config|
      directory = File.join(root, "compliance", "example", "generated-documents")
      FileUtils.mkdir_p(directory)
      File.write(
        File.join(directory, "sbom.cdx.json"),
        JSON.pretty_generate(
          {
            "bomFormat" => "CycloneDX",
            "specVersion" => "1.6",
            "version" => 1,
            "components" => []
          }
        )
      )

      result = Flightdeck::Doctor.new(config).run
      refute_includes result["issues"].map { |item| item["code"] }, "compliance.orphan_json"
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
      assert_includes output.string, "--pending-client-id ORIGINAL and --task-id RESOLVED"
      assert_includes output.string, "Mission graph nodes may be added only while fully planned"
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

  def test_mission_is_separate_ignored_record_and_default_route_does_not_monitor
    with_hub do |root, config|
      mission = Flightdeck::MissionStore.new(config).create(
        slug: "dispatch-default", title: "Dispatch", outcome: "Return receipt."
      )
      assert_equal "MissionRecord", mission["kind"]
      assert_equal "dispatch_only", mission.dig("spec", "mode")
      assert File.file?(File.join(root, "hub", "missions", "dispatch-default", "mission.yaml"))
      assert_includes File.read(File.join(root, ".gitignore")), "/hub/missions/"
      assert_equal "return_without_monitoring", config.routing["post_dispatch_policy"]
      assert_equal "user_initiated_only", config.routing["monitoring_policy"]
      route = Flightdeck::RoutePlanner.new(config).plan(
        workload_name: "development", work_type: "implementation"
      )
      assert_includes route.fetch("steps").join(" "), "do not inspect owner artifacts, poll, wait, or read progress"
      error = assert_raises(Flightdeck::ValidationError) do
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(
          slug: "dispatch-default", observations_path: write_mission_observations(root, "dispatch-default", [])
        )
      end
      assert_includes error.message, "dispatch_only"
    end
  end

  def test_mission_success_contract_and_durable_authorization_are_machine_enforced
    with_hub do |root, config|
      output = StringIO.new
      errors = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: errors)
      assert_equal 0, cli.run(%w[mission new compatible --title Compatible --outcome delivered --json])
      compatible = JSON.parse(output.string)
      assert_equal [{ "id" => "criterion-001", "text" => "delivered" }], compatible.dig("spec", "success_criteria")
      assert_equal [], compatible.dig("spec", "non_goals")
      assert_match(/\Ascope-[0-9a-f]{48}\z/, compatible.dig("spec", "authorization_boundary"))

      output.truncate(0)
      output.rewind
      errors.truncate(0)
      errors.rewind
      assert_equal 2, cli.run(
        %w[mission new missing-criterion --title Durable --outcome delivered --mode watch_only
           --authorized-target-json {} --json]
      )
      assert_includes errors.string, "--success-criterion"

      errors.truncate(0)
      errors.rewind
      assert_equal 2, cli.run(
        %w[mission new missing-target --title Durable --outcome delivered --mode supervised
           --success-criterion verified --json]
      )
      assert_includes errors.string, "--authorized-target-json"

      output.truncate(0)
      output.rewind
      target_json = JSON.generate(mission_authorized_target(config))
      assert_equal 0, cli.run(
        ["mission", "new", "durable", "--title", "Durable", "--outcome", "delivered", "--mode", "supervised",
         "--success-criterion", "tested", "--success-criterion", "reviewed", "--non-goal", "deployment",
         "--non-goal", "publication", "--authorized-target-json", target_json, "--json"]
      )
      durable = JSON.parse(output.string)
      assert_equal [
        { "id" => "criterion-001", "text" => "tested" },
        { "id" => "criterion-002", "text" => "reviewed" }
      ], durable.dig("spec", "success_criteria")
      assert_equal %w[deployment publication], durable.dig("spec", "non_goals")

      mission_path = File.join(config.mission_dir, "durable", "mission.yaml")
      durable["spec"]["success_criteria"] = []
      Flightdeck::Support.atomic_yaml(mission_path, durable)
      assert Flightdeck::MissionStore.new(config).validate("durable").any? { |message| message.include?("success_criteria") }
    end
  end

  def test_mission_unit_limits_cover_small_and_large_graphs
    with_hub do |_root, config|
      [1, 8, 9, 16, 50].each do |count|
        slug = "units-#{count}"
        target_count = count == 50 ? 51 : count
        targets = target_count.times.map { |index| mission_authorized_target(config, node_id: "unit-#{index}") }
        create_mission(config, slug: slug, authorized_targets: targets)
        count.times do |index|
          add_mission_node(config, slug: slug, node_id: "unit-#{index}")
        end
        assert_equal count, Flightdeck::MissionStore.new(config).snapshot(slug).dig("spec", "graph", "nodes").length
      end
      error = assert_raises(Flightdeck::ValidationError) do
        add_mission_node(config, slug: "units-50", node_id: "unit-50")
      end
      assert_includes error.message, "unit budget exhausted"
    end
  end

  def test_mission_graph_rejects_cycle_and_unordered_same_checkout_writers
    with_hub do |root, config|
      checkout = File.join(root, "development", "shared")
      writer_targets = %w[writer-a writer-b].map do |id|
        mission_authorized_target(config, node_id: id, project_path: checkout, access_mode: "write")
      end
      create_mission(config, slug: "graph-safety", authorized_targets: writer_targets)
      add_mission_node(
        config, slug: "graph-safety", node_id: "writer-a", access_mode: "write", project_path: checkout
      )
      error = assert_raises(Flightdeck::ValidationError) do
        add_mission_node(
          config, slug: "graph-safety", node_id: "writer-b", access_mode: "write", project_path: checkout
        )
      end
      assert_includes error.message, "concurrent local writer conflict"
      add_mission_node(
        config, slug: "graph-safety", node_id: "writer-b", access_mode: "write",
        project_path: checkout, dependencies: ["writer-a"], accepted: ["validation_result"]
      )

      mission = Flightdeck::MissionStore.new(config).snapshot("graph-safety")
      mission.dig("spec", "graph", "nodes").first["dependencies"] = ["writer-b"]
      Flightdeck::Support.atomic_yaml(
        File.join(config.mission_dir, "graph-safety", "mission.yaml"), mission
      )
      errors = Flightdeck::MissionStore.new(config).validate("graph-safety")
      assert errors.any? { |message| message.include?("dependency cycle") }
    end
  end

  def test_mission_sync_states_required_optional_fan_in_and_explicit_close
    with_hub do |root, config|
      create_mission(
        config, slug: "fan-in", authorized_targets: %w[required-unit optional-unit].map do |id|
          mission_authorized_target(config, node_id: id)
        end
      )
      add_mission_node(config, slug: "fan-in", node_id: "required-unit")
      add_mission_node(config, slug: "fan-in", node_id: "optional-unit", required: false)
      dispatch_mission_node(config, slug: "fan-in", node_id: "required-unit")
      dispatch_mission_node(config, slug: "fan-in", node_id: "optional-unit")
      observations = [
        mission_observation(config, slug: "fan-in", node_id: "required-unit", state: "review_ready", revision: 1),
        mission_observation(config, slug: "fan-in", node_id: "optional-unit", state: "blocked", revision: 1)
      ]
      path = write_mission_observations(root, "fan-in", observations)
      sync = Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config))
      assert_equal "review_ready", sync.plan(slug: "fan-in", observations_path: path)["resulting_state"]
      result = apply_mission_sync(sync, slug: "fan-in", observations_path: path)
      assert_equal "review_ready", result["resulting_state"]
      assert_equal ["offer_fan_in"], Flightdeck::MissionStore.new(config).outbox_for("fan-in").map { |item| item["type"] }
      closed = Flightdeck::MissionStore.new(config).close("fan-in")
      assert_equal "complete", closed.dig("status", "state")
      states = closed.dig("spec", "graph", "nodes").to_h { |node| [node["id"], node["observed_state"]] }
      assert_equal "complete", states["required-unit"]
      assert_equal "cancelled", states["optional-unit"]
      assert_equal "explicit_close", closed.dig("status", "history").last["event"]
    end
  end

  def test_mission_state_precedence_and_review_ready_requires_passed_typed_output
    with_hub do |root, config|
      create_mission(
        config, slug: "state-matrix", authorized_targets: %w[failed approval blocked runtime].map do |id|
          mission_authorized_target(config, node_id: id)
        end
      )
      %w[failed approval blocked runtime].each do |id|
        add_mission_node(config, slug: "state-matrix", node_id: id)
      end
      %w[failed approval blocked runtime].each do |id|
        dispatch_mission_node(config, slug: "state-matrix", node_id: id)
      end
      states = {
        "failed" => "failed_validation",
        "approval" => "needs_approval",
        "blocked" => "blocked",
        "runtime" => "runtime_failure"
      }
      observations = states.map do |id, state|
        mission_observation(config, slug: "state-matrix", node_id: id, state: state, revision: 1)
      end
      path = write_mission_observations(root, "state-matrix", observations)
      result = apply_mission_sync(Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)),
        slug: "state-matrix", observations_path: path
      )
      assert_equal "failed_validation", result["resulting_state"]

      invalid = mission_observation(
        config, slug: "state-matrix", node_id: "failed", state: "review_ready", revision: 2,
        validation: "not_applicable", output_declarations: []
      )
      invalid_path = write_mission_observations(root, "state-matrix", [invalid], name: "invalid-outcome.json")
      error = assert_raises(Flightdeck::ValidationError) do
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(
          slug: "state-matrix", observations_path: invalid_path
        )
      end
      assert_includes error.message, "requires passed"
    end
  end

  def test_mission_observation_status_codes_are_required_persisted_and_non_controlling
    with_hub do |root, config|
      create_mission(config, slug: "status-codes", mode: "watch_only")
      add_mission_node(config, slug: "status-codes")
      dispatch_mission_node(config, slug: "status-codes")
      sync = Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config))

      approval = mission_observation(
        config, slug: "status-codes", node_id: "unit-a", state: "needs_approval",
        status_code: "approval_requested", revision: 1
      )
      refute approval.key?("outcome")
      apply_mission_sync(sync,
        slug: "status-codes",
        observations_path: write_mission_observations(root, "status-codes", [approval], name: "approval-code.json")
      )
      node = Flightdeck::MissionStore.new(config).status("status-codes").dig("spec", "graph", "nodes", 0)
      assert_equal "needs_approval", node["observed_state"]
      assert_equal "approval_requested", node["status_code"]
      assert_nil node["outcome_code"]

      blocked = mission_observation(
        config, slug: "status-codes", node_id: "unit-a", state: "blocked",
        status_code: "dependency_unavailable", revision: 2
      )
      apply_mission_sync(sync,
        slug: "status-codes",
        observations_path: write_mission_observations(root, "status-codes", [blocked], name: "blocked-code.json")
      )
      assert_equal "dependency_unavailable",
                   Flightdeck::MissionStore.new(config).status("status-codes").dig("spec", "graph", "nodes", 0, "status_code")

      missing = mission_observation(config, slug: "status-codes", node_id: "unit-a", state: "running", revision: 3)
      missing.delete("status_code")
      error = assert_raises(Flightdeck::ValidationError) do
        sync.plan(
          slug: "status-codes",
          observations_path: write_mission_observations(root, "status-codes", [missing], name: "missing-code.json")
        )
      end
      assert_includes error.message, "missing fields: status_code"

      invalid = mission_observation(
        config, slug: "status-codes", node_id: "unit-a", state: "running", revision: 3,
        status_code: "NOT VALID"
      )
      error = assert_raises(Flightdeck::ValidationError) do
        sync.plan(
          slug: "status-codes",
          observations_path: write_mission_observations(root, "status-codes", [invalid], name: "invalid-code.json")
        )
      end
      assert_includes error.message, "status_code"

      mismatch = mission_observation(
        config, slug: "status-codes", node_id: "unit-a", state: "review_ready", revision: 3,
        status_code: "ready_for_review"
      )
      mismatch["outcome"]["code"] = "different_code"
      error = assert_raises(Flightdeck::ValidationError) do
        sync.plan(
          slug: "status-codes",
          observations_path: write_mission_observations(root, "status-codes", [mismatch], name: "mismatch-code.json")
        )
      end
      assert_includes error.message, "must equal child outcome code"
    end
  end

  def test_mission_criteria_are_stable_covered_and_disposed_without_validation_bypass
    with_hub do |root, config|
      targets = %w[unit-a unit-b].map { |id| mission_authorized_target(config, node_id: id) }
      mission = Flightdeck::MissionStore.new(config).create(
        slug: "criterion-contract", title: "Criterion contract", outcome: "Meet both criteria.",
        mode: "supervised", success_criteria: ["First condition passes.", "Second condition passes."],
        non_goals: ["No deployment."], authorized_targets: targets
      )
      assert_equal %w[criterion-001 criterion-002], mission.dig("spec", "success_criteria").map { |item| item["id"] }
      add_mission_node(
        config, slug: "criterion-contract", node_id: "unit-a", criterion_ids: ["criterion-001"]
      )
      assert_raises(Flightdeck::UsageError) do
        add_mission_node(
          config, slug: "criterion-contract", node_id: "unit-b",
          criterion_ids: %w[criterion-002 criterion-002]
        )
      end
      error = assert_raises(Flightdeck::ValidationError) do
        dispatch_mission_node(config, slug: "criterion-contract", node_id: "unit-a")
      end
      assert_includes error.message, "do not cover criterion IDs: criterion-002"

      add_mission_node(
        config, slug: "criterion-contract", node_id: "unit-b", criterion_ids: ["criterion-002"]
      )
      dispatch_mission_node(config, slug: "criterion-contract", node_id: "unit-a")
      degraded = mission_observation(
        config, slug: "criterion-contract", node_id: "unit-a", state: "review_ready", revision: 1,
        criterion_results: [
          { "criterion_id" => "criterion-001", "disposition" => "degraded", "status_code" => "partial_result" }
        ]
      )
      degraded_path = write_mission_observations(root, "criterion-contract", [degraded], name: "degraded-criterion.json")
      error = assert_raises(Flightdeck::ValidationError) do
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(
          slug: "criterion-contract", observations_path: degraded_path
        )
      end
      assert_includes error.message, "requires every assigned criterion to pass"

      blocked = mission_observation(
        config, slug: "criterion-contract", node_id: "unit-a", state: "failed_validation", revision: 1,
        validation: "failed", output_declarations: [], criterion_results: [
          { "criterion_id" => "criterion-001", "disposition" => "blocked", "status_code" => "dependency_blocked" }
        ]
      )
      result = apply_mission_sync(
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)), slug: "criterion-contract",
        observations_path: write_mission_observations(root, "criterion-contract", [blocked], name: "blocked-criterion.json")
      )
      assert_equal "failed_validation", result["resulting_state"]
      persisted = Flightdeck::MissionStore.new(config).snapshot("criterion-contract").dig("spec", "graph", "nodes", 0)
      assert_equal "blocked", persisted.dig("criterion_results", 0, "disposition")
      refute Flightdeck::MissionStore.new(config).fan_in_ready?(
        Flightdeck::MissionStore.new(config).snapshot("criterion-contract")
      )
    end
  end

  def test_mission_sync_plan_token_binds_generation_observations_and_actions
    with_hub do |root, config|
      create_mission(config, slug: "plan-token", mode: "watch_only")
      add_mission_node(config, slug: "plan-token")
      dispatch_mission_node(config, slug: "plan-token")
      sync = Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config))
      observation = mission_observation(
        config, slug: "plan-token", node_id: "unit-a", state: "running", revision: 1
      )
      path = write_mission_observations(root, "plan-token", [observation], name: "plan-token.json")
      plan = sync.plan(slug: "plan-token", observations_path: path)
      assert_match(/\A[0-9a-f]{64}\z/, plan["plan_token"])
      generation = Flightdeck::MissionStore.new(config).snapshot("plan-token").dig("status", "generation")
      assert_raises(Flightdeck::ValidationError) do
        sync.apply(slug: "plan-token", observations_path: path, plan_token: "0" * 64)
      end
      assert_equal generation, Flightdeck::MissionStore.new(config).snapshot("plan-token").dig("status", "generation")

      changed = observation.merge("cursor" => "different-cursor", "event_id" => "different-event")
      changed_path = write_mission_observations(root, "plan-token", [changed], name: "changed-plan-token.json")
      assert_raises(Flightdeck::ValidationError) do
        sync.apply(slug: "plan-token", observations_path: changed_path, plan_token: plan["plan_token"])
      end
      Flightdeck::MissionStore.new(config).checkpoint("plan-token")
      error = assert_raises(Flightdeck::ValidationError) do
        sync.apply(slug: "plan-token", observations_path: path, plan_token: plan["plan_token"])
      end
      assert_includes error.message, "does not match the locked mission generation"
      fresh = sync.plan(slug: "plan-token", observations_path: path)
      applied = sync.apply(slug: "plan-token", observations_path: path, plan_token: fresh["plan_token"])
      assert applied["applied"]
    end
  end

  def test_mission_authorized_scope_is_derived_and_tamper_evident
    with_hub do |_root, config|
      create_mission(config, slug: "scope-bound")
      add_mission_node(config, slug: "scope-bound")
      mission_path = File.join(config.mission_dir, "scope-bound", "mission.yaml")
      mission = Flightdeck::Support.load_data(mission_path)
      original_boundary = mission.dig("spec", "authorization_boundary")
      mission.dig("spec", "non_goals") << "Expanded hidden scope."
      Flightdeck::Support.atomic_yaml(mission_path, mission)
      errors = Flightdeck::MissionStore.new(config).validate("scope-bound")
      assert errors.any? { |message| message.include?("authorization_boundary does not match") }

      mission.dig("spec", "non_goals").pop
      mission.dig("spec", "graph", "nodes", 0)["host_id"] = "foreign-host"
      mission["spec"]["authorization_boundary"] = original_boundary
      Flightdeck::Support.atomic_yaml(mission_path, mission)
      errors = Flightdeck::MissionStore.new(config).validate("scope-bound")
      assert errors.any? { |message| message.include?("outside the mission authorized target scope") }
    end
  end

  def test_mission_sync_duplicate_out_of_order_not_loaded_and_stale_are_distinct
    with_hub do |root, config|
      create_mission(config, slug: "ordering", mode: "watch_only")
      add_mission_node(config, slug: "ordering")
      dispatch_mission_node(config, slug: "ordering")
      sync = Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config))
      first = mission_observation(config, slug: "ordering", node_id: "unit-a", state: "running", revision: 2)
      path = write_mission_observations(root, "ordering", [first])
      apply_mission_sync(sync, slug: "ordering", observations_path: path)
      generation = Flightdeck::MissionStore.new(config).snapshot("ordering").dig("status", "generation")
      duplicate = apply_mission_sync(sync, slug: "ordering", observations_path: path)
      assert_equal "duplicate_event_id", duplicate.dig("ignored", 0, "reason")
      assert_equal generation, Flightdeck::MissionStore.new(config).snapshot("ordering").dig("status", "generation")

      old = mission_observation(config, slug: "ordering", node_id: "unit-a", state: "blocked", revision: 1)
      old_path = write_mission_observations(root, "ordering", [old], name: "old.json")
      assert_equal "stale_revision", sync.plan(slug: "ordering", observations_path: old_path).dig("ignored", 0, "reason")
      unloaded = mission_observation(config, slug: "ordering", node_id: "unit-a", state: "notLoaded", revision: 3)
      unloaded_path = write_mission_observations(root, "ordering", [unloaded], name: "unloaded.json")
      unloaded_plan = sync.plan(slug: "ordering", observations_path: unloaded_path)
      assert_equal "not_loaded", unloaded_plan.dig("ignored", 0, "reason")
      assert_equal "running", unloaded_plan["resulting_state"]

      future_store = Flightdeck::MissionStore.new(config, clock: -> { Time.now.utc + 7200 })
      assert_equal "stale", future_store.status("ordering").dig("status", "state")
    end
  end

  def test_mission_rejects_identity_drift_raw_text_secrets_and_oversize
    with_hub do |root, config|
      create_mission(config, slug: "hostile")
      add_mission_node(config, slug: "hostile")
      dispatch_mission_node(config, slug: "hostile")
      observation = mission_observation(
        config, slug: "hostile", node_id: "unit-a", state: "running", revision: 1
      )
      observation["runtime_project_id"] = "wrong-runtime"
      path = write_mission_observations(root, "hostile", [observation])
      error = assert_raises(Flightdeck::ValidationError) do
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(slug: "hostile", observations_path: path)
      end
      assert_includes error.message, "identity drift"

      malicious = mission_observation(
        config, slug: "hostile", node_id: "unit-a", state: "running", revision: 1,
        include_outcome: true
      )
      malicious["outcome"]["final_text"] = "done"
      path = write_mission_observations(root, "hostile", [malicious], name: "raw.json")
      error = assert_raises(Flightdeck::ValidationError) do
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(slug: "hostile", observations_path: path)
      end
      assert_includes error.message, "forbidden fields"
      assert_raises(Flightdeck::UsageError) do
        Flightdeck::MissionStore.new(config).create(
          slug: "secret", title: "Secret", outcome: "Bearer abcdefghijklmnopqrstuvwxyz"
        )
      end
      assert_raises(Flightdeck::UsageError) do
        Flightdeck::MissionStore.new(config).create(
          slug: "oversized", title: "x" * 300, outcome: "bounded"
        )
      end
      store = Flightdeck::MissionStore.new(config)
      assert_raises(Flightdeck::ValidationError) do
        store.action_record(store.snapshot("hostile"), type: "deploy", payload: {}, trigger: "malicious")
      end
      observation.delete("outcome")
      refute File.read(File.join(config.mission_dir, "hostile", "mission.yaml")).include?("final_text")
    end
  end

  def test_mission_dispatch_unknown_action_ledger_crash_replay_and_lock_conflict
    with_hub do |_root, config|
      create_mission(config, slug: "ledger", mode: "watch_only")
      add_mission_node(config, slug: "ledger")
      store = Flightdeck::MissionStore.new(config)
      mission = store.record_dispatch(
        slug: "ledger", node_id: "unit-a", runtime_project_id: "runtime-unit-a",
        host_id: "host-local", dispatch_unknown: true
      )
      assert_equal "dispatch_unknown", mission.dig("spec", "graph", "nodes", 0, "observed_state")
      action = store.outbox_for("ledger").first
      assert_equal "observe", action["type"]
      store.prepare_action(slug: "ledger", action_id: action["id"])
      assert_raises(Flightdeck::ValidationError) { store.checkpoint("ledger") }
      assert_raises(Flightdeck::ValidationError) { store.prepare_action(slug: "ledger", action_id: action["id"]) }
      store.acknowledge_action(slug: "ledger", action_id: action["id"])
      assert_equal "acknowledged", store.outbox_for("ledger").first["status"]

      lock_path = File.join(config.mission_dir, "ledger", ".lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        error = assert_raises(Flightdeck::ValidationError) do
          store.add_node(
            slug: "ledger", node_id: "unit-b", logical_project_key: "project-unit-b",
            runtime_project_id: "runtime-unit-b",
            project_path: File.join(config.root, "development", "unit-b"), host_id: "host-local",
            execution_mode: "local", access_mode: "read_only", work_type: "validation", required: false,
            allowed_output_types: ["validation_result"]
          )
        end
        assert_includes error.message, "lease conflict"
      end


      create_mission(
        config, slug: "pending-worktree", mode: "watch_only",
        authorized_targets: [mission_authorized_target(config, execution_mode: "worktree", access_mode: "write")]
      )
      add_mission_node(config, slug: "pending-worktree", execution_mode: "worktree", access_mode: "write")
      store.record_dispatch(
        slug: "pending-worktree", node_id: "unit-a", runtime_project_id: "runtime-unit-a",
        host_id: "host-local", pending_client_id: "pending-client-a"
      )
      empty = write_mission_observations(config.root, "pending-worktree", [], name: "pending.json")
      error = assert_raises(Flightdeck::ValidationError) do
        Flightdeck::MissionSync.new(store).plan(slug: "pending-worktree", observations_path: empty)
      end
      assert_includes error.message, "worktree creation is pending or unknown"
      assert_raises(Flightdeck::ValidationError) do
        store.record_dispatch(
          slug: "pending-worktree", node_id: "unit-a", runtime_project_id: "runtime-unit-a",
          host_id: "host-local", task_id: "task-unit-a", pending_client_id: "wrong-client"
        )
      end
      resolved = store.record_dispatch(
        slug: "pending-worktree", node_id: "unit-a", runtime_project_id: "runtime-unit-a",
        host_id: "host-local", task_id: "task-unit-a", pending_client_id: "pending-client-a"
      )
      assert_equal "task-unit-a", resolved.dig("spec", "graph", "nodes", 0, "task_id")
      assert_nil resolved.dig("spec", "graph", "nodes", 0, "pending_client_id")

      create_mission(config, slug: "retry-budget", mode: "watch_only")
      add_mission_node(config, slug: "retry-budget")
      store.record_dispatch(
        slug: "retry-budget", node_id: "unit-a", runtime_project_id: "runtime-unit-a",
        host_id: "host-local", dispatch_unknown: true
      )
      retry_action = store.outbox_for("retry-budget").first
      4.times do
        store.prepare_action(slug: "retry-budget", action_id: retry_action["id"])
        store.fail_action(slug: "retry-budget", action_id: retry_action["id"], code: "transient_failure")
      end
      assert_raises(Flightdeck::ValidationError) do
        store.prepare_action(slug: "retry-budget", action_id: retry_action["id"])
      end

      started = Time.utc(2026, 1, 1)
      Flightdeck::MissionStore.new(config, clock: -> { started }).create(
        slug: "duration-budget", title: "Duration", outcome: "Bounded mission.", mode: "watch_only",
        success_criteria: ["The bounded mission finishes before its duration budget expires."],
        authorized_targets: [mission_authorized_target(config)]
      )
      expired = Flightdeck::MissionStore.new(config, clock: -> { started + 604_801 })
      assert_raises(Flightdeck::ValidationError) do
        expired.add_node(
          slug: "duration-budget", node_id: "unit-a", logical_project_key: "project-unit-a",
          runtime_project_id: "runtime-unit-a",
          project_path: File.join(config.root, "development", "unit-a"), host_id: "host-local",
          execution_mode: "local", access_mode: "read_only", work_type: "validation", required: true,
          allowed_output_types: ["validation_result"], criterion_ids: ["criterion-001"]
        )
      end
    end
  end

  def test_mission_stress_graphs_and_replay_classification_are_bounded
    nodes = 16.times.map do |index|
      {
        "id" => "unit-#{index}", "required" => true, "dependencies" => index.zero? ? [] : ["unit-#{index - 1}"],
        "observed_state" => "planned", "execution_mode" => "worktree", "access_mode" => "write",
        "project_path_digest" => Digest::SHA256.hexdigest("worktree-#{index}")
      }
    end
    100.times { assert_empty Flightdeck::MissionGraph.new(Marshal.load(Marshal.dump(nodes))).validate }

    node = { "revision" => 10, "cursor" => "cursor-10", "event_id" => "event-10", "seen_event_ids" => ["event-10"] }
    sync = Flightdeck::MissionSync.allocate
    10_000.times do |index|
      observation = {
        "revision" => index.even? ? 10 : 9,
        "cursor" => index.even? ? "cursor-10" : "cursor-9",
        "event_id" => index.even? ? "event-10" : "event-9"
      }
      reason = sync.send(:stale_reason, node, observation)
      assert_includes %w[duplicate_event_id stale_revision], reason
    end
    assert_equal 1, node["seen_event_ids"].length
  end

  def test_mission_cli_json_surface_is_installable_and_coherent
    with_hub do |root, _config|
      output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new)
      cli_path = File.join(root, "development", "unit-a")
      target = {
        "logical_project_key" => "project-a", "runtime_project_id" => "opaque-runtime",
        "project_path_digest" => Digest::SHA256.hexdigest(File.expand_path(cli_path)),
        "host_id" => "local-host", "execution_mode" => "local", "access_mode" => "read_only"
      }
      assert_equal 0, cli.run(
        ["mission", "new", "cli-mission", "--title", "CLI", "--outcome", "validated",
         "--success-criterion", "verified", "--non-goal", "deployment", "--mode", "watch_only",
         "--authorized-target-json", JSON.generate(target), "--json"]
      )
      created = JSON.parse(output.string)
      assert_equal "MissionRecord", created["kind"]

      output.truncate(0)
      output.rewind
      assert_equal 0, cli.run(
        [
          "mission", "add", "cli-mission", "unit-a", "--project-key", "project-a",
          "--runtime-project-id", "opaque-runtime", "--project-path", cli_path, "--host-id", "local-host",
          "--execution-mode", "local", "--access-mode", "read_only", "--work-type", "validation",
          "--required", "--criterion-id", "criterion-001", "--allows-output", "validation_result", "--json"
        ]
      )
      added = JSON.parse(output.string)
      assert_equal "unit-a", added.dig("spec", "graph", "nodes", 0, "id")

      output.truncate(0)
      output.rewind
      assert_equal 0, cli.run(
        %w[mission record-dispatch cli-mission unit-a --runtime-project-id opaque-runtime --host-id local-host --dispatch-unknown --json]
      )
      unknown = JSON.parse(output.string)
      assert_equal "dispatch_unknown", unknown.dig("status", "state")
      assert_equal "observe", unknown.dig("status", "outbox", 0, "type")
    end
  end

  def test_mission_list_contract_is_deterministic_bounded_paginated_and_read_only
    with_hub do |root, config|
      output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new)

      assert_equal 0, cli.run(["mission", "list", "--hub-root", root, "--limit", "1"])
      empty = JSON.parse(output.string)
      assert_equal "flightdeck.mission-list/v1", empty["api_version"]
      assert_equal "MissionList", empty["kind"]
      assert_equal [], empty["missions"]
      assert_equal({ "limit" => 1, "returned" => 0, "next_cursor" => nil }, empty["page"])

      create_mission(config, slug: "zulu-mission")
      create_mission(config, slug: "alpha-mission")
      add_mission_node(config, slug: "alpha-mission")
      store = Flightdeck::MissionStore.new(config)
      store.record_dispatch(
        slug: "alpha-mission",
        node_id: "unit-a",
        runtime_project_id: "runtime-unit-a",
        host_id: "host-local",
        dispatch_unknown: true
      )
      alpha_path = File.join(config.mission_dir, "alpha-mission", "mission.yaml")
      before_bytes = File.binread(alpha_path)
      before_status = store.status("alpha-mission")
      before_validation = store.validate("alpha-mission")
      before_tree = Dir.glob(File.join(config.mission_dir, "**", "*"), File::FNM_DOTMATCH).sort

      output.truncate(0)
      output.rewind
      assert_equal 0, cli.run(["mission", "list", "--hub-root", root, "--limit", "1", "--json"])
      first_page = JSON.parse(output.string)
      assert_equal ["alpha-mission"], first_page["missions"].map { |item| item["mission_id"] }
      assert_match(/\Av1\.[A-Za-z0-9_-]+\z/, first_page.dig("page", "next_cursor"))
      summary = first_page.fetch("missions").first
      assert_equal %w[
        created_at fan_in_ready generation mission_id mode progress state title updated_at
      ], summary.keys.sort
      assert_equal 1, summary.dig("progress", "total_units")
      assert_equal 1, summary.dig("progress", "required_units")
      assert_equal 1, summary.dig("progress", "attention_units")
      assert_equal "dispatch_unknown", summary["state"]
      refute_includes output.string, root
      refute_includes output.string, "Produce validated typed outputs."
      refute_includes output.string, "project_path"
      refute_includes output.string, "task_id"
      refute_includes output.string, "outbox"

      output.truncate(0)
      output.rewind
      assert_equal 0, cli.run(
        ["mission", "list", "--hub-root", root, "--limit", "1", "--cursor", first_page.dig("page", "next_cursor")]
      )
      second_page = JSON.parse(output.string)
      assert_equal ["zulu-mission"], second_page["missions"].map { |item| item["mission_id"] }
      assert_nil second_page.dig("page", "next_cursor")

      output.truncate(0)
      output.rewind
      assert_equal 0, cli.run(["mission", "list", "--hub-root", root, "--limit", "100"])
      all = JSON.parse(output.string)
      assert_equal %w[alpha-mission zulu-mission], all["missions"].map { |item| item["mission_id"] }

      output.truncate(0)
      output.rewind
      assert_equal 2, cli.run(["mission", "list", "--hub-root", root, "--limit", "101"])
      assert_equal "invalid_limit", JSON.parse(output.string).dig("error", "code")

      output.truncate(0)
      output.rewind
      assert_equal 2, cli.run(["mission", "list", "--hub-root", root, "--cursor", "not-a-v1-cursor"])
      assert_equal "invalid_cursor", JSON.parse(output.string).dig("error", "code")

      output.truncate(0)
      output.rewind
      assert_equal 2, cli.run(["mission", "list", "--hub-root", root, "--unknown-#{'x' * 512}"])
      invalid_request = JSON.parse(output.string)
      assert_equal "invalid_request", invalid_request.dig("error", "code")
      assert_equal "Mission list request is invalid.", invalid_request.dig("error", "message")
      assert_operator invalid_request.dig("error", "message").bytesize, :<=, 256

      assert_equal before_bytes, File.binread(alpha_path)
      assert_equal before_status, store.status("alpha-mission")
      assert_equal before_validation, store.validate("alpha-mission")
      assert_equal before_tree, Dir.glob(File.join(config.mission_dir, "**", "*"), File::FNM_DOTMATCH).sort
    end
  end

  def test_mission_list_contract_returns_safe_structured_root_and_record_errors
    Dir.mktmpdir("flightdeck-list-errors-") do |directory|
      output = StringIO.new
      cli = Flightdeck::CLI.new(root: directory, out: output, err: StringIO.new)
      missing = File.join(directory, "absent-hub")
      assert_equal 1, cli.run(["mission", "list", "--hub-root", missing])
      missing_error = JSON.parse(output.string)
      assert_equal "MissionListError", missing_error["kind"]
      assert_equal false, missing_error["ok"]
      assert_equal "hub_root_not_found", missing_error.dig("error", "code")
      refute_includes output.string, missing

      invalid = File.join(directory, "invalid-hub")
      FileUtils.mkdir_p(invalid)
      File.write(File.join(invalid, "flightdeck.yaml"), YAML.dump({ "kind" => "NotAFlightdeck" }))
      output.truncate(0)
      output.rewind
      assert_equal 1, cli.run(["mission", "list", "--hub-root", invalid])
      invalid_error = JSON.parse(output.string)
      assert_equal "invalid_hub_root", invalid_error.dig("error", "code")
      refute_includes output.string, invalid
    end

    with_hub do |root, config|
      create_mission(config, slug: "valid-mission")
      create_mission(config, slug: "broken-mission")
      broken_path = File.join(config.mission_dir, "broken-mission", "mission.yaml")
      broken = Flightdeck::Support.load_data(broken_path)
      broken["kind"] = "UnexpectedRecord"
      Flightdeck::Support.atomic_yaml(broken_path, broken)

      output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new)
      assert_equal 1, cli.run(["mission", "list", "--hub-root", root])
      error = JSON.parse(output.string)
      assert_equal "flightdeck.mission-list/v1", error["api_version"]
      assert_equal "MissionListError", error["kind"]
      assert_equal "hub/schemas/mission-list.schema.json", error["schema"]
      assert_equal "malformed_mission_record", error.dig("error", "code")
      assert_equal "broken-mission", error.dig("error", "mission_id")
      refute_includes output.string, root
      refute_includes output.string, "UnexpectedRecord"
      refute error.key?("missions")
    end

    with_hub do |root, config|
      create_mission(config, slug: "oversized-mission")
      path = File.join(config.mission_dir, "oversized-mission", "mission.yaml")
      File.binwrite(path, "x" * (config.mission_budgets.fetch("max_record_bytes") + 1))

      output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new)
      assert_equal 1, cli.run(["mission", "list", "--hub-root", root])
      error = JSON.parse(output.string)
      assert_equal "malformed_mission_record", error.dig("error", "code")
      assert_equal "oversized-mission", error.dig("error", "mission_id")
      refute_includes output.string, root
    end

    with_hub do |root, _config|
      compatibility_path = File.join(root, "hub", "compatibility.json")
      compatibility = JSON.parse(File.read(compatibility_path))
      compatibility.fetch("capabilities").delete("flightdeck.command.mission-list.v1")
      Flightdeck::Support.atomic_write(compatibility_path, JSON.pretty_generate(compatibility))

      output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new)
      assert_equal 1, cli.run(["mission", "list", "--hub-root", root])
      error = JSON.parse(output.string)
      assert_equal "unsupported_hub_contract", error.dig("error", "code")
      refute_includes output.string, root
    end
  end

  def test_mission_list_fails_closed_when_same_record_changes_during_read
    with_hub do |_root, config|
      create_mission(config, slug: "changing-mission")
      path = File.join(config.mission_dir, "changing-mission", "mission.yaml")
      store = Flightdeck::MissionStore.new(
        config,
        after_list_record_read: lambda do |changed_path|
          File.binwrite(changed_path, "#{File.binread(changed_path)}\n")
        end
      )

      error = assert_raises(Flightdeck::MissionStore::ListError) { store.list_page }
      assert_equal "malformed_mission_record", error.code
      assert_equal "changing-mission", error.mission_id
      assert File.file?(path)
    end
  end

  def test_mission_list_schema_and_capability_are_declared
    schema = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "schemas", "mission-list.schema.json")))
    assert_equal "https://flightdeck.dev/schemas/mission-list.schema.json", schema["$id"]
    assert_equal 100, schema.dig("$defs", "success", "properties", "missions", "maxItems")
    assert_includes schema.dig("$defs", "error", "properties", "error", "properties", "code", "enum"),
                    "unsupported_hub_contract"
    assert_includes schema.dig("$defs", "error", "properties", "error", "properties", "code", "enum"),
                    "mission_limit_exceeded"

    compatibility = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "compatibility.json")))
    capability = compatibility.dig("capabilities", "flightdeck.command.mission-list.v1")
    assert_equal "command", capability["kind"]
    assert_equal "bin/flightdeck mission list ", capability.dig("probe", "help_contains")
    assert_includes capability["managed_paths"], "hub/schemas/mission-list.schema.json"
  end

  def test_mission_cli_rejects_cross_boundary_nodes_and_handoff_actions
    with_hub do |root, config|
      create_mission(
        config, slug: "authorization", authorized_targets: %w[producer consumer].map do |id|
          mission_authorized_target(config, node_id: id)
        end
      )
      output = StringIO.new
      error_output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: error_output)
      status = cli.run(
        [
          "mission", "add", "authorization", "foreign", "--project-key", "foreign-project",
          "--runtime-project-id", "runtime-foreign",
          "--project-path", File.join(root, "development", "foreign"), "--host-id", "host-local",
          "--execution-mode", "local", "--access-mode", "read_only", "--work-type", "validation",
          "--required", "--criterion-id", "criterion-001", "--allows-output", "validation_result", "--json"
        ]
      )
      assert_equal 1, status
      assert_includes error_output.string, "outside the mission authorized target scope"
      assert_empty Flightdeck::MissionStore.new(config).snapshot("authorization").dig("spec", "graph", "nodes")

      add_mission_node(config, slug: "authorization", node_id: "producer", outputs: ["candidate"])
      add_mission_node(
        config, slug: "authorization", node_id: "consumer", required: false,
        dependencies: ["producer"], accepted: ["candidate"]
      )
      dispatch_mission_node(config, slug: "authorization", node_id: "producer")
      observation = mission_observation(
        config, slug: "authorization", node_id: "producer", state: "review_ready", revision: 1
      )
      path = write_mission_observations(root, "authorization", [observation], name: "authorization.json")
      apply_mission_sync(Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)),
        slug: "authorization", observations_path: path
      )
      mission_path = File.join(config.mission_dir, "authorization", "mission.yaml")
      mission = Flightdeck::Support.load_data(mission_path)
      handoff = mission.dig("status", "outbox").find { |action| action["type"] == "dependency_handoff" }
      refute_nil handoff
      boundary = mission.dig("spec", "authorization_boundary")
      assert_match(/\Ascope-[0-9a-f]{48}\z/, handoff["authorization_boundary"])
      handoff["authorization_boundary"] = "foreign_boundary"
      Flightdeck::Support.atomic_yaml(mission_path, mission)

      output = StringIO.new
      error_output = StringIO.new
      cli = Flightdeck::CLI.new(root: root, out: output, err: error_output)
      assert_equal 1, cli.run(["mission", "prepare", "authorization", handoff["id"], "--json"])
      assert_includes error_output.string, "authorization boundary"
      tampered = Flightdeck::Support.load_data(mission_path)
      assert_equal "pending", tampered.dig("status", "outbox").find { |action| action["id"] == handoff["id"] }["status"]

      tampered.dig("status", "outbox").find { |action| action["id"] == handoff["id"] }["authorization_boundary"] = boundary
      tampered.dig("spec", "graph", "nodes").find { |node| node["id"] == "consumer" }["authorization_boundary"] = "foreign_boundary"
      Flightdeck::Support.atomic_yaml(mission_path, tampered)
      output = StringIO.new
      assert_equal 1, Flightdeck::CLI.new(root: root, out: output, err: StringIO.new).run(
        %w[mission validate authorization --json]
      )
      validation = JSON.parse(output.string)
      assert validation.fetch("errors").any? { |message| message.include?("dependency authorization boundary mismatch") }
    end
  end

  def test_mission_artifact_resolvers_bind_producer_consumer_host_and_action_ledger
    with_hub do |root, config|
      digest = Digest::SHA256.hexdigest("artifact-bundle")
      artifact_declaration = lambda do
        {
          "type" => "artifact_bundle",
          "artifact_id" => "bundle-v1",
          "digest" => digest
        }
      end

      create_mission(
        config, slug: "missing-resolver",
        authorized_targets: [mission_authorized_target(config, node_id: "producer")]
      )
      add_mission_node(config, slug: "missing-resolver", node_id: "producer", outputs: ["artifact_bundle"])
      dispatch_mission_node(config, slug: "missing-resolver", node_id: "producer")
      observation = mission_observation(
        config, slug: "missing-resolver", node_id: "producer", state: "review_ready", revision: 1,
        output_declarations: [artifact_declaration.call]
      )
      error = assert_raises(Flightdeck::ValidationError) do
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(
          slug: "missing-resolver",
          observations_path: write_mission_observations(root, "missing-resolver", [observation], name: "missing-resolver.json")
        )
      end
      assert_includes error.message, "producer artifact resolver"

      create_mission(
        config, slug: "bound-artifact", authorized_targets: %w[producer consumer].map do |id|
          mission_authorized_target(config, node_id: id)
        end
      )
      add_mission_node(
        config, slug: "bound-artifact", node_id: "producer", outputs: ["artifact_bundle"],
        artifact_resolver_kind: "same_host_workspace", artifact_resolver_id: "workspace_a"
      )
      add_mission_node(
        config, slug: "bound-artifact", node_id: "consumer", required: false,
        dependencies: ["producer"], accepted: ["artifact_bundle"],
        artifact_resolver_kind: "same_host_workspace", artifact_resolver_id: "workspace_a"
      )
      dispatch_mission_node(config, slug: "bound-artifact", node_id: "producer")
      observation = mission_observation(
        config, slug: "bound-artifact", node_id: "producer", state: "review_ready", revision: 1,
        status_code: "artifact_ready", output_declarations: [artifact_declaration.call]
      )
      sync = Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config))
      result = apply_mission_sync(sync,
        slug: "bound-artifact",
        observations_path: write_mission_observations(root, "bound-artifact", [observation], name: "bound-artifact.json")
      )
      handoff = result.fetch("actions").find { |action| action["type"] == "dependency_handoff" }
      assert_equal({ "kind" => "same_host_workspace", "id" => "workspace_a" }, handoff.dig("payload", "artifact_resolver"))
      expected_ref = "artifact:workspace_a/producer/#{Base64.urlsafe_encode64('task-producer', padding: false)}/#{digest}/bundle-v1"
      assert_equal expected_ref, handoff.dig("payload", "output_refs", 0, "ref")

      mission_path = File.join(config.mission_dir, "bound-artifact", "mission.yaml")
      mission = Flightdeck::Support.load_data(mission_path)
      stored_handoff = mission.dig("status", "outbox").find { |action| action["id"] == handoff["id"] }
      stored_handoff["payload"]["artifact_resolver"]["id"] = "workspace_b"
      Flightdeck::Support.atomic_yaml(mission_path, mission)
      error = assert_raises(Flightdeck::ValidationError) do
        Flightdeck::MissionStore.new(config).prepare_action(slug: "bound-artifact", action_id: handoff["id"])
      end
      assert_includes error.message, "artifact resolver binding"

      create_mission(
        config, slug: "resolver-mismatch", authorized_targets: %w[producer consumer].map do |id|
          mission_authorized_target(config, node_id: id)
        end
      )
      add_mission_node(
        config, slug: "resolver-mismatch", node_id: "producer", outputs: ["artifact_bundle"],
        artifact_resolver_kind: "external_approved", artifact_resolver_id: "locker_a"
      )
      add_mission_node(
        config, slug: "resolver-mismatch", node_id: "consumer", required: false,
        dependencies: ["producer"], accepted: ["artifact_bundle"],
        artifact_resolver_kind: "external_approved", artifact_resolver_id: "locker_b"
      )
      dispatch_mission_node(config, slug: "resolver-mismatch", node_id: "producer")
      observation = mission_observation(
        config, slug: "resolver-mismatch", node_id: "producer", state: "review_ready", revision: 1,
        output_declarations: [artifact_declaration.call]
      )
      error = assert_raises(Flightdeck::ValidationError) do
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(
          slug: "resolver-mismatch",
          observations_path: write_mission_observations(root, "resolver-mismatch", [observation], name: "resolver-mismatch.json")
        )
      end
      assert_includes error.message, "artifact resolver mismatch"

      create_mission(
        config, slug: "cross-host", authorized_targets: [
          mission_authorized_target(config, node_id: "producer", host_id: "host-a"),
          mission_authorized_target(config, node_id: "consumer", host_id: "host-b")
        ]
      )
      add_mission_node(
        config, slug: "cross-host", node_id: "producer", outputs: ["artifact_bundle"], host_id: "host-a",
        artifact_resolver_kind: "same_host_workspace", artifact_resolver_id: "workspace_a"
      )
      add_mission_node(
        config, slug: "cross-host", node_id: "consumer", required: false, host_id: "host-b",
        dependencies: ["producer"], accepted: ["artifact_bundle"],
        artifact_resolver_kind: "same_host_workspace", artifact_resolver_id: "workspace_a"
      )
      dispatch_mission_node(config, slug: "cross-host", node_id: "producer", host_id: "host-a")
      observation = mission_observation(
        config, slug: "cross-host", node_id: "producer", state: "review_ready", revision: 1,
        output_declarations: [artifact_declaration.call]
      )
      error = assert_raises(Flightdeck::ValidationError) do
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(
          slug: "cross-host",
          observations_path: write_mission_observations(root, "cross-host", [observation], name: "cross-host.json")
        )
      end
      assert_includes error.message, "crosses host identity"

      create_mission(
        config, slug: "approved-external", authorized_targets: [
          mission_authorized_target(config, node_id: "producer", host_id: "host-a"),
          mission_authorized_target(config, node_id: "consumer", host_id: "host-b")
        ]
      )
      add_mission_node(
        config, slug: "approved-external", node_id: "producer", outputs: ["artifact_bundle"], host_id: "host-a",
        artifact_resolver_kind: "external_approved", artifact_resolver_id: "locker_a"
      )
      add_mission_node(
        config, slug: "approved-external", node_id: "consumer", required: false, host_id: "host-b",
        dependencies: ["producer"], accepted: ["artifact_bundle"],
        artifact_resolver_kind: "external_approved", artifact_resolver_id: "locker_a"
      )
      dispatch_mission_node(config, slug: "approved-external", node_id: "producer", host_id: "host-a")
      observation = mission_observation(
        config, slug: "approved-external", node_id: "producer", state: "review_ready", revision: 1,
        output_declarations: [artifact_declaration.call]
      )
      plan = Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(
        slug: "approved-external",
        observations_path: write_mission_observations(root, "approved-external", [observation], name: "approved-external.json")
      )
      assert_equal "external_approved", plan.dig("actions", 0, "payload", "artifact_resolver", "kind")
    end
  end

  def test_mission_auto_handoff_requires_provenance_and_jit_idle_receipt
    with_hub do |root, config|
      targets = %w[producer consumer].map { |id| mission_authorized_target(config, node_id: id) }
      create_mission(config, slug: "jit-handoff", authorized_targets: targets)
      add_mission_node(
        config, slug: "jit-handoff", node_id: "producer", outputs: ["candidate"],
        artifact_resolver_kind: "external_approved", artifact_resolver_id: "producer_locker"
      )
      add_mission_node(
        config, slug: "jit-handoff", node_id: "consumer", required: false,
        dependencies: ["producer"], accepted: ["candidate"],
        artifact_resolver_kind: "external_approved", artifact_resolver_id: "future_locker"
      )
      dispatch_mission_node(config, slug: "jit-handoff", node_id: "producer")
      observation = mission_observation(
        config, slug: "jit-handoff", node_id: "producer", state: "review_ready", revision: 1
      )
      result = apply_mission_sync(
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)), slug: "jit-handoff",
        observations_path: write_mission_observations(root, "jit-handoff", [observation], name: "jit-handoff.json")
      )
      handoff = result.fetch("actions").find { |action| action["type"] == "dependency_handoff" }
      refute_nil handoff
      assert_nil handoff.dig("payload", "artifact_resolver")
      store = Flightdeck::MissionStore.new(config)
      store.prepare_action(slug: "jit-handoff", action_id: handoff["id"])
      error = assert_raises(Flightdeck::ValidationError) do
        store.acknowledge_action(slug: "jit-handoff", action_id: handoff["id"])
      end
      assert_includes error.message, "awaiting_handoff task"
      receipt = store.record_dispatch(
        slug: "jit-handoff", node_id: "consumer", runtime_project_id: "runtime-consumer",
        host_id: "host-local", task_id: "task-consumer"
      )
      assert_equal "awaiting_handoff", receipt.dig("spec", "graph", "nodes", 1, "observed_state")
      status_view = store.status("jit-handoff").dig("spec", "graph", "nodes", 1)
      assert_equal "running", status_view["observed_state"]
      assert_equal "handing_off", status_view["status_code"]
      acknowledged = store.acknowledge_action(slug: "jit-handoff", action_id: handoff["id"])
      assert_equal "running", acknowledged.dig("spec", "graph", "nodes", 1, "observed_state")
      %w[dispatch_pending dispatch_unknown].each do |non_actionable_state|
        simulated = Marshal.load(Marshal.dump(acknowledged))
        consumer = simulated.dig("spec", "graph", "nodes").find { |node| node["id"] == "consumer" }
        consumer["observed_state"] = non_actionable_state
        consumer["task_id"] = nil
        consumer["pending_client_id"] = "pending-consumer"
        actions = Flightdeck::MissionSync.new(store).send(
          :coordination_actions, simulated, [{ "state" => "review_ready" }]
        )
        refute actions.any? { |action| %w[dependency_handoff resume].include?(action["type"]) }
      end

      create_mission(config, slug: "terminal-only", authorized_targets: targets)
      add_mission_node(config, slug: "terminal-only", node_id: "producer", outputs: ["candidate"])
      add_mission_node(
        config, slug: "terminal-only", node_id: "consumer", required: false,
        dependencies: ["producer"], accepted: ["candidate"]
      )
      dispatch_mission_node(config, slug: "terminal-only", node_id: "producer")
      check_only = mission_observation(
        config, slug: "terminal-only", node_id: "producer", state: "review_ready", revision: 1,
        output_declarations: [{ "type" => "candidate", "ref" => "check:operator-evidence", "digest" => nil }]
      )
      terminal_plan = Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(
        slug: "terminal-only",
        observations_path: write_mission_observations(root, "terminal-only", [check_only], name: "terminal-only.json")
      )
      refute terminal_plan.fetch("actions").any? { |action| %w[dependency_handoff resume].include?(action["type"]) }

      forged = mission_observation(
        config, slug: "terminal-only", node_id: "producer", state: "review_ready", revision: 2,
        output_declarations: [{ "type" => "candidate", "ref" => "codex-task:consumer/dGFzay1wcm9kdWNlcg", "digest" => nil }]
      )
      error = assert_raises(Flightdeck::ValidationError) do
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(
          slug: "terminal-only",
          observations_path: write_mission_observations(root, "terminal-only", [forged], name: "forged-task-ref.json")
        )
      end
      assert_includes error.message, "terminal reference must use check: or review:"
    end
  end

  def test_mission_prepared_handoff_survives_unresolved_dispatch_receipts_fail_closed
    with_hub do |root, config|
      node_ids = %w[producer pending-consumer unknown-consumer]
      targets = node_ids.map { |id| mission_authorized_target(config, node_id: id) }
      create_mission(config, slug: "unresolved-handoff", authorized_targets: targets)
      add_mission_node(config, slug: "unresolved-handoff", node_id: "producer", outputs: ["candidate"])
      %w[pending-consumer unknown-consumer].each do |consumer_id|
        add_mission_node(
          config, slug: "unresolved-handoff", node_id: consumer_id, required: false,
          dependencies: ["producer"], accepted: ["candidate"]
        )
      end
      dispatch_mission_node(config, slug: "unresolved-handoff", node_id: "producer")
      observation = mission_observation(
        config, slug: "unresolved-handoff", node_id: "producer", state: "review_ready", revision: 1
      )
      result = apply_mission_sync(
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)), slug: "unresolved-handoff",
        observations_path: write_mission_observations(root, "unresolved-handoff", [observation], name: "unresolved.json")
      )
      actions = result.fetch("actions").select { |action| action["type"] == "dependency_handoff" }
      assert_equal 2, actions.length
      by_consumer = actions.to_h { |action| [action.dig("payload", "node_id"), action] }
      store = Flightdeck::MissionStore.new(config)

      pending_action = by_consumer.fetch("pending-consumer")
      store.prepare_action(slug: "unresolved-handoff", action_id: pending_action["id"])
      pending = store.record_dispatch(
        slug: "unresolved-handoff", node_id: "pending-consumer", runtime_project_id: "runtime-pending-consumer",
        host_id: "host-local", pending_client_id: "client-pending-consumer"
      )
      pending_node = pending.dig("spec", "graph", "nodes").find { |node| node["id"] == "pending-consumer" }
      assert_equal "dispatch_pending", pending_node["observed_state"]
      assert_equal "prepared", pending.dig("status", "outbox").find { |action| action["id"] == pending_action["id"] }["status"]
      assert_empty store.validate("unresolved-handoff")
      mission_path = File.join(config.mission_dir, "unresolved-handoff", "mission.yaml")
      without_handoff = Flightdeck::Support.load_data(mission_path)
      without_handoff.dig("status", "outbox").reject! { |action| action["id"] == pending_action["id"] }
      Flightdeck::Support.atomic_yaml(mission_path, without_handoff)
      assert store.validate("unresolved-handoff").any? { |message| message.include?("requires exactly one preserved") }
      Flightdeck::Support.atomic_yaml(mission_path, pending)
      refute store.next_actions("unresolved-handoff").any? { |action| action["id"] == pending_action["id"] }
      error = assert_raises(Flightdeck::ValidationError) do
        store.acknowledge_action(slug: "unresolved-handoff", action_id: pending_action["id"])
      end
      assert_includes error.message, "awaiting_handoff task"
      generation = store.snapshot("unresolved-handoff").dig("status", "generation")
      repeated = store.record_dispatch(
        slug: "unresolved-handoff", node_id: "pending-consumer", runtime_project_id: "runtime-pending-consumer",
        host_id: "host-local", pending_client_id: "client-pending-consumer"
      )
      assert_equal generation, repeated.dig("status", "generation")
      assert_equal 2, repeated.dig("status", "outbox").count { |action| action["type"] == "dependency_handoff" }
      reconciled = store.record_dispatch(
        slug: "unresolved-handoff", node_id: "pending-consumer", runtime_project_id: "runtime-pending-consumer",
        host_id: "host-local", task_id: "task-pending-consumer", pending_client_id: "client-pending-consumer"
      )
      assert_equal "awaiting_handoff", reconciled.dig("spec", "graph", "nodes").find { |node| node["id"] == "pending-consumer" }["observed_state"]
      store.acknowledge_action(slug: "unresolved-handoff", action_id: pending_action["id"])

      unknown_action = by_consumer.fetch("unknown-consumer")
      store.prepare_action(slug: "unresolved-handoff", action_id: unknown_action["id"])
      unknown = store.record_dispatch(
        slug: "unresolved-handoff", node_id: "unknown-consumer", runtime_project_id: "runtime-unknown-consumer",
        host_id: "host-local", dispatch_unknown: true
      )
      unknown_node = unknown.dig("spec", "graph", "nodes").find { |node| node["id"] == "unknown-consumer" }
      assert_equal "dispatch_unknown", unknown_node["observed_state"]
      assert_equal "prepared", unknown.dig("status", "outbox").find { |action| action["id"] == unknown_action["id"] }["status"]
      refute store.next_actions("unresolved-handoff").any? { |action| action["id"] == unknown_action["id"] }
      error = assert_raises(Flightdeck::ValidationError) do
        store.acknowledge_action(slug: "unresolved-handoff", action_id: unknown_action["id"])
      end
      assert_includes error.message, "awaiting_handoff task"
      store.fail_action(slug: "unresolved-handoff", action_id: unknown_action["id"], code: "receipt_unresolved")
      refute store.next_actions("unresolved-handoff").any? { |action| action["id"] == unknown_action["id"] }
      assert_empty store.validate("unresolved-handoff")
    end
  end

  def test_mission_dependent_dispatch_requires_complete_exact_prepared_handoff
    with_hub do |root, config|
      node_ids = %w[producer-a producer-b consumer]
      targets = node_ids.map { |id| mission_authorized_target(config, node_id: id) }
      create_mission(config, slug: "complete-handoff", authorized_targets: targets)
      %w[producer-a producer-b].each do |producer_id|
        add_mission_node(config, slug: "complete-handoff", node_id: producer_id, outputs: ["candidate"])
      end
      add_mission_node(
        config, slug: "complete-handoff", node_id: "consumer", required: false,
        dependencies: %w[producer-a producer-b], accepted: ["candidate"]
      )
      %w[producer-a producer-b].each do |producer_id|
        dispatch_mission_node(config, slug: "complete-handoff", node_id: producer_id)
      end
      observations = [
        mission_observation(
          config, slug: "complete-handoff", node_id: "producer-a", state: "review_ready", revision: 1
        ),
        mission_observation(
          config, slug: "complete-handoff", node_id: "producer-b", state: "review_ready", revision: 1,
          output_declarations: [{ "type" => "candidate", "ref" => "check:terminal-only", "digest" => nil }]
        )
      ]
      result = apply_mission_sync(
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)), slug: "complete-handoff",
        observations_path: write_mission_observations(root, "complete-handoff", observations, name: "partial-parent.json")
      )
      refute result.fetch("actions").any? { |action| action["type"] == "dependency_handoff" }
      store = Flightdeck::MissionStore.new(config)
      error = assert_raises(Flightdeck::ValidationError) do
        store.record_dispatch(
          slug: "complete-handoff", node_id: "consumer", runtime_project_id: "runtime-consumer",
          host_id: "host-local", pending_client_id: "client-consumer"
        )
      end
      assert_includes error.message, "requires its exact prepared dependency handoff"

      compatible = mission_observation(
        config, slug: "complete-handoff", node_id: "producer-b", state: "review_ready", revision: 2
      )
      result = apply_mission_sync(
        Flightdeck::MissionSync.new(store), slug: "complete-handoff",
        observations_path: write_mission_observations(root, "complete-handoff", [compatible], name: "complete-parent.json")
      )
      action = result.fetch("actions").find { |item| item["type"] == "dependency_handoff" }
      refute_nil action
      assert_equal %w[producer-a producer-b], action.dig("payload", "dependency_node_ids")
      assert_equal 2, action.dig("payload", "output_refs").length
      store.prepare_action(slug: "complete-handoff", action_id: action["id"])

      mission_path = File.join(config.mission_dir, "complete-handoff", "mission.yaml")
      mission = Flightdeck::Support.load_data(mission_path)
      stored = mission.dig("status", "outbox").find { |item| item["id"] == action["id"] }
      stored["payload"]["output_refs"] = [stored.dig("payload", "output_refs", 0)]
      Flightdeck::Support.atomic_yaml(mission_path, mission)
      errors = store.validate("complete-handoff")
      assert errors.any? { |message| message.include?("complete handoffable dependency set") }
      error = assert_raises(Flightdeck::ValidationError) do
        store.record_dispatch(
          slug: "complete-handoff", node_id: "consumer", runtime_project_id: "runtime-consumer",
          host_id: "host-local", pending_client_id: "client-consumer"
        )
      end
      assert_includes error.message, "complete handoffable dependency set"
    end
  end

  def test_mission_core_materializes_root_and_jit_artifact_declarations
    with_hub do |root, config|
      targets = %w[root-producer jit-producer consumer].map do |id|
        mission_authorized_target(config, node_id: id)
      end
      create_mission(config, slug: "declaration-bootstrap", authorized_targets: targets)
      add_mission_node(
        config, slug: "declaration-bootstrap", node_id: "root-producer", outputs: ["bootstrap"]
      )
      add_mission_node(
        config, slug: "declaration-bootstrap", node_id: "jit-producer",
        dependencies: ["root-producer"], accepted: ["bootstrap"], outputs: ["artifact_bundle"],
        artifact_resolver_kind: "external_approved", artifact_resolver_id: "artifact_store"
      )
      add_mission_node(
        config, slug: "declaration-bootstrap", node_id: "consumer", required: false,
        dependencies: ["jit-producer"], accepted: ["artifact_bundle"],
        artifact_resolver_kind: "external_approved", artifact_resolver_id: "artifact_store"
      )
      dispatch_mission_node(config, slug: "declaration-bootstrap", node_id: "root-producer")
      root_observation = mission_observation(
        config, slug: "declaration-bootstrap", node_id: "root-producer", state: "review_ready", revision: 1
      )
      assert_equal({ "type" => "bootstrap", "codex_task" => true },
                   root_observation.dig("outcome", "output_declarations", 0))
      refute root_observation.dig("outcome", "output_declarations", 0).key?("ref")
      root_result = apply_mission_sync(
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)), slug: "declaration-bootstrap",
        observations_path: write_mission_observations(root, "declaration-bootstrap", [root_observation], name: "root-declaration.json")
      )
      root_ref = root_result.dig("accepted", 0, "output_refs", 0)
      assert_equal "codex-task:root-producer/#{Base64.urlsafe_encode64('task-root-producer', padding: false)}", root_ref["ref"]
      root_handoff = root_result.fetch("actions").find { |action| action["type"] == "dependency_handoff" }
      store = Flightdeck::MissionStore.new(config)
      store.prepare_action(slug: "declaration-bootstrap", action_id: root_handoff["id"])
      store.record_dispatch(
        slug: "declaration-bootstrap", node_id: "jit-producer", runtime_project_id: "runtime-jit-producer",
        host_id: "host-local", task_id: "task-jit-producer"
      )
      store.acknowledge_action(slug: "declaration-bootstrap", action_id: root_handoff["id"])

      digest = Digest::SHA256.hexdigest("jit artifact")
      jit_observation = mission_observation(
        config, slug: "declaration-bootstrap", node_id: "jit-producer", state: "review_ready", revision: 1,
        output_declarations: [{ "type" => "artifact_bundle", "artifact_id" => "bundle-v2", "digest" => digest }]
      )
      changed_observation = Marshal.load(Marshal.dump(jit_observation))
      changed_observation.dig("outcome", "output_declarations", 0)["artifact_id"] = "bundle-v3"
      sync = Flightdeck::MissionSync.new(store)
      plan = sync.plan(
        slug: "declaration-bootstrap",
        observations_path: write_mission_observations(root, "declaration-bootstrap", [jit_observation], name: "jit-declaration.json")
      )
      changed_plan = sync.plan(
        slug: "declaration-bootstrap",
        observations_path: write_mission_observations(root, "declaration-bootstrap", [changed_observation], name: "jit-declaration-changed.json")
      )
      refute_equal plan["plan_token"], changed_plan["plan_token"]
      refute_equal plan.dig("accepted", 0, "event_digest"), changed_plan.dig("accepted", 0, "event_digest")
      refute_equal plan.dig("actions", 0, "trigger_digest"), changed_plan.dig("actions", 0, "trigger_digest")
      applied = sync.apply(
        slug: "declaration-bootstrap", observations_path: File.join(root, "jit-declaration.json"),
        plan_token: plan.fetch("plan_token")
      )
      task_binding = Base64.urlsafe_encode64("task-jit-producer", padding: false)
      expected = "artifact:artifact_store/jit-producer/#{task_binding}/#{digest}/bundle-v2"
      assert_equal expected, applied.dig("accepted", 0, "output_refs", 0, "ref")
      assert_equal expected, applied.dig("actions", 0, "payload", "output_refs", 0, "ref")
      persisted = store.snapshot("declaration-bootstrap").dig("spec", "graph", "nodes").find do |node|
        node["id"] == "jit-producer"
      end
      assert_equal jit_observation.dig("outcome", "output_declarations"), persisted["output_declarations"]
      assert_match(/\A[0-9a-f]{64}\z/, persisted["event_digest"])
    end
  end

  def test_mission_rejects_forged_declarations_and_record_reference_tamper
    with_hub do |root, config|
      targets = %w[producer consumer].map { |id| mission_authorized_target(config, node_id: id) }
      create_mission(config, slug: "declaration-tamper", authorized_targets: targets)
      add_mission_node(
        config, slug: "declaration-tamper", node_id: "producer", outputs: ["artifact_bundle"],
        artifact_resolver_kind: "external_approved", artifact_resolver_id: "artifact_store"
      )
      add_mission_node(
        config, slug: "declaration-tamper", node_id: "consumer", required: false,
        dependencies: ["producer"], accepted: ["artifact_bundle"],
        artifact_resolver_kind: "external_approved", artifact_resolver_id: "artifact_store"
      )
      dispatch_mission_node(config, slug: "declaration-tamper", node_id: "producer")
      digest = Digest::SHA256.hexdigest("artifact")
      valid = mission_observation(
        config, slug: "declaration-tamper", node_id: "producer", state: "review_ready", revision: 1,
        output_declarations: [{ "type" => "artifact_bundle", "artifact_id" => "bundle-v1", "digest" => digest }]
      )
      invalid_declarations = [
        [{ "type" => "artifact_bundle", "artifact_id" => "../escape", "digest" => digest }, "artifact_id"],
        [{ "type" => "artifact_bundle", "artifact_id" => "bundle-v1", "digest" => digest.upcase }, "lowercase sha256"],
        [{ "type" => "artifact_bundle", "ref" => "artifact:forged/producer/binding/#{digest}/bundle-v1", "digest" => digest }, "check: or review:"],
        [{ "type" => "artifact_bundle", "ref" => "codex-task:producer/forged", "digest" => nil }, "check: or review:"]
      ]
      invalid_declarations.each_with_index do |(declaration, message), index|
        observation = Marshal.load(Marshal.dump(valid))
        observation["outcome"]["output_declarations"] = [declaration]
        error = assert_raises(Flightdeck::ValidationError) do
          Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(
            slug: "declaration-tamper",
            observations_path: write_mission_observations(root, "declaration-tamper", [observation], name: "invalid-declaration-#{index}.json")
          )
        end
        assert_includes error.message, message
      end

      apply_mission_sync(
        Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)), slug: "declaration-tamper",
        observations_path: write_mission_observations(root, "declaration-tamper", [valid], name: "valid-declaration.json")
      )
      mission_path = File.join(config.mission_dir, "declaration-tamper", "mission.yaml")
      mission = Flightdeck::Support.load_data(mission_path)
      producer = mission.dig("spec", "graph", "nodes").find { |node| node["id"] == "producer" }
      original_ref = producer.dig("output_refs", 0, "ref")
      producer.dig("output_refs", 0)["ref"] = original_ref.sub("bundle-v1", "bundle-v9")
      Flightdeck::Support.atomic_yaml(mission_path, mission)
      errors = Flightdeck::MissionStore.new(config).validate("declaration-tamper")
      assert errors.any? { |message| message.include?("do not match core-materialized") }

      producer.dig("output_refs", 0)["ref"] = original_ref
      producer.dig("output_declarations", 0)["artifact_id"] = "bundle-v9"
      Flightdeck::Support.atomic_yaml(mission_path, mission)
      errors = Flightdeck::MissionStore.new(config).validate("declaration-tamper")
      assert errors.any? { |message| message.include?("event digest does not match") }
    end
  end

  def test_mission_blocked_and_stale_consumers_are_never_actionable
    with_hub do |root, config|
      targets = %w[producer consumer].map { |id| mission_authorized_target(config, node_id: id) }
      create_mission(config, slug: "non-actionable-consumer", authorized_targets: targets)
      add_mission_node(config, slug: "non-actionable-consumer", node_id: "producer", outputs: ["candidate"])
      add_mission_node(
        config, slug: "non-actionable-consumer", node_id: "consumer", required: false,
        dependencies: ["producer"], accepted: ["candidate"]
      )
      dispatch_mission_node(config, slug: "non-actionable-consumer", node_id: "producer")
      store = Flightdeck::MissionStore.new(config)
      observation = mission_observation(
        config, slug: "non-actionable-consumer", node_id: "producer", state: "review_ready", revision: 1
      )
      result = apply_mission_sync(
        Flightdeck::MissionSync.new(store), slug: "non-actionable-consumer",
        observations_path: write_mission_observations(root, "non-actionable-consumer", [observation], name: "non-actionable-root.json")
      )
      action = result.fetch("actions").find { |item| item["type"] == "dependency_handoff" }
      store.prepare_action(slug: "non-actionable-consumer", action_id: action["id"])
      store.record_dispatch(
        slug: "non-actionable-consumer", node_id: "consumer", runtime_project_id: "runtime-consumer",
        host_id: "host-local", task_id: "task-consumer"
      )
      store.fail_action(slug: "non-actionable-consumer", action_id: action["id"], code: "delivery_failed")

      store.mutate("non-actionable-consumer") do |record|
        consumer = record.dig("spec", "graph", "nodes").find { |node| node["id"] == "consumer" }
        consumer["observed_state"] = "blocked"
      end
      refute store.next_actions("non-actionable-consumer").any? { |item| item["type"] == "dependency_handoff" }
      error = assert_raises(Flightdeck::ValidationError) do
        store.prepare_action(slug: "non-actionable-consumer", action_id: action["id"])
      end
      assert_includes error.message, "failed dependency handoff is not retryable"

      stale_time = Time.now.utc - 7200
      store.mutate("non-actionable-consumer") do |record|
        consumer = record.dig("spec", "graph", "nodes").find { |node| node["id"] == "consumer" }
        consumer["observed_state"] = "running"
        consumer["dispatched_at"] = stale_time.iso8601
        consumer["updated_at"] = stale_time.iso8601
      end
      stale_store = Flightdeck::MissionStore.new(config, clock: -> { Time.now.utc + 7200 })
      refute stale_store.next_actions("non-actionable-consumer").any? { |item| item["type"] == "dependency_handoff" }
      error = assert_raises(Flightdeck::ValidationError) do
        stale_store.prepare_action(slug: "non-actionable-consumer", action_id: action["id"])
      end
      assert_includes error.message, "cannot target a stale consumer"
      assert_raises(Flightdeck::ValidationError) do
        store.action_record(store.snapshot("non-actionable-consumer"), type: "resume", payload: {}, trigger: "forbidden")
      end
    end
  end

  def test_mission_observation_size_is_checked_before_read_and_state_is_unchanged
    with_hub do |root, config|
      create_mission(config, slug: "size-first", mode: "watch_only")
      add_mission_node(config, slug: "size-first")
      dispatch_mission_node(config, slug: "size-first")
      store = Flightdeck::MissionStore.new(config)
      sync = Flightdeck::MissionSync.new(store)
      mission_path = File.join(config.mission_dir, "size-first", "mission.yaml")
      before = Digest::SHA256.file(mission_path).hexdigest
      oversized = File.join(root, "oversized-observations.json")
      File.write(oversized, "{" + ("x" * config.mission_budgets.fetch("max_forwarded_bytes")))

      file_singleton = File.singleton_class
      original_binread = file_singleton.instance_method(:binread)
      file_singleton.define_method(:binread) { |_path| raise "oversized observation was read before size rejection" }
      begin
        error = assert_raises(Flightdeck::ValidationError) do
          sync.plan(slug: "size-first", observations_path: oversized)
        end
        assert_includes error.message, "max_forwarded_bytes"
        error = assert_raises(Flightdeck::ValidationError) do
          sync.apply(slug: "size-first", observations_path: oversized, plan_token: "0" * 64)
        end
        assert_includes error.message, "max_forwarded_bytes"
      ensure
        file_singleton.define_method(:binread, original_binread)
      end
      assert_equal before, Digest::SHA256.file(mission_path).hexdigest

      error = assert_raises(Flightdeck::ValidationError) do
        sync.plan(slug: "size-first", observations_path: root)
      end
      assert_includes error.message, "regular file"
      unreadable = File.join(root, "unreadable-observations.json")
      File.write(unreadable, "{}")
      original_readable = file_singleton.instance_method(:readable?)
      file_singleton.define_method(:readable?) { |_path| false }
      begin
        error = assert_raises(Flightdeck::ValidationError) do
          sync.plan(slug: "size-first", observations_path: unreadable)
        end
        assert_includes error.message, "unreadable"
      ensure
        file_singleton.define_method(:readable?, original_readable)
      end
      assert_equal before, Digest::SHA256.file(mission_path).hexdigest
    end
  end

  def test_mission_cli_syncs_outcomeless_tool_states_and_rejects_wrong_outcome_shape
    with_hub do |root, config|
      create_mission(config, slug: "tool-states", mode: "watch_only")
      add_mission_node(config, slug: "tool-states")
      dispatch_mission_node(config, slug: "tool-states")
      cli = Flightdeck::CLI.new(root: root, out: StringIO.new, err: StringIO.new)
      states = %w[running needs_approval blocked runtime_failure cancelled]
      states.each_with_index do |state, index|
        revision = index + 1
        observation = mission_observation(
          config, slug: "tool-states", node_id: "unit-a", state: state, revision: revision
        )
        refute observation.key?("outcome"), state
        path = write_mission_observations(root, "tool-states", [observation], name: "#{state}.json")
        output = StringIO.new
        error_output = StringIO.new
        status = Flightdeck::CLI.new(root: root, out: output, err: error_output).run(
          ["mission", "sync-apply", "tool-states", "--observations", path, "--plan-token",
           Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(
             slug: "tool-states", observations_path: path
           ).fetch("plan_token"), "--json"]
        )
        assert_equal 0, status, error_output.string
        result = JSON.parse(output.string)
        assert_equal state, result["resulting_state"]
        node = Flightdeck::MissionStore.new(config).snapshot("tool-states").dig("spec", "graph", "nodes", 0)
        assert_equal observation["cursor"], node["cursor"]
        assert_equal revision, node["revision"]
        assert_nil node["outcome_code"]
        assert_nil node["validation_status"]
        assert_empty node["output_refs"]
      end

      before_not_loaded = Flightdeck::MissionStore.new(config).snapshot("tool-states")
      unloaded = mission_observation(
        config, slug: "tool-states", node_id: "unit-a", state: "notLoaded", revision: 6
      )
      refute unloaded.key?("outcome")
      unloaded_path = write_mission_observations(root, "tool-states", [unloaded], name: "not-loaded.json")
      output = StringIO.new
      unloaded_token = Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)).plan(
        slug: "tool-states", observations_path: unloaded_path
      ).fetch("plan_token")
      assert_equal 0, Flightdeck::CLI.new(root: root, out: output, err: StringIO.new).run(
        ["mission", "sync-apply", "tool-states", "--observations", unloaded_path,
         "--plan-token", unloaded_token, "--json"]
      )
      unloaded_result = JSON.parse(output.string)
      assert_equal "not_loaded", unloaded_result.dig("ignored", 0, "reason")
      after_not_loaded = Flightdeck::MissionStore.new(config).snapshot("tool-states")
      assert_equal before_not_loaded.dig("spec", "graph", "nodes", 0, "cursor"), after_not_loaded.dig("spec", "graph", "nodes", 0, "cursor")
      assert_equal "cancelled", after_not_loaded.dig("spec", "graph", "nodes", 0, "observed_state")

      %w[running needs_approval blocked runtime_failure cancelled notLoaded].each_with_index do |state, index|
        fabricated = mission_observation(
          config, slug: "tool-states", node_id: "unit-a", state: state, revision: 20 + index,
          include_outcome: true
        )
        path = write_mission_observations(root, "tool-states", [fabricated], name: "fabricated-#{index}.json")
        error_output = StringIO.new
        status = Flightdeck::CLI.new(root: root, out: StringIO.new, err: error_output).run(
          ["mission", "sync-plan", "tool-states", "--observations", path, "--json"]
        )
        assert_equal 1, status
        assert_includes error_output.string, "forbidden fields: outcome"
      end

      %w[review_ready failed_validation].each_with_index do |state, index|
        missing = mission_observation(
          config, slug: "tool-states", node_id: "unit-a", state: state, revision: 40 + index
        )
        missing.delete("outcome")
        path = write_mission_observations(root, "tool-states", [missing], name: "missing-final-#{index}.json")
        error_output = StringIO.new
        status = Flightdeck::CLI.new(root: root, out: StringIO.new, err: error_output).run(
          ["mission", "sync-plan", "tool-states", "--observations", path, "--json"]
        )
        assert_equal 1, status
        assert_includes error_output.string, "missing fields: outcome"
      end
    end
  end

  def test_mission_cli_freezes_graph_after_any_execution_or_action_marker
    with_hub do |root, config|
      add_via_cli = lambda do |slug, node_id|
        output = StringIO.new
        error_output = StringIO.new
        status = Flightdeck::CLI.new(root: root, out: output, err: error_output).run(
          [
            "mission", "add", slug, node_id, "--project-key", "project-#{node_id}",
            "--runtime-project-id", "runtime-#{node_id}",
            "--project-path", File.join(root, "development", node_id), "--host-id", "host-local",
            "--execution-mode", "local", "--access-mode", "read_only", "--work-type", "validation",
            "--optional", "--allows-output", "validation_result", "--json"
          ]
        )
        [status, output.string, error_output.string]
      end
      assert_frozen = lambda do |slug, node_id|
        mission_path = File.join(config.mission_dir, slug, "mission.yaml")
        before = Digest::SHA256.file(mission_path).hexdigest
        status, _output, error_output = add_via_cli.call(slug, node_id)
        assert_equal 1, status
        assert_includes error_output, "mission graph is frozen once execution begins"
        assert_equal before, Digest::SHA256.file(mission_path).hexdigest
      end

      create_mission(
        config, slug: "planning-open", authorized_targets: %w[unit-a planned-extra].map do |id|
          mission_authorized_target(config, node_id: id)
        end
      )
      add_mission_node(config, slug: "planning-open")
      status, output, error_output = add_via_cli.call("planning-open", "planned-extra")
      assert_equal 0, status, error_output
      assert_equal 2, JSON.parse(output).dig("spec", "graph", "nodes").length

      create_mission(config, slug: "task-dispatched")
      add_mission_node(config, slug: "task-dispatched")
      dispatch_mission_node(config, slug: "task-dispatched")
      assert_frozen.call("task-dispatched", "late-task-owner")

      create_mission(
        config, slug: "pending-dispatch",
        authorized_targets: [mission_authorized_target(config, execution_mode: "worktree", access_mode: "write")]
      )
      add_mission_node(config, slug: "pending-dispatch", execution_mode: "worktree", access_mode: "write")
      Flightdeck::MissionStore.new(config).record_dispatch(
        slug: "pending-dispatch", node_id: "unit-a", runtime_project_id: "runtime-unit-a",
        host_id: "host-local", pending_client_id: "pending-unit-a"
      )
      assert_frozen.call("pending-dispatch", "late-pending-owner")

      create_mission(config, slug: "unknown-dispatch", mode: "watch_only")
      add_mission_node(config, slug: "unknown-dispatch")
      Flightdeck::MissionStore.new(config).record_dispatch(
        slug: "unknown-dispatch", node_id: "unit-a", runtime_project_id: "runtime-unit-a",
        host_id: "host-local", dispatch_unknown: true
      )
      assert_frozen.call("unknown-dispatch", "late-unknown-owner")

      create_mission(config, slug: "observed-mission", mode: "watch_only")
      add_mission_node(config, slug: "observed-mission")
      dispatch_mission_node(config, slug: "observed-mission")
      running = mission_observation(
        config, slug: "observed-mission", node_id: "unit-a", state: "running", revision: 1
      )
      observations_path = write_mission_observations(
        root, "observed-mission", [running], name: "freeze-observed.json"
      )
      apply_mission_sync(Flightdeck::MissionSync.new(Flightdeck::MissionStore.new(config)),
        slug: "observed-mission", observations_path: observations_path
      )
      assert_frozen.call("observed-mission", "late-observed-owner")

      create_mission(config, slug: "action-mission", mode: "watch_only")
      add_mission_node(config, slug: "action-mission")
      store = Flightdeck::MissionStore.new(config)
      store.mutate("action-mission") do |mission|
        action = store.action_record(
          mission,
          type: "observe",
          payload: { "node_id" => "unit-a", "reason" => "dispatch_unknown" },
          trigger: "synthetic-planned-action"
        )
        store.append_actions!(mission, [action])
      end
      planned_with_action = store.snapshot("action-mission")
      assert_equal "planned", planned_with_action.dig("status", "state")
      assert_equal "planned", planned_with_action.dig("spec", "graph", "nodes", 0, "observed_state")
      assert_frozen.call("action-mission", "late-action-owner")
      action_id = store.outbox_for("action-mission").first["id"]
      store.prepare_action(slug: "action-mission", action_id: action_id)
      assert_frozen.call("action-mission", "late-prepared-owner")
    end
  end

  def test_mission_authoring_catalog_exposes_only_exact_safe_eligible_choices
    with_authoring_fixture do |root, _config, _authoring, catalog, target|
      refute_nil target
      assert_equal "flightdeck.command.mission-authoring.v1", catalog["capability"]
      assert_match(/\Acatalog-[0-9a-f]{48}\z/, catalog["catalog_generation"])
      assert_equal %w[local worktree], catalog["targets"].map { |item| item["execution_mode"] }.uniq.sort
      assert_equal %w[read_only write], catalog["targets"].map { |item| item["access_mode"] }.uniq.sort
      assert catalog["targets"].all? { |item| item.keys.sort == %w[access_mode display_label execution_mode host_id logical_project_key project_path_digest runtime_project_id target_id].sort }
      refute_includes JSON.generate(catalog), root
      refute_includes JSON.generate(catalog), "project_path\""
    end
  end

  def test_mission_authoring_plan_is_read_only_complete_acyclic_and_canonical
    with_authoring_fixture do |_root, config, authoring, _catalog, target|
      nodes = [
        {
          "id" => "producer", "target_id" => target.fetch("target_id"), "required" => true,
          "dependencies" => [], "accepted_input_types" => [], "allowed_output_types" => ["contract_ref"]
        },
        {
          "id" => "consumer", "target_id" => target.fetch("target_id"), "required" => true,
          "dependencies" => ["producer"], "accepted_input_types" => ["contract_ref"],
          "allowed_output_types" => ["validation_ref"]
        }
      ]
      draft = authoring_draft(target, nodes: nodes)
      plan = authoring_plan(authoring, draft)
      reordered = draft.to_a.reverse.to_h
      reordered["selected_targets"] = draft.fetch("selected_targets").map { |item| item.to_a.reverse.to_h }
      same_plan = authoring_plan(authoring, reordered)

      assert_equal plan.values_at("plan_id", "plan_generation", "plan_digest", "plan_token"),
                   same_plan.values_at("plan_id", "plan_generation", "plan_digest", "plan_token")
      canonical = lambda do |value|
        case value
        when Hash then value.keys.sort.to_h { |key| [key, canonical.call(value[key])] }
        when Array then value.map { |item| canonical.call(item) }
        else value
        end
      end
      digest_input = {
        "capability" => "flightdeck.command.mission-authoring.v1",
        "catalog_generation" => plan.fetch("catalog_generation"),
        "mission" => plan.fetch("mission")
      }
      assert_equal Digest::SHA256.hexdigest(JSON.generate(canonical.call(digest_input))), plan["plan_digest"]
      assert_match(/\Amission-[0-9a-f]{24}\z/, plan.dig("mission", "id"))
      assert_equal %w[producer consumer], plan.dig("mission", "graph", "nodes").map { |node| node["id"] }
      assert_equal ["criterion-001"], plan.dig("mission", "graph", "nodes", 0, "criterion_ids")
      assert_equal ["criterion-001"], plan.dig("mission", "graph", "nodes", 1, "criterion_ids")
      assert_equal target["project_path_digest"], plan.dig("mission", "authorized_targets", 0, "project_path_digest")
      refute Dir.exist?(config.mission_dir)
      assert_equal "all_required_nodes_own_all_criteria", plan.fetch("warnings").last.fetch("code")
    end
  end

  def test_mission_authoring_rejects_forbidden_secret_future_cycle_and_target_drift
    with_authoring_fixture do |_root, config, authoring, _catalog, target|
      draft = authoring_draft(target)

      forbidden = Marshal.load(Marshal.dump(draft)).merge("raw_yaml" => "kind: MissionRecord")
      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) { authoring_plan(authoring, forbidden) }
      assert_equal "malformed_request", error.code

      secret = Marshal.load(Marshal.dump(draft))
      secret["outcome"] = "Bearer abcdefghijklmnopqrstuvwxyz"
      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) { authoring_plan(authoring, secret) }
      assert_equal "forbidden_content", error.code

      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) do
        authoring.plan("schema_version" => "flightdeck.mission-authoring.plan-request/v2", "draft" => draft)
      end
      assert_equal "future_version", error.code

      drift = Marshal.load(Marshal.dump(draft))
      drift.dig("selected_targets", 0)["runtime_project_id"] = "fabricated-runtime"
      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) { authoring_plan(authoring, drift) }
      assert_equal "ineligible_target", error.code

      cycle = authoring_draft(
        target,
        nodes: [
          {"id" => "a", "target_id" => target["target_id"], "required" => true, "dependencies" => ["b"], "accepted_input_types" => ["ref"], "allowed_output_types" => ["ref"]},
          {"id" => "b", "target_id" => target["target_id"], "required" => true, "dependencies" => ["a"], "accepted_input_types" => ["ref"], "allowed_output_types" => ["ref"]}
        ]
      )
      assert_raises(Flightdeck::MissionAuthoring::ContractError, Flightdeck::ValidationError) do
        authoring_plan(authoring, cycle)
      end

      bounded = authoring_draft(target)
      bounded.fetch("nodes").first["id"] = "a#{'b' * 127}"
      assert_equal 128, bounded.fetch("nodes").first.fetch("id").bytesize
      authoring_plan(authoring, bounded)
      oversized = Marshal.load(Marshal.dump(bounded))
      oversized.fetch("nodes").first["id"] = "a#{'b' * 128}"
      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) { authoring_plan(authoring, oversized) }
      assert_equal "malformed_request", error.code
    end
  end

  def test_mission_authoring_create_is_exact_atomic_and_recoverable
    with_authoring_fixture do |_root, config, authoring, _catalog, target|
      draft = authoring_draft(target)
      plan = authoring_plan(authoring, draft)
      created = authoring.create(authoring_create_request(plan, draft, "client-operation-001"))
      assert_equal "created", created["outcome"]
      mission = Flightdeck::MissionStore.new(config).snapshot(created.fetch("mission_id"))
      assert_equal 1, mission.dig("spec", "graph", "nodes").length
      assert_equal plan["plan_id"], mission.dig("metadata", "authoring", "plan_id")
      assert_equal plan["plan_digest"], mission.dig("metadata", "authoring", "plan_digest")
      assert_empty Flightdeck::MissionStore.new(config).validate(created.fetch("mission_id"))

      recovered = authoring.operation(
        "schema_version" => Flightdeck::MissionAuthoring::OPERATION_REQUEST,
        "operation_id" => "client-operation-001"
      )
      assert_equal "created", recovered["outcome"]
      assert_equal created["mission_id"], recovered["mission_id"]
    end
  end

  def test_mission_authoring_stale_duplicate_conflicting_and_consumed_operations_fail_closed
    with_authoring_fixture do |_root, config, authoring, _catalog, target|
      draft = authoring_draft(target)
      plan = authoring_plan(authoring, draft)
      stale = authoring_create_request(plan, draft, "client-operation-stale")
      stale["confirmation"]["plan_token"] = "0" * 64
      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) { authoring.create(stale) }
      assert_equal "stale_or_mismatched_plan", error.code
      not_created = authoring.operation(
        "schema_version" => Flightdeck::MissionAuthoring::OPERATION_REQUEST,
        "operation_id" => "client-operation-stale"
      )
      assert_equal "not_created", not_created["outcome"]

      drift_draft = authoring_draft(target, title: "Exact path catalog drift")
      drift_plan = authoring_plan(authoring, drift_draft)
      registry = Flightdeck::Support.load_data(config.project_registry_path)
      registry.dig("projects", "authoring-project")["runtime_project_id"] = "runtime-project-replaced"
      Flightdeck::Support.atomic_yaml(config.project_registry_path, registry)
      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) do
        authoring.create(authoring_create_request(drift_plan, drift_draft, "client-operation-drift"))
      end
      assert_equal "stale_or_mismatched_plan", error.code
      registry.dig("projects", "authoring-project")["runtime_project_id"] = "runtime-project-authoring"
      Flightdeck::Support.atomic_yaml(config.project_registry_path, registry)

      request = authoring_create_request(plan, draft, "client-operation-once")
      authoring.create(request)
      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) { authoring.create(request) }
      assert_equal "duplicate_operation", error.code

      changed_draft = authoring_draft(target, title: "Different exact plan")
      changed_plan = authoring_plan(authoring, changed_draft)
      conflict = authoring_create_request(changed_plan, changed_draft, "client-operation-once")
      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) { authoring.create(conflict) }
      assert_equal "conflicting_operation", error.code

      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) do
        authoring.create(authoring_create_request(plan, draft, "client-operation-second"))
      end
      assert_equal "consumed_plan", error.code
    end
  end

  def test_mission_authoring_failed_atomic_write_leaves_no_partial_mission
    with_authoring_fixture do |_root, config, authoring, _catalog, target|
      draft = authoring_draft(target)
      plan = authoring_plan(authoring, draft)
      request = authoring_create_request(plan, draft, "client-operation-atomic-failure")
      original = Flightdeck::Support.method(:atomic_yaml)
      Flightdeck::Support.singleton_class.define_method(:atomic_yaml) do |path, value|
        raise IOError, "synthetic Mission write failure" if path.end_with?("/mission.yaml")

        original.call(path, value)
      end
      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) { authoring.create(request) }
      assert_equal "persistence_failed", error.code
      refute File.exist?(File.join(config.mission_dir, plan.dig("mission", "id"), "mission.yaml"))
      status = authoring.operation(
        "schema_version" => Flightdeck::MissionAuthoring::OPERATION_REQUEST,
        "operation_id" => "client-operation-atomic-failure"
      )
      assert_equal "not_created", status["outcome"]

      Flightdeck::Support.singleton_class.define_method(:atomic_yaml, original)
      retry_plan = authoring_plan(authoring, draft)
      assert_equal plan["plan_id"], retry_plan["plan_id"]
      retried = authoring.create(authoring_create_request(retry_plan, draft, "client-operation-after-not-created"))
      assert_equal "created", retried["outcome"]
    ensure
      Flightdeck::Support.singleton_class.define_method(:atomic_yaml, original) if original
    end
  end

  def test_mission_authoring_unknown_result_recovers_exact_created_without_retry
    with_authoring_fixture do |_root, config, authoring, _catalog, target|
      draft = authoring_draft(target)
      plan = authoring_plan(authoring, draft)
      request = authoring_create_request(plan, draft, "client-operation-unknown")
      original = authoring.method(:write_operation!)
      authoring.define_singleton_method(:write_operation!) do |record|
        raise IOError, "synthetic lost result" if record["state"] == "created"

        original.call(record)
      end
      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) { authoring.create(request) }
      assert_equal "unknown_outcome", error.code
      assert File.file?(File.join(config.mission_dir, plan.dig("mission", "id"), "mission.yaml"))

      recovered = Flightdeck::MissionAuthoring.new(config).operation(
        "schema_version" => Flightdeck::MissionAuthoring::OPERATION_REQUEST,
        "operation_id" => "client-operation-unknown"
      )
      assert_equal "created", recovered["outcome"]
      assert_equal plan.dig("mission", "id"), recovered["mission_id"]
    end
  end

  def test_mission_authoring_post_commit_fault_remains_unknown_and_consumed
    with_authoring_fixture do |_root, config, authoring, _catalog, target|
      draft = authoring_draft(target)
      plan = authoring_plan(authoring, draft)
      request = authoring_create_request(plan, draft, "client-operation-post-commit")
      original = Flightdeck::MissionStore.instance_method(:persist_complete_mission!)
      Flightdeck::MissionStore.define_method(:persist_complete_mission!) do |mission|
        original.bind(self).call(mission)
        raise IOError, "synthetic post-commit failure"
      end

      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) { authoring.create(request) }
      assert_equal "unknown_outcome", error.code
      operation_path = Dir.glob(File.join(config.mission_dir, ".authoring-operations", "*.json")).first
      assert_equal "unresolved", JSON.parse(File.read(operation_path)).fetch("state")
      assert File.file?(File.join(config.mission_dir, plan.dig("mission", "id"), "mission.yaml"))
      recovered = Flightdeck::MissionAuthoring.new(config).operation(
        "schema_version" => Flightdeck::MissionAuthoring::OPERATION_REQUEST,
        "operation_id" => "client-operation-post-commit"
      )
      assert_equal "created", recovered["outcome"]
      error = assert_raises(Flightdeck::MissionAuthoring::ContractError) do
        authoring.create(authoring_create_request(plan, draft, "client-operation-after-post-commit"))
      end
      assert_equal "consumed_plan", error.code
    ensure
      Flightdeck::MissionStore.define_method(:persist_complete_mission!, original) if original
    end
  end

  def test_mission_authoring_recovery_returns_unresolved_on_binding_or_store_conflict
    with_authoring_fixture do |_root, config, authoring, _catalog, target|
      draft = authoring_draft(target)
      plan = authoring_plan(authoring, draft)
      created = authoring.create(authoring_create_request(plan, draft, "client-operation-conflict"))
      mission_path = File.join(config.mission_dir, created.fetch("mission_id"), "mission.yaml")
      mission = Flightdeck::Support.load_data(mission_path)
      mission.dig("metadata", "authoring")["operation_digest"] = "f" * 64
      Flightdeck::Support.atomic_yaml(mission_path, mission)
      status = authoring.operation(
        "schema_version" => Flightdeck::MissionAuthoring::OPERATION_REQUEST,
        "operation_id" => "client-operation-conflict"
      )
      assert_equal "unresolved", status["outcome"]
      assert_equal "mission_identity_conflict", status["reason"]

      operation_path = Dir.glob(File.join(config.mission_dir, ".authoring-operations", "*.json")).first
      File.write(operation_path, "{\"schema_version\":\"future\"}\n")
      status = authoring.operation(
        "schema_version" => Flightdeck::MissionAuthoring::OPERATION_REQUEST,
        "operation_id" => "client-operation-conflict"
      )
      assert_equal "unresolved", status["outcome"]
      assert_equal "operation_store_invalid", status["reason"]
    end
  end

  def test_mission_authoring_recovery_rejects_unbound_and_unsafe_operation_records
    with_authoring_fixture do |_root, config, authoring, _catalog, target|
      draft = authoring_draft(target)
      plan = authoring_plan(authoring, draft)
      authoring.create(authoring_create_request(plan, draft, "client-operation-boundary"))
      operation_path = Dir.glob(File.join(config.mission_dir, ".authoring-operations", "*.json")).first
      operation = JSON.parse(File.read(operation_path))
      operation["mission_id"] = "../../outside"
      Flightdeck::Support.atomic_write(operation_path, "#{JSON.pretty_generate(operation)}\n")

      status = authoring.operation(
        "schema_version" => Flightdeck::MissionAuthoring::OPERATION_REQUEST,
        "operation_id" => "client-operation-boundary"
      )
      assert_equal "unresolved", status["outcome"]
      assert_equal "operation_store_invalid", status["reason"]

      File.delete(operation_path)
      File.symlink(__FILE__, operation_path)
      status = authoring.operation(
        "schema_version" => Flightdeck::MissionAuthoring::OPERATION_REQUEST,
        "operation_id" => "client-operation-boundary"
      )
      assert_equal "unresolved", status["outcome"]
      assert_equal "operation_store_invalid", status["reason"]
    end
  end

  def test_mission_authoring_cli_converts_unexpected_failures_to_closed_json
    with_authoring_fixture do |root, _config, _authoring, _catalog, _target|
      request_path = File.join(root, "catalog-internal-error.json")
      File.write(request_path, JSON.generate("schema_version" => Flightdeck::MissionAuthoring::CATALOG_REQUEST))
      original = Flightdeck::MissionAuthoring.instance_method(:catalog)
      Flightdeck::MissionAuthoring.define_method(:catalog) { |_request| raise IOError, "sensitive local path" }

      output = StringIO.new
      status = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new).run(
        ["mission", "authoring-catalog", "--request", request_path]
      )
      result = JSON.parse(output.string)
      assert_equal 1, status
      assert_equal Flightdeck::MissionAuthoring::ERROR_RESULT, result["schema_version"]
      assert_equal "internal_error", result.dig("error", "code")
      refute_includes output.string, "sensitive local path"
      refute_includes result.dig("error", "message"), "operation ID"
    ensure
      Flightdeck::MissionAuthoring.define_method(:catalog, original) if original
    end
  end

  def test_mission_authoring_capability_schema_and_cli_are_closed_machine_readable_surfaces
    compatibility = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "compatibility.json")))
    family = compatibility.fetch("capabilities").keys.grep(/mission-authoring/)
    assert_equal ["flightdeck.command.mission-authoring.v1"], family
    assert_equal "1.2.0", compatibility["template_version"]
    assert_equal({"mode" => "stop_and_plan_migration"}, compatibility.dig("capabilities", family.first, "fallback"))

    types = JSON.parse(File.read(File.join(TEMPLATE_ROOT, "hub", "schemas", "mission-authoring-types.schema.json")))
    assert_equal false, types.dig("$defs", "draft", "additionalProperties")
    assert_equal false, types.dig("$defs", "draftNode", "additionalProperties")
    assert_equal false, types.dig("$defs", "selectedTarget", "additionalProperties")

    with_authoring_fixture do |root, _config, _authoring, _catalog, target|
      request_path = File.join(root, "catalog-request.json")
      File.write(request_path, JSON.generate("schema_version" => Flightdeck::MissionAuthoring::CATALOG_REQUEST))
      output = StringIO.new
      status = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new).run(
        ["mission", "authoring-catalog", "--request", request_path, "--json"]
      )
      assert_equal 0, status
      assert_equal Flightdeck::MissionAuthoring::CATALOG_RESULT, JSON.parse(output.string)["schema_version"]

      draft = authoring_draft(target)
      File.write(
        request_path,
        JSON.generate("schema_version" => Flightdeck::MissionAuthoring::PLAN_REQUEST, "draft" => draft)
      )
      output = StringIO.new
      status = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new).run(
        ["mission", "authoring-plan", "--request", request_path]
      )
      assert_equal 0, status
      plan = JSON.parse(output.string)
      assert_equal Flightdeck::MissionAuthoring::PLAN_RESULT, plan["schema_version"]

      File.write(request_path, JSON.generate(authoring_create_request(plan, draft, "client-cli-operation")))
      output = StringIO.new
      status = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new).run(
        ["mission", "authoring-create", "--request", request_path]
      )
      assert_equal 0, status
      assert_equal "created", JSON.parse(output.string)["outcome"]

      File.write(
        request_path,
        JSON.generate(
          "schema_version" => Flightdeck::MissionAuthoring::OPERATION_REQUEST,
          "operation_id" => "client-cli-operation"
        )
      )
      output = StringIO.new
      status = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new).run(
        ["mission", "authoring-operation", "--request", request_path]
      )
      assert_equal 0, status
      assert_equal "created", JSON.parse(output.string)["outcome"]

      File.write(request_path, JSON.generate("schema_version" => "future", "shell" => "echo denied"))
      output = StringIO.new
      status = Flightdeck::CLI.new(root: root, out: output, err: StringIO.new).run(
        ["mission", "authoring-catalog", "--request", request_path]
      )
      result = JSON.parse(output.string)
      assert_equal 1, status
      assert_equal false, result["ok"]
      assert_equal "malformed_request", result.dig("error", "code")
    end
  end

  def test_mission_authoring_requires_declared_capability_before_any_operation_state
    with_authoring_fixture do |root, config, authoring, _catalog, target|
      compatibility_path = File.join(root, "hub", "compatibility.json")
      compatibility = JSON.parse(File.read(compatibility_path))
      compatibility.fetch("capabilities").delete(Flightdeck::MissionAuthoring::CAPABILITY)
      Flightdeck::Support.atomic_write(compatibility_path, JSON.pretty_generate(compatibility))
      draft = authoring_draft(target)
      plan_request = { "schema_version" => Flightdeck::MissionAuthoring::PLAN_REQUEST, "draft" => draft }
      create_request = {
        "schema_version" => Flightdeck::MissionAuthoring::CREATE_REQUEST,
        "operation_id" => "unsupported-operation",
        "confirmation" => { "plan_id" => "plan-#{'a' * 48}", "plan_generation" => "generation-#{'a' * 48}", "plan_digest" => "a" * 64, "plan_token" => "a" * 64 },
        "draft" => draft
      }
      [
        -> { authoring.catalog("schema_version" => Flightdeck::MissionAuthoring::CATALOG_REQUEST) },
        -> { authoring.plan(plan_request) },
        -> { authoring.create(create_request) },
        -> { authoring.operation("schema_version" => Flightdeck::MissionAuthoring::OPERATION_REQUEST, "operation_id" => "unsupported-operation") }
      ].each do |callable|
        error = assert_raises(Flightdeck::MissionAuthoring::ContractError, &callable)
        assert_equal "unsupported_hub_contract", error.code
      end
      refute Dir.exist?(File.join(config.mission_dir, ".authoring-operations"))
    end
  end
end
