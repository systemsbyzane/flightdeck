---
name: flightdeck-development
description: Coordinate secure application and multi-repository implementation through a Flightdeck. Use when a user wants to build or change features, fix bugs, implement backend or frontend behavior, modify APIs or data, coordinate cross-repository contracts, or hand off runtime validation. Planning-only and review-only requests belong to the focused Flightdeck plan and review skills.
---

# Flightdeck Development

Dispatch each implementation unit to the repository that owns it. Every child
must read applicable repo instructions and the installed Hub bridge before
editing.

Use `$flightdeck-plan` when the user wants a plan without implementation. Use
`$flightdeck-review` when the user wants findings without fixes.
Use `$flightdeck-ci` for delivery pipelines and `$flightdeck-platform` for
infrastructure or environment ownership.

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
