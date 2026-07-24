# Repo Bridge AGENTS.md Section

Copy this section into a nested repo `AGENTS.md` after reviewing that repo's
existing instructions.

```md
## Flightdeck Bridge

This repo participates in the local Flightdeck at:

`<hub-root>`

Repo-specific instructions in this `AGENTS.md` remain authoritative for code
layout, commands, tests, coverage, generated files, and implementation rules.
Use the hub docs for cross-repo workflow, design, security posture, validation
evidence, and Codex routing.

If this section is copied into `AGENTS.override.md`, add a startup requirement:
read `./AGENTS.md` completely before implementation, review, or PR-ready claims
because the override can supersede the tracked file during Codex instruction
discovery.

Reference guides:

- `<hub-root>/docs/workflows/thread-routing.md`
- `<hub-root>/docs/architecture/design-review.md`
- `<hub-root>/docs/architecture/manifest-architecture.md`
- `<hub-root>/docs/security/secure-code-preflight.md`
- `<hub-root>/docs/security/threat-model.md`
- `<hub-root>/docs/patching/image-compatibility.md`
- `<hub-root>/docs/templates/task-intake.md`
- `<hub-root>/docs/templates/implementation-plan.md`
- `<hub-root>/docs/templates/pr-readiness.md`
- `<hub-root>/docs/templates/validation-evidence.md`

Minimum bridge checklist for non-trivial work:

- Identify the intended outcome, owning workload, and owning repo before editing.
- Use this repo's `AGENTS.md` for implementation mechanics.
- Use the hub design review guide for architecture, security-sensitive,
  data-model, deployment, workflow, or multi-repo changes.
- Use the hub secure-code preflight before PR-ready claims.
- Keep Local repository changes, Codex worktrees, `remote-validation` discovery, and cluster
  validation in separate threads when work spans those contexts.
- Treat `remote-validation` changes as evidence or patches until they are intentionally
  moved into the local checkout.
- Capture validation evidence with commands, artifacts, and skipped checks.

If the absolute hub path is unavailable, follow the minimum bridge checklist and
the repo-specific rules in this file.
```
