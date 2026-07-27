---
name: flightdeck-setup
description: Generate and validate a portable Flightdeck, discover and connect existing local Git repositories in place, install safe reference bridges, and verify exact-path saved projects. Use when a user asks to set up Flightdeck, set up Flightdeck for repositories under a folder, connect repositories, onboard a team workspace, or validate a generated Hub.
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

When the request identifies a repositories root, pass
`--repositories-root <absolute-path>` to both preview and apply. Setup then
discovers Git roots, records portable declarations, keeps exact attached paths
in ignored local state, and installs safe `reference` bridges automatically.
The setup request authorizes those ordinary local writes. It does not authorize
tracked changes inside an attached repository, `repo-native` bridges, project
tasks, commits, remotes, publication, deployment, or external communication.

If no repositories root is named, finish and validate the core Hub, then ask
one question: which folder contains the repositories to connect? Users do not
need to name this skill, edit YAML, or ask separately for bridge setup.

Read `references/setup-contract.md` for provider, registration, and portability
requirements. Do not install, publish, share, or activate the plugin unless the
user separately authorizes that action.
