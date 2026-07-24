# Flightdeck

A local control plane for coordinating independent repositories, program
workspaces, environments, research, and recurring operational checks.

Start work here, resolve the owner, dispatch to the owning Codex project, return
the logical project key, opaque runtime project ID, task ID, and mode, then stop
without monitoring. Owning projects remain authoritative for code, tests,
branches, artifacts, and live validation.

## Start here

1. Read [the guide map](docs/README.md) and
   [Codex project model](docs/codex-ui-workflow.md).
2. Add verified, credential-free repository declarations to
   `hub/repositories.yaml`.
3. Ask `configure bridge repos` and review the complete plan before apply.
4. Run `bin/flightdeck doctor --json`.
5. Describe an outcome naturally. Flightdeck routes it to the owning project,
   returns the task receipt, and stops without monitoring.

## Repository placement

Declared repository checkouts live under this Hub's workload roots. Declaration
`local_path` values are Hub-relative; they cannot point to repositories
elsewhere on the machine.

Flightdeck does not move existing repositories. It verifies an existing
checkout when it is already under the declared workload root. When the only
checkout is outside the Hub, Flightdeck may inspect it read-only to verify
repository facts and, with explicit authorization, clone a fresh checkout into
the appropriate workload directory. The original remains untouched.

Keep the original checkout until any uncommitted or unpushed work has been
transferred deliberately, because a fresh clone does not contain that local
state.

Start `hub/repositories.yaml` with verified, credential-free facts:

```yaml
api_version: flightdeck.dev/v1alpha1
kind: RepositoryDeclarations
schema: hub/schemas/repository-declarations.schema.json
repositories:
  - id: example-service
    workload: development
    provider: github
    locator: example-company/example-service
    local_path: development/example-service
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

Replace every synthetic value with verified metadata. An empty declaration list
is valid and means bridge setup has nothing to configure.

See [thread routing](docs/workflows/thread-routing.md) for Local, Worktree, and
remote mode rules, and
[repository onboarding](docs/workflows/repo-onboarding.md) for the absent or
unsaved checkout path.

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
bin/flightdeck route plan --workload development --work-type implementation --repo-id example-service
bin/flightdeck repo plan --workload patching --provider github --repo example/image
bin/flightdeck bridge plan --repo-id example-service --mode reference
bin/flightdeck bridge plan --all --failure-policy stop --json
bin/flightdeck bridge install --all --failure-policy stop --json
bin/flightdeck task new development example-feature --title "Example feature" --outcome "Deliver the scoped behavior"
```

Read-only commands do not fetch, clone, edit, register projects, or mutate
environments. Generated state is ignored.

Declare repositories in `hub/repositories.yaml`. Then ask the Hub to
“configure bridge repos” or follow
`docs/workflows/configure-bridge-repos.md`. The workflow verifies or onboards
each checkout, plans and installs non-destructive bridges, runs Doctor,
registers exact Codex projects, and writes an ignored per-repository receipt.
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
