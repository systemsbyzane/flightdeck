# Flightdeck Missions

A Mission is an opt-in durable parent record for one outcome that spans
multiple verified persistent Codex tasks. The Codex task where the Mission was
requested remains the control room; there is no separate Mission dashboard.

Ordinary owner dispatch remains the default and still returns a receipt and
stops. Use a Mission only when the user explicitly asks to persist, watch, or
supervise a multi-task outcome.

## Modes

- `dispatch_only` persists the graph and verified dispatch receipts, then
  stops. It performs no wait, read, follow-up, or dependency handoff.
- `watch_only` obtains compact child observations and derives status. It never
  forwards an output or advances a dependent.
- `supervised` may forward only core-materialized, schema-valid typed output
  references to a declared dependency-ready node. It does not
  expand authorization.

Choose the least powerful mode that satisfies the request. A mode change is an
explicit Mission update, not an inference from child text.
A bare Mission defaults to `dispatch_only`; natural “monitor” intent selects
`watch_only`; “coordinate end-to-end” or “take this to review-ready” selects
`supervised` unless the user sets a different boundary.

## Durable state

Each Mission is stored in ignored local state at
`hub/missions/<slug>/mission.yaml`. The record is the single source of truth for:

- title, outcome, mode, original authorization boundary, budgets, and status;
- graph nodes, required/optional edges, accepted input types, and allowed
  output-reference types;
- logical project key plus exact path or path digest;
- opaque runtime project ID, host ID, task ID or pending `clientThreadId`, and
  execution mode;
- opaque per-task cursor, dedupe key, compact state, validation result,
  approval request, and observation time;
- bounded child output declarations, core-materialized typed output references,
  and event digests; and
- outbox actions, preparation state, delivery receipts, and bounded failures.

Never persist raw child commentary or final text, credentials, artifact bodies,
private evidence, arbitrary summaries, or customer-sensitive data. Those
values are not accepted Mission control input.

## Build the graph

Create the parent, add nodes, and validate before dispatch:

```text
bin/flightdeck mission new example --title "Example" \
  --outcome "Prepare the coordinated change for review" \
  --success-criterion "Backend and frontend implementations validate" \
  --success-criterion "Integration review validates" \
  --non-goal "Do not commit, publish, deploy, or close" --mode supervised \
  --authorized-target-json \
    '{"logical_project_key":"example-backend","runtime_project_id":"project-backend","project_path_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","host_id":"local","execution_mode":"worktree","access_mode":"write"}' \
  --authorized-target-json \
    '{"logical_project_key":"example-frontend","runtime_project_id":"project-frontend","project_path_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","host_id":"local","execution_mode":"worktree","access_mode":"write"}' \
  --authorized-target-json \
    '{"logical_project_key":"example-deploy","runtime_project_id":"project-deploy","project_path_digest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","host_id":"local","execution_mode":"worktree","access_mode":"read_only"}'
bin/flightdeck mission add example backend --project-key example-backend \
  --runtime-project-id project-backend \
  --project-path-digest aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --host-id local \
  --execution-mode worktree --access-mode write --work-type implementation --required \
  --criterion-id criterion-001 \
  --allows-output contract_ref --allows-output test_ref \
  --artifact-resolver-kind same_host_workspace \
  --artifact-resolver-id example-shared-workspace
bin/flightdeck mission add example frontend --project-key example-frontend \
  --runtime-project-id project-frontend \
  --project-path-digest bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --host-id local \
  --execution-mode worktree --access-mode write --work-type implementation --required \
  --criterion-id criterion-001 \
  --allows-output test_ref \
  --artifact-resolver-kind same_host_workspace \
  --artifact-resolver-id example-shared-workspace
bin/flightdeck mission add example integration --project-key example-deploy \
  --runtime-project-id project-deploy \
  --project-path-digest cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc --host-id local \
  --execution-mode worktree --access-mode read_only --work-type review --required \
  --criterion-id criterion-002 \
  --depends-on backend --depends-on frontend --accepts contract_ref \
  --accepts test_ref --allows-output validation_ref \
  --artifact-resolver-kind same_host_workspace \
  --artifact-resolver-id example-shared-workspace
bin/flightdeck mission validate example --json
bin/flightdeck mission status example --json
```

Node IDs are stable. The graph must be acyclic and every dependency must
exist. Each node declares `read_only` or `write` access. Local write nodes for
the same exact path must be dependency-ordered; Flightdeck rejects parallel
same-checkout writers. A dependent becomes ready only after all declared
predecessors produce their declared validated outputs. Optional nodes remain visible but do
not block unrelated required fan-in unless their output is explicitly required.

Every required node declares at least one repeatable `--criterion-id`. Before
first dispatch or any action, the required nodes must collectively cover every
Mission criterion. If several required nodes share a criterion, every one must
pass it before fan-in. Every node and action carries the core-derived Mission
boundary; missing or unequal target, criterion, or boundary values fail closed.

`mission add` records routing intent; it does not create a Codex task. Use
[thread routing](thread-routing.md) for exact ownership, bridge, and project
verification.

`--success-criterion`, `--non-goal`, and `--authorized-target-json` are
repeatable. Criteria persist as ordered `{id, text}` records with core-assigned
IDs `criterion-001`, `criterion-002`, and so on. `watch_only` and `supervised`
require an explicit criterion and target. `dispatch_only` alone derives a
missing criterion from `--outcome` and assigns all criteria to a required node
when `--criterion-id` is omitted.

Each authorized target has exactly `logical_project_key`, `runtime_project_id`,
`project_path_digest`, `host_id`, `execution_mode`, and `access_mode`, obtained
from fresh exact project and route resolution. `mission add` requires the same
runtime ID and exactly one path or digest, and the resulting target must equal a
persisted target. Core sorts targets and derives `scope-<48hex>` from canonical
JSON of Mission ID, targets, criteria, and non-goals. The caller never supplies
the boundary. Core revalidates it throughout the record and action lifecycle;
the token detects equality drift but grants or proves no authority.

`mission add` is planning-only. Declare the complete graph while the Mission
and every node are `planned`, with no runtime/task/pending identity and an empty
outbox. Any exact, pending, or unknown dispatch receipt, observation, or outbox
state freezes membership and edges. If work discovers a new owner afterward,
finish only the declared phase within its original scope or stop it safely,
then propose a separate new Mission; create it only after user approval.

Do not dispatch every declared task at startup. Dispatch roots first. A
dependent remains `planned` without task identity until all dependencies are
`review_ready` with passed validation and the core emits a complete compatible
handoff. Only after preparing exactly that one matching action may the adapter create and
record the already-declared node before observation or delivery. Readiness
alone never permits a non-root dispatch.

## Dispatch and identity

The installed Mission skill is the injected Codex UI task adapter. For every
ready node it:

1. resolves the stable logical key to an exact normalized saved-project path;
2. captures the opaque runtime project ID from that match;
3. creates only ready root tasks initially; planned dependents are created just
   in time only after a prepared core handoff;
4. includes the complete verified bridge handoff and required skills; and
5. records the returned identity with `mission record-dispatch`.

Display names never establish identity. Runtime project IDs, host IDs, task
IDs, and `clientThreadId` values are opaque.

A create operation may return an immediate task ID, a pending
`clientThreadId`, or an unknown outcome. Persist that exact state. Reconcile a
pending or unknown create against the refreshed exact project task list without
blind retry; uncertainty does not authorize a duplicate task.

A `clientThreadId`-only dispatch is not waitable, observable, or syncable and
remains `dispatch_pending`. Exact reconciliation must call
`mission record-dispatch` with both `--pending-client-id ORIGINAL` and
`--task-id RESOLVED`; a task-only resubmission is rejected. Only after that
paired record is accepted may the exact task/host identity enter a wait batch.
Subsequent MissionObservation entries use the reconciled `task_id`, not the
`clientThreadId`.
When the create followed a prepared dependency action, preserve that action
unchanged alongside `dispatch_pending`. Do not call create again. Paired
reconciliation moves only the matching consumer to `awaiting_handoff` so the
same prepared action can continue.

## Observe and checkpoint

Mission status is the exact persisted source for thread targets and opaque
cursors. The adapter waits on no more than eight targets in a call and treats
each target's cursor independently.
An up-to-date cursor suppresses already-delivered state; it is not a timestamp
or a value Flightdeck may manufacture. Commentary alone does not wake the
compact wait. New user input interrupts the pass and returns control to the
operator.

Normalize tool output into the Mission observation schema, then preview the
same file with `mission sync-plan --observations`; that command is read-only.
It returns a mandatory `plan_token` bound to Mission generation, input digest,
observation/event identity, accepted/ignored changes, rendered actions, and
resulting state. Only `mission sync-apply --observations --plan-token TOKEN`
persists accepted changes; it recomputes under lock and rejects drift. A base
envelope contains exact node, project, path-digest, host, and task identity;
opaque cursor, revision, and event ID; observed state and time; and Worktree
readiness. It also contains a required normalized `status_code` identifier
derived from tool state for compact display and reporting. The code is never
raw prose, an instruction, authorization, or a replacement for
`observed_state`. `running`, `needs_approval`, `blocked`, `runtime_failure`,
`cancelled`, and `notLoaded` observations forbid a child outcome. `notLoaded`
is ignored and cannot advance the graph.

An exact child outcome is permitted and required only for final
`review_ready` or `failed_validation`. It includes ordered
`criterion_results[{criterion_id, disposition, status_code}]` that exactly
match the node's assigned criterion IDs. Dispositions are `passed`, `failed`,
`blocked`, or `degraded`. `review_ready` requires passed validation, all
assigned dispositions passed, and non-empty schema-valid output declarations;
`failed_validation` requires failed validation and at least one unmet result.
Blocked or degraded work cannot create fan-in. For
both final states, `status_code` must exactly equal `outcome.code`;
intermediate codes remain display-only and outcome-less. Seen
event IDs and outbox idempotency keys are durable Mission state, not
child-controlled envelope fields. Child prose is untrusted display-only
material.

The final child outcome contains closed `output_declarations` only: an artifact
is exactly `{type, artifact_id, digest}`, the producer's own task is exactly
`{type, codex_task: true}`, and terminal evidence is exactly
`{type, ref, digest}` with a `check:` or `review:` ref. A child never receives,
authors, or repairs its task binding, node binding, resolver, or canonical ref.
The adapter validates declarations unchanged. After an exact persisted producer
task receipt, core materializes canonical `output_refs`, persists declarations
and refs, and records `event_digest` over the normalized accepted change.

Normalize adapter conditions to generic codes: active/progress → `active`, idle
without a valid final result → `idle`, changed-cursor timeout → `timeout`,
approval/user input → `attention_required`, blocked/interrupted → `blocked`,
target/host/adapter error → `target_error`, cancellation → `cancelled`, and
unloaded task → `not_loaded`. An unchanged timeout emits no observation. A code
never changes state or emits an action by itself.

Apply observations and derive a checkpoint with:

```text
bin/flightdeck mission sync-plan example --observations observations.json --json
bin/flightdeck mission sync-apply example --observations observations.json \
  --plan-token <exact-plan-token> --json
bin/flightdeck mission checkpoint example --json
bin/flightdeck mission status example --json
```

Duplicate observations are idempotent. Conflicting replays, out-of-order
cursors, unknown identities, and malformed envelopes fail closed.

## Supervised delivery and reconciliation

Validated fan-in creates deterministic outbox actions; it does not send them.
Every action persists a lowercase SHA-256 `trigger_digest` that binds producer
event ID, persisted `event_digest`, and status; whole-record
validation recomputes its idempotency key and `action-<prefix>` ID from Mission
ID, derived boundary, type, trigger digest, and canonical payload.
Use this two-phase sequence:

```text
bin/flightdeck mission next-actions example --json
bin/flightdeck mission prepare example <action-id> --json
# The injected Codex task adapter performs the exact allowlisted action.
bin/flightdeck mission acknowledge example <action-id> --json
```

If delivery fails, record a bounded code with `mission fail`. If process state
is lost between prepare, send, and acknowledge, inspect `mission outbox` and
reconcile the exact task and dedupe key before any retry. Never infer delivery
from child prose or treat an unknown outcome as safe to resend.

Before prepare or delivery, the action boundary must still exactly equal the
producer node and Mission parent boundaries. It is a required top-level action
field, participates in the idempotency key, and is revalidated at create,
append, prepare, acknowledge, fail, and whole-record validation. Authorization
drift leaves the action undelivered and stops the pass.

For a dependency action whose consumer is still `planned`, verify the edge,
accepted types, all declared dependencies, and resolvability, then prepare the
single matching core-emitted action. Every dependency must be `review_ready`,
validation-passed, and supply at least one core-materialized automatic ref
whose type the consumer accepts, with every compatible accepted ref included.
Terminal `check:`/`review:` evidence cannot
make a dependent dispatch-eligible. Require the
action's `dependency_node_ids` to equal the complete declared parent list; its
exact payload fields are `node_id`, `dependency_node_ids`, `output_refs`, and
`artifact_resolver`. Partial or early dependency lists fail validation.
Immediately before `create_thread`, refresh the live project list and reverify
the exact normalized path, opaque runtime project, and host against the planned
route.
Create
only that already-declared task with its scope and an instruction to await
handoff, but no dependency references. Persist its exact task/runtime/host
receipt; the core records that prepared-action consumer as the internal
`awaiting_handoff` transient. Operator status projects it as `running` with
status code `handing_off`; it is not child-observed blocked work. Reconfirm dependency readiness,
budget, boundary, and resolvability, deliver the references, then acknowledge
to transition the consumer to `running`. A client-only result leaves the exact
action prepared and the consumer `dispatch_pending`; it cannot be delivered or
observed and never authorizes another create. Reconcile the original client ID
and resolved task ID to move that consumer to `awaiting_handoff`. An unknown
create also preserves the prepared action as non-actionable. Either unresolved
action may be failed explicitly; once failed it is never retried.
Genuine child `blocked` and derived `stale` states are also non-actionable.

The action type controls the adapter boundary: `observe` is bounded read-only
work; `dependency_handoff` may message only the exact prepared
`awaiting_handoff` consumer; `offer_fan_in` is presented to the operator and is
never sent to a child or treated as permission to close.

Only a `review_ready` predecessor with passed validation, every assigned
criterion passed, and non-empty machine-verifiable core-materialized references
from declarations accepted by the consumer may cross an edge. Raw text, arbitrary paths,
credentials, artifact bodies, terminal-only check/review evidence, undeclared
outputs, intermediate states, and failed/blocked/degraded criteria cannot
create a dependency handoff. Fan-in also requires full required-node criterion
coverage and hands off to the dependent at most once.

## Reference resolvability

Mission is a control plane, not an artifact data plane. A typed reference and
digest do not copy patches, binaries, documents, plans, scans, or evidence into
the consumer task. Before dispatching a consumer, prove its exact task context
can resolve each required reference through either an authorized same-host
shared workspace already accessible to both tasks or an external artifact
system whose use and any required publication are already approved. Do not
assume cross-project files or uncommitted Worktree changes are available merely
because their references validate.

Declare resolver identity with the paired `--artifact-resolver-kind` and
`--artifact-resolver-id` flags; either both are present or both absent. Kinds
are exactly `same_host_workspace` and `external_approved`, persisted as
`artifact_resolver: {kind, id}` or null. The child declares an artifact with
exactly `{type, artifact_id, digest}`; after its exact task receipt, core
constructs automatic artifact refs exactly as
`artifact:<resolver-id>/<producer-node-id>/<task-binding>/<sha256>/<artifact-id>`;
`task-binding` is unpadded base64url of the exact persisted producer task ID,
and the namespace SHA must equal the lowercase declaration digest. The child
does not know or compute the binding. Core requires canonical
producer provenance, producer/consumer resolver equality, and equal host for
`same_host_workspace`. After `{type, codex_task: true}`, core constructs the
automatic task ref exactly as
`codex-task:<producer-node-id>/<task-binding>`. `check:` and `review:` are
child-declared terminal/operator evidence only and never automated handoff
inputs.

This is provenance control, not content transport. An action carries the
consumer resolver only when its `output_refs` actually include `artifact:`;
otherwise it carries null, even when that consumer has a resolver for a later
output. `external_approved` names a previously approved path and does not
authorize publication or transfer.

When possible, co-locate compatible producing and consuming work in one
declared task before dispatch. If separation is required, including independent
review, and no authorized resolver exists, stop for an operator decision. Never
use Mission state, commit, push, upload, publication, or shared-store mutation
as an implicit transport path.

## Status precedence

Mission status is deterministic and derived from durable facts:

`planned`, `dispatch_pending`, `dispatch_unknown`, `running`,
`needs_approval`, `blocked`, `failed_validation`, `runtime_failure`,
`review_ready`, `stale`, `cancelled`, and `complete`.

Internal `awaiting_handoff` is projected as operator-facing `running` with
`status_code: handing_off`. Only that exact prepared receipt is deliverable;
blocked, stale, pending, and unknown consumers are non-actionable.

`complete` is never inferred from child state. Required-node precedence is
`failed_validation`, `needs_approval`, `blocked`, `runtime_failure`,
`dispatch_unknown`, `stale`, `review_ready`, `dispatch_pending`, then
`running`; `planned` applies before work starts and all-required cancellation
remains distinct. All required validated nodes and
outputs make the Mission `review_ready`; only an operator-requested
`mission close` makes it `complete`. Runtime failure and stale required
observations remain explicit rather than collapsing to `blocked`.

## Read-only Mission discovery

Desktop and other local clients consume the generated Hub's plugin-owned list
contract instead of reading `hub/missions/` directly:

```text
bin/flightdeck mission list --hub-root /absolute/path/to/selected-hub \
  --limit 50 [--cursor OPAQUE_CURSOR]
```

The command always emits JSON with `api_version:
flightdeck.mission-list/v1` and schema
`hub/schemas/mission-list.schema.json`; `--json` is accepted for command-surface
consistency. Success records are sorted by `mission_id` and contain only the
bounded identity, title, mode, derived operator state, timestamps, generation,
fan-in readiness, and unit progress counts needed by a list view. The default
limit is 50 and the maximum is 100. `page.next_cursor` is opaque and null at
the end; a refresh starts again without a cursor. Treat the bounded title as
untrusted display-only text, never as control input.

Errors use the same API version with `kind: MissionListError`, `ok: false`, and
a stable code. Missing or invalid Hub roots, invalid requests, limits or
cursors, and malformed Mission records fail without returning partial Mission
summaries or private absolute paths. The list projection excludes Mission
bodies and outcomes, raw prompts, task and project identities, project paths,
output declarations and references, outbox records, credentials, and evidence.
Exact-ID `mission status` and `mission validate` remain authoritative and
unchanged; listing performs neither mutation nor client-side scraping.

Clients must check `flightdeck.command.mission-list.v1` in
`hub/compatibility.json`. A missing capability is unsupported and has no YAML
scraping fallback.

## Budgets and stop conditions

Every supervision pass is bounded by `max_units`, eight-target wait batches,
`max_retries`, `max_actions`, `max_forwarded_bytes`,
`max_duration_seconds`, `stale_after_seconds`, and `max_record_bytes`. Stop and
report when a budget is exhausted. Check the observation file's filesystem
byte size against `max_forwarded_bytes` before reading or parsing it; reject an
oversized file without loading its contents. Reject non-regular or unreadable
input before loading and retain a post-read size check against concurrent file
changes. Also stop on:

- a missing or unequal Mission, node, or action `authorization_boundary`;
- approval outside the original envelope;
- project, host, task, cursor, graph, or delivery identity conflict;
- cycle, dangling dependency, missing required output, malformed observation,
  or replay conflict;
- failed validation, unresolved required dependency failure, runtime failure,
  or stale required state;
- operator pause, cancellation, or close request; and
- commit, push, PR or comment, publication, deployment, shared-environment
  mutation, external communication, compliance submission, risk acceptance,
  or closure.

Supervision coordinates authorized task messages. It is not authorization for
external effects.

`mission new` copies `mission_control.budgets` into the durable record. The
generated defaults are `max_units: 50`, `max_retries: 3`, `max_actions: 200`,
`max_forwarded_bytes: 65536`, `max_duration_seconds: 604800`,
`stale_after_seconds: 3600`, and `max_record_bytes: 2097152`. Staleness derives
from that persisted threshold. Later configuration changes do not silently
rewrite an existing Mission. Inspect the persisted values with `mission show
--json` or `mission status --json`; there are no per-command budget flags and
Mission YAML is not hand-edited.

## Recommended reference types

- Compliance: `control_assessment_ref`, `evidence_index_ref`,
  `poam_candidate_ref`, `artifact_ref`.
- Patching: `patch_ref`, `scan_ref`, `sbom_ref`, `image_digest_ref`,
  `runtime_validation_ref`.
- Development: `contract_ref`, `test_ref`, `validation_ref`.
- CI/CD: `failure_ref`, `patch_ref`, `check_ref`.
- Platform: `plan_ref`, `render_ref`, `runtime_observation_ref`.
- Research: `source_ledger_ref`, `decision_brief_ref`.
- DOCX/PDF/XLSX: `docx_ref`, `pdf_ref`, `xlsx_ref`,
  `render_inspection_ref`.
- Independent review: `review_ref`.

These are recommended identifiers, not a global enum. Every type needs a
bounded producer declaration; automated inputs also need consumer acceptance
and resolvability. A child declares artifact ID and digest for files, ledgers,
patches, plans, and deliverables, then core materializes canonical
producer-bound `artifact:` refs. A child declares `codex_task: true` for task
identity, then core materializes the `codex-task:` ref. `check:` and `review:`
may be declared as terminal
operator evidence but cannot cross an automated edge. Canonical advisory
spellings are `patch_ref`, `review_ref`,
`source_ledger_ref`, `decision_brief_ref`, `check_ref`, `plan_ref`, `docx_ref`,
`pdf_ref`, `xlsx_ref`, and `render_inspection_ref`; terminal check/review types
need no downstream consumer.

## End-to-end examples

### Review and security-scan routing

Use `$flightdeck-review` for ordinary change, readiness, and security-focused
review. The word “security” alone does not authorize a scan. Only explicit scan
intent loads applicable Codex Security; use `$codex-security:security-scan` for
a standard repository or scoped-path scan. When independence is requested,
give the review or scan a separate declared runtime task and resolvable inputs.

### Compliance

Use required nodes for the isolated program workspace and technical evidence
trace. Children declare evidence artifact IDs and digests; after exact task
receipts, core materializes the artifact-backed inputs for assessment and
deliverable building. Put independent review last in a separate persistent task
that directly consumes every materialized artifact it inspects; its declared
`review:` result is terminal operator
evidence. Submission, control-effectiveness decisions, risk acceptance, finding
closure, and Mission closure remain operator-only.

### Patching

Patch the owning image source, feed validated digest/SBOM/scan references into
every required chart or product consumer, and make runtime validation depend on
those consumers. A failed rebuilt-image scan becomes `failed_validation`.
Deployment and residual-risk acceptance require separate approval.

### Development

Default to a contract-first graph: an `api_contract` root emits `contract_ref`;
backend and frontend implementations each directly depend on it and emit
resolvable `patch_ref` plus test/validation references; integration directly
depends on the contract and every implementation. A requested independent
review directly depends on every producer whose refs it inspects, not merely
the integration node. Prototype-first ordering requires explicit user intent
and success criteria/non-goals that persist the tradeoff.

The reviewer must have a runtime task identity distinct from every producer it
reviews; this does not by itself prove personnel or organizational
independence. A continuation or second pass inside a producer task is not
independent, and co-location is not a fallback. Prove reference resolvability
before reviewer dispatch. Review readiness does not authorize commit, PR
creation, review requests, or deployment.

### CI/CD

Bind a read-only provider-diagnosis node to an exact revision and assign its
diagnosis criterion. It declares a diagnostic artifact such as
`{type: failure_ref, artifact_id: diagnostic-ledger, digest: <sha256>}`. After
the exact producer receipt, core materializes the canonical
resolver/producer/task/SHA ref. The repository fix depends on and consumes that
materialized artifact; a bare `check:` URL is
terminal operator evidence and cannot drive automated repair. Assign fix and
validation criteria and require their terminal results to pass. The diagnostic
handoff carries its resolver; a non-artifact action carries null. Pipeline
rerun, cancellation, publication, promotion, and deployment remain separate.

### Platform

Keep IaC or manifest source, generated plan, applied state, and runtime
observation in separate nodes. Children declare only artifact IDs and digests;
core materializes canonical refs from their persisted receipts and resolver
identity. A review may consume those materialized plan and observation refs.
Blocked or stale producers stop the handoff. Apply, restart, secret rotation,
failover, restore, and data mutation stay approval-gated in the exact
environment.

### Research

Assign each independent source track explicit freshness, accessibility, and
coverage criteria. The child declares its dated `source_ledger_ref` artifact ID
and digest, and core materializes canonical producer provenance; synthesis
consumes it only after every required assignment
passes. Missing, stale, or inaccessible primary sources produce `blocked` or
`degraded` under `failed_validation`, preventing automated synthesis. A
`review:` citation or prose confidence statement is terminal operator evidence,
not a machine handoff. Mission never invents unavailable evidence.

### DOCX, PDF, and XLSX building

Fan core-materialized artifact-backed source references into the appropriate installed
artifact capability, then require render-and-inspect validation. If independent
review is required, make it the final separate task with direct artifact inputs
and keep its declared `review:` result terminal. Persist declarations plus
materialized deliverable and QA references only. Packaging, publication,
delivery, or compliance submission remains
external and separately authorized.

## Compatibility and upgrade

The Mission command surface belongs to generated-Hub template `1.1.0`. Existing
Hubs are never automatically migrated. Before Mission work, the installed skill
checks `hub/compatibility.json` for the Mission command and document
capabilities.

The neutral typed desktop-client authoring surface first appears in template
`1.2.0` as exactly `flightdeck.command.mission-authoring.v1`. Its catalog,
preview, confirmed create, and recovery contract is documented in
[Mission authoring API](mission-authoring-api.md). Older Hubs remain selectable
but diagnosably unsupported for that capability; existing Mission commands do
not imply authoring support.

If a command capability is missing, stop and return the checker's exact managed
plan-and-diff scope. Do not run setup, overwrite the Hub, touch ignored state,
or silently turn the request into direct dispatch. The bundled Mission
reference may explain the contract when this document is missing, but it is not
a behavioral fallback for missing commands.
