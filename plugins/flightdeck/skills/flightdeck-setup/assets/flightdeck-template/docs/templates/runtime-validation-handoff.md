# multi-repository application remote-validation Validation Handoff

Use this template after running:

```bash
bash scripts/development-vm-preflight.sh
```

## Coordinator Prompt

Coordinate multi-repository application runtime validation from locally authored code to `remote-validation`.

Rules:

- Local repositories are the source of truth for code and Git.
- `remote-validation` is the build, image-load, rollout, and cluster validation host.
- Do not test random dirty VM code unless explicitly approved as a scratch
  experiment.
- Prefer exact pushed branch/SHA. If Mac changes are dirty and not pushed, stop
  and ask whether to commit/push or create a patch bundle.
- Do not commit, push, force-push, or open PRs unless explicitly requested.

Required evidence:

- local branch/SHA/dirty state for backend, frontend, and charts
- remote branch/SHA/dirty state for backend, frontend, and charts
- Docker availability on `remote-validation`
- `kind` cluster name and kube context
- current Helm release image refs
- image build commands and tags
- kind image-load commands
- Helm upgrade commands
- rollout status and pod image refs after upgrade
- logs or smoke check output
- skipped checks and residual risk

## Backend VM Thread Prompt

You are running on `remote-validation` in `<remote-checkout>/backend`.

Build and load the backend image for multi-repository application runtime validation.

Before building:

1. Read repo instructions.
2. Confirm branch, SHA, and dirty state.
3. Confirm whether the remote repository matches the local branch/SHA supplied by the
   coordinator.
4. Confirm Docker works.
5. Confirm kind configured validation cluster exists and kube context is `kind-validation`.

Build rules:

- Use the repo-managed Docker build path.
- Tag with a branch/SHA-specific tag.
- Tag the image as `ghcr.io/source-owner/backend:<tag>` for chart
  compatibility.
- Load the image into kind configured validation cluster.
- Do not change source code unless the coordinator explicitly approves it.

Return:

- branch, SHA, dirty state
- build command
- final image ref
- kind load command
- success or failure evidence
- skipped checks and residual risk

## Frontend VM Thread Prompt

You are running on `remote-validation` in `<remote-checkout>/frontend`.

Build and load the frontend image for multi-repository application runtime validation.

Before building:

1. Read repo instructions.
2. Confirm branch, SHA, and dirty state.
3. Confirm whether the remote repository matches the local branch/SHA supplied by the
   coordinator.
4. Confirm Docker works.
5. Confirm kind configured validation cluster exists and kube context is `kind-validation`.

Build rules:

- Use the repo-managed Docker build path.
- Tag with a branch/SHA-specific tag.
- Tag the image as `ghcr.io/source-owner/frontend:<tag>` for chart
  compatibility.
- Load the image into kind configured validation cluster.
- Do not change source code unless the coordinator explicitly approves it.

Return:

- branch, SHA, dirty state
- build command
- final image ref
- kind load command
- success or failure evidence
- skipped checks and residual risk

## Charts VM Thread Prompt

You are running on `remote-validation` in `<remote-checkout>/charts`.

Roll out the supplied backend and frontend image tags to kind configured validation cluster.

Before mutating the cluster:

1. Read repo instructions.
2. Confirm branch, SHA, and dirty state.
3. Confirm kube context is `kind-validation`.
4. Confirm configured validation namespace exists.
5. Capture current deployed image refs for:
   - `development-backend`
   - `development-frontend`

Rollout rules:

- Prefer temporary Helm CLI overrides for local validation.
- Preserve existing release values unless overriding image tags and image pull
  behavior is required for local kind testing.
- Do not touch non-kind clusters.
- Do not commit chart changes unless explicitly requested.

Return:

- Helm release names and namespace
- previous image refs
- Helm upgrade commands
- rollout status commands
- final pod image refs
- logs or smoke checks
- skipped checks and residual risk


