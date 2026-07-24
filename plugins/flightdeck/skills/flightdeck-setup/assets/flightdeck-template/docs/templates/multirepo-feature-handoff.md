# multi-repository application Feature Handoff Template

Use this with `docs/workflows/development-multirepo-coordination.md`.

## Coordinator Intake

- Feature:
- Intended outcome:
- Non-goals:
- Backend branch expectation:
- Frontend branch expectation:
- Charts branch expectation:
- Mode: Local for current branches, or Worktree for isolated work
- User approved commits or pushes: yes/no
- Security boundaries:
- Validation evidence required:

## Backend Thread Prompt

You are implementing the backend portion of this multi-repository application feature:

`<feature>`

Before editing, read the repo `AGENTS.md`, any `AGENTS.override.md`, and these
hub guides:

- `<hub-root>/docs/security/secure-code-preflight.md`
- `<hub-root>/docs/architecture/design-review.md`
- `<hub-root>/docs/review/backend-review-guidelines.md`
- `<hub-root>/docs/review/codex-review-readiness.md`
- `<hub-root>/docs/review/pr-evidence-packet.md`
- `<hub-root>/docs/templates/validation-evidence.md`

Work only in the backend repo. Confirm branch and dirty state first. Identify
API, auth, persistence, audit, and test impacts. Implement the smallest coherent
backend change, run relevant checks, and return changed files, commands run,
skipped checks, risks, and any frontend or charts contract notes.

Do not commit, push, or open a PR unless the coordinator prompt explicitly says
the user approved that action.

## Frontend Thread Prompt

You are implementing the frontend portion of this multi-repository application feature:

`<feature>`

Before editing, read the repo `AGENTS.md`, any `AGENTS.override.md`, and these
hub guides:

- `<hub-root>/docs/security/secure-code-preflight.md`
- `<hub-root>/docs/architecture/design-review.md`
- `<hub-root>/docs/review/frontend-review-guidelines.md`
- `<hub-root>/docs/review/codex-review-readiness.md`
- `<hub-root>/docs/review/pr-evidence-packet.md`
- `<hub-root>/docs/templates/validation-evidence.md`

Work only in the frontend repo. Confirm branch and dirty state first. Identify
route, UI state, API client, authorization-display, validation, error handling,
and test impacts. Implement the smallest coherent frontend change, run relevant
checks, and return changed files, commands run, skipped checks, risks, and any
backend or charts contract notes.

Do not commit, push, or open a PR unless the coordinator prompt explicitly says
the user approved that action.

## Charts Thread Prompt

You are implementing the charts portion of this multi-repository application feature:

`<feature>`

Before editing, read the repo `AGENTS.md`, any `AGENTS.override.md`, and these
hub guides:

- `<hub-root>/docs/security/secure-code-preflight.md`
- `<hub-root>/docs/architecture/manifest-architecture.md`
- `<hub-root>/docs/review/charts-review-guidelines.md`
- `<hub-root>/docs/review/codex-review-readiness.md`
- `<hub-root>/docs/review/pr-evidence-packet.md`
- `<hub-root>/docs/templates/validation-evidence.md`

Work only in the charts repo. Confirm branch and dirty state first. Identify
values, templates, rendered manifests, RBAC, network policy, secrets, probes,
resources, image metadata, and rollout impacts. Implement the smallest coherent
chart change, run relevant rendering/lint/security checks, and return changed
files, commands run, skipped checks, risks, and app contract notes.

Do not commit, push, or open a PR unless the coordinator prompt explicitly says
the user approved that action.

