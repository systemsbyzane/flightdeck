# Codex Review Readiness

Use this before requesting GitHub `@codex review` or marking a PR ready.

## Goal

Reduce review churn by catching the high-severity issues Codex is likely to flag
before the PR enters GitHub review.

## Universal Preflight

- Confirm the change is in the repo that owns the behavior.
- Read the repo `AGENTS.md`, especially `Review guidelines`.
- Keep the diff focused and easy to explain.
- Verify security-sensitive behavior at the owning boundary, not only in the UI
  or chart consumer.
- Preserve API, schema, chart value, image, and deployment compatibility unless
  the breaking change is intentional and documented.
- Run the repo-required checks or document why they could not run.
- Prepare a PR evidence packet with commands, results, skipped checks, security
  impact, and rollback notes.

## Review Request Standard

Before `@codex review`, the PR should answer:

- What changed and why?
- What security boundary is affected?
- What compatibility contract might break?
- What tests, scans, renders, or cluster checks prove the behavior?
- What remains unverified?

## Common Sources Of Slow Review

- frontend-only authorization for privileged behavior
- tenant or namespace fallback paths that widen access
- API contract changes without coordinated frontend or chart updates
- migrations without backfill, compatibility, or generated-code updates
- Helm values or rendered manifests that widen RBAC, expose secrets, or change
  immutable selectors
- image patching that changes runtime contracts while only reporting CVE counts
- missing validation evidence or skipped checks without reasons

