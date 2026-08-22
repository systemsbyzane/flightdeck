# multi-repository application Multi-Repo Coordination

Use this workflow when one multi-repository application feature touches backend, frontend, and
optionally charts. The hub coordinates the feature; repo-scoped Codex threads do
the implementation.

## Coordinator Contract

The hub thread owns:

- feature intent, non-goals, affected user flow, and security boundaries
- backend/frontend/charts work split
- choice of Local mode or Worktree mode for each repo thread
- child-thread prompts and thread ids
- cross-repo sequencing and approvals; status, evidence, and reviewer notes are
  read only after a later explicit user request

The hub thread does not edit application code inside nested repos. It starts or
continues the actual repo projects and summarizes their outputs.

## Thread Tool Flow

1. Use `list_projects` and confirm these saved projects exist by exact
   normalized real path:
   - `development/backend`
   - `development/frontend`
   - `charts`
   - `<remote-checkout>/backend` on `remote-validation` for runtime image builds
   - `<remote-checkout>/frontend` on `remote-validation` for runtime image builds
   - `<remote-checkout>/charts` on `remote-validation` for cluster rollouts
   - `<remote-checkout>` on `remote-validation` for cluster validation
   If a required existing checkout is missing, register it automatically and
   refresh `list_projects` before continuing. Keep each stable logical key
   separate from the opaque runtime project ID returned by the exact-path
   match. Do not accept a display name as identity.
2. Choose mode:
   - Use **Local** mode when the user says current branch, current checkout,
     continue existing work, or push commits to the current branches.
   - Use **Worktree** mode when the user wants isolation, parallel experiments,
     or a branch that should not touch the current checkout.
3. If the user asks to continue existing chats, use `list_threads` and
   `send_message_to_thread` for the matching backend/frontend/charts threads.
4. When the request starts in the Hub, use `create_thread` to create one
   repo-scoped task per owning repo without requiring the user to request each
   child task explicitly.
5. Record logical project keys, runtime project IDs, child thread IDs, repo
   paths, branch expectations, and check status in a handoff packet or in the
   Hub response, then return immediately. Do not poll, wait, or read child
   progress after dispatch.

## Repo Split

Backend owns:

- API behavior, request validation, authorization, audit events, persistence,
  backend tests, and service-to-service boundaries

Frontend owns:

- UI state, user flows, API client calls, route guards, form validation,
  display behavior, frontend tests, and error handling

Charts owns:

- Helm values, templates, rendered Kubernetes manifests, image metadata,
  environment variables, RBAC, network policy, probes, resources, and rollout
  behavior

`remote-validation` owns:

- cluster inspection, logs, image rebuilds, deployment smoke checks, and
  Kubernetes validation that cannot be proven from the local checkout

For code authored on the local workstation and tested on `remote-validation`, follow:

- `docs/workflows/remote-validation.md`
- `docs/templates/development-vm-validation-handoff.md`
- `scripts/development-vm-preflight.sh`

## Required Guidance In Child Prompts

Every child-thread prompt must point at:

- `AGENTS.md` and any `AGENTS.override.md` in that repo
- `<hub-root>/docs/security/secure-code-preflight.md`
- `<hub-root>/docs/architecture/design-review.md`
- `<hub-root>/docs/templates/validation-evidence.md`
- `<hub-root>/docs/review/codex-review-readiness.md`
- `<hub-root>/docs/review/pr-evidence-packet.md`

For charts work, also include:

- `<hub-root>/docs/architecture/manifest-architecture.md`
- `<hub-root>/docs/review/charts-review-guidelines.md`

For backend work, also include:

- `<hub-root>/docs/review/backend-review-guidelines.md`

For frontend work, also include:

- `<hub-root>/docs/review/frontend-review-guidelines.md`

## Child Thread Prompt Requirements

Each repo thread must:

1. Read the repo instructions before editing.
2. Confirm current branch and dirty working tree state.
3. Restate the repo-owned portion of the feature.
4. Identify trust boundaries, authorization requirements, validation needs, and
   likely tests.
5. Make the smallest coherent implementation.
6. Run repo-appropriate checks or state exactly why they were skipped.
7. Capture validation evidence and residual risk.
8. Avoid commits, pushes, or PR actions unless explicitly requested.

## Completion Summary

Produce this only when the user later asks the Hub to read completed project
tasks or coordinate follow-up. Do not wait in the original dispatch turn.

The hub final summary for a coordinated feature should include:

- backend thread id, branch, files changed, checks, risks
- frontend thread id, branch, files changed, checks, risks
- charts thread id if used, branch, files changed, checks, risks
- remote build/rollout/cluster validation thread ids if used
- cross-repo compatibility notes
- remaining manual checks before GitHub `@codex review`

