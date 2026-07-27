# Codex UI Workflow

Use the Flightdeck Hub as the entrypoint and each declared repository,
compliance workspace, or validation environment as its own Codex project.
The Hub resolves the owner and launches or resumes the owning task.

## Project Setup

Register the Hub root as one Codex project:

```text
<hub-root>
```

Declare independent repositories in `hub/repositories.yaml`. A synthetic
development layout might include:

```text
<hub-root>/development/example-api
<hub-root>/development/example-web
<hub-root>/charts/example-deployments
```

Use stable logical project keys such as `example-api`, `example-web`, and
`example-deployments`. Runtime task operations use the opaque project ID
returned by an exact normalized path match; a display name is never identity.

Follow [repository onboarding](workflows/repo-onboarding.md) and
[bridge configuration](workflows/configure-bridge-repos.md) to verify or clone
declared checkouts, install non-destructive bridges, and register exact saved
projects. Do not create an implementation task during setup.

Register a matching remote or environment project only when runtime validation
requires a durable context outside the local checkout. Use synthetic,
environment-local paths such as:

```text
<remote-root>/example-api
<remote-root>/example-deployments
<remote-root>
```

The environment root may own cross-service inspection while each remote
repository remains a separate project for build or repository-specific work.

## Dispatch And Parallel Work

- Start the request in the Hub. The Hub resolves ownership, verifies the saved
  project and bridge, resumes a matching task or creates one, returns the
  dispatch receipt, and stops without monitoring.
- Use Local mode for read-only work or intentional work in the current
  checkout.
- Use Worktree mode for isolated implementation, review follow-up, or security
  remediation inside one repository.
- Keep each feature branch scoped to one repository unless the change requires
  a coordinated contract across several owners.
- For a multi-repository change, use one owning task per repository and keep the
  Hub task limited to sequencing, approvals, and later consolidation.
- Pass the complete verified `bridge_handoff` to every repository task.

See [thread routing](workflows/thread-routing.md) and
[multi-repository coordination](workflows/multirepo-coordination.md) for the
full dispatch boundary.

## Local And Environment Workflow

- Keep local checkouts as the source of truth for source changes.
- Use the matching environment project for live inspection, image builds,
  image loads, deployment actions, logs, and runtime checks.
- Transfer only reviewed branch history or an explicit patch bundle between
  local and remote contexts.
- Record the exact branch, commit, artifact digest, configuration, and
  environment used for validation.
- Require explicit authorization before changing a shared environment,
  publishing an artifact, or deploying a candidate.

Follow [remote validation](workflows/remote-validation.md) for the handoff and
evidence contract. Use [CI/CD and delivery](workflows/ci-cd.md) for pipeline
evidence and [platform and environments](workflows/platform.md) for the
source-to-runtime boundary.

## Plugins And Skills

- Ask for planning or review in natural language. Flightdeck infers the focused
  skill and appropriate depth; explicit skill invocation is optional.
- Ask about pipeline failures, releases, infrastructure, platform services, or
  environments the same way. Flightdeck infers CI/CD or platform guidance
  without requiring a skill name.
- Ask about STIG rules, CKLs, evidence gaps, applicability, inherited controls,
  or remediation naturally. Flightdeck infers the STIG workflow and keeps
  unfinished assessments flexible while applying stricter checks only when
  export readiness is requested.
- Ask to update Flightdeck or show Flightdeck patch notes naturally. The
  installed upgrade skill compares exact versions and treats generated Hubs and
  attached repositories as protected state.
- Use the connected source-control capability for pull request, issue, review,
  and CI context.
- Use the security capability for diff scans, repository scans, finding
  validation, and remediation planning.
- Use the applicable artifact or compliance skill for spreadsheets, documents,
  checklists, or structured assessment outputs.

Add a custom skill only when the workflow is stable and repeated. Repository
instructions, verified Flightdeck bridges, and existing focused skills are the
default operating surface.
