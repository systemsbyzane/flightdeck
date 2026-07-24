# Flightdeck environment bridge

Hub root: `{{HUB_ROOT}}`
Repository root: `{{REPOSITORY_ROOT}}`
Bridge version: `{{BRIDGE_VERSION}}`
Bridge mode: `{{BRIDGE_MODE}}`

Read `./AGENTS.md` and applicable nested instructions first. Repository rules
own commands and layout; the stricter security and authorization rule wins.

Read:

- `{{HUB_ROOT}}/docs/workflows/operations.md`
- `{{HUB_ROOT}}/docs/workflows/remote-validation.md`
- `{{HUB_ROOT}}/docs/security/secure-code-preflight.md`
- `{{HUB_ROOT}}/docs/templates/validation-evidence.md`

Keep desired-state source separate from live observations. Record exact source
refs and environment context. Use read-only inspection by default and never
copy credentials or secret values into Hub state.
