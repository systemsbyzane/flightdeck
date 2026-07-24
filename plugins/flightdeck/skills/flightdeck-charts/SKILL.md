---
name: flightdeck-charts
description: Coordinate Helm, Kubernetes manifest, YAML, deployment, and workflow changes through a Flightdeck. Use for chart values, templates, RBAC, networking, secrets, images, storage, probes, scheduling, rendered manifests, or rollout review.
---

# Flightdeck Charts

Treat manifests as production code. Dispatch edits to the owning chart or
deployment repository after reading its instructions.

Before changing behavior, identify identity and RBAC, networking and TLS,
secrets, storage, images, pod security, scheduling, observability, CRDs and
hooks, upgrades, immutable fields, and rollback.

Preserve stable names, selectors, value contracts, image metadata, and storage
identities unless a breaking rollout is intentional and coordinated. Do not
render plaintext secrets or broaden permissions by default.

Run repo-native lint and schema checks, render affected manifests, and inspect
the output. Use `references/manifest-review.md` for the review checklist.
Deployment and shared cluster mutation require separate explicit approval.

