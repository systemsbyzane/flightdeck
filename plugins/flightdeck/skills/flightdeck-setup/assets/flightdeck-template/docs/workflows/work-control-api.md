# Work control API

## Boundary

`flightdeck.command.work-control.v1` is the selected-Hub command and
conversation metadata boundary. It does not execute a runtime, store a
transcript, inspect global Codex recents, or expose a runtime binding. The Hub
owns each display-safe Work ID, title, timestamp, status, normalized event, and
exact Operation association. Codex is the current private adapter; OMP is an
unavailable declared adapter and can be added later without changing these
Work envelopes.

An older Hub that does not declare this exact capability is unsupported. The
client must stop and surface the compatibility result; it must not scrape
`hub/state/work`, inspect global runtime history, infer Work from Operations,
or silently migrate the Hub.

`flightdeck.command.work-operation-lifecycle.v1` is the companion lifecycle
contract over the same WorkStore, OperationAuthoring record, and MissionStore.
It does not create a competing Operation model. It adds durable proposal state,
decline, launch recovery, exact native-only dispatch authorization, and
deduplicated receipt attachment. A client must require this companion
capability before presenting lifecycle actions or attempting managed dispatch.
The declaration does not by itself authorize a client implementation to create
runtime tasks; that owner must independently validate its dispatch boundary.

## Commands

All mutating commands run from the explicitly selected Hub. Only list accepts
an absolute root because it is the selected-Hub discovery boundary.

```text
bin/flightdeck work list --hub-root ABSOLUTE_PATH [--limit 1..100] [--cursor CURSOR] [--json]
bin/flightdeck work create --request FILE [--json]
bin/flightdeck work adapter-bind --request FILE [--json]
bin/flightdeck work open --request FILE [--json]
bin/flightdeck work coordinate --request FILE [--json]
bin/flightdeck work launch --request FILE [--json]
bin/flightdeck work decline --request FILE [--json]
bin/flightdeck work lifecycle-open --request FILE [--json]
bin/flightdeck work dispatch-plan --request FILE [--json]
bin/flightdeck work dispatch-report --request FILE [--json]
bin/flightdeck work guidance --request FILE [--json]
```

Requests must be regular non-symlink JSON files no larger than 65,536 bytes.
Every envelope is closed (`additionalProperties: false`) and uses the exact
schema identifiers in `hub/schemas/work-*.schema.json`.

## Create, list, and resume

Create accepts:

```json
{
  "schema_version": "flightdeck.work.create-request/v1",
  "request_key": "request-example-0001",
  "title_hint": "Add OIDC authentication"
}
```

The request key is only an idempotency key; the Hub hashes it before
persistence. The Hub authors `work-<24 lowercase hex>` and normalizes the title.
An empty title becomes `New Work`. Path-like, UUID-bearing, credential-like,
control-character, or oversized display text is rejected. The create result is
the ordinary-conversation handoff: the native client starts or resumes the
dedicated runtime thread immediately. Ordinary Work requires no classification
call, no recommendation, and no additional model round trip.

`work list` returns `flightdeck.work.list/v1`, sorted deterministically by
updated time and Work ID. A page contains at most 100 summaries. Its opaque
cursor is bound to the exact list generation; a changed collection returns
`stale_cursor`. `work open` accepts only one exact Hub-authored Work ID and
returns `flightdeck.work.open-result/v1` with bounded events, Operation links,
runtime availability, and resume metadata. Resume metadata contains only the
Work ID, adapter name, availability, a generation, last event ID, and optional
active Operation ID. It contains no runtime session/task/project identity or
binding secret.

Work status is closed:

```text
open | blocked | operation_proposed | operation_active |
unknown_outcome | result_ready | failed
```

## Native adapter binding

`work adapter-bind` is native-adapter-only. It binds the exact selected Hub,
Hub-authored Work ID, current public resume generation, private persistent
runtime session ID, adapter, stable binding request ID, and
`flightdeck.runtime.work-recommendation/v1` structured channel. The Hub hashes
the private runtime session ID and authors the Hub binding ID, binding ID,
adapter-session generation, and a 256-bit shared secret. The bind result and
secret must remain in the native adapter and must never cross renderer IPC.
The result echoes the exact submitted resume generation persisted for this
binding; it does not substitute a generation derived after the bind event.

An exact bind replay returns the same binding. A changed payload under the same
binding request ID fails. Rebinding requires the current resume generation and
invalidates the previous session binding. Binding state is persisted only in
ignored, bounded, mode-restricted Work state and is excluded from every
renderer-safe Work result.

After acceptance, `runtime_binding.resume_generation` is immutable for that
adapter binding and is the sole generation accepted on signed observations.
The display-safe `resume.generation` may advance as Work events are persisted;
the client must never substitute that mutable projection for the accepted
binding generation.

## Signed runtime recommendation and proposal

`work coordinate` never receives or persists a prompt, response, command,
tool payload, transcript, or chain-of-thought. It accepts only one signed
`flightdeck.runtime.work-observation/v1` from the native adapter. Assistant
prose, regex matches, titles, and ordinary responses cannot create a proposal.
The observation repeats the exact Hub binding, Work ID, binding ID, private
session ID, adapter-session generation, persisted binding resume generation, channel,
stable observation ID, type, and observed timestamp.

The signature is lowercase HMAC-SHA256 using the native-only shared secret over
UTF-8 canonical JSON of the observation with `signature` omitted. Canonical
JSON recursively sorts object keys lexicographically, preserves array order,
and contains no insignificant whitespace. Exact replay requires the same
binding, observation ID, canonical observation digest, recommendation ID, and
recommendation content. Every observation uses the immutable resume generation
accepted for that binding; unrelated Work events and display resume metadata
do not change it. Cross-Hub, cross-Work, cross-session, stale, malformed, unsigned,
or differently signed evidence fails closed.

A managed Operation recommendation may name only unique logical project keys plus a
closed access/execution mode, normalized title and work intent, success
criteria, and non-goals. The Hub resolves every logical key against the current
exact Operation-authoring catalog and selects the full target identity itself.
An unknown or unavailable key fails closed. The runtime and client cannot mint
a target or Operation ID. Prompt text alone never creates a proposal.

The result is review-only and display-safe. It includes logical keys and safe
labels, access/execution modes, `external_actions_authorized: false`, and the
server-authored Operation ID plus immutable plan ID, generation, digest, and
token. It omits paths, path digests, runtime project IDs, host IDs, task IDs,
and the private adapter binding. Proposal creation never launches or dispatches
an Operation.

## Explicit launch, decline, and recovery

`work launch` accepts only the exact Work ID, proposed Operation ID, and these
five stored confirmation fields:

```text
operation_id | plan_id | plan_generation | plan_digest | plan_token
```

The Hub reconstructs the private exact proposal from current catalog facts and
requires every stored field to match before delegating to
`flightdeck.command.operation-authoring.v1`. A stale catalog or changed payload
returns `stale_or_mismatched_plan`. A confirmed result atomically links the
exact persisted Operation to Work. Exact replay returns the existing link and
does not author a second Operation.

`work decline` accepts the same five-field confirmation. It persists
`declined`, is idempotent for the same exact proposal, and guarantees that the
producer creates neither an Operation nor a child receipt. A tampered, stale,
foreign-Work, already-launched, or launch-unknown proposal fails closed. A
declined proposal cannot later launch.

If a launch commits but its response is lost, Operation authoring keeps the
outcome unresolved. Work records `operation_launch_unknown`, remains
`unknown_outcome`, and forbids a blind resubmit. `work open` performs recovery
using only the original Operation ID. It links a recovered durable Mission
state without exposing child runtime identities. `work lifecycle-open` is the
companion restart projection: each proposal is exactly `not_started`,
`declined`, `launched`, or `launch_unknown`; actions are enabled only while
`not_started`, and the canonical active Operation link plus safe per-owner
dispatch progress survive navigation, refresh, and process restart.

## Native dispatch authorization and receipt attachment

`work dispatch-plan` is read-only execution authorization after the exact
Operation is durably launched and linked to the same Work. It re-resolves every
persisted authored node through route planning and requires exact equality for
logical project key, accepted runtime project ID, real-path digest, execution
mode, and verified repository bridge. It returns a generation and digest over
the complete target set, exact bridge handoffs, authorization boundary, and a
closed policy:

```text
strategy: parallel_independent
max_concurrency: min(target_count, 8)
requires_all_receipts: true
retry_known_failures_only: true
```

This command never starts a runtime task. An independently authorized native
owner must dispatch dependency-independent targets concurrently and preserve
the exact returned identities. It must not serialize them, silently downgrade
the request to chat, or dispatch before confirmation.

`work dispatch-report` attaches the resulting bounded receipt batch to the
same Work and authoritative Mission. It requires the exact dispatch generation
and plan digest, one stable report ID, one stable attempt key per child, and the
exact runtime project, host, and path digest from the plan. Outcomes are
`created`, `pending`, `unknown_outcome`, or `failed`. Pending reconciliation
requires both the original pending client ID and the resolved task ID. Exact
report replay is idempotent; report-ID reuse, consumed attempts, foreign or
mismatched targets, duplicate child creation, retry of running/unknown work,
and changed plan identity fail closed. Only known `failed` targets may be
retried. Before the first Mission mutation the Hub persists an `applying`
digest-only report journal. It checkpoints each accepted child in Work after
MissionStore accepts the exact receipt; an interrupted exact replay skips
matching applied children, resumes the remainder, and marks the journal
`complete`. While a journal is `applying`, every different report identity is
blocked as `unknown_outcome`. A Mission-rejected receipt terminates that journal
as `rejected` with only a safe error code, preserves earlier accepted
checkpoints, and permits a new report identity for remaining retryable targets;
exact replay of the rejected report returns the same rejection. No task or
pending identity is stored in Work. The Work projection preserves partial failure while MissionStore
remains authoritative for accepted child progress and final result state.
The client passes the canonical `active_operation.operation_id` unchanged to
`flightdeck.command.operation-projection.v1` for safe child sessions, verified
activity, progress, and output references. Final synthesis prose remains in the
same persisted Work runtime conversation; this contract supplies durable facts
and linkage, not a second transcript or renderer-generated conclusion.

## Guidance and Operation events

Guidance is never inferred from an ordinary message or from a Work association.
`work guidance` requires a separate typed request naming the exact Work ID and
its exact active Operation ID. It delegates bounded redaction, persistence,
idempotency, and terminal-state enforcement to Operation authoring. Foreign,
missing, proposed-only, or terminal Operation guidance fails closed.

Work events are ordered by `(observed_at, event_id)` and deduplicated by the
server-authored event ID. The closed types are:

```text
work_created | runtime_delegated | runtime_unavailable | runtime_disconnected |
operation_proposed | operation_launched | operation_launch_unknown |
operation_declined | operation_dispatch_started | operation_dispatch_pending |
operation_dispatch_unknown | operation_dispatch_failed |
guidance_attached | operation_progress | operation_result
```

Each event includes a closed status, observed time, optional exact Operation
ID, evidence and payload digests, and a versioned source capability/schema.
Operation progress/result links are derived only from the exact durable
Operation-authoring and Mission record. Result availability is
`in_progress | available | failed | not_created | unknown_outcome`; it is never
inferred from a title, prompt, display label, or runtime prose.

## Persistence and bounds

Ignored state lives under `hub/state/work`. Version 2 Work records add only
closed lifecycle and receipt metadata; version 1 records are normalized in
memory and are rewritten as version 2 only on an authorized mutation. Writes
use a Hub-contained lock and atomic rename. Records reject symlinks, unexpected filenames, identity/filename
mismatches, conflicting request keys, malformed timestamps, unknown fields,
and invalid restart state. Limits are 10,000 Work records, 262,144 bytes per
record, 200 persisted recommendations/events, 200 receipt reports, and 50
Operation links/targets per Work.
Open responses add at most one deduplicated derived event per Operation.

Closed error codes are defined by `work-error-result.schema.json`. Important
states include `unsupported_hub_contract`, `invalid_hub_root`,
`work_not_found`, `duplicate_request_conflict`, `unknown_target`,
`ineligible_target`, `stale_or_mismatched_plan`, `unknown_outcome`,
`operation_identity_conflict`, `proposal_declined`, `conflicting_operation`,
`terminal_operation`, `work_store_invalid`, and `stale_cursor`.
Adapter-specific states are `adapter_unavailable`,
`binding_absent`, `stale_binding`, `binding_mismatch`,
`adapter_authentication_failed`, `runtime_disconnected`, and
`unsupported_structured_channel`. Unknown internal failures return only
`internal_error`.

## OMP execution handoff

Work launch remains the only proposal confirmation boundary. It does not
silently bind the Work conversation to OMP. A native owner that supports
`flightdeck.command.omp-operation-execution.v1` may pass the exact launched
identity and `work dispatch-plan` generation to the separate
[OMP Operation execution API](omp-operation-execution-api.md). That API binds
stable Flightdeck agents to opaque OMP sessions and reports only authenticated
bounded observations. Work and Control Center read projections; they never
poll or command OMP. Older Clients must stop and plan migration rather than
fall back to plain chat or managed Codex dispatch.

Migration is preservation-first: back up ignored `hub/state/work`, Mission,
Operation-authoring, project-verification, and bridge state; compare and update
only the capability's declared managed paths plus `hub/compatibility.json`;
then validate schemas and deterministic legacy reads before enabling the client
adapter. Rollback stops use of the companion commands and restores the exact
backed-up managed files and ignored state together. Downgrading code while
leaving mutated version 2 Work records is unsupported and must fail closed.
