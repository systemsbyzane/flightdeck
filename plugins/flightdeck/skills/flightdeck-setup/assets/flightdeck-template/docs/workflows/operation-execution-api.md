# Operation execution adapter API

Template `1.9.0` makes confirmed Operation execution runtime-neutral through two
declaration-required capabilities:

- `flightdeck.command.operation-execution.v1`
- `flightdeck.command.operation-observation.v1`
- `flightdeck.command.operation-start-recovery.v1` (template 1.11 and later)
- `flightdeck.command.operation-agent-telemetry.v1` (template 1.12 and later)

Work conversation runtime is independently selected as `omp`. An Operation
continues to select the exact adapter declared by
`runtime_capabilities.operation_execution`; changing the conversation adapter
does not change launch authorization, execution, observation, or recovery.
Template 1.9 selects `omp`; `codex_app_server` is declared unavailable and is
rejected with `adapter_unavailable`. Unknown adapters return
`unsupported_adapter`, and a request for a known but non-selected adapter
returns `authorization_conflict`. There is no fallback from Operation execution
to ordinary chat.

## Closed wire boundary

| Command | Request | Result |
| --- | --- | --- |
| `execution-plan` | `operation-execution-plan-request.schema.json` | `operation-execution-plan-result.schema.json` |
| `execution-bind` | `operation-execution-bind-request.schema.json` | `operation-execution-bind-result.schema.json` |
| `execution-start-report` | `operation-execution-start-report-request.schema.json` | `operation-execution-start-report-result.schema.json` |
| `execution-start-open` | `operation-execution-start-open-request.schema.json` | `operation-execution-start-open-result.schema.json` |
| `execution-retry-bind` | `operation-execution-retry-bind-request.schema.json` | `operation-execution-retry-bind-result.schema.json` |
| `execution-observe` | `operation-execution-observe-request.schema.json` | `operation-execution-observe-result.schema.json` |
| `execution-open` | `operation-execution-open-request.schema.json` | `operation-execution-open-result.schema.json` |

Shared closed types are in `operation-execution-types.schema.json`; all errors
use `operation-execution-error-result.schema.json`. Every request carries the
exact adapter descriptor (`id`, configuration schema, and both capability IDs).
Provider controls live only in the closed per-agent `adapter_configuration`.

`execution-plan` requires the exact five-field authored confirmation, current
dispatch generation/digest, idempotency key, bounded authorized task text, and
exact agent/project graph. It creates generic `operation-execution-*` durable
identity only after launch. Exact replay returns the same identity; conflicting
content fails closed. It creates no repository tasks.

Template `1.12.0` authors read-only work as one isolated `research` agent per
selected project. Write work is an explicit two-stage graph: an
`implementation` agent owns the managed Worktree and its dependent `review`
agent receives read-only access to that exact target only after implementation
reaches its terminal handoff. The reviewer has a distinct Flightdeck identity
and adapter session, may inspect the complete uncommitted change set, and may
not edit it. Dependencies, access modes, and work types are authenticated parts
of the dispatch and execution plans; clients must reject graph drift or a
reviewer allocated to a different target.

`execution-bind` attaches one opaque `adapter_session_ref` to one stable
Flightdeck agent. Only its digest is persisted. `execution-observe` requires
the exact Operation/execution/agent/binding generations plus an HMAC-SHA256 of
the canonical request with `adapter_session_ref` and `signature` omitted.
Sequence, time, lifecycle, payload size, terminal state, and replay are bounded.
`execution-open` is read-only restart recovery.

Before an adapter session exists, a binding generation and observation HMAC do
not exist either. `execution-start-report` is the separate service-side failure
boundary for that phase. It requires the exact execution identity, Flightdeck
agent, dispatch generation, dispatch receipt, registered runtime project, and
current retry generation. It stores only a bounded code, summary, retryability,
and timestamp; no session, path, prompt, provider payload, or credential.
Reports are ID-idempotent and limited to eight per agent. A retryable report
issues a single exact retry generation. The ordinary `execution-bind` path is
then closed; only `execution-retry-bind` may consume that generation. A
non-retryable failure cannot bind. `execution-start-open` recovers the bounded
audit history and current retry state after restart. Exact report replay remains
valid after later recovery, while conflicting content, stale generation,
foreign dispatch/project identity, or an already bound agent fails closed.

Renderer projections expose only adapter identity, stable Flightdeck identity,
bounded lifecycle/action/tool/subagent/attention fields, timestamps, and final
summary/evidence references. They exclude session references, native runtime
project IDs, raw prompts or reasoning, provider metadata, credentials, tool
schemas, environment variables, and raw protocol payloads. Control Center only
reads these durable projections.

## Runtime-agent telemetry

Template 1.12 adds additive v2 `execution-observe` and `execution-open`
contracts. The v1 requests and renderer projections remain unchanged. A v2
authenticated observation may carry bounded updates for runtime-reported task
agents and subagents without restricting their names to a built-in catalog.
Each observation and each owning Flightdeck agent's durable runtime roster are
bounded to 64 agents; attempting to accumulate a 65th agent fails without
changing the accepted record.
Core derives each public `operation-runtime-agent-*` identity from the exact
Operation, owning Flightdeck agent, and runtime reference digest. Raw runtime
agent, session, and tool-call references are never persisted or projected.

Immutable reported name, role, source, kind, and exact authored project scope
are bound on first sight. Later identity drift, duplicated runtime/event
identity, foreign project scope, unauthorized write/tool activity, cycles,
out-of-order events, or post-terminal updates fail closed. Typed events cover
activity, tools, skills, files, changes, and approvals; agents also expose a
bounded structured yield, validations, error, and terminal result. These are
authenticated runtime claims, not inferences from prose.

OMP RPC currently reports `parentToolCallId` rather than a parent agent ID.
When only that correlation exists, Flightdeck persists its digest and projects
`parent.availability: correlated` with no invented `agent_id`. A runtime-proven
parent projects `available`. When neither form of parent evidence is present,
Flightdeck projects `parent.availability: unavailable` with no agent or
tool-call identity; it never substitutes the owning Flightdeck agent.
Similarly, unsupported plugin provenance, skill use, or approval semantics
remain `unknown` or absent; generic messages and confirm/select UI frames are
not promoted into typed evidence. Advisor is not part of this contract.

Flightdeck retains accepted terminal subagent history even when the runtime no
longer returns that subagent in a current snapshot or loses it after session
switch/restart. This durable history is the recovery source for Operations and
Control Center.

State is stored under `hub/state/operation-execution`. Template 1.12 writes
record v3 and reads records v1 and v2, adding empty runtime-agent history only
on a later authorized write. Rollback requires restoring the complete managed
control-plane set and compatibility file together. A Hub rolled back below
1.12 must not open a record already upgraded to v3; preserve it for forward
recovery instead of rewriting or discarding its audit history.
