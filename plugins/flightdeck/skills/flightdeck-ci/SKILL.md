---
name: flightdeck-ci
description: Coordinate trustworthy CI/CD and software-delivery work through Flightdeck. Use when a user asks about failing or slow checks, pipeline diagnosis, build and test workflows, release automation, artifact provenance, caching, matrices, runners, permissions, secrets, environments, approvals, promotion, rollback, or changing GitHub Actions, GitLab CI, Jenkins, or another delivery system. Natural CI/CD intent should trigger this skill; explicit invocation is optional.
---

# Flightdeck CI/CD

Diagnose or change delivery pipelines with evidence tied to the exact source
revision. Keep inspection, source edits, workflow execution, publication, and
deployment as distinct actions.

## Resolve the surface

1. Determine the repository, provider, pipeline, run, candidate revision, and
   delivery environment involved. Do not assume the latest run matches the
   current checkout.
2. In a generated Hub, read `AGENTS.md` and `docs/workflows/ci-cd.md`, use
   provider metadata only to resolve ownership, and dispatch repository-owned
   diagnosis or implementation before inspecting pipeline source.
3. In the owning project, read applicable repository instructions before
   inspecting workflow definitions, scripts, logs, checks, or artifacts.
4. Use a connected source-control or CI capability for current run evidence
   when available. Reconcile it with the exact workflow revision in the
   repository.

## Infer the requested action

Adapt to the request without requiring a mode selection:

- Status or explanation is read-only.
- Diagnosis traces the first causal failure, not every downstream symptom.
- A requested fix changes the smallest owning source surface and validates it.
- A release or delivery request separates build, publish, promote, deploy, and
  verify gates.

Ask one focused question only when the target or authority changes the action
materially.

## Preserve delivery safety

Check identity and permissions, secret exposure, untrusted inputs, dependency
pinning, caches, concurrency, artifact integrity and provenance, environment
protection, failure behavior, retries, and rollback in proportion to risk.
Avoid unrelated pipeline modernization during a focused fix.

Use `references/delivery-method.md` for deeper diagnosis, change, and
cross-repository delivery work.

## Authorization and result

Read-only inspection and local validation do not authorize rerunning or
cancelling workflows, changing provider settings, publishing artifacts,
promoting releases, deploying, or mutating an environment. Require explicit
authorization for each applicable external action.

Report the exact target and revision, observed cause or implemented source
change, checks run, skipped checks, artifact or environment boundaries, and
residual risk. After Hub dispatch, return the receipt without monitoring.
