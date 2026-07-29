---
name: flightdeck-platform
description: Coordinate platform engineering and environment work through Flightdeck. Use when a user asks about infrastructure as code, Terraform or OpenTofu, Pulumi, cloud resources, Kubernetes clusters, SSH or remote-host operations, kind, kubectl, live deployments, platform services, identity, networking, DNS, certificates, secrets, storage, backups, observability, reliability, capacity, upgrades, environment drift, runtime validation, or operational change. Natural platform intent should trigger this skill; explicit invocation is optional.
---

# Flightdeck Platform

Coordinate platform source, live state, and runtime validation without
conflating them. Keep the method adaptive so a focused question does not inherit
an unnecessary infrastructure checklist.

## Resolve ownership and context

1. Identify the owning layer: infrastructure source, chart or manifest,
   application contract, platform service, environment configuration, or live
   runtime.
2. In a generated Hub, read `AGENTS.md`,
   `docs/workflows/platform.md`, and routing policy. Dispatch repository-owned
   source analysis before inspecting that source.
3. Perform source edits in the owning repository. Use `$flightdeck-charts` for
   Helm or Kubernetes manifest mechanics.
4. Perform durable live inspection or validation in the matching environment
   project. Record the exact account, project, subscription, region, cluster,
   namespace, and revision that are actually observed.

If runtime evidence reveals a database, schema, migration-version, backfill,
locking, or persistence issue, announce and read `$flightdeck-db` before any
database action. Do not preload it for routine platform work, and do not treat
the handoff as new authorization.

## Adapt the method

Infer whether the user wants design, diagnosis, implementation, validation, or
an operational action. For planning-only or review-only intent, combine this
domain guidance with `$flightdeck-plan` or `$flightdeck-review`.

Evaluate only the relevant risk surfaces: identity and least privilege, state
and locking, secrets, network exposure, data and storage, availability,
capacity and cost, observability, dependencies, upgrades, blast radius,
rollout, rollback, and recovery.

Use `references/platform-method.md` for cross-layer changes, infrastructure
plans, drift, and live validation.

## Evidence and mutation gates

Tie proposed or implemented source changes to exact plans, renders, policy
checks, tests, or diffs. Keep declared configuration, generated plan, applied
state, and observed runtime state distinct. A successful plan or render is not
evidence that a change was applied.

Read-only inspection does not authorize applying infrastructure, changing
provider or cluster settings, rotating secrets, modifying data, restarting
workloads, deploying, or otherwise mutating a shared environment. Require
explicit authorization for each environment write and record rollback or
restoration evidence.

Return owners, contexts, evidence, changes or findings, validation gaps, blast
radius, rollback, and residual risk. After Hub dispatch, return the receipt
without monitoring.
