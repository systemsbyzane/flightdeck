# Hub-first application contract

## Decision

A Flightdeck application connects to exactly one selected Hub. The Hub is the
only source for its visible projects, coordination destination, Mission work,
and capability declaration. Repository checkouts, a Codex project list, and
cached runtime state are proof sources; none independently define application
membership.

Codex remains the declared ordinary-conversation runtime. Confirmed Operation
execution is a separate runtime-neutral boundary: OMP is the selected available
adapter, while Codex app-server is declared unavailable until independently
implemented and validated.

## Contract

`bin/flightdeck hub snapshot --hub-root ABSOLUTE_PATH --json` implements
`flightdeck.command.hub-snapshot.v1` and returns
`hub/schemas/hub-snapshot.schema.json`. A client must require both the exact
capability and schema before using the response.

The success projection contains only:

- Hub display name, template version, and Doctor capability.
- Logical project key, safe display label, workload, availability, bridge
  health, destination kind, and routing capability.
- Runtime capability metadata: Codex handles conversation; Operation execution
  declares an exact selected adapter and renderer-safe availability/configuration
  metadata for OMP and Codex app-server.

It never contains a local path, runtime project UUID, local registry detail,
bridge handoff, bridge digest, repository locator, native adapter authorization,
or task identity. A Hub
coordinator is `destination: hub_coordinator`; a repository is only
`destination: repository_routing_hint`. A client routes repository work through
the Hub and must not treat that hint as a direct runtime destination.

## Deterministic reconciliation and failure handling

The canonical list is exactly one configured coordination project followed by
the durable records in `hub/repositories.yaml`, ordered by logical project key.
`hub/state/repositories.yaml` supplies the local checkout and bridge proof;
`hub/state/projects.yaml` supplies the exact-path project verification. Neither
local file may add a project absent from the durable declaration. This means a
locally registered project is intentionally invisible until it has a matching
Hub declaration.

Every listed project must have an exact live-list verification. Repository
members must also have an installed, verified bridge. A missing verification,
path conflict, unavailable checkout, bridge drift, malformed registry, or
missing capability returns a typed error and no project list. Clients must not
retain or synthesize stale projects from a failed result.

Mission commands and their status semantics are unchanged. This snapshot is a
separate additive discovery surface; it does not read or mutate Mission state.

## Operations snapshot contract

`bin/flightdeck hub operations-snapshot --hub-root ABSOLUTE_PATH --json`
implements `flightdeck.command.operations-snapshot.v1` and returns
`flightdeck.operations-snapshot/v1` under
`hub/schemas/operations-snapshot.schema.json`. A client must require the exact
capability and schema before presenting a Control Center or Operations view.

The projection enumerates only currently durable `hub/missions/*/mission.yaml`
and `hub/tasks/*/task.yaml` records. It never reads Codex global recent tasks,
project recents, prompts, commentary, or a task list outside the selected Hub.

Clients that open Operation detail must additionally require
`flightdeck.command.operations-snapshot-detail-identity.v1`. The snapshot
`operation_id` remains the typed `mission:` or `task:` source identity. Its
closed `detail` value is either `unavailable` or contains the exact canonical
`operation-<24 lowercase hex>` identity copied from a persisted
Operation-authoring record. The producer validates that record's Mission
identity, authoring binding, and immutable fingerprint before exposing it. It
never derives detail identity from the source ID, title, list position,
renderer input, or any runtime/project/task identifier.

Any malformed, duplicate, foreign, or mismatched authoring identity, unsafe
filesystem entry, invalid capability, or invalid Hub closes the response with
a typed error and no partial operation list.

Clients that open Operation detail must additionally require
`flightdeck.command.operations-snapshot-detail-identity.v1`. The snapshot
`operation_id` remains the typed `mission:` or `task:` source identity. Its
closed `detail` value is either `unavailable` or contains the exact canonical
`operation-<24 lowercase hex>` identity copied from a persisted
Operation-authoring record. The producer validates that record's Mission
identity, authoring binding, and immutable fingerprint before exposing it. It
never derives detail identity from the source ID, title, list position,
renderer input, or any runtime/project/task identifier.

The status vocabulary is closed: `queued`, `working`, `waiting`,
`approval_required`, `blocked`, `review_ready`, `failed_validation`,
`cancelled`, and `reconcile_required`. Lifecycle mappings are deterministic:
planning/intake states map to `queued`; active execution and validation map to
`working`; integration and handoff states map to `waiting`; explicit approval,
block, validation-failure, and cancellation states retain their corresponding
status; and dispatch uncertainty, stale state, rollback, or an unknown state
map to `reconcile_required`. A pending structured task approval or failed
structured check takes precedence over its task lifecycle state. Free-form
agent text never changes a status.

Operation children exist only for durable Mission nodes or durable task units
that name a logical project key. Their display label and role name are derived
only from the declared repository/project and verified workload. When neither
is known, the deterministic fallback is `Hub Agent — <label>`; the projection
does not invent responsibility, skill, or persona names. Skills are always
`{state: unavailable, items: []}` until a future authenticated, task-bound Hub
telemetry producer persists an invocation observation. Output declarations and
validation fields appear only when a Mission record contains the corresponding
typed durable observation.

Malformed, duplicate, foreign, or mismatched authoring identities, unsafe
filesystem entries, invalid capabilities, and record count overflow fail
closed with a typed error and no partial operation list.
The schema excludes paths, runtime project/task/host IDs, bridge handoffs,
prompts, raw protocol errors, evidence bodies, secrets, and customer data.

## Work to Operation lifecycle

The selected Hub may declare
`flightdeck.command.work-operation-lifecycle.v1` in addition to Work control.
The companion contract persists a typed `not_started` Operation proposal in the
originating Work, requires the exact immutable confirmation for either launch
or decline, and projects the canonical active Operation and safe child progress
after restart. Decline creates no Operation or receipt. Launch is idempotent and
authors exactly one durable Operation before dispatch can be authorized.

The producer's `dispatch-plan` is a native-only exact route, runtime-binding,
path-digest, authorization, and verified-bridge envelope with a required
parallel-independent policy. It does not dispatch. The separately authorized
native owner reports exact created, pending, unknown, or failed receipts back
through `dispatch-report`; the Hub rejects stale generations, foreign identity,
duplicate children, and unsafe retry. A client that has not independently
validated managed dispatch must remain fail-closed even when this producer
capability is available.

## Migration and rollback

1. Upgrade the Hub and confirm the compatibility manifest declares
   `flightdeck.command.hub-snapshot.v1` plus `runtime_capabilities`.
2. Add every application-visible repository to `hub/repositories.yaml`, then
   register its checkout and record an exact-path verification. Local-only
   registrations remain excluded by design.
3. Install and verify each repository bridge, then run the snapshot command.
   Migrate clients only after the returned project list is complete and valid.
4. During rollout, clients that do not find the capability keep their existing
   compatibility behavior and do not infer snapshot support.

Rollback is additive: clients stop calling the new command and continue their
prior command paths. Do not delete project verification or bridge state as a
rollback shortcut; correct the declaration or local proof and retry. An
unavailable or unsupported Operation adapter always fails closed.
