# Charts Review Guidelines

Use these before requesting review on Helm, YAML, GitHub workflow YAML, or
rendered Kubernetes manifest changes.

## High-Risk Areas

- RBAC, ServiceAccounts, namespaces, labels, and selectors
- Ingress, Gateway, Services, ports, TLS, and NetworkPolicy
- Secrets, ExternalSecrets, projected files, env vars, and SOPS material
- image repository, tag, digest, pull policy, and image metadata
- pod security context, capabilities, host access, and writable filesystems
- PVCs, volume mounts, storage classes, backups, and migrations
- CRDs, hooks, immutable fields, and upgrade or rollback behavior
- GitHub Actions permissions, secrets, artifacts, and release automation

## Preflight

- Treat manifests as production code.
- Keep chart behavior, defaults, values, templates, and image metadata in
  `the owning charts repository`.
- Do not widen RBAC, expose secrets, change selectors, rename resources, or
  change immutable fields unless intentional and documented.
- Preserve backwards-compatible values unless a breaking rollout is explicitly
  coordinated.
- Render affected charts and inspect output when template behavior changes.
- Run `make validate`, Checkov-relevant local checks when available, and
  `actionlint` after workflow edits, or document skipped checks.
- Capture rendered manifest evidence for security-sensitive fields.

