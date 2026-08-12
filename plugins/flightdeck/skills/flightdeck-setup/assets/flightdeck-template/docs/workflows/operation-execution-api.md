# Operation execution adapter API

Template `1.9.0` makes confirmed Operation execution runtime-neutral through two
declaration-required capabilities:

- `flightdeck.command.operation-execution.v1`
- `flightdeck.command.operation-observation.v1`
- `flightdeck.command.operation-start-recovery.v1` (template 1.11 and later)

Work conversation runtime remains `codex`. An Operation independently selects
the exact adapter declared by `runtime_capabilities.operation_execution`.
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

State is stored under `hub/state/operation-execution`. Template 1.11 writes
record v2 and reads record v1, upgrading v1 atomically only on a later authorized
write. Rollback requires restoring the complete pre-1.11 managed control-plane
set and compatibility file together. A Hub rolled back to 1.10 must not open a
record already upgraded to v2; preserve it for forward recovery instead of
rewriting or discarding its audit history.
