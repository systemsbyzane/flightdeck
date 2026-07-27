# Workflows

These workflows keep coordination, repository implementation, external review,
and runtime validation separated.

- [Thread routing](thread-routing.md) chooses the owning Codex project,
  execution mode, and dispatch boundary.
- [Planning](planning.md) creates a right-sized, read-only plan without forcing
  every request through one template.
- [CI/CD and delivery](ci-cd.md) correlates exact source revisions with
  pipeline evidence and separates delivery actions.
- [Platform and environments](platform.md) separates infrastructure source,
  generated plans, applied state, and runtime observations.
- [Plugin lifecycle](plugin-lifecycle.md) separates supported plugin updates
  from generated-Hub migration and protects user-owned state.
- [Repository onboarding](repo-onboarding.md) verifies or acquires an owning
  checkout without inventing provider or branch facts.
- [Configure bridge repositories](configure-bridge-repos.md) plans and applies
  non-destructive instruction bridges and exact saved-project verification.
- [Repository bridges](repo-bridge.md) defines reference, materialized, and
  repo-native bridge behavior.
- [Multi-repository coordination](multirepo-coordination.md) splits one outcome
  across independently owned repositories.
- [Remote validation](remote-validation.md) keeps source authoring local and
  sends only exact revisions or explicit bundles to a configured runtime
  project.
- [Artifacts](artifacts.md) routes Word, PDF, and spreadsheet work through the
  required installed capabilities and visual quality gates.
- [Automations](automations.md) distinguishes disabled Hub specifications from
  real Codex schedules.
- [Operations](operations.md) covers Doctor, task lifecycle, approvals, stable
  findings, and generated state.
- [Weekly image patch review](weekly-image-patch-review.md) turns current scan
  artifacts into a review-first patch queue.

Use the Hub for coordination. Use the owning repository project for code edits,
tests, Git history, and implementation evidence.
