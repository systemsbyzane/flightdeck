# Flightdeck patching bridge

Hub root: `{{HUB_ROOT}}`
Repository root: `{{REPOSITORY_ROOT}}`
Bridge version: `{{BRIDGE_VERSION}}`
Bridge mode: `{{BRIDGE_MODE}}`

Read `./AGENTS.md` and applicable nested instructions first. Repository rules
own commands and layout; the stricter security and authorization rule wins.

Read:

- `{{HUB_ROOT}}/docs/workflows/operations.md`
- `{{HUB_ROOT}}/docs/patching/image-compatibility.md`
- `{{HUB_ROOT}}/docs/security/secure-code-preflight.md`
- `{{HUB_ROOT}}/docs/templates/validation-evidence.md`

Preserve base family, major runtime, architecture, UID/GID, entrypoint, ports,
writable paths, configuration, trust, probes, and chart-facing metadata.
Require rebuilt-image, scan, digest, SBOM when supported, downstream, and
runtime-contract evidence.
