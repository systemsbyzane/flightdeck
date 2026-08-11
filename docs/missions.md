# Flightdeck Missions

## What is a mission?

A Mission is an opt-in, durable parent record for one outcome that spans several
verified persistent Codex tasks. It records the dependency graph, exact task
identities, compact observations, bounded child output declarations,
core-materialized typed output references, delivery receipts, and derived
status under one bounded authorization envelope.

A Mission is not a new dashboard, a background agent, or a replacement for a
Codex task. The Codex task where the Mission starts remains the control room.
Each child task remains visible and independently owned by its exact saved Codex
project.

Ordinary Flightdeck dispatch is unchanged: resolve one owner, create or resume
its task, return the receipt, and stop. A Mission exists only when the user asks
Flightdeck to coordinate an outcome as a mission, watch it, or supervise a
declared dependency graph.

## What's new?

Missions add a durable coordination layer without making child tasks less
independent:

- three explicit modes: `dispatch_only`, `watch_only`, and `supervised`;
- a directed acyclic graph with required or optional nodes;
- exact logical project, opaque runtime project, host, path, and task identity;
- bounded compact waits in batches of at most eight targets, using opaque
  per-thread cursors;
- normalized observation envelopes instead of persisted child prose;
- bounded child output declarations plus core-materialized,
  machine-verifiable producer-bound references for controlled fan-in;
- a two-phase outbox with delivery reconciliation;
- deterministic status precedence and explicit stop conditions; and
- operator-only closure: child success can make a Mission `review_ready`, but
  only `mission close` can make it `complete`.

Mission state is ignored local Hub state under
`hub/missions/<mission>/mission.yaml`. It must never contain credentials,
private evidence, raw child commentary or final text, arbitrary summaries, or
customer-sensitive material.

## Direct dispatch or Mission?

| Need | Use | Runtime behavior |
| --- | --- | --- |
| One repository owner or one bounded handoff | Direct dispatch | Return the verified receipt and stop |
| Persist a multi-task graph but do not observe it | Mission `dispatch_only` | Record graph and dispatch receipts, then stop |
| Refresh compact child state without sending follow-ups | Mission `watch_only` | Wait, normalize, checkpoint, report, then stop |
| Advance declared dependencies from validated outputs | Mission `supervised` | Observe, checkpoint, deliver allowlisted actions, reconcile, then stop |

Choose the least powerful mode that satisfies the outcome. Supervision does not
grant permission to commit, publish, deploy, submit, accept risk, or close.
A bare Mission request defaults to `dispatch_only`; natural “monitor” intent
selects `watch_only`; “coordinate end-to-end” or “take this to review-ready”
selects `supervised` unless the user sets a different boundary.

## Run a mission

Generated-Hub template `1.2.0` adds two independent neutral desktop-client
capabilities: `flightdeck.command.mission-list.v1` for bounded read-only
discovery and `flightdeck.command.mission-authoring.v1` for closed JSON catalog,
complete preview, explicitly confirmed atomic create, and read-only operation
recovery without exposing Mission YAML or generic command execution. Older Hubs
remain selectable but unsupported for either missing capability; they are never
regenerated or migrated automatically. The exact client contract lives in the generated template's
[Mission authoring API](../plugins/flightdeck/skills/flightdeck-setup/assets/flightdeck-template/docs/workflows/mission-authoring-api.md).

In a fresh Codex task with a Mission-capable Hub, ask naturally:

```text
Run this as a supervised Flightdeck mission. Coordinate the API, web, and chart
owners through review-ready, but do not commit, open a PR, deploy, or close the
mission without asking me.
```

The installed mission skill uses the generated Hub's explicit commands. The
operator-facing sequence is:

```text
bin/flightdeck mission new example-release --title "Example release" \
  --outcome "Prepare the coordinated change for review" \
  --success-criterion "API and web implementations validate" \
  --success-criterion "Integration review validates" \
  --non-goal "Do not commit, publish, deploy, or close" --mode supervised \
  --authorized-target-json \
    '{"logical_project_key":"example-api","runtime_project_id":"project-api","project_path_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","host_id":"local","execution_mode":"worktree","access_mode":"write"}' \
  --authorized-target-json \
    '{"logical_project_key":"example-web","runtime_project_id":"project-web","project_path_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","host_id":"local","execution_mode":"worktree","access_mode":"write"}' \
  --authorized-target-json \
    '{"logical_project_key":"example-deployments","runtime_project_id":"project-deployments","project_path_digest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","host_id":"local","execution_mode":"worktree","access_mode":"read_only"}'
bin/flightdeck mission add example-release api --project-key example-api \
  --runtime-project-id project-api \
  --project-path-digest aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --host-id local --execution-mode worktree \
  --access-mode write --work-type implementation --required \
  --criterion-id criterion-001 \
  --allows-output contract_ref --allows-output test_ref \
  --artifact-resolver-kind same_host_workspace \
  --artifact-resolver-id example-release-workspace
bin/flightdeck mission add example-release web --project-key example-web \
  --runtime-project-id project-web \
  --project-path-digest bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --host-id local --execution-mode worktree \
  --access-mode write --work-type implementation --required \
  --criterion-id criterion-001 \
  --allows-output test_ref \
  --artifact-resolver-kind same_host_workspace \
  --artifact-resolver-id example-release-workspace
bin/flightdeck mission add example-release integration \
  --project-key example-deployments --runtime-project-id project-deployments \
  --project-path-digest cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  --host-id local --execution-mode worktree --access-mode read_only \
  --work-type review --required --criterion-id criterion-002 \
  --depends-on api --depends-on web --accepts contract_ref \
  --accepts test_ref --allows-output validation_ref \
  --artifact-resolver-kind same_host_workspace \
  --artifact-resolver-id example-release-workspace
bin/flightdeck mission validate example-release
bin/flightdeck mission status example-release --json
```

`mission add` defines graph nodes; it does not create Codex tasks. The installed
skill resolves every exact project, creates only root tasks initially, and later
creates a declared dependent just in time from a prepared core handoff. It then
records each verified receipt with `mission record-dispatch`. A create call
may return an immediate task ID or only a pending `clientThreadId`. Pending and
unknown create outcomes remain explicit until a later exact-list reconciliation
proves the persistent task identity. A `clientThreadId`-only node is not
waitable, observable, or syncable and remains `dispatch_pending`.
If it came from a prepared dependency action, the action remains prepared and
bound to that consumer while the pending receipt is reconciled. Do not prepare
another action, call `create_thread` again, or infer that no task was created.
Reconciliation must call `mission record-dispatch` with both
`--pending-client-id ORIGINAL` and `--task-id RESOLVED`; a task-only resubmission
is rejected. Only then may the exact task/host pair enter a wait batch. Later
MissionObservation entries identify that reconciled node by `task_id`, not by
`clientThreadId`.
Flightdeck must not issue a duplicate create merely because the first result
was uncertain.

`--success-criterion`, `--non-goal`, and `--authorized-target-json` are
repeatable. MissionRecord assigns criteria deterministic ordered IDs
`criterion-001`, `criterion-002`, and so on, and stores unique bounded
`{id, text}` criteria plus bounded non-goals. `watch_only` and `supervised`
require at least one explicit criterion and target. For `dispatch_only` only,
omission derives one criterion from `--outcome`; a required node with no
`--criterion-id` is assigned all criteria for compatibility.

Each authorized-target JSON object has exactly six fields:
`logical_project_key`, `runtime_project_id`, `project_path_digest`, `host_id`,
`execution_mode`, and `access_mode`. The skill obtains them from a fresh exact
project/route resolution before creation. The core normalizes and sorts the
targets, then derives `authorization_boundary` as `scope-` plus the first 48
lowercase hex characters of the SHA-256 of canonical JSON containing
`mission_id`, `authorized_targets`, `success_criteria`, and `non_goals`. There
is no caller-supplied boundary flag. `mission add` requires
`--runtime-project-id` and exactly one of `--project-path` or
`--project-path-digest`; its six target values must exactly match one persisted
authorized target. The derived token is revalidated on every node and action.
It detects scope drift but grants, expands, or proves no authority.

For observation, the skill reads the exact persisted targets and cursors from
Mission status, waits on no more than eight targets per call, and builds a
compact normalized observation file. `mission sync-plan --observations`
returns a mandatory `plan_token` bound to the Mission generation, input digest,
observation hashes and event IDs, accepted/ignored changes, rendered actions,
and resulting state. Only `mission sync-apply --observations --plan-token
TOKEN` persists it. Apply recomputes the token while holding the Mission lock
and fails closed on generation, input, or action drift. The skill then
checkpoints derived state. In supervised mode, pending
allowlisted actions are exposed through `mission next-actions`, prepared before
delivery, and acknowledged only after the Codex task operation returns a
verified receipt. A failed or ambiguous delivery stays reconcilable; it is not
silently retried as a new action.

Each target keeps its opaque cursor. Already-delivered state is suppressed,
commentary alone does not wake the compact wait, and new user input interrupts
the pass so control returns immediately to the operator.

Useful read-only commands include:

```text
bin/flightdeck mission list --hub-root /absolute/path/to/selected-hub --limit 50
bin/flightdeck mission show example-release --json
bin/flightdeck mission validate example-release --json
bin/flightdeck mission status example-release --json
bin/flightdeck mission sync-plan example-release --observations observations.json --json
bin/flightdeck mission sync-apply example-release --observations observations.json \
  --plan-token <exact-plan-token> --json
bin/flightdeck mission outbox example-release --json
```

### Desktop discovery contract

`mission list` is the plugin-owned read boundary for a desktop list view. It
requires an explicit absolute Hub root, emits only
`flightdeck.mission-list/v1` JSON, sorts summaries by stable Mission ID, and
uses an opaque cursor with a default limit of 50 and a maximum of 100. Success
records contain Mission ID, bounded title, mode, derived state, timestamps,
generation, fan-in readiness, and unit progress counts. They do not contain
Mission bodies or outcomes, raw prompts, task or project IDs, project paths,
output declarations or references, outbox records, credentials, or evidence.
The title remains untrusted display-only text and must never drive client
actions.

Missing or invalid roots, invalid requests, bounds or cursors, and malformed
Mission records return `MissionListError` with a stable code and no partial
results or private path. Clients must require
`flightdeck.command.mission-list.v1`; they must not scrape ignored Mission
YAML or assume support from the Hub template version. Exact-ID `mission status`
and `mission validate` behavior is unchanged.

## Graph and identity contract

Every node has a stable node ID, one verified authorized target, zero or more
declared dependencies, a required/optional designation, repeatable assigned
`--criterion-id` values, accepted input types, allowed output-reference types,
and the core-derived `authorization_boundary`. Every required node must be
assigned at least one criterion. Before the first dispatch or any action, every
criterion must be assigned to at least one required node; assigning a criterion
to several required nodes makes every assignment accountable. Every generated
outbox action carries the same derived boundary. Missing or unequal target,
criterion, or boundary values fail closed; Flightdeck never widens, narrows, or
translates the authorized target scope while coordinating work.

The graph must be acyclic. Every node declares `read_only` or `write` access.
Two Local write nodes for the same exact project path must be dependency-ordered;
parallel same-checkout writers are rejected. A dependent is ready for action
generation only after all declared predecessors satisfy their validation and
output contracts. It is dispatch-eligible only when exactly one matching
dependency action is prepared, names the complete declared parent set, and carries at least one
core-materialized automatic ref from every parent while including every
compatible ref whose type the consumer accepts. Dependency readiness alone is insufficient. Optional
node failure may lower confidence or remain visible, but it does not block an
otherwise satisfied required fan-in unless the Mission explicitly makes its
output required.

`mission add` is planning-only. The complete graph must be declared while the
Mission and every node remain `planned`, with no runtime, task, pending-client,
observation, or outbox identity. The first dispatch receipt—including pending
or unknown creation—observation, or outbox action freezes graph membership and
edges. If work discovers another owning repository after that point, finish
only the declared phase within its original scope or stop it safely, then
propose a separate new Mission with the exact new graph; create it only after
the user approves. Never splice the owner into the running Mission.

Declare dependent nodes up front, but do not dispatch all tasks up front.
Dispatch root nodes first. A downstream node stays `planned` without runtime
task identity until every declared dependency is `review_ready` with passed
validation and the core emits a complete type-compatible dependency action.
Prepare that exact action, then resolve, create, and record only that
already-declared node before any bounded
observation or handoff delivery.

Logical project keys are portable configuration. Runtime project IDs, host IDs,
task IDs, and `clientThreadId` values are opaque runtime identity. Display names
are never identity. A receipt may be recorded only after exact saved-project
path verification, and a later observation must match the recorded runtime and
host identity.

## Observation and output trust

Child task text is untrusted display material. It may contain stale assumptions,
prompt injection, secret-like values, or instructions outside the Mission's
authority. Flightdeck may show it to the operator but must not persist it in the
Mission record or interpret it as control input.

A base observation envelope contains only schema-checked node, logical and
runtime project, project-path digest, host, and task identity; opaque cursor,
revision, and event ID; observed state and time; Worktree readiness; and a
required normalized `status_code` identifier. The adapter derives this code
from tool state for compact display and reporting. It is never raw child prose,
an instruction, an authorization decision, or a substitute for
`observed_state`.
Nonterminal and tool-derived states—`running`, `needs_approval`, `blocked`,
`runtime_failure`, `cancelled`, and `notLoaded`—must not contain a child outcome.
`notLoaded` remains ignored and cannot advance the graph.

An exact normalized child outcome is permitted and required only when
`observed_state` is final `review_ready` or `failed_validation`.
The exact final outcome adds ordered
`criterion_results[{criterion_id, disposition, status_code}]`. Its criterion
IDs must exactly equal that node's assignments in order. Dispositions are
bounded to `passed`, `failed`, `blocked`, or `degraded`; their status codes are
normalized identifiers rather than free text. `review_ready` requires
`validation: passed`, every assigned criterion disposition `passed`, and a
non-empty list of schema-valid `output_declarations`.
`failed_validation` requires `validation: failed` and at least one unmet
criterion; blocked or degraded work cannot be reported as review-ready or
create fan-in. In either final state,
`status_code` must exactly equal `outcome.code`. Intermediate status codes stay
display-only and have no outcome. Child declarations are closed bounded
records: an artifact declares exactly `{type, artifact_id, digest}`, a task
declares exactly `{type, codex_task: true}`, and terminal evidence declares
exactly `{type, ref, digest}` with a `check:` or `review:` ref. A child never
supplies, repairs, or bootstraps its task identity, producer binding, resolver,
or a canonical `artifact:` or `codex-task:` ref.

After validating the exact persisted producer task receipt, the core
materializes canonical `output_refs`, persists both the declarations and refs,
and persists `event_digest` over the normalized accepted change. A transported
artifact ref additionally requires the producer's persisted resolver. The
Mission stores seen event IDs separately, and deterministic outbox actions bind
the producer event ID, event digest, and status in their trigger digest. Types
and consumer dependencies must be declared before supervision begins.

Normalize adapter conditions to generic identifiers: active/progress →
`active`; idle without a valid final result → `idle`; changed-cursor timeout →
`timeout`; approval/user input → `attention_required`; blocked/interrupted →
`blocked`; target/host/adapter error → `target_error`; cancellation →
`cancelled`; and unloaded task → `not_loaded`. An unchanged timeout emits no
observation. A code never changes state or emits an action by itself.

Only a `review_ready` predecessor with passed validation, all assigned criteria
passed, and non-empty core-materialized typed references from producer
declarations accepted by the consumer may cross an automated edge. The Mission reaches fan-in only when all
criteria are covered by required nodes and every required assignment passes.
Free text, arbitrary paths, credentials, raw evidence, undeclared outputs,
intermediate tool state, failed validation, and `blocked` or `degraded`
criterion results cannot create a dependency handoff.

## References are not artifact transport

Mission is a control plane, not a data plane. A typed reference and digest
prove bounded identity and integrity; they do not copy a patch, binary,
document, scan, plan, or evidence body into another task. Before dispatching a
consumer, prove that its exact task context can resolve every required
reference through either an authorized same-host shared workspace already
accessible to both tasks or an external artifact system whose use and any
required publication are already approved. Do not assume a local Worktree
path, another project's filesystem, or `codex-task:` text is readable by the
consumer merely because a reference validates.

Persist the resolver on each relevant node with the paired
`--artifact-resolver-kind` and `--artifact-resolver-id` flags; providing only
one is invalid. Kinds are exactly `same_host_workspace` and
`external_approved`. The durable node value is either
`artifact_resolver: {kind, id}` or null. After a child declares
`{type, artifact_id, digest}`, the core constructs an automatically transported
artifact reference exactly as
`artifact:<resolver-id>/<producer-node-id>/<task-binding>/<sha256>/<artifact-id>`,
where `task-binding` is the unpadded base64url encoding of the producer's exact
persisted task ID and the namespace SHA equals the declaration's lowercase
`digest`. The child does not receive or compute that binding. The core verifies
producer provenance, exact producer/consumer resolver equality, and equal host
identity for `same_host_workspace`.

After `{type, codex_task: true}`, the core constructs an automatically
transported task reference exactly as
`codex-task:<producer-node-id>/<task-binding>`. `check:` and `review:`
declarations are terminal/operator evidence only; they never enter automated
dependency handoff. This
is provenance control over which producer-bound references may cross a node
boundary, not artifact content transport. The action payload carries the
consumer's resolver only when that action actually transports an `artifact:`
reference; it is null for a `codex-task:`-only action even if the consumer has a
resolver for artifacts it will produce later. `external_approved` names an
already-approved external system and grants no publication or transfer.

If resolvability is absent, co-locate compatible producer and consumer work in
one declared task before dispatch. If separation is required—especially for an
independent review—or co-location would violate ownership, access, or
same-checkout writer rules, stop and request an operator decision. Do not use a
commit, push, upload, publication, shared-store mutation, or raw Mission payload
as an undeclared transport workaround.

## Outbox and reconciliation

Supervised delivery is plan-token-bound and two phase:

1. `sync-plan` renders observations and actions plus a generation-bound token;
   `sync-apply --plan-token` verifies that exact token, persists accepted
   observations, and enqueues deterministic actions. Each action persists a
   lowercase SHA-256 `trigger_digest`. Whole-record validation recomputes its
   `idempotency_key` and `action-<prefix>` ID from Mission ID, derived boundary,
   type, trigger digest, and canonical payload.
2. `mission prepare` marks the exact action for one adapter attempt.
3. The adapter performs the allowlisted action: bounded observation is
   read-only; `dependency_handoff` may message only the exact prepared
   consumer; `offer_fan_in` is shown only to the operator.
4. `mission acknowledge` records the returned delivery receipt, or `mission
   fail` records a bounded failure code.

For a dependency action targeting a still-`planned` consumer, verify the edge,
accepted types, and reference resolvability, then prepare the emitted action.
Every declared dependency—not merely the one that changed—must be
`review_ready`, validation-passed, and supply at least one accepted automatic
reference, with all compatible accepted refs included. Terminal
`check:`/`review:` refs do not qualify.
The emitted action payload contains exactly `node_id`, the complete declared
parent list in `dependency_node_ids`, `output_refs`, and `artifact_resolver`;
partial or early dependency lists fail validation.
Immediately before `create_thread`, refresh the live project list, resolve the
consumer's exact normalized path again, and verify the opaque runtime project
and host identity still match the planned route; stop on drift.
Create only that already-declared task with its scope and an instruction to
await handoff; do not put dependency references in the creation prompt. Record
the exact task/runtime/host receipt; while the prepared dependency action waits,
the core records the internal transient `awaiting_handoff`. Operator status
projects that transient as `running` with status code `handing_off`; it is not a
child-observed `blocked` state. Reconfirm dependency readiness, authorization,
budget, and resolvability, deliver the core-rendered references, and only then
acknowledge the action, which transitions the consumer to `running`. A
client-only result preserves the same prepared action and records the consumer
as `dispatch_pending`. It is non-deliverable and non-observable, but it never
authorizes another create; reconcile the original client ID together with the
resolved task ID, which moves only that consumer to `awaiting_handoff`. An
unknown create remains `dispatch_unknown` with the prepared action preserved.
Neither state can be delivered or acknowledged. Either unresolved action may
be failed explicitly; once failed it remains non-actionable and is never
retried. Genuine child `blocked` and
derived `stale` states are also non-actionable stops. Mission supervision never
prepares or delivers to them.

Before an action may be prepared or delivered, its `authorization_boundary`
must still exactly equal both the producer node and Mission parent values. The
boundary is a required top-level action field, participates in the idempotency
key, and is revalidated when the action is created, appended, prepared,
acknowledged, failed, and checked as part of the full Mission record. Any
authorization drift leaves the action undelivered and stops the pass.

If the process stops between any two steps, `mission outbox`, task-list
reconciliation, and the action's dedupe key establish what is known. Flightdeck
never converts an unknown outcome into success and never treats a second send
as safe without reconciliation.

## Status, budgets, and stop conditions

Mission status is derived deterministically from durable facts. `complete` is
reserved for explicit operator closure. Before closure, required-node
precedence is `failed_validation`, `needs_approval`, `blocked`,
`runtime_failure`, `dispatch_unknown`, `stale`, `review_ready`,
`dispatch_pending`, then `running`; `planned` applies before work starts and
all-required cancellation remains distinct. The operator-facing status
vocabulary is:

`planned`, `dispatch_pending`, `dispatch_unknown`, `running`,
`needs_approval`, `blocked`, `failed_validation`, `runtime_failure`,
`review_ready`, `stale`, `cancelled`, and `complete`.

The stored internal `awaiting_handoff` transient is intentionally absent from
that vocabulary: `mission status` renders it as `running` with
`status_code: handing_off`. Only that exact prepared receipt may receive a
dependency delivery. `blocked`, `stale`, `dispatch_pending`, and
`dispatch_unknown` remain non-actionable.

Each observation run is bounded by `max_units`, eight-target wait batches,
`max_retries`, `max_actions`, `max_forwarded_bytes`,
`max_duration_seconds`, `stale_after_seconds`, and `max_record_bytes`. The
installed adapter checks the observation file's filesystem byte size against
`max_forwarded_bytes` before reading or parsing it; an oversized file is
rejected without loading its contents. Non-regular and unreadable inputs are
also rejected before loading, and a post-read size check protects against a
file changing during the operation. It must report the exhausted budget and
stop. It also stops on:

- any missing or unequal Mission, node, or action `authorization_boundary`;
- any approval request or action outside the original envelope;
- unknown or conflicting project, host, task, cursor, or delivery identity;
- malformed, replay-conflicting, or out-of-order observations;
- graph drift, cycles, dangling dependencies, or missing required outputs;
- failed validation, unresolved required dependency failure, or stale required
  state;
- an external action such as commit, push, PR/comment, publication, deployment,
  shared-environment mutation, external communication, compliance submission,
  risk acceptance, or closure; and
- an operator pause, cancellation, or close request.

`mission new` copies the current `mission_control.budgets` configuration into
the durable Mission record. The generated defaults are:

| Persisted budget | Default |
| --- | ---: |
| `max_units` | 50 |
| `max_retries` | 3 |
| `max_actions` | 200 |
| `max_forwarded_bytes` | 65,536 |
| `max_duration_seconds` | 604,800 |
| `stale_after_seconds` | 3,600 |
| `max_record_bytes` | 2,097,152 |

Status and checkpoint derive staleness from the persisted 3,600-second default
unless the generated Hub configuration intentionally supplied another positive
value before Mission creation. Later configuration edits do not silently
rewrite an existing Mission's persisted limits. Inspect them with `mission show
--json` or `mission status --json`; there are no per-command budget flags and
Mission YAML is not hand-edited.

## Recommended reference types

Reference types remain graph-declared rather than a global enum. These domain
examples are recommended when their meaning fits:

| Domain | Recommended types |
| --- | --- |
| Compliance | `control_assessment_ref`, `evidence_index_ref`, `poam_candidate_ref`, `artifact_ref` |
| Patching | `patch_ref`, `scan_ref`, `sbom_ref`, `image_digest_ref`, `runtime_validation_ref` |
| Development | `contract_ref`, `test_ref`, `validation_ref` |
| CI/CD | `failure_ref`, `patch_ref`, `check_ref` |
| Platform | `plan_ref`, `render_ref`, `runtime_observation_ref` |
| Research | `source_ledger_ref`, `decision_brief_ref` |
| DOCX/PDF/XLSX | `docx_ref`, `pdf_ref`, `xlsx_ref`, `render_inspection_ref` |
| Independent review | `review_ref` |

Each type requires a bounded producer declaration. Automated inputs also
require consumer acceptance and proven resolvability. For files, ledgers,
patches, plans, and deliverables, the child declares artifact ID and digest and
the core materializes canonical producer-bound `artifact:` refs. For task
identity, the child declares `codex_task: true` and the core materializes the
`codex-task:` ref. `check:` and `review:` may be declared as terminal evidence
for the operator but cannot cross an automated edge. The canonical advisory
spellings are `patch_ref`, `review_ref`,
`source_ledger_ref`, `decision_brief_ref`, `check_ref`, `plan_ref`, `docx_ref`,
`pdf_ref`, `xlsx_ref`, and `render_inspection_ref`; terminal check/review types
need no downstream consumer.

## End-to-end patterns

### Review and security-scan routing

Use `$flightdeck-review` for an ordinary change, readiness, or security-focused
review. Security awareness does not by itself authorize a repository scan.
Only an explicit security-scan request loads the applicable Codex Security
skill; a standard repository or scoped-path scan uses
`$codex-security:security-scan`. Keep that review or scan in its own declared
runtime task when independence is requested, with resolvable inputs and its
own typed result.

### Compliance

Create required nodes for the isolated program workspace and technical evidence
trace. Those children declare evidence artifact IDs and digests; only the core,
after their exact task receipts, materializes the artifact-backed inputs for the
assessment and DOCX/PDF/XLSX builder. Put independent review last in a separate
persistent runtime task that directly consumes every materialized artifact it
inspects. Its declared `review:` result is
terminal operator evidence and is not forwarded into another builder. The
Mission stores only typed evidence-index and deliverable references. It cannot
submit to an external system, accept risk, mark a control effective, or close a
finding.

### Patching

Route the image-source fix first. Fan its validated image digest, SBOM, and scan
references into chart or product consumer nodes. Make runtime validation depend
on every required consumer. A scan failure yields `failed_validation`; a
deployment request yields `needs_approval`. Residual-risk acceptance and rollout
remain operator actions.

### Development

Default cross-stack development to a contract-first graph:

```text
api_contract
  ├─> backend_feature ─┐
  └─> frontend_feature ├─> integration_tests ─> independent_review
                       ┘
```

The contract root emits `contract_ref`. Every implementation directly depends
on it and emits a resolvable `patch_ref` plus declared test/validation
references. Integration directly depends on the contract and every
implementation. A requested independent review directly depends on every
producer whose references it must inspect; never assume transitive reference
access. Use prototype-first ordering only when the user explicitly requests it
and persisted success criteria/non-goals record that tradeoff.

The review node must be a separate persistent runtime task from every producer; it can make
the Mission `review_ready`, but does not prove personnel or organizational
independence. A continuation or second pass inside the producer task is not
independent, and co-location is not a fallback. Prove the review task can
resolve every input before dispatch. Supervision cannot commit, open a PR,
request external review, or deploy.

### CI/CD

Start with a read-only provider-diagnosis node bound to the exact revision and
assign it a diagnosis criterion. It declares a bounded diagnostic artifact,
for example `{type: failure_ref, artifact_id: diagnostic-ledger, digest:
<sha256>}`. After the exact producer receipt, the core materializes its
canonical producer/resolver/task/SHA ref. The repository-owned fix node depends
on and consumes that materialized artifact;
a bare `check:` URL is terminal operator evidence and cannot drive an automated
fix handoff. Assign the fix and validation criteria explicitly, and require
their terminal criterion results to pass. The action carries the resolver
because it transports the diagnostic artifact; a later check-only action would
carry null. Rerun, cancel, publish, promote, and deploy remain separate
approval-gated actions and are not performed merely because the fix validates.

### Platform

Use separate source, plan, and environment-observation nodes. Each child
declares only bounded artifact IDs and digests; the core constructs canonical
refs from persisted receipts and resolver identity. A review node may consume
those materialized plan and observation refs. A blocked or stale producer stops
the handoff. Apply, restart, secret rotation, failover, restore, and data
mutation remain prohibited without explicit approval in the exact environment.

### Research

Dispatch independent source tracks, each assigned explicit source freshness,
accessibility, and coverage criteria. Each track declares a dated
`source_ledger_ref` artifact ID and digest; the core materializes its canonical
producer provenance after the exact receipt. The synthesis node may consume it
only after every required track reports all assigned criteria `passed`. Stale
or inaccessible required primary sources must
produce a `blocked` or `degraded` criterion disposition under
`failed_validation`, preventing automated synthesis. A `review:` citation or
free-form confidence statement remains terminal operator evidence, not a
machine handoff. The Mission never invents source content or silently treats
optional research as required evidence.

### DOCX, PDF, and XLSX building

Fan core-materialized artifact-backed source references into an artifact-builder task
using the installed document capability, then require a render-and-inspect
validator. If independent review is required, make it the final separate task
and give it direct artifact inputs; keep its `review:` result terminal. The
Mission persists child declarations plus materialized deliverable and
validation references, not document contents.
Packaging, publication, external delivery, or compliance submission remains
separately authorized.

## Verified skill telemetry

Generated-Hub template `1.3.0` adds the independent
`flightdeck.command.skill-telemetry.v1` contract. A Mission sync may accept a
bounded `skill_events` list only from explicit structured Codex task
skill-event metadata with source `codex_task_skill_event`. Prompt text, task
titles, display labels, commands, free text, and arbitrary tool payloads never
prove invocation. Core binds each accepted event to the persisted Mission node
and exact project/host/task receipt, deduplicates stable evidence IDs, rejects
conflicts, and persists the ordered result atomically with the Mission.

`bin/flightdeck mission skill-telemetry SLUG --json` returns the closed
`flightdeck.skill-telemetry/v1` envelope: Mission operation ID and generation,
operation and partial-failure status, bounded counts, deduplicated skills, and
per-child opaque provenance. Pages sort deterministically and cursors bind the
Mission generation; mutation between pages returns `snapshot_changed`.
Supported-but-empty is `absent`. Missing, malformed, or incompatible contracts
return typed errors and never fall back to Mission-file or command-text
scraping.

## Existing Hubs and upgrades

Plugin lifecycle and generated-Hub lifecycle remain separate. Upgrade the
plugin only through the supported preservation-aware workflow, then start a
fresh Codex task so the new mission skill loads.

Existing generated Hubs are never auto-migrated. If Mission intent reaches a
Hub without `flightdeck.command.mission-*` capabilities, Flightdeck must stop
and return the compatibility checker's exact managed plan-and-diff scope. It
must not run setup, overwrite the Hub, edit ignored state, or silently fall
back to ordinary dispatch while claiming to run a Mission. Documentation may
use the bundled Mission reference only as guidance; missing commands have no
behavioral fallback.
