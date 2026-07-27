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
```

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
  dispatch, and persistent task resume/create behavior
- Optional authenticated provider CLIs for ownership and default-branch
  discovery; credentials remain in the user's configured credential stores
- Python 3 only when using the plugin's setup, comparison, de-branding, or CKL
  utilities

Run `make validate` and `bin/flightdeck doctor --json` after generation and after
control-plane changes.
