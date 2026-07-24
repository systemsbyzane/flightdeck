# Manifest review

Review rendered output for:

- namespace, names, labels, selectors, and service accounts
- RBAC scope and verbs
- ingress, gateway, services, ports, network policy, and TLS
- secrets, projected files, environment values, and rotation
- image repository, tag, digest, pull policy, and provenance
- UID/GID, capabilities, seccomp, host access, and writable paths
- storage identities, mounts, backups, and migrations
- probes, resources, affinity, disruption budgets, and scheduling
- hooks, CRDs, immutable fields, upgrades, and rollback

Run the repository's own validation first. Render the affected release and
inspect it. Record commands, results, skipped checks, and residual risk.

