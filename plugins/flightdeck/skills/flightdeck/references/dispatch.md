# Dispatch contract

Resolve the owner from stable Hub topology and live Codex project state.

## Allowed before dispatch

- Hub policy, registry, adapters, and bridge metadata
- read-only route and repo plans
- live saved-project list
- recent task titles, modes, and state needed to find a matching objective
- provider metadata needed to identify an owner or default branch

## Prohibited before dispatch

- target code or artifact analysis
- workbook enumeration or program evidence hashing
- live environment inspection
- project-specific scripts or implementation

Create every required owner task in one dispatch phase. A successful
create/resume response is the receipt. For ordinary dispatch, return IDs and
stop. Do not infer mission intent from multi-project scope alone.

Only explicit mission intent such as “mission,” “coordinate end-to-end,” “take
this to review-ready,” dependent-task monitoring, mission sync/status,
supervision, consolidation, or closure transfers control to
`$flightdeck-mission`. That skill may observe only the exact task IDs persisted
in the mission, within the core-derived exact authorized-target boundary, and
only in `watch_only` or `supervised` mode. Ordinary dispatch continues to
prohibit monitoring. A Mission handoff may automatically carry only
core-materialized, producer-bound `artifact:` or `codex-task:` references from
closed child declarations; children and adapters never author or repair that
provenance. `check:` and `review:` remain terminal/operator evidence.

For repository-owned work, the route plan must report
`bridge_handoff.status: verified`. Include the complete verified
`bridge_handoff` unchanged in the child prompt. It contains the original
checkout, target and artifact
paths, SHA-256 digests, mode, profile, version, and instruction order. The
child reads every applicable `AGENTS.md` in its active checkout first. When a
reference or materialized bridge is ignored and therefore absent from a Codex
Worktree, the child verifies and reads it from the original checkout named in
the handoff. Never copy ignored bridge files into the Worktree. Refuse
dispatch when the bridge record is missing, stale, or drifting.

If registration is needed, verify the exact normalized project path in the live
project list after native registration or supported open-folder fallback.
Keep the stable logical project key separate, capture the opaque runtime
`projectId` only from that exact-path live-list record, and use the runtime ID
for task search/resume/create. Never accept a display-name-only match. Refresh
and retry once. Only then return one manual action.

Persist the exact `threadId` and `hostId` returned by task creation; never
reconstruct a task from its title, summary, pin, or list position. If creation
returns only `clientThreadId`, report and persist `dispatch_pending` without a
blind retry. That client-only receipt is not waitable and cannot be normalized
as an observation. Reconciliation must supply both the original client ID and
the resolved task ID; only the resulting task/host pair may be monitored. If
the call's side effect is unknown, report `dispatch_unknown` and stop for
reconciliation because task creation has no idempotency key.
