# Flightdeck instructions

This repository is a coordination Hub, not a source monorepo. Independent
repositories keep their own Git history and applicable `AGENTS.md` rules.

## Repository connection intent

When the user asks to connect repositories, run `setup plan` against the
authorized root, then the explicit `setup connect` apply. Existing checkouts
stay in place; portable declarations omit attached absolute paths; safe local
reference bridges are automatic. Do not create implementation tasks.

For advanced bridge mode changes, migration, manually declared sets, or drift
repair, read `docs/workflows/configure-bridge-repos.md` completely and follow it
end to end.

## Coordinator boundary

- Start ambiguous, cross-project, security-sensitive, artifact, compliance, or
  runtime-validation work here.
- Resolve the owning repository, program workspace, or environment.
- For project-owned work, create or resume a persistent task in the owning
  Codex project before inspecting target code, workbooks, evidence, or live
  state.
- Return the logical project key, opaque runtime project ID, task ID, mode, and
  authorization boundary immediately after dispatch. Do not poll, wait, read,
  or monitor the child task.
- Read child results only after a later explicit request to consolidate or
  coordinate follow-up.

## Planning and review intent

- A natural-language planning-only request is read-only by default. Use
  `docs/workflows/planning.md`; do not edit files or create tasks merely to fill
  a plan template.
- In the Hub, plan ownership and sequence from registry and routing evidence.
  Do not inspect owner code. Dispatch a read-only owner investigation only when
  the user also asks Flightdeck to have that owner investigate or proceed.
- A natural-language review request uses `docs/review/change-review.md`.
  Resolve and dispatch every repository review to its owning project before
  code analysis, return the receipt, and stop without monitoring.
- Review leads with actionable findings and remains read-only unless the user
  separately asks for fixes.

## CI/CD and platform intent

- Natural pipeline, check, build, release, or delivery intent uses
  `docs/workflows/ci-cd.md`. Correlate provider evidence with the exact source
  revision and dispatch repository-owned diagnosis or source changes before
  inspecting pipeline code.
- Natural infrastructure, cloud, cluster, platform-service, or environment
  intent uses `docs/workflows/platform.md`. Keep source ownership and live
  environment ownership distinct.
- Pipeline reruns, cancellations, provider setting changes, publication,
  promotion, deployment, infrastructure apply, restarts, secret rotation, data
  changes, and every other shared-environment write require explicit
  authorization.
- A plan, render, or green source check does not prove publication, apply,
  rollout, or runtime success.

## STIG intent

- Natural STIG, CKL, checklist, evidence-gap, applicability, inherited-control,
  or STIG-remediation intent uses `docs/compliance/stig-evaluation.md`; users do
  not need to name a skill or complete a fixed intake form.
- Keep quick evaluations flexible. Ask only for context that blocks an honest
  status, and return `Not Reviewed` with explicit gaps when evidence remains
  inconclusive.
- Decide applicability before status. Notes and declared controls are not
  evidence; inherited controls require a verified boundary, responsible party,
  and authoritative source.
- Use draft readiness while evidence is developing and export readiness only
  for a requested final checklist or evidence package. A generated CKL does not
  prove compliance or authorize submission.
- Dispatch repository, program, CI/CD, platform, or environment-owned
  inspection before analysis. Route remediation to the owner and preserve
  source-change, pipeline, deployment, environment, submission, risk, and
  closure approval boundaries.

## Flightdeck plugin lifecycle

- Natural Flightdeck update, reinstall, version, rollback, preservation, or
  patch-note intent uses the installed `$flightdeck-upgrade` skill.
- Treat this generated Hub, ignored local state, attached repositories, tasks,
  evidence, and credentials as protected user state.
- Plugin upgrade must not run setup, bootstrap, bridge installation, or Hub
  migration. Existing Hubs remain on their generated template version.
- Patch notes and preflight are read-only. Marketplace refresh, plugin
  reinstall, and rollback require explicit authorization.
- After a verified upgrade, start a fresh Codex task before claiming new skill
  definitions are loaded.

## Child project rules

The child reads every applicable repository `AGENTS.md` in its active checkout
before work, then the verified Hub bridge. Every repository dispatch prompt
must include the complete `bridge_handoff` from `route plan`. When an ignored
reference or materialized bridge is absent in a Codex Worktree, the child
verifies its digests and reads it from the original checkout recorded in the
handoff; it never copies the bridge into the Worktree. Repository rules own
layout, commands, tests, and implementation mechanics. The stricter security
and authorization rule wins.

Use Local mode for read-only or intentional current-checkout work, Worktree
mode for isolated implementation, and a matching remote project for durable
runtime validation.

If an existing checkout is not saved, use native registration when available;
otherwise use the supported Codex or operating-system open-folder mechanism.
Refresh the live project list and verify the exact path. Capture the opaque
runtime project ID only from that match; never substitute the stable logical
key or accept a display name. Retry once after a refresh, then return one exact
manual action if registration still fails.

## Approval boundaries

An implementation request authorizes edits and non-destructive local checks in
the resolved owning project. Require explicit authorization for commit, push,
pull request or comment, package or registry publication, deployment, shared
environment mutation, external communication, compliance submission, risk
acceptance, and closure claims.

Never place credentials, tokens, private keys, controlled evidence, or
customer-sensitive material in Hub task state, prompts, reports, tests, or Git
history.

## Control plane

Use `bin/flightdeck doctor --json`, `status`, `route plan`, `repo plan`, and
`bridge plan` for read-only inspection. Use `bridge plan --all` before the
explicit state-changing `bridge install --all`. State-changing commands have
explicit names and may not overwrite existing tasks or instructions.

Read `docs/architecture/control-plane.md` and
`docs/workflows/operations.md` before changing the Hub itself.
