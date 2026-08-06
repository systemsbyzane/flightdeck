# Flightdeck

A local control plane for coordinating independent repositories, program
workspaces, environments, research, and recurring operational checks.

Start work here, resolve the owner, dispatch to the owning Codex project, return
the logical project key, opaque runtime project ID, task ID, and mode, then stop
without monitoring. Owning projects remain authoritative for code, tests,
branches, artifacts, and live validation.

## Start here

To set up Flightdeck or connect repositories, use natural language; no skill
name or YAML editing is required.

1. Read [the guide map](docs/README.md) and
   [Codex project model](docs/codex-ui-workflow.md).
2. Ask: `Connect the Git repositories under <absolute-folder>.`
3. Flightdeck previews discovery, connects safe checkouts in place, adds local
   reference bridges, and reports only conflicts that need attention.
4. Run `bin/flightdeck doctor --json`.
5. Ask Flightdeck to plan or review work in natural language; no skill name or
   mode selection is required.
6. Ask about CI/CD, infrastructure, platform services, or environments the same
   way; Flightdeck separates source work from external and runtime actions.
7. Ask about a STIG rule, CKL, evidence gap, applicability decision, or
   remediation naturally; Flightdeck adapts the depth without a fixed form.
8. Ask to upgrade Flightdeck or show patch notes naturally. The installed
   plugin workflow protects this Hub and never regenerates it.
9. Describe an implementation outcome naturally. Flightdeck routes it to the
   owning project, returns the task receipt, and stops without monitoring.
10. For an explicitly durable multi-task outcome, ask Flightdeck to run a
    Mission in `dispatch_only`, `watch_only`, or `supervised` mode. This Codex
    task remains the control room.

## What is a Mission?

A Mission is an opt-in ignored local parent record linking exact verified
persistent Codex tasks in a dependency graph. Ordinary dispatch remains
receipt-and-stop. A Mission may persist dispatch receipts, refresh compact
observations, or advance declared dependencies from allowlisted typed output
references, depending on its mode.

Child text is untrusted display-only material. Mission state stores normalized
envelopes and references, not prose, evidence bodies, credentials, or arbitrary
summaries. Supervision is bounded and never grants external actions. Only an
operator-requested close can mark a Mission complete.

The Mission parent, every graph node, and every outbox action must carry an
exactly equal `authorization_boundary`; any missing or different value fails
closed. Non-regular, unreadable, or oversized observation inputs are rejected
before their contents are read or parsed. A `clientThreadId`-only dispatch stays
`dispatch_pending` and cannot enter a wait batch until exact reconciliation
records both the original client ID and resolved task ID. A prepared handoff
survives that pending receipt, and the adapter never issues another create.

Nonterminal tool snapshots contain normalized state only and no child outcome.
Only `review_ready` or `failed_validation` requires an exact final outcome, and
fan-in requires all criteria covered and passed by required nodes plus
producer-bound typed refs materialized by core from closed child declarations
after the exact task receipt. Children never author canonical refs or bindings.

Mission creation persists finite generated defaults: 50 units, 3 retries, 200
actions, 65,536 forwarded bytes, 604,800 seconds duration, 3,600 seconds before
stale, and a 2,097,152-byte record. Declare the graph before dispatch; runtime
state freezes it. Dispatch a downstream task only when exactly one matching
complete, type-compatible handoff is prepared whose refs equal the complete eligible set
and include an automatic ref from every parent;
terminal check/review evidence and dependency readiness alone cannot start it.
References do not transport artifacts, so prove consumer access, co-locate
compatible work, or stop. Independent review uses a separate runtime task.

`watch_only` and `supervised` persist repeatable success criteria and exact
six-field authorized targets. Core assigns ordered criterion IDs and derives
the equality-only boundary. Automated handoff accepts only canonical refs that
core materializes from declarations and exact receipts; `check:` and `review:` are terminal operator
evidence. Action resolver metadata is present only for transported artifacts,
and sync apply requires the exact token returned by sync plan.
Only an internal prepared `awaiting_handoff` receipt can receive delivery;
status projects it as `running`/`handing_off`. Blocked, stale, pending, and
unknown consumers are non-actionable.

See [Missions](docs/workflows/missions.md) for the graph, identity, cursor,
outbox, status, budget, stop, fan-in, and upgrade contracts.

## Repository placement

Existing repositories attach in place by default. Flightdeck discovers only
under the folder you authorize, preserves dirty and untracked work, and does
not move, reset, clean, fetch, or edit tracked repository files.

Portable facts are written to `hub/repositories.yaml`. An attached
repository's exact absolute path exists only in ignored
`hub/state/repositories.yaml`, so the tracked declaration remains reusable on
another machine:

```yaml
api_version: flightdeck.dev/v1alpha1
kind: RepositoryDeclarations
schema: hub/schemas/repository-declarations.schema.json
repositories:
  - id: example-service
    placement: attached
    workload: development
    provider: github
    locator: example-company/example-service
    owner: example-company
    default_branch: main
    default_branch_verified: true
    bridge:
      profile: application
      mode: reference
    codex_project:
      expectation: saved_exact_path
      logical_key: example-service
```

Repositories intentionally managed under a Hub workload root use
`placement: managed` plus a Hub-relative `local_path`. Manual declaration
editing remains available for advanced or ambiguous cases, but is not required
for ordinary first-time setup.

See [thread routing](docs/workflows/thread-routing.md) for Local, Worktree, and
remote mode rules, and
[repository onboarding](docs/workflows/repo-onboarding.md) for the absent or
unsaved checkout path. See [planning](docs/workflows/planning.md) for
right-sized planning and [change review](docs/review/change-review.md) for the
findings-first review contract. Use [CI/CD](docs/workflows/ci-cd.md) for
delivery pipelines and [platform](docs/workflows/platform.md) for
infrastructure and environment work. Use
[STIG evaluation](docs/compliance/stig-evaluation.md) for adaptive evidence,
applicability, CKL, and remediation workflows.
Use [plugin lifecycle](docs/workflows/plugin-lifecycle.md) to understand why a
plugin update does not rewrite this generated Hub.
Use [Missions](docs/workflows/missions.md) when one outcome must persist across
several owning tasks; use direct [thread routing](docs/workflows/thread-routing.md)
for ordinary receipt-and-stop dispatch.
Use [generated-Hub compatibility](docs/workflows/hub-compatibility.md) to
inspect the versioned command and document surface before newer skills use it.

## Workload roots

- `development/` - application and service repositories
- `charts/` - Helm, YAML, manifest, and deployment repositories
- `patching/` - image and dependency source repositories
- `research/` - durable technical research workspaces
- `environments/` - platform and remote validation checkouts
- `operations/` - local operational inputs and review notes
- `compliance/` - isolated program workspaces and the reusable template

## Commands

```text
bin/flightdeck doctor --json
bin/flightdeck status
bin/flightdeck setup plan --repositories-root /absolute/repositories --json
bin/flightdeck setup connect --repositories-root /absolute/repositories --json
bin/flightdeck route plan --workload development --work-type implementation --repo-id example-service
bin/flightdeck repo plan --workload patching --provider github --repo example/image
bin/flightdeck bridge plan --repo-id example-service --mode reference
bin/flightdeck bridge plan --all --failure-policy stop --json
bin/flightdeck bridge install --all --failure-policy stop --json
bin/flightdeck task new development example-feature --title "Example feature" --outcome "Deliver the scoped behavior"
bin/flightdeck mission new example-release --title "Example release" --outcome "Prepare the coordinated change for review" --success-criterion "Contract and implementation validate" --non-goal "Do not commit, publish, deploy, or close" --mode supervised --authorized-target-json '{"logical_project_key":"example-api","runtime_project_id":"project-api","project_path_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","host_id":"local","execution_mode":"worktree","access_mode":"write"}'
bin/flightdeck mission add example-release api --project-key example-api --runtime-project-id project-api --project-path-digest aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --host-id local --execution-mode worktree --access-mode write --work-type implementation --required --criterion-id criterion-001 --allows-output contract_ref --artifact-resolver-kind same_host_workspace --artifact-resolver-id example-release-workspace
bin/flightdeck mission validate example-release --json
bin/flightdeck mission next-actions example-release --json
bin/flightdeck mission status example-release --json
```

Desktop clients use the closed, capability-gated
[Mission authoring API](docs/workflows/mission-authoring-api.md), never Mission
YAML or generic command passthrough. Require exactly
`flightdeck.command.mission-authoring.v1`, preview the complete graph, confirm
its exact plan identity/generation/digest/token, submit create once with one
opaque operation ID, and recover ambiguity through the read-only operation
command.

Read-only commands do not fetch, clone, edit, register projects, or mutate
environments. Generated state is ignored.

Initial setup discovers repositories and creates declarations automatically.
Advanced bridge mode changes, migrations, drift repair, or manually declared
sets follow `docs/workflows/configure-bridge-repos.md`. Both paths verify
checkouts, install non-destructive bridges, run Doctor, register exact Codex
projects, and write an ignored per-repository receipt.
Declarations use stable logical project keys and never require pre-known
runtime IDs. Registration refreshes the live project list, rejects display-name
matches, requires the exact normalized real path, and records the returned
opaque runtime ID only in ignored state. It does not create implementation
tasks.

Mission graph construction also creates no Codex task. The installed Mission
skill acts as the injected Codex UI task adapter, records exact dispatch
receipts, waits in batches of at most eight using per-task opaque cursors, and
feeds normalized observation envelopes into the explicit sync and outbox
commands. Pending `clientThreadId` and unknown create outcomes are reconciled
without blind retry so a timeout cannot silently duplicate a task.

For later repository work, `route plan` refuses a missing or drifting bridge
and emits a verified `bridge_handoff`. Dispatch includes it completely in the
child prompt. A Worktree reads its applicable repository `AGENTS.md` first,
then verifies and reads ignored reference or materialized bridge artifacts
from the original registered checkout because those ignored files do not
travel into a new Worktree. Repo-native policy is tracked and read in place.

## Runtime prerequisites

- Ruby with its standard JSON, YAML, Open3, and Minitest libraries
- Git for repository inspection, cloning, and Git-local bridge exclusions
- Codex project and task capabilities for registration, live-list verification,
  dispatch, persistent task resume/create behavior, compact waits, opaque
  cursors, and supervised follow-ups
- Optional authenticated provider CLIs for ownership and default-branch
  discovery; credentials remain in the user's configured credential stores
- Python 3 only when using the plugin's setup, comparison, de-branding, or CKL
  utilities

Run `make validate` and `bin/flightdeck doctor --json` after generation and after
control-plane changes.
