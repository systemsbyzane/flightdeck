---
name: flightdeck-patching
description: Coordinate vulnerability, dependency, base-image, and container-image patching while preserving downstream runtime contracts. Use for CVEs, SBOMs, scans, image ownership, rebuilds, tags or digests, or patch review queues.
---

# Flightdeck Patching

Resolve image ownership before cloning or editing. If the organization only
consumes an upstream image, route the tag or digest change to its actual
consumer instead of inventing source ownership.

Preserve base family, major runtime, architecture, UID/GID, entrypoint, signal
behavior, ports, writable paths, configuration, probes, certificates, plugins,
and chart-facing metadata unless a breaking change is explicitly coordinated.

Prefer the smallest compatible patch. Require before and after scan evidence,
build result, immutable digest, SBOM when supported, downstream consumer trace,
focused tests, runtime smoke evidence when needed, skipped checks, and residual
findings.

Read `references/compatibility.md`. Dispatch the owning implementation task and
stop without monitoring. Builds may be in scope for an implementation request;
commit, push, publication, pull request, deployment, and risk acceptance remain
separate gates.

