# Architecture Guides

Use these guides before making non-trivial code, chart, infrastructure, or
workflow changes.

- `design-review.md` - review a proposed change before implementation.
- `decision-record-template.md` - capture durable architecture decisions.
- `manifest-architecture.md` - secure architecture guidance for Helm,
  YAML, and rendered Kubernetes manifests.
- [Control plane](control-plane.md) defines the executable Hub registry, task
  lifecycle, routing, security boundaries, validation, and recovery.
- [Control-plane design history](../superpowers/specs/flightdeck-control-plane-design.md)
  records the reusable design rationale.

Keep architecture notes short and tied to the owning repo. The goal is not
ceremony; the goal is to prevent unclear ownership, weak security boundaries,
and changes that cannot be validated.
