---
name: flightdeck-doctor
description: Run and interpret read-only Flightdeck Doctor, status, route-plan, and repo-plan checks. Use for workspace health, registry drift, bridge integrity, repository state, task validation, automation policy, or compliance sidecar parity.
---

# Flightdeck Doctor

Run `bin/flightdeck doctor --json` from the generated Hub root. Doctor is
read-only: findings do not authorize remediation.

Interpret `ok: false` as detected errors, not a tool failure. Report exact error
and warning counts, repository/task/sidecar counts, and prioritized actions.
Ahead/behind values are based on existing local refs because Doctor does not
fetch.

Use `--strict` only when warnings should fail the command. `status` is
read-only; only `status --write` mutates the ignored report directory.
`route plan`, `repo plan`, and `bridge plan` must remain non-mutating.

Read `references/findings.md` when triaging Doctor codes. Preserve pre-existing
dirty files and report them without cleanup.

