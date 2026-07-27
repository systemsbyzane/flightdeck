# CI/CD and delivery

Ask about checks, pipelines, builds, releases, or delivery in natural language.
Users do not need to name a skill or select a workflow mode.

## Exact evidence

Identify the repository, provider, pipeline, run, candidate SHA, and delivery
environment. Correlate current provider evidence with the workflow definition
at that exact revision; the latest run and current checkout may differ.

From the Hub, use provider metadata only to resolve ownership, then dispatch
repository-owned diagnosis or implementation before inspecting pipeline
source. Return the receipt without monitoring.

## Adaptive action

- Status and explanation are read-only.
- Diagnosis finds the first causal failure rather than listing downstream
  symptoms.
- A requested fix changes the smallest owning source surface and validates it.
- Delivery separates build, publish, promote, deploy, and verify.

Check permissions, secrets, untrusted inputs, dependencies, caches,
concurrency, artifact integrity, provenance, environment protection, failure
behavior, and rollback only as the risk requires.

Read-only inspection and local validation do not authorize rerun, cancel,
provider setting changes, publication, promotion, deployment, or environment
mutation. Each external action requires explicit authorization.
