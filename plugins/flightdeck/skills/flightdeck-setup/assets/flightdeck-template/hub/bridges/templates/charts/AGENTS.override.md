# Flightdeck chart and manifest bridge

Hub root: `{{HUB_ROOT}}`
Repository root: `{{REPOSITORY_ROOT}}`
Bridge version: `{{BRIDGE_VERSION}}`
Bridge mode: `{{BRIDGE_MODE}}`

Read `./AGENTS.md` and applicable nested instructions first. Repository rules
own commands and layout; the stricter security and authorization rule wins.

Read:

- `{{HUB_ROOT}}/docs/workflows/operations.md`
- `{{HUB_ROOT}}/docs/architecture/manifest-architecture.md`
- `{{HUB_ROOT}}/docs/security/secure-code-preflight.md`
- `{{HUB_ROOT}}/docs/templates/validation-evidence.md`

Treat templates and YAML as production code. Render and inspect affected
manifests. Review identity, RBAC, networking, secrets, storage, images, pod
security, scheduling, observability, upgrades, and rollback. Shared environment
mutation requires explicit approval.
