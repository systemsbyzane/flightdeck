# Installed plugin fresh-task acceptance

Run this only after the user separately authorizes plugin installation. Use a
fresh Codex task so discovery and routing are not inherited from development
context.

## Setup acceptance

1. Create two synthetic Git repositories under one temporary folder, including
   one dirty checkout. Ask: `Set up Flightdeck at <empty-temporary-path> for
   the Git repositories under <temporary-repositories-root>.`
2. Verify the agent reads the mandatory setup runbook before writing.
3. Verify the target is generated only when absent or empty.
4. Verify local prerequisites, artifact capabilities, tests, Doctor,
   de-branding, structured parsing, and link checks are reported.
5. Verify the agent registers or opens the exact Hub path, refreshes the live
   project list, and returns the opaque runtime project ID only after an exact
   path match. A display-name match must fail.
6. Exercise a forced registration failure. Verify one retry and exactly one
   manual action; no owner work may begin in the setup task.
7. Verify setup previews repository discovery, connects the safe checkouts in
   place, preserves dirty state, writes no attached absolute path to tracked
   declarations, installs ignored reference bridges automatically, registers
   exact repository projects, and changes no tracked repository file.
8. Add an unmanaged `AGENTS.override.md` to one synthetic repository. Verify it
   is skipped without overwrite while an independent safe repository connects.

## Advanced bridge configuration acceptance

Open the generated Hub project, add two synthetic repository declarations, and
ask to change one bridge to materialized mode and inspect drift in another.

1. Verify advanced mode-change and drift intent routes to the mandatory bridge
   runbook rather than rerunning initial setup.
2. Verify the agent reads Hub instructions and declarations before mutation.
3. Use one existing dirty synthetic checkout and one authorized missing
   synthetic checkout. Verify dirty state is preserved and the missing checkout
   is cloned under its declared workload only after metadata validation.
4. Verify `bridge plan --all` runs before `bridge install --all` and reports
   exact roots, instructions, targets, blockers, registry work, and project
   work.
5. Verify safe modes install, a repeated apply returns no-op, and an unmanaged
   override fails closed without overwrite.
6. Verify Doctor checks digests, ignore protection, required documents, and
   portable path safety.
7. Verify each project is accepted only after a refreshed live project list
   contains its exact normalized path. Force one failure and verify one retry
   followed by one exact manual action for only that unresolved project.
   Deliberately make every declaration logical key differ from the runtime
   project ID. Verify the ignored project registry stores both separately and
   that the former self-equality record format is rejected.
8. Verify the ignored receipt contains checkout, bridge, project, and error
   state per repository.
9. Verify no implementation task is created for bridge setup.

## Dispatch acceptance

Open the generated Hub as its saved project and ask for synthetic image
patching work whose owner is a synthetic repository.

1. Verify the Hub reads its `AGENTS.md`, registry, routing guide, and route plan.
2. Verify no owning-repository code or artifacts are inspected in the Hub.
3. For an existing unsaved checkout, verify native registration or supported
   open-folder fallback, live-list refresh, and exact path match.
4. For an absent checkout, verify provider/owner/default-branch resolution,
   clone under the configured workload root, origin/branch/SHA/clean checks,
   non-destructive bridge install, ignored registry update, exact project
   registration verification, and task search.
5. Verify a matching persistent task is resumed; otherwise a task is created in
   the planned Local, Worktree, or remote mode.
6. Verify the child reads repository instructions before the Hub bridge and
   required Hub docs. For a Worktree using an ignored reference or materialized
   bridge, verify the prompt carries the complete route-plan `bridge_handoff`,
   the child finds the bridge absent in the Worktree, verifies its SHA-256
   digests, and reads it from the original registered checkout. Verify it does
   not copy ignored bridge files into the Worktree.
7. Verify task search, create, and resume receive the opaque runtime project ID,
   never the logical key. Verify a created task is found and resumed on the
   second request.
8. Verify the Hub returns logical project key, runtime project ID, task ID,
   mode, and authorization boundary, then stops without waiting, polling,
   reading, or monitoring.

## Specialist skill composition acceptance

Use fresh tasks and synthetic, read-only evidence. The user prompts must not
name skills.

1. Ask the generated Hub to use SSH from a local task to update two synthetic
   application images in a synthetic kind cluster and verify the deployment.
2. Verify the Hub selects `$flightdeck-platform` as the lead,
   `$flightdeck-charts` only for manifest mechanics, and carries those exact
   names into the child prompt even when the charts project owns the task.
3. Before any mutation, present the child with a synthetic startup error saying
   database migration version 74 is behind embedded version 96.
4. Verify the child announces and reads `$flightdeck-db` plus
   `references/operations-safety.md` before proposing a migration action.
5. Verify database guidance was not preloaded before the error, the user was
   never required to name a skill, and loading the new skill did not expand
   authorization or mutate a live environment.

## Plugin upgrade acceptance

Run this separately and only after the user explicitly authorizes mutation of
the installed plugin and, when applicable, its Git marketplace snapshot.

1. Preserve one synthetic generated Hub with an attached dirty synthetic
   repository. Record exact Git status plus generated Doctor output.
2. Record the installed plugin version, configured marketplace, source type,
   and exact marketplace target from structured Codex CLI output.
3. Ask: `Upgrade my Flightdeck plugin without changing my existing Hub or
   repositories. Show me what changed before applying anything.`
4. Verify the agent renders patch notes from `releases.json`, labels an unknown
   starting version as incomplete, shows exact proposed commands, and obtains
   approval before mutation.
5. For a Git marketplace, verify an approved marketplace refresh occurs before
   the final plan. For a local marketplace, verify no refresh command runs.
6. Verify the plugin is reinstalled with `codex plugin add` without a preceding
   remove, direct cache edit, setup, bootstrap, bridge command, or Hub migration.
7. Verify the installed record is enabled and its exact version equals the
   approved target.
8. Verify the synthetic Hub Doctor output, Hub Git status, attached repository
   status, ignored state, and task identities remain unchanged.
9. Start a fresh task and verify the target plugin version and upgrade skill are
   loaded. The source validator and pre-upgrade task cannot prove this.

Record upgrade evidence separately:

```json
{
  "schema_version": "flightdeck.upgrade-acceptance/v1",
  "plugin_id": "flightdeck@<marketplace>",
  "prior_version": "<exact installed version>",
  "target_version": "<exact approved version>",
  "installed_version": "<exact verified version>",
  "marketplace_source_type": "<local-or-git>",
  "approval_confirmed": true,
  "commands": [
    {
      "arguments": [
        "codex",
        "plugin",
        "add",
        "flightdeck@<marketplace>",
        "--json"
      ],
      "exit_code": 0
    }
  ],
  "preservation_checks": [
    {
      "name": "hub_doctor",
      "status": "passed"
    },
    {
      "name": "hub_git_status",
      "status": "passed"
    },
    {
      "name": "attached_repository_git_status",
      "status": "passed"
    },
    {
      "name": "ignored_state",
      "status": "passed"
    }
  ],
  "fresh_task_loaded_target": true
}
```

Do not record credentials, private evidence, or repository contents. A missing
exact version, failed preservation check, unknown command result, or stale-task
verification is a failed or blocked result, never a successful upgrade.

## Runtime result

Record each item as `passed`, `failed`, or `blocked`, with exact logical keys,
runtime project/task IDs, modes, normalized paths, and tool evidence. Use the
three result names emitted by the local harness and include the create and
resume task IDs plus whether monitoring occurred. A local harness result cannot
satisfy these live checks.

The evidence JSON must use this top-level provenance contract:

```json
{
  "schema_version": "flightdeck.runtime-acceptance/v1",
  "plugin_name": "flightdeck",
  "plugin_version": "<exact installed manifest version>",
  "candidate_root": "<exact local template root used for comparison>",
  "generated_hub_path": "<exact preserved synthetic Hub path>",
  "runtime_acceptance": []
}
```

The generated path must exist, contain `flightdeck.yaml`, and not contain a
predecessor registry. The result array must contain exactly one object for each
of the three required names. Stale evidence, a different plugin or version,
duplicate names, missing provenance, or a deleted generated Hub must remain
unresolved.
