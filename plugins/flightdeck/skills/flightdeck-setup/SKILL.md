---
name: flightdeck-setup
description: Generate and validate a portable Flightdeck workspace from the bundled template, including exact-path saved-project registration with separate logical and runtime identities. Use when creating a new Hub, onboarding a team workspace, configuring workload roots or declarative repositories, or checking that a generated Hub is portable and de-branded.
---

# Flightdeck Setup

Before any setup action, read `references/setup-runbook.md` completely and
follow it end to end. The runbook is mandatory, including artifact capability
preflight, validation, project registration verification, and the installed
fresh-task acceptance boundary.

Use `scripts/bootstrap.py --target <absolute-path>` to preview setup, then add
`--apply` when generation is authorized. The bootstrap calls
`scripts/setup_flightdeck.py`, validates the result, and recognizes an existing
valid generated Hub as a validation-only no-op. It refuses unmanaged or
drifting non-empty targets while preserving valid configured topology,
repository declarations, workload payloads, and ignored runtime state. It
provides no merge, repair, or overwrite mode.

Read `references/setup-contract.md` for provider, registration, and portability
requirements. Do not install, publish, share, or activate the plugin unless the
user separately authorizes that action.
