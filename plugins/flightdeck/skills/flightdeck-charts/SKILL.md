---
name: flightdeck-charts
description: Coordinate Helm, Kubernetes manifest, deployment YAML, and rendered configuration changes through a Flightdeck. Use for chart values, templates, RBAC, networking, secrets, images, storage, probes, scheduling, rendered manifests, or rollout review. CI/CD pipeline files belong to the focused Flightdeck CI/CD skill.
---

# Flightdeck Charts

Treat manifests as production code. Dispatch edits to the owning chart or
deployment repository after reading its instructions.

Use `$flightdeck-platform` for broader infrastructure, platform-service, or
environment coordination. Use this skill for Helm, Kubernetes manifest, and
deployment-configuration source mechanics.

When the requested outcome is primarily live cluster or environment work, use
`$flightdeck-platform` as the lead skill even when a charts repository owns the
task. If execution reveals a database, schema, migration-version, backfill,
locking, or persistence issue, announce and read `$flightdeck-db` before any
database action. Do not preload skills for domains that have not appeared.

Before changing behavior, identify identity and RBAC, networking and TLS,
secrets, storage, images, pod security, scheduling, observability, CRDs and
hooks, upgrades, immutable fields, and rollback.

Preserve stable names, selectors, value contracts, image metadata, and storage
identities unless a breaking rollout is intentional and coordinated. Do not
render plaintext secrets or broaden permissions by default.

Run repo-native lint and schema checks, render affected manifests, and inspect
the output. Use `references/manifest-review.md` for the review checklist.
Deployment and shared cluster mutation require separate explicit approval.
