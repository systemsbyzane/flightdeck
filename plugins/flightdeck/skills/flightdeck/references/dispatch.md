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
create/resume response is the receipt. Return IDs and stop.

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
