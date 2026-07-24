# Patching Review Guidelines

Use these before requesting review on image or dependency patching changes.

## High-Risk Areas

- runtime version, base image family, package manager, and architecture
- entrypoint, command, args, ports, probes, and signal behavior
- UID/GID, writable paths, permissions, and filesystem layout
- installed binaries, plugins, certificates, trust stores, and shell tools
- chart image metadata, product pins, and customer overrides
- before/after vulnerability evidence without runtime validation

## Preflight

- Patch vulnerability risk without accidental product behavior changes.
- Preserve downstream runtime contracts for application, data, analytics,
  machine-learning, and shared platform workloads.
- Keep Dockerfile/base-image changes, chart metadata, product pins, and customer
  overrides in their owning repos.
- Do not change major versions, base image family, runtime version, UID/GID,
  entrypoint, ports, config paths, writable paths, probes, or chart-facing image
  metadata unless a coordinated rollout plan exists.
- Capture before/after scan data, consuming chart/product references, build
  evidence, runtime smoke evidence, skipped checks, and residual risk.
