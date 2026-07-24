# Configure bridge repositories

This is the mandatory Hub-local runbook for “configure bridge repos”,
“configure repository bridges”, “set up all repos”, and equivalent requests.
It configures declared checkouts, bridges, and Codex projects without creating
implementation tasks.

## Inputs and authority

Read `AGENTS.md`, `flightdeck.yaml`, `hub/repositories.yaml`, this file, and
`docs/workflows/repo-onboarding.md`. Validate every declaration against
`hub/schemas/repository-declarations.schema.json`. Reject duplicate IDs,
escaping paths, credentials, unknown providers/workloads, unverified default
branches, or missing bridge/project fields.

Each declaration supplies a stable logical project key. It does not and cannot
require a pre-known Codex runtime project ID.

Default new declarations to `reference`; select `materialized` for an ignored
portable pack. Never default to tracked `repo-native` mode.

## Checkout preparation

Use already-authenticated provider tools to verify provider, owner, canonical
locator/URL, and default branch without storing secrets. For an existing
checkout, verify the exact Git root, origin when applicable, branch, SHA, and
status. Preserve dirty and untracked content; do not clean, reset, stash,
switch, fetch, or pull.

For an authorized missing checkout, run `repo plan` and then `repo onboard`
under its declared workload root. Use the `existing-local` adapter to register
an existing unregistered checkout. Onboarding may install the declared bridge;
the later bulk apply must treat it as an idempotent no-op.

Repo-native mode requires explicit authorization and diff review per
repository. No bridge command overwrites an existing instruction, override,
materialized pack, or unmanaged marker.

## Bulk plan and apply

Run:

```text
bin/flightdeck bridge plan --all --failure-policy stop --json
```

Review every Git root, checkout, existing `AGENTS` file, profile/mode, target,
overwrite blocker, registry change, and project-registration action. `stop` is
the default failure policy. Use `continue` only when explicitly authorized.

Apply:

```text
bin/flightdeck bridge install --all --failure-policy stop --json
```

Add `--authorize-repo-native <repository-id>` once for each separately
authorized repo-native declaration. The command writes the ignored
`hub/state/bridge-repos.json` receipt. A valid bridge returns `noop`; conflicts
and drift fail closed. Receipt `ok` covers bridge application; `complete` is
true only when every declared bridge and exact saved project are verified.

## Doctor and project verification

Run `bin/flightdeck doctor --json`. Require bridge/artifact digests, local ignore
protection, portable-content path safety, and all required Hub documents.
Doctor does not fetch.

For each exact Git root, refresh the live Codex project list. Accept only an
exact normalized real-path match; never accept a display-name-only match.
Otherwise use native registration, or the supported Codex/operating-system
open-folder fallback, refresh, and verify. Retry once after refreshing
capability state.

After a second verified failure, record the error and give exactly:

```text
In Codex, choose File > Open Folder, select "<exact-repository-path>", then reply "done".
```

Give that one action per unresolved repository and no alternatives. Record only
live-list-verified matches in ignored `hub/state/projects.yaml`; a successful
open action alone is not verification. Key the record by the declaration's
logical project key, store that key separately from the opaque runtime project
ID returned by the live list, and include the exact path, verification source,
and timestamp. Use only the opaque runtime ID for later task operations.

Rerun the bulk plan and idempotent apply to refresh the receipt with checkout,
bridge, project, and error status per repository. Return those outcomes and
stop. Do not create owning-project implementation tasks for bridge setup.
Later project-owned work follows normal search/resume/create dispatch and
returns without monitoring.
