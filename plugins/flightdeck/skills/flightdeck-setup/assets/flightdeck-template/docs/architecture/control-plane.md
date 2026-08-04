# Flightdeck Control Plane

## Intent

Make `<hub-root>` the single operational entrypoint
for the organization engineering work. The Hub should route, track, validate, and summarize
patching, research, multi-repository application, daily operations, cluster validation, and
program compliance without collapsing the owning repositories or sensitive
evidence into a monorepo.

## Owning Boundary

The Hub owns:

- workload and repository topology
- task intake and lifecycle state
- execution routing between Hub, repo, Worktree, GitHub, and remote contexts
- approval boundaries
- cross-repo coordination
- validation and evidence requirements
- generated operational status

Each nested Git repository continues to own its code, tests, branches, commits,
and pull requests. Program workspaces continue to own program facts and evidence.
`remote-validation` and AWS/Kubernetes environments continue to own runtime state.

## Non-Goals

- Do not combine nested repositories into one Git history.
- Do not place raw program evidence, scan archives, VM patches, or generated task
  state in the Hub control-plane history.
- Do not make commits, pushes, pull requests, deployments, submissions, or
  external communications without task authorization.
- Do not require all compliance evidence to be locally accessible.
- Do not encode mutable branch, SHA, or deployment state in durable policy.

## Design

The Hub uses five layers:

1. `flightdeck.yaml` records stable workload, repo, project, and environment
   topology.
2. `hub/workflows/` defines declarative adapters for common task types.
3. `hub/schemas/` defines machine-readable registry and task contracts.
4. `bin/flightdeck` provides diagnostics, task and Mission lifecycle, status,
   onboarding plans, and artifact validation without external dependencies.
5. `hub/tasks/`, `hub/missions/`, `hub/reports/`, and `hub/state/` hold local
   generated state and are excluded from control-plane versioning by default.

The common task lifecycle is:

```text
intake -> scoped -> designed -> authorized -> executing -> validating
       -> review_ready -> closed
```

Workflows may add gates but may not bypass authorization or validation. Tasks
may also move to `blocked`, `cancelled`, or `rollback_required` when applicable.

## Execution Routing

- Use the Hub task as the durable coordinator.
- Resolve project ownership from the request and registry; do not require the
  user to name a Codex project or request a child thread.
- Enforce dispatch before project work. Pre-dispatch Hub activity is limited to
  policy, registry, route planning, project registration, and recent-task lookup
  needed to create or resume the owner task.
- Do not inspect target code, artifacts, workbooks, or evidence and do not
  create analysis files in the Hub before dispatch.
- Search for and resume a matching owning-project task; otherwise create it
  automatically.
- Register an existing checkout as a saved Codex project when missing. For a
  new image repo, resolve ownership, clone under `patching/`, register topology
  and project state, install the bridge, and then launch the owning task.
- Treat configured project keys as stable logical identity only. Refresh the
  live project list, require an exact normalized real-path match, capture the
  opaque runtime project ID from that record, and use it for task operations.
  Display names never establish identity.
- Do not use bounded subagents as a substitute for owning-project tasks. Use
  them only when explicitly requested for synchronous, coordination-only work.
- Use persistent project tasks for project-owned work and durable results.
- Keep receipt-and-stop dispatch as the default. An opt-in Mission is a
  separate ignored durable parent linking verified persistent tasks; it does
  not replace them or create a second UI control surface.
- Use Local mode to continue an existing checkout branch.
- Use Worktree mode for isolated implementation and record its base ref and SHA.
- Include the complete verified route-plan `bridge_handoff` in every
  repository child prompt. A Worktree reads its repository instructions first,
  then verifies and reads ignored bridge artifacts from the registered
  original checkout; never copy them into the Worktree.
- Use remote tasks for durable remote or cluster work; embed required instructions
  because Mac-local absolute paths are not portable.
- Use the manual handoff template only after verified automatic registration or
  task-launch failure; never silently perform owning-repo work in the Hub.
- After dispatch, return logical keys, runtime project IDs, task IDs, and modes
  immediately. Child monitoring, progress reads, waits, and consolidation are
  user-initiated only unless the user explicitly opted into a Mission mode.

## Mission Coordination Layer

Mission graph and synchronization logic stays inside the generated Hub. The
installed Mission skill supplies the injected Codex UI task adapter for exact
project lookup, root and JIT-dependent creation, bounded compact waits, and
declared follow-ups.
The Hub CLI never invents runtime identity or interprets raw child text.

Durable Mission state under ignored `hub/missions/` contains graph ownership,
required/optional dependencies, declared `read_only`/`write` access, exact project/task receipts, opaque per-thread
cursors, normalized observation envelopes, bounded output declarations,
core-materialized typed output refs, event digests, dedupe keys, status, and
outbox receipts. It excludes raw commentary/final text,
artifact bodies, credentials, and private evidence.

Mission creation persists exact six-field authorized targets and ordered
core-assigned criterion IDs. Required nodes must cover every criterion before
dispatch, and every assigned result must pass before fan-in. Core derives the
`authorization_boundary` from canonical Mission ID, targets, criteria, and
non-goals. Every node/action carries and revalidates that value; a caller cannot
supply or translate it. Each action includes it in its idempotency key and
revalidates through create, append, prepare, acknowledge, fail, and whole-record
validation. Observation input must be a
readable regular file; its size is checked against `max_forwarded_bytes` before
read or parse, with a post-read check retained against concurrent size changes.

Observation is batched to at most eight targets per wait. Supervised fan-in
uses a generation-bound sync plan token plus persist-before-send outbox:
preview, token-verified apply, prepare, deliver, then acknowledge or record a
bounded failure. Every action persists `trigger_digest` bound to producer event
ID, `event_digest`, and status; whole-record
validation recomputes its key and ID from Mission ID, derived boundary, type,
trigger digest, and canonical payload. Drift or unknown outcomes fail closed.
Only canonical `artifact:` and `codex-task:` refs materialized by core can cross an automated edge;
`check:` and `review:` remain terminal/operator evidence. Only explicit
operator close can produce `complete`.

A dependency action payload has exactly `node_id`, the consumer's complete
declared parent list in `dependency_node_ids`, `output_refs`, and
`artifact_resolver`. For every parent it contains at least one accepted
core-materialized automatic ref, and its refs exactly equal the complete
eligible accepted set;
terminal or type-incompatible refs do not count. Partial, early, or incomplete
payloads fail validation. A non-root dispatch record requires that exact action
to be the sole matching prepared action; dependency readiness by itself is not authorization to
create. Immediately
before every downstream create, the adapter refreshes live projects and
reverifies exact normalized path, opaque runtime project ID, and host identity.
After prepare, exact JIT task/runtime/host receipt records the planned consumer
as internal `awaiting_handoff`; status projects it as `running` with
`handing_off`. Delivery plus acknowledgement transitions it to ordinary
running. Child-observed blocked, derived stale, pending-client, and unknown
consumers remain non-actionable.

Base observations persist normalized identity, status, cursor, revision, event,
time, Worktree state, and a bounded display-only `status_code` only. The code is
tool-derived and cannot authorize or drive state. `running`, `needs_approval`, `blocked`,
`runtime_failure`, `cancelled`, and `notLoaded` forbid a child outcome, and
`notLoaded` is ignored. An exact child outcome is required only for final
`review_ready` or `failed_validation` and includes ordered assigned criterion
results. Bounded dispositions are `passed`, `failed`, `blocked`, and
`degraded`. `review_ready` requires all assignments passed; fan-in additionally
requires full required-node criterion coverage and core-materialized typed refs.

Final children emit only closed declarations: `{type, artifact_id, digest}` for
an artifact, `{type, codex_task: true}` for their own task, or
`{type, ref, digest}` for terminal `check:`/`review:` evidence. They never see,
author, or repair the producer task binding, node binding, resolver, or
canonical ref. The adapter preserves declarations unchanged; core validates the
exact persisted receipt, materializes refs, and persists both forms plus the
event digest.

Final observations require `status_code == outcome.code`. Artifact-producing
and consuming nodes persist an exact `{kind, id}` resolver binding. From the
child's artifact ID and digest, core constructs canonical refs containing
resolver ID, producer node, unpadded base64url exact persisted task binding,
lowercase SHA equal to the declaration digest, and artifact ID. Core enforces
producer provenance, resolver equality, and same-host identity where required.
An action carries the resolver only when it transports an artifact and null
otherwise, regardless of the consumer's future outputs. This is provenance
control, not content transport. `external_approved` identifies a previously
approved system and authorizes no upload or publication.

A create response containing only `clientThreadId` is pending identity, not a
wait target. The node stays `dispatch_pending` and cannot be observed until
exact project-list reconciliation records both the original client ID and the
resolved task ID; only the resulting exact task/host pair enters bounded wait
batches. If the create followed a prepared handoff, the core preserves that
same prepared action alongside the pending receipt. It is neither deliverable
nor retriable, and no duplicate create is allowed. Exact paired reconciliation
moves the consumer to `awaiting_handoff`. An unknown create likewise preserves
the prepared action as non-actionable. Either unresolved action may be failed
explicitly; once failed it remains non-actionable and is never retried.

Two Local write nodes that resolve to the same project path must be ordered by
a dependency edge. Graph validation rejects parallel same-checkout writers
before dispatch.

Mission membership is planning state. All nodes and edges are declared before
runtime identity exists. Any exact, pending, or unknown dispatch receipt,
observation, or outbox state freezes the graph. A newly discovered owner is not
inserted into that graph; the coordinator finishes only the declared phase in
its original scope or stops safely, then proposes a new Mission for user
approval.

Downstream nodes are declared but remain `planned` without task identity until
all their dependencies validate and the core emits a handoff. Immediately
before creation, the adapter refreshes the live project list and reverifies the
exact path, opaque runtime project, and host. Only then does it dispatch the
already-declared node and record its receipt. The Mission action ledger carries
typed references only; it does not transport artifact bytes. Consumer
resolvability is a precondition. Co-locate compatible work before dispatch when
needed, or stop if separation, ownership, or independent-review requirements
prevent it. Independent review always has a task identity distinct from the
producer it reviews.

`mission new` persists the configured budget mapping in the record. Generated
defaults are 50 units, 3 retries, 200 actions, 65,536 forwarded bytes, 604,800
seconds total duration, a 3,600-second stale threshold, and a 2,097,152-byte
record limit.

## Security Model

- Shell commands must use argument arrays rather than interpolated shell text.
- Slugs, paths, workflow names, and state transitions must be validated.
- Task creation must never overwrite an existing task.
- Generated writes must be atomic.
- Diagnostic commands are read-only unless a separate explicit execution command
  and task authorization allow mutation.
- Mandatory repo review and security rules belong in committed repo policy.
- Local overrides contain machine-local facts only and must require the tracked
  repo instructions to be read.
- Compliance artifacts must be treated as program-sensitive, and missing or
  external evidence must be represented as a gap rather than invented.

## Validation

The v1 control plane is ready when:

- every YAML and JSON control-plane file parses
- the registry references existing local paths or explicitly optional repos
- the CLI passes syntax and automated unit tests
- `flightdeck doctor` inspects the live workspace without modifying nested repos
- task creation is non-destructive and transitions are enforced
- generated aggregate status is deterministic
- invalid or unequal compliance JSON/YAML pairs are reported
- bridge coverage and override propagation problems are visible
- no raw compliance program data or nested repo contents appear in root Git
  status

## Rollback And Recovery

The control plane is additive. Removing `bin/flightdeck`, `lib/flightdeck/`,
`flightdeck.yaml`, and `hub/` restores the prior docs-driven Hub without affecting
nested repos. Root Git initialization, if used, can remain as a control-plane
history; no nested repo history is rewritten. Local generated task state can be
archived independently before any cleanup.
