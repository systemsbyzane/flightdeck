---
name: flightdeck-development
description: Coordinate secure application and multi-repository development through a Flightdeck. Use for features, bugs, backend or frontend work, API or data changes, review readiness, cross-repo contracts, or runtime validation handoffs.
---

# Flightdeck Development

Dispatch each implementation unit to the repository that owns it. Every child
must read applicable repo instructions and the installed Hub bridge before
editing.

Before implementation, record outcome, owner, non-goals, trust boundaries,
contracts, migrations, compatibility, validation, and rollback. Backend or
service-side authorization is the enforcement boundary; client visibility
checks do not replace it.

For multi-repo work, create one persistent task per repository that owns a
change. Reconcile API types, identity and scope, errors, configuration,
migrations, image metadata, and tests only after the user later asks the Hub to
consolidate results.

Use `references/development-gates.md` for design, secure-code, test, review, and
evidence checks. Commits, pushes, pull requests, reviews, deployments, and
shared-environment changes remain explicit gates.

