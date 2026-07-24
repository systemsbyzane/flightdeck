# Flightdeck instructions

This repository is a coordination Hub, not a source monorepo. Independent
repositories keep their own Git history and applicable `AGENTS.md` rules.

## Bridge configuration intent

When the user says “configure bridge repos”, “configure repository bridges”,
“set up all repos”, or makes an equivalent request, read
`docs/workflows/configure-bridge-repos.md` completely and follow it end to end.
This is a setup workflow: configure declared checkouts, bridges, and exact
saved projects, emit the ignored per-repository receipt, and do not create
implementation tasks.

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
