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
4. `bin/flightdeck` provides diagnostics, task lifecycle, status, onboarding plans,
   and artifact validation without external dependencies.
5. `hub/tasks/`, `hub/reports/`, and `hub/state/` hold local generated state and
   are excluded from control-plane versioning by default.

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
  user-initiated only.

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
