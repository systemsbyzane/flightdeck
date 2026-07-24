# Design Review Gate

Use this before implementation when a change affects architecture, security,
data ownership, auth, compliance, deployment behavior, cross-repo contracts, or
user-facing workflows.

## Required Shape

1. **Intent**: State the user outcome in one or two sentences.
2. **Owning boundary**: Name the repo, service, chart, environment, or cluster
   component that should own the behavior.
3. **Non-goals**: State what will not change.
4. **Current evidence**: List the files, docs, PRs, cluster output, artifacts, or
   scan results used to understand the current state.
5. **Proposed design**: Describe the smallest coherent design that solves the
   problem.
6. **Security model**: Identify auth, tenancy, data exposure, secrets, network,
   image, and dependency risks.
7. **Validation plan**: List exact checks that prove the change works.
8. **Rollback or recovery**: Explain how to back out or disable the change.

## Architecture Questions

- Does the change live in the layer that owns the behavior?
- Can the change be implemented in one repo, or does it require a coordinated
  frontend, backend, chart, image, or deployment rollout?
- Are external contracts changing, such as API fields, Helm values, chart image
  metadata, database schema, RBAC, or environment variables?
- Are tenant scope, namespace ownership, stable identity, or admin behavior
  affected?
- Are failure states visible and safe?
- Can the change be tested locally on the local workstation, or does validation require
  `remote-validation`, Kubernetes, GitHub Actions, or an AWS environment?

## Quality Bar

The design is ready when a second engineer can answer:

- what changes
- where the change belongs
- why this design is safer than the alternatives
- what must be verified before the work is considered complete

