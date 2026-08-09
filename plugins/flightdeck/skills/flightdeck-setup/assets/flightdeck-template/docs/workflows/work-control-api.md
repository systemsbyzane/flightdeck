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

An exact bind replay returns the same binding. A changed payload under the same
binding request ID fails. Rebinding requires the current resume generation and
invalidates the previous session binding. Binding state is persisted only in
ignored, bounded, mode-restricted Work state and is excluded from every
renderer-safe Work result.

## Signed runtime recommendation and proposal

`work coordinate` never receives or persists a prompt, response, command,
tool payload, transcript, or chain-of-thought. It accepts only one signed
`flightdeck.runtime.work-observation/v1` from the native adapter. Assistant
prose, regex matches, titles, and ordinary responses cannot create a proposal.
The observation repeats the exact Hub binding, Work ID, binding ID, private
session ID, adapter-session generation, current resume generation, channel,
stable observation ID, type, and observed timestamp.

The signature is lowercase HMAC-SHA256 using the native-only shared secret over
UTF-8 canonical JSON of the observation with `signature` omitted. Canonical
JSON recursively sorts object keys lexicographically, preserves array order,
and contains no insignificant whitespace. Exact replay requires the same
binding, observation ID, canonical observation digest, recommendation ID, and
recommendation content. A new observation requires the current resume
generation. Cross-Hub, cross-Work, cross-session, stale, malformed, unsigned,
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

## Explicit launch and recovery

`work launch` accepts only the exact Work ID, proposed Operation ID, and these
five stored confirmation fields:

```text
operation_id | plan_id | plan_generation | plan_digest | plan_token
```

The Hub reconstructs the private exact proposal from current catalog facts and
requires every stored field to match before delegating to
`flightdeck.command.operation-authoring.v1`. A stale catalog or changed payload
returns `stale_or_mismatched_plan`. A confirmed result links the exact
Operation to Work. No Work command dispatches child tasks or claims success.

If a launch commits but its response is lost, Operation authoring keeps the
outcome unresolved. Work records `operation_launch_unknown`, remains
`unknown_outcome`, and forbids a blind resubmit. `work open` performs recovery
using only the original Operation ID. It links a recovered durable Mission
state without exposing child runtime identities.

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
guidance_attached | operation_progress | operation_result
```

Each event includes a closed status, observed time, optional exact Operation
ID, evidence and payload digests, and a versioned source capability/schema.
Operation progress/result links are derived only from the exact durable
Operation-authoring and Mission record. Result availability is
`in_progress | available | failed | not_created | unknown_outcome`; it is never
inferred from a title, prompt, display label, or runtime prose.

## Persistence and bounds

Ignored state lives under `hub/state/work`. Writes use a Hub-contained lock and
atomic rename. Records reject symlinks, unexpected filenames, identity/filename
mismatches, conflicting request keys, malformed timestamps, unknown fields,
and invalid restart state. Limits are 10,000 Work records, 262,144 bytes per
record, 200 persisted recommendations/events, and 50 Operation links per Work.
Open responses add at most one deduplicated derived event per Operation.

Closed error codes are defined by `work-error-result.schema.json`. Important
states include `unsupported_hub_contract`, `invalid_hub_root`,
`work_not_found`, `duplicate_request_conflict`, `unknown_target`,
`ineligible_target`, `stale_or_mismatched_plan`, `unknown_outcome`,
`operation_identity_conflict`, `terminal_operation`, `work_store_invalid`, and
`stale_cursor`. Adapter-specific states are `adapter_unavailable`,
`binding_absent`, `stale_binding`, `binding_mismatch`,
`adapter_authentication_failed`, `runtime_disconnected`, and
`unsupported_structured_channel`. Unknown internal failures return only
`internal_error`.
