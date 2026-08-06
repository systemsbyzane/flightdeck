# Mission authoring API

## Capability and trust boundary

The exact client capability is `flightdeck.command.mission-authoring.v1`. It
first appears in generated-Hub template `1.2.0`. This is the only capability
family for catalog, preview, create, and create-outcome recovery.

The API is a narrow Flightdeck core boundary for an unprivileged desktop
client. The client may invoke only the four commands below with one bounded
JSON request file. It does not read or edit Mission YAML, mint Mission or
criterion identities, provide an authorization boundary, invoke shell text, or
call generic Flightdeck commands through this contract. Catalog, plan, and
operation recovery are read-only. Create persists one complete Mission record;
it does not create, resume, dispatch, observe, execute, or close Codex tasks.

Before enabling the controls, read the regular non-symlink
`hub/compatibility.json` and require the exact capability ID. This versioned,
bounded manifest is the lightweight client probe: it does not run Doctor,
status, repository discovery, or a generic command. A Hub without the required
capability remains selectable, but the client must show a diagnosable
unsupported state. Do not infer support from a plugin version, probe older
Mission commands as a substitute, regenerate the Hub, or automatically apply
the compatibility checker's migration plan.

The authoring capability is independent of task dispatch. It never proves a
managed Worktree's source-path reconciliation, exclusive ownership, lock
publication, or provider receipt. A desktop client must keep managed dispatch
disabled unless its own separately reviewed control plane proves all of those
conditions. An unknown task or create outcome remains recovery-only: never
retry, guess identity, or create a replacement task.

## Read-only Mission listing

Require `flightdeck.command.mission-list.v1` before invoking:

```text
bin/flightdeck mission list --hub-root /absolute/path/to/selected-hub \
  --limit 50 [--cursor OPAQUE_CURSOR] [--json]
```

This is the only plugin-owned list surface for a selected Hub. It returns the
closed `flightdeck.mission-list/v1` projection: stable Mission ID, bounded
display title, mode, state, timestamps, generation, fan-in readiness, and unit
progress counts. The cursor is opaque; the default limit is 50 and the maximum
is 100. The result contains no Mission YAML, outcome text, task or project
identity, raw path, output reference, outbox record, credential, or evidence.
Malformed records fail the whole page closed with a stable error and no partial
results. Core scans at most 1,000 Mission entries and reads at most 262,144
bytes per record; a limit breach is a stable closed error, never a partial page.
Listing is not a recovery mechanism for an unknown authoring create:
recover only through the original authoring operation ID.

## Commands and schemas

All four commands always emit JSON. `--json` is accepted for consistency but
does not change their output. A nonzero exit emits the closed error result.

| Operation | Command | Request schema | Success result schema |
| --- | --- | --- | --- |
| Catalog | `bin/flightdeck mission authoring-catalog --request FILE --json` | `hub/schemas/mission-authoring-catalog-request.schema.json` | `hub/schemas/mission-authoring-catalog-result.schema.json` |
| Plan | `bin/flightdeck mission authoring-plan --request FILE --json` | `hub/schemas/mission-authoring-plan-request.schema.json` | `hub/schemas/mission-authoring-plan-result.schema.json` |
| Create | `bin/flightdeck mission authoring-create --request FILE --json` | `hub/schemas/mission-authoring-create-request.schema.json` | `hub/schemas/mission-authoring-create-result.schema.json` |
| Recover | `bin/flightdeck mission authoring-operation --request FILE --json` | `hub/schemas/mission-authoring-operation-request.schema.json` | `hub/schemas/mission-authoring-operation-result.schema.json` |

All errors use
`hub/schemas/mission-authoring-error-result.schema.json`. Shared closed types
are in `hub/schemas/mission-authoring-types.schema.json`. Request files must be
regular non-symlink `.json` files no larger than 262,144 bytes. Every object
rejects unknown fields; lists are bounded; identifiers, text, and opaque values
reject control characters; and secret-like text is rejected.

## Catalog

The catalog request contains only:

```json
{"schema_version":"flightdeck.mission-authoring.catalog-request/v1"}
```

Core catalogs only configured projects whose current ignored project
verification still proves an exact normalized real-path match. Each eligible
choice is one exact combination of:

- stable logical project key;
- opaque runtime project ID;
- SHA-256 path digest, never the raw path;
- opaque host ID;
- `local` or `worktree` execution mode;
- `read_only` or `write` access mode; and
- a display-only label that is never identity.

Repository projects can expose Local and Worktree choices. Eligible
non-repository local workspace projects expose Local choices. The current v1
catalog does not expose remote projects. Ineligible projects appear only as
bounded warnings without a raw path. The opaque `target_id` names the exact
six-field choice; the client returns that complete choice in the draft, and
core requires exact equality with a current catalog entry.

## Typed draft and complete preview

A plan request contains `schema_version` plus one closed `draft`. The draft has
only:

- title and outcome;
- one to 50 unique success-criterion texts;
- one to 50 unique non-goal texts;
- Mission mode: `dispatch_only`, `watch_only`, or `supervised`;
- one to 50 selected exact catalog targets; and
- one to 50 nodes.

A node contains only its ID, selected `target_id`, required/optional boolean,
dependency IDs, accepted input types, and allowed output types. The request has
no slug, criterion ID, work type, budget, authorization boundary, resolver,
raw YAML, arbitrary JSON fragment, command, path, credential, task identity, or
operation side effect. Every selected target must be used. A dependent node
must declare at least one accepted input type. The complete graph must be
acyclic and contain at least one required node.

Core normalizes the draft, assigns the Mission ID, assigns ordered
`criterion-001` IDs, derives work type from the target's access mode, loads
budgets from `flightdeck.yaml`, derives the authorization boundary, builds all
nodes, and runs the ordinary Mission graph and whole-record validators. V1
assigns every success criterion to every required node and none to optional
nodes; the plan warns when that creates shared responsibility. Confirmation
accepts that exact mapping.

The read-only result includes the complete graph, exact authorized targets,
criteria, dependencies, non-goals, budgets, warnings, authorization boundary,
and four confirmation fields:

- `plan_id`: opaque identity derived by core from the canonical plan;
- `plan_generation`: opaque identity of the exact eligible-target catalog;
- `plan_digest`: SHA-256 of the canonical capability, catalog generation, and
  complete Mission preview; and
- `plan_token`: SHA-256 binding the three values above to that canonical plan.

Canonical JSON recursively sorts object keys, preserves array order, and uses
compact UTF-8 JSON. The digest and token detect drift but do not grant
authority. Create independently rebuilds the plan from the typed draft while
holding the authoring lock and compares all four confirmation values.

## Explicit create and recovery

Create requires the unchanged draft, an exact `confirmation` object copied
from the plan result, and a new opaque `operation_id` generated by the client.
Core rejects stale catalog state, a changed draft, a malformed or future
schema, a duplicated operation ID, the same operation ID with different
content, and any plan consumed by a created or unresolved operation. A
`not_created` operation did not consume the plan: after the operator obtains
a fresh catalog and plan, they may explicitly submit a new operation ID.

Before Mission persistence, core atomically records an unresolved operation
intent. It then builds and validates the complete Mission in memory and writes
the single `mission.yaml` atomically. The persisted Mission contains a digest
binding to the operation and exact plan, but never a client-supplied
authorization boundary. The final operation record is then marked `created`.
If graph validation or the Mission write fails, no partial Mission is retained.

The client must treat transport loss or an `unknown_outcome` error as unknown.
It must never call create again, reuse the plan with a new operation ID, search
by title, or guess from a recent-Mission list. It calls
`authoring-operation` with the original operation ID. Under a shared lock, core
reconciles the operation record, exact Mission ID, operation binding, plan
binding, and complete Mission fingerprint and returns exactly one outcome:

- `created`: the exact bound Mission exists;
- `not_created`: no Mission was persisted for the operation; or
- `unresolved`: creation is in progress, state is malformed or conflicting,
  or exact identity cannot be proven.

Recovery is observational and never repairs or rewrites either record. A
`not_created` outcome does not authorize an automatic retry; the operator must
return to catalog and plan and explicitly confirm a new operation.

## Errors and client behavior

Closed errors contain only `operation`, stable `error.code`, and a bounded
message. Important codes include `malformed_request`, `forbidden_content`,
`unsupported_version`, `future_version`, `ineligible_target`,
`stale_or_mismatched_plan`, `duplicate_operation`, `conflicting_operation`,
`consumed_plan`, `persistence_failed`, `unknown_outcome`,
`operation_store_invalid`, and `capability_incomplete`.

The safe client sequence is:

1. Require `flightdeck.command.mission-authoring.v1` for the selected Hub.
2. Load the catalog and preserve opaque runtime identities without parsing.
3. Submit one typed draft and render the complete returned plan for explicit
   user confirmation.
4. On confirmation, generate one operation ID and submit create exactly once.
5. On any ambiguous create transport/result, query only that operation ID.
6. After `created`, use existing Mission status/manage/sync surfaces according
   to their own capabilities and approval gates.

## Residual risks and limits

- Eligibility depends on the freshness and integrity of ignored exact-path
  project verification state; drift removes a target or invalidates a plan.
- Operation and Mission records are machine-local ignored state. Deletion,
  corruption, restore from backup, or concurrent out-of-band editing yields an
  unresolved result rather than repair.
- The v1 catalog supports local hosts only and does not model an external
  artifact resolver. Cross-host authoring needs a future versioned contract.
- Assigning all criteria to every required node is deliberately conservative
  and can over-constrain broad graphs; the user must inspect that mapping.
- Request-file confidentiality and cleanup belong to the desktop client. Core
  rejects credential-like content but cannot guarantee secure temporary-file
  handling outside the Hub process.
- Local source validation proves this generated-Hub implementation, not
  installed-plugin loading, existing-Hub migration, or desktop-client wiring.
