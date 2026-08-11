# OMP Operation execution API

Template `1.8.0` adds two declaration-required capabilities:

- `flightdeck.command.omp-operation-execution.v1`
- `flightdeck.command.omp-operation-observation.v1`

They extend, and do not replace,
`flightdeck.command.work-operation-lifecycle.v1`. The Codex adapter remains the
ordinary Work conversation runtime. OMP is selected only for execution of an
authored Operation after the exact proposal has reached `launched`. The Hub
must never substitute either runtime for the other.

## Commands and schemas

All commands take one closed JSON request with `--request FILE`. Argument order
is exact: `operation`, subcommand, `--request`, file, optional `--json`.

```text
bin/flightdeck operation execution-plan --request FILE [--json]
bin/flightdeck operation execution-bind --request FILE [--json]
bin/flightdeck operation execution-observe --request FILE [--json]
bin/flightdeck operation execution-open --request FILE [--json]
```

The request/result pairs are:

| Command | Request schema | Result schema | Boundary |
| --- | --- | --- | --- |
| `execution-plan` | `omp-operation-execution-plan-request.schema.json` | `omp-operation-execution-plan-result.schema.json` | native-only mutation |
| `execution-bind` | `omp-operation-bind-request.schema.json` | `omp-operation-bind-result.schema.json` | native-only mutation |
| `execution-observe` | `omp-operation-observe-request.schema.json` | `omp-operation-observe-result.schema.json` | authenticated mutation, safe result |
| `execution-open` | `omp-operation-open-request.schema.json` | `omp-operation-open-result.schema.json` | read-only renderer-safe recovery |

Every schema is closed with `additionalProperties: false`. Unknown fields,
versions, enums, lifecycle values, or identities fail closed. Shared types are
in `hub/schemas/omp-operation-types.schema.json`. Errors use
`hub/schemas/omp-operation-error-result.schema.json`.

## Execution authorization

`execution-plan` requires all of the following exact values:

1. the originating Work ID and canonical `operation-<24 lowercase hex>` ID;
2. the five-field confirmation: `operation_id`, `plan_id`, `plan_generation`,
   `plan_digest`, and `plan_token`;
3. the current `dispatch_generation` and `dispatch_plan_digest` returned by
   `work dispatch-plan` after launch;
4. one idempotency key; and
5. an agent request for every authored Mission node, with no omissions or
   additions.

Core reopens Work, requires the exact proposal to be `launched` and active,
compares the confirmation without reconstruction, then regenerates the native
dispatch plan. Proposed, declined, foreign, stale, tampered, route-drifted, or
bridge-drifted input is rejected. Exact replay returns the same durable
`execution_id`, generation, digest, stable agent identities, and authorization.
Reusing an identity with changed content returns
`duplicate_request_conflict`.

The result is native-only because each agent includes exact runtime project,
host, project-path digest, authorization boundary, execution/access mode, and
work type. It never includes a project path. Independent nodes retain
`parallel_independent` policy and a maximum concurrency of eight; dependency
order comes only from the authored Mission graph. Model, reasoning effort, and
closed tool policy are explicit. Read-only targets cannot select a write
profile. Network tools remain denied because Work proposal authorization does
not grant external actions.

The only persisted task body is the bounded `authorized_task` (8 KiB maximum)
for that exact agent. System prompts, raw reasoning, transcripts, arbitrary
environment variables, tool schemas, raw OMP protocol messages, credentials,
OAuth/provider metadata, and uncontrolled paths are prohibited.

## Session binding and observations

`execution-bind` maps one stable `flightdeck-agent-<48 lowercase hex>` identity
to one opaque OMP session reference. The reference is accepted only at the
native boundary; only its SHA-256 digest is persisted. Exact replay is
idempotent. Rebinding an agent or changing content under the same idempotency
key fails closed.

Every observation must name the exact Work, Operation, execution ID,
execution generation/digest, agent, and binding generation. It carries the
opaque OMP session reference only to prove possession and an HMAC-SHA256 over
the canonical request with `omp_session_ref` and `signature` omitted. Neither
the reference nor signature is persisted. `observation_id` replay is exact;
changed replay conflicts. Sequence starts at one and advances by exactly one;
stale generations, skipped/reordered sequence, and regressing timestamps are
rejected.

Persisted renderer-safe fields are limited to lifecycle, a 512-byte action
summary, closed tool kind/status, bounded subagent counts, closed attention and
error codes, canonical timestamps, and a terminal summary plus opaque
`omp-evidence-<48 lowercase hex>` references. Terminal observations require a
final result; nonterminal observations prohibit one. `review_ready` requires
at least one evidence reference. OMP cannot explicitly close a Mission.

`execution-open`, Mission status, the Operation detail projection, and the
Operations snapshot read only this validated durable record. They never poll
OMP and never launch, bind, observe, or mutate. OMP session IDs remain below
the stable Flightdeck agent abstraction. Control Center consumes only the safe
projection and stays read-only.

## Recovery, compatibility, and rollback

State is bounded and atomically written under ignored
`hub/state/omp-operation-execution`. Each record is closed and self-digested;
agent histories are capped at 200 observations and 2 MiB total. An
`unknown_outcome` from a mutation is recovered with the original exact
`execution-open` identity. Blind retry with a new identity is prohibited.

Older Clients and Hubs must fail closed because template `1.8.0`, both
capabilities, all schemas, and the split runtime declaration are required. A
preservation-first migration must back up the exact ignored Work, Mission,
Operation-authoring, and OMP execution state plus every declared managed file.
Apply reviewed source hunks and schemas before writing `hub/compatibility.json`
last. Rollback first stops OMP writes, restores compatibility first to disable
new calls, restores all managed files and exact ignored-state backups, and
then re-runs read-only compatibility and Doctor checks. Never downgrade while
retaining records a prior implementation cannot validate.
