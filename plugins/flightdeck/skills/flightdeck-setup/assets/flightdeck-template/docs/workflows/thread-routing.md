# Codex Thread Routing

Use this to resolve and launch the owning task automatically from the organization Work
Hub. The user describes the outcome; the Hub chooses the project and mode.

## Automatic Flow

1. Classify intent and choose the smallest lead Flightdeck skill for the
   requested outcome: planning, review, CI/CD, platform, read-only,
   implementation, compliance, runtime-validation, or coordination.
2. Resolve workload and ownership from `flightdeck.yaml`, repo code, artifacts,
   GitHub, or authorized environment evidence.
3. Use `bin/flightdeck route plan --workload <id> --work-type <type>` and add
   `--repo-id <id>` when a registered repository owns the work.
4. Resolve the stable logical project key to an exact normalized path in the
   refreshed live project list. Capture the opaque runtime project ID from that
   match; display-name-only matches are invalid.
5. Verify the project is saved. Register an existing checkout automatically if
   missing, then refresh the project list and repeat the exact-path match.
6. Require `bridge_handoff.status: verified` for a repository owner and include
   the complete handoff plus exact lead and currently applicable companion
   `$flightdeck-*` names in the child prompt.
7. List recent tasks using the opaque runtime project ID and resume the
   matching objective when one exists.
8. Create the Local or Worktree task when no matching task exists.
9. Return logical project key, runtime project ID, child task ID, and mode
   immediately. Do not monitor it.

## Skill Composition

Project ownership and skill expertise are independent. A charts repository can
own a live deployment while `$flightdeck-platform` remains the lead skill.
Choose companions only for domains already involved; do not preload speculative
skills.

When new evidence crosses domains, announce and read the newly applicable skill
before domain-specific mutation. Preserve the existing authorization boundary;
loading a skill never grants a new action.

## Dispatch Gate

Before the child exists, the Hub may use only Hub policy, registry, routing,
saved-project state, and recent task metadata needed to identify and launch the
owner. It must not inspect target code, open or analyze workbooks, hash program
evidence, create temporary analysis scripts, run project-specific tools, or
begin implementation.

After create/resume succeeds, do not call `read_thread`, wait, poll, repeatedly
list tasks, or consolidate progress. The user monitors the child directly. Read
the result only after a later explicit request to resume or consolidate.

An ignored reference or materialized bridge is not copied into a new Codex
Worktree. The child reads every applicable repository `AGENTS.md` in the active
Worktree first, verifies the SHA-256 digests in `bridge_handoff`, then reads the
bridge target and required documents from the recorded original checkout. A
repo-native bridge is tracked and is read in the Worktree. Refuse dispatch if
the bridge record is absent, stale, or drifting.

For an unknown image repository, first verify source ownership. When that repo
owns the patch, clone it under `patching/`, register it in `flightdeck.yaml`,
install and locally ignore the patching bridge, register the saved project, and
launch its Worktree task. If the organization only consumes the image, route to the chart or
product repo that owns the tag or digest instead.

## Default Routing

- **Hub task**: intake, ownership resolution, right-sized coordination
  planning, cross-repo design, sequencing, approvals, and final synthesis.
- **Repo project on Mac**: code edits, tests, diffs, commits, PR preparation,
  findings-first repo review, code-level planning, and pipeline or
  infrastructure source changes; also read-only repo audits when that repo owns
  the work.
- **Codex Worktree mode**: parallel feature work or review fixes inside one Git
  repo.
- **`remote-validation` remote thread**: cluster inspection, logs, image rebuilds,
  Kubernetes validation, platform observation, and VM-hosted environment
  checks.
- **GitHub plugin or app controls**: PR, issue, review, CI, and workflow context.
- **Codex Security plugin**: diff scans, repository scans, finding validation,
  and security remediation planning.

## Before Editing Code

1. Name the workload and repo.
2. Confirm the owning layer: application code, chart, product composition,
   customer/program config, deployment tooling, cluster state, or CI.
3. Open the actual repo project in Codex.
4. Read the repo `AGENTS.md`.
5. Use the hub docs for design, security, bridge, and validation guidance when
   the repo has opted into the bridge or when the user explicitly asks for the
   hub workflow.

## VM And Local Split

- Use the local checkout as the source of truth for code changes.
- Use `remote-validation` for environment discovery and validation that depends on the
  VM-hosted Kubernetes cluster.
- Do not treat dirty remote worktrees as source of truth.
- Before transferring VM work, identify whether it is committed branch history,
  uncommitted diff, or untracked files.
- Prefer pushing a committed branch or capturing an explicit patch before
  applying remote-only changes locally.

## Multi-Repo Work

Create or resume one task per repo that owns work. Use the Hub only to coordinate
sequence and evidence. For multi-repository application changes, a common split is:

- backend repo thread for API, persistence, auth, and tests
- frontend repo thread for UI, API clients, route behavior, and tests
- charts repo thread for deployment, image metadata, values, and manifest
  validation
- `remote-validation` thread for cluster checks and rebuilds

The user does not need to request these child tasks individually. The Hub
creates the required split after ownership and authorization are clear.

When several repos own work, create all required tasks in the dispatch phase,
return all IDs, and stop. Do not remain active to monitor the set.

## Failure Fallback

Use `hub/templates/project-handoff.yaml` only after project registration or
cross-project task creation fails after a live-state refresh and one retry.
Never perform owning-repo implementation in the Hub merely because launch
failed.

## Completion Standard

A task is complete only when the owning repo's checks have run or an explicit
reason is recorded, security preflight is addressed, validation evidence is
captured, and any remaining risk is named.
