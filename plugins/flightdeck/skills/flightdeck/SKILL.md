---
name: flightdeck
description: Coordinate portable multi-repository work from a generated Flightdeck using exact-path project verification and separate logical/runtime project identities. Use when a request begins in a Hub, spans projects or environments, needs ownership routing, planning, review, CI/CD, platform, database, STIG, or plugin lifecycle coordination, asks to connect repositories, requires an owning Codex project task, or must preserve explicit approval and no-monitoring boundaries.
---

# Flightdeck

Use the Hub as a coordinator and each owning repository, program workspace, or
environment as the execution surface.

For “set up Flightdeck” or “connect repositories” intent, use
`$flightdeck-setup`; users do not need to invoke the skill by name.
For planning-only intent, use `$flightdeck-plan`. For change, pull-request,
architecture, or readiness review, use `$flightdeck-review`. Natural intent is
enough; explicit skill invocation is optional.
For pipeline and delivery intent, use `$flightdeck-ci`. For infrastructure,
platform-service, or environment intent, use `$flightdeck-platform`.
For database, data-store, schema, query, migration, backup, restore,
replication, or database-performance intent, use `$flightdeck-db`.
For STIG, CKL, applicability, inherited-control, evidence-gap, or
STIG-remediation intent, use `$flightdeck-stig`.
For Flightdeck plugin update, reinstall, preservation, rollback, version, or
patch-note intent, use `$flightdeck-upgrade`. An existing Hub is protected user
state and is never regenerated as part of a plugin upgrade.

## Skill composition

Choose the smallest lead Flightdeck skill that owns the requested outcome,
independent of the owning workload, repository, or bridge profile. Add companion
skills only when their domains are already involved; do not preload speculative
skills.

When dispatching, include the exact lead and currently applicable companion
`$flightdeck-*` names in the child prompt. Re-evaluate when new evidence crosses
domains. Before domain-specific mutation, announce and read the newly applicable
skill without expanding the existing authorization boundary.

## Start

1. Locate the generated Hub by walking upward to `flightdeck.yaml`.
2. Read the Hub `AGENTS.md`, registry, and
   `docs/workflows/thread-routing.md`.
3. Classify the request as coordination, planning, review, CI/CD, platform,
   database, STIG, plugin lifecycle, read-only, implementation, artifact,
   compliance, or runtime validation.
4. Run `bin/flightdeck route plan` with the resolved workload and work type.
5. For repository-owned work, require a verified `bridge_handoff` and include
   it completely in the child prompt.

Read `references/dispatch.md` before creating or resuming a project task.
For initial repository discovery and connection, use `$flightdeck-setup`.
For advanced bridge mode changes, migration, or drift repair, use
`$flightdeck-repo-bridge` and its mandatory
`references/configure-bridge-repos.md` runbook. Do not create implementation
tasks during setup.

## Dispatch Gate

For project-owned work, dispatch before inspecting target code, workbooks,
evidence, or live runtime state. Use Hub policy, registry, routing output, live
project state, and recent task metadata only to resolve the owner.

Search for a matching persistent task in the owning project. Resume it when it
already owns the objective; otherwise create it. Use Local mode for read-only
or intentional current-checkout work, Worktree mode for isolated repository
implementation, and a matching remote project for durable runtime validation.
The child reads active-checkout repository instructions first. If an ignored
reference or materialized bridge is absent in a Worktree, it verifies and reads
the handoff paths from the original checkout; it does not copy them into the
Worktree. A repo-native bridge remains tracked and is read in place.

After a successful create or resume response, return the logical project key,
opaque runtime project ID, task ID, mode, and authorization boundary
immediately. Do not read, wait for, poll, or monitor the child task.
Consolidate only after a later explicit user request.

## Project Registration

If a checkout exists but is not saved, detect available capabilities:

1. Use a native project-registration tool when available.
2. Otherwise use the supported operating-system or Codex UI open-folder
   mechanism.
3. Refresh the live project list, verify the exact normalized real path, and
   capture its opaque runtime project ID before dispatch. A display-name match
   is never sufficient, and the logical project key is never a runtime ID.
4. Retry registration once after refreshing state.
5. After a verified second failure, return one exact manual action and a
   self-contained handoff. Never perform owner work in the Hub as fallback.

For a missing checkout, resolve provider, ownership, remote URL, and default
branch; clone under the configured workload root; verify remotes, branch, SHA,
and clean state; install the selected bridge without overwriting instructions;
update the local registry; register and verify the project; then dispatch.

## Authorization

Require explicit approval for commit, push, pull requests or comments,
publication, deployment, shared environment mutation, external communication,
compliance submission, risk acceptance, and closure claims. Never place
credentials or sensitive evidence in Hub state or task prompts.

Use the specialized bundled skill for planning, review, CI/CD, platform,
database, development, charts, patching, research, artifacts, compliance,
STIG, setup, Doctor, repo-bridge, or plugin-upgrade work.
