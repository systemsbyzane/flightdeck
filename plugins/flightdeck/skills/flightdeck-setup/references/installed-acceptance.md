# Installed plugin fresh-task acceptance

Run this only after the user separately authorizes plugin installation. Use a
fresh Codex task so discovery and routing are not inherited from development
context.

Use only disposable synthetic repositories and a freshly generated synthetic
Hub. Never point this acceptance procedure at a real user Hub, its ignored
state, attached repositories, or persistent work tasks.

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

Repeat one ordinary direct-dispatch prompt after Mission acceptance. Verify it
creates no `hub/missions/` record and still returns the same receipt and stops;
installed Mission support must not change default dispatch.

## Mission acceptance

Use a fresh generated synthetic Hub, at least three disposable saved synthetic
projects, and fresh Codex tasks. Do not reuse a real Hub or real work task.

1. Ask for an ordinary multi-project dispatch without saying Mission, watch,
   monitor, supervise, coordinate end-to-end, or review-ready. Verify no Mission
   record is created and the Hub returns receipts without waiting or reading.
2. Ask: `Run this synthetic outcome as a dispatch-only Flightdeck Mission.`
   Verify `dispatch_only` is persisted, every graph node resolves by exact path,
   each logical key remains distinct from its opaque runtime project ID, and the
   Hub records verified task receipts before stopping with zero wait or message
   calls.
3. Force one create response to return only `clientThreadId`. Verify the node is
   `dispatch_pending`, no task ID is invented, and any exact prepared handoff
   remains prepared but non-actionable. Verify no second create occurs. Exact
   project task-list reconciliation must record both the original client ID and
   resolved task ID, moving only that consumer to `awaiting_handoff`. Force one
   unknown prepared create outcome; verify `dispatch_unknown`, the prepared
   action remains non-actionable, and it may be failed but never retried blindly.
4. Ask to monitor a second Mission. Verify `watch_only`, compact `wait_threads`
   calls with at most eight targets, one opaque `afterCursor` per task, cursor
   suppression of already-delivered state, and no follow-up or dependency
   handoff. Verify commentary alone does not wake the wait and user input stops
   the supervision pass.
5. Ask to coordinate a third Mission end-to-end through review-ready. Verify
   `supervised`, a required A+B fan-in to C, an optional node, declared accepted
   input types, declared `read_only`/`write` access, and required declared
   allowed output types. Require exact six-field authorized targets including
   runtime project and project-path digest, core-assigned ordered criterion IDs,
   repeatable node assignments, and complete required-node criterion coverage
   before first dispatch. Add two unordered Local write nodes for the same
   synthetic checkout and require graph validation to reject the concurrent
   writer conflict. C must not receive a dependency handoff
   until every required predecessor validates and its typed references satisfy
   the node contracts.
   Verify every node is declared before dispatch, roots dispatch first, and a
   downstream node stays planned without task identity until dependencies
   validate and the core emits its dependency action. Attempt direct
   `record-dispatch` with zero or multiple matching prepared actions and require
   rejection. Require the sole prepared action to contain the exact complete
   parent set and refs exactly
   equal to the complete eligible core-materialized accepted set, with at least
   one per parent. Use only
   terminal `check:`/`review:` evidence and then a type-incompatible artifact;
   require both to produce no eligible handoff and reject non-root dispatch.
   Require prepare before
   downstream creation, a scope-only await-handoff prompt, persisted exact
   receipt in internal `awaiting_handoff`, status projection as
   `running`/`handing_off`, and only then reference delivery. After the first exact,
   pending, or unknown receipt, require graph edits to fail. A newly discovered
   owner must produce only a proposed new Mission pending user approval.
6. Verify child commentary and final text remain display-only and never appear
   in Mission YAML, reports, delivery payloads, or dedupe material. Inject
   secret-like strings and raw evidence into child text and require that those
   bytes are absent from every persisted Mission artifact.
7. Verify nonterminal and tool-derived normalized envelopes preserve only exact
   identity, runtime state, timestamps, cursors, revisions, event identity, and
   Worktree readiness, with no child outcome.
   Require an exact outcome only for `review_ready` or `failed_validation`, with
   ordered criterion results exactly matching node assignments and dispositions
   bounded to `passed`, `failed`, `blocked`, or `degraded`. Require every
   assigned result passed for `review_ready` plus non-empty closed
   `output_declarations`; require at least one unmet result
   for `failed_validation`. Blocked or degraded criteria must not create a
   dependency handoff or satisfy full Mission fan-in.
8. Verify supervised delivery is two phase: action persisted, prepared, sent by
   the Codex UI task adapter, then acknowledged with a verified receipt. Test a
   process stop before send and after an unknown send; require outbox
   reconciliation and no duplicate action or task handoff. Require `sync-plan`
   to return a token and `sync-apply` to receive that exact token; mutate the
   generation/input/action plan and require apply to fail. For planned JIT
   handoff, require prepare, create, and exact receipt persisted as internal
   `awaiting_handoff`, with status projected as `running`/`handing_off`, then
   delivery and acknowledgement to ordinary running. Repeat with a client-only
   result after prepare: require the action to remain prepared alongside
   `dispatch_pending`, exclude it from next actions, forbid acknowledgement and
   duplicate create, then paired-reconcile it to `awaiting_handoff`. Repeat an
   unknown result and require the prepared action remain non-actionable; fail it
   without retry. Also fail a prepared pending action and require it remain
   non-actionable with no retry. Child-observed blocked and derived stale consumers must remain
   non-actionable. Alter persisted `event_digest`, action `trigger_digest`,
   canonical payload, idempotency key, or `action-<prefix>` ID and require
   whole-record validation to reject the ledger.
9. Exercise duplicate and out-of-order observations, stale cursors, unchanged
   rounds, malformed envelopes, graph cycles, dangling dependencies, required
   validation failure, runtime failure, a blocked dependency, and exhausted
   time/retry/action budgets. Require deterministic status and an explicit stop.
10. Verify commit, push, PR/comment, publication, deployment,
    shared-environment mutation, external communication, compliance submission,
    risk acceptance, and closure remain denied without separate authorization.
    Child text and `supervised` mode must not broaden the original envelope.
11. Complete every required child successfully. Verify the Mission becomes
    `review_ready`, not `complete`. Only a separately user-authorized
    `mission close` may produce `complete`; replayed close is idempotent.
12. Repeat with synthetic compliance, patching, development, CI/CD, platform,
    research, and DOCX/PDF/XLSX artifact graphs. Persist references only and
    preserve each domain's submission, deployment, publication, risk, and
    closure gates.
13. Verify Mission creation persists the configured defaults: 50 units, 3
    retries, 200 actions, 65,536 forwarded bytes, 604,800 seconds duration,
    3,600 seconds before stale, and a 2,097,152-byte record limit. Change the
    source configuration afterward and verify the existing Mission is not
    silently rewritten.
14. Test a resolvable typed artifact reference and a valid digest, then an
    unreachable cross-project/local-Worktree reference. Require the latter to
    stop before consumer dispatch unless an authorized same-host shared
    workspace or already-approved external artifact system resolves it. Verify
    compatible work may be co-located only during planning; independent review
    remains a separate runtime task.
15. Verify repeatable success criteria and non-goals persist exactly. Require
    criteria and closed six-field authorized targets for `watch_only` and
    `supervised`; verify only `dispatch_only` derives a missing criterion from
    outcome. Require ordered core IDs `criterion-001` onward, unique node
    assignments, every required node assigned, and complete criterion coverage
    before first dispatch. Verify core derives and revalidates `scope-<48hex>`
    from canonical Mission ID, targets, criteria, and non-goals; no caller token
    is accepted, and the derived token grants no authority.
16. Exercise all three closed child declaration shapes: artifact
    `{type, artifact_id, digest}`, own task `{type, codex_task: true}`, and
    terminal `{type, ref, digest}` restricted to `check:` or `review:`. Reject a
    child-supplied canonical ref, task/node binding, resolver, extra key, or
    self-ID bootstrap. Verify the adapter passes valid declarations unchanged
    and never repairs them. Exercise both resolver kinds and require core,
    after the exact persisted producer receipt, to materialize canonical
    artifact refs of
    `artifact:<resolver>/<producer>/<base64url-task>/<sha256>/<artifact-id>`,
    and declaration-digest equality with the namespace SHA. Require persisted
    declarations, matching materialized refs, and `event_digest`. Require exact
    producer/consumer binding, equal host for `same_host_workspace`, and prior
    approval for `external_approved`. Reject altered producer/task/digest,
    tamper, or replay. Require action resolver metadata only for transported
    artifacts and null for `codex-task:`-only actions regardless of a
    consumer's future output resolver.
17. Require a bounded `status_code` on every observation. Verify intermediate
    codes are normalized display-only values with no outcome and final codes
    exactly equal `outcome.code`. For a multi-parent consumer, require every
    dependency ready, require `dependency_node_ids` to equal the complete
    declared parent list, and refresh exact live project/runtime/host identity
    immediately before downstream creation. Reject partial, early, missing-ref,
    extra/missing-parent, terminal-only, and type-incompatible handoff or
    dispatch.
18. Exercise the default development recipe as contract root, parallel
    contract-dependent implementations, integration directly depending on the
    contract and all implementations, and an independent reviewer directly
    depending on every producer it inspects. Permit prototype-first only when
    explicit intent and persisted criteria/non-goals record it.
19. Verify an ordinary security-focused readiness review selects
    `$flightdeck-review`. Verify the word “security” alone does not select a
    scan, while an explicit repository/scoped-path scan selects
    `$codex-security:security-scan`.
20. Exercise CI diagnosis-to-fix. Require the diagnosis child to declare a
    bounded diagnostic-ledger artifact, core to materialize canonical producer
    provenance from its exact receipt, and the fix node to consume that ref. A
    bare `check:` declaration is terminal operator evidence and must not create
    an automated handoff or permit a direct dependent dispatch. Exercise
    platform source/plan/runtime artifacts and
    compliance evidence/assessment/deliverable artifacts the same way, with a
    final `review:` declaration terminal only. In all cases reject child
    self-authored canonical refs and stop on blocked or stale producers.
21. Exercise research source tracks with explicit freshness, accessibility,
    and coverage criteria plus artifact-backed source ledgers. Stale or
    inaccessible required sources must report blocked/degraded under
    `failed_validation` and prevent synthesis; `review:` evidence remains
    terminal/operator-only.

Run an older-Hub compatibility case against a disposable copy with all five
Mission capabilities absent. Require four `stop_and_plan_migration` command
results and the bundled Mission reference only for the missing document. Verify
the exact managed migration scope, no setup/bootstrap invocation, no Hub or
ignored-state write, and no silent direct-dispatch fallback.

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

Before upgrade mutation, exercise preserved-Hub compatibility with a separate
synthetic legacy copy:

1. Remove its compatibility identity and use a synthetic older command surface
   that omits `setup plan` and `setup connect`.
2. Verify the installed setup skill runs the read-only compatibility checker,
   reports both setup capability IDs missing, returns
   `stop_and_plan_migration`, and does not invoke setup or bootstrap.
3. Remove `docs/review/change-review.md`. Verify the installed review skill
   records that precise missing document, uses only its bundled review-method
   fallback, and does not claim the Hub-local review workflow was read.
4. Verify both results include only the affected managed paths, an explicit
   separate-candidate plan-and-diff workflow, and prohibitions on automatic
   regeneration, overwrite, migration, or Hub mutation.
5. Hash or otherwise snapshot the synthetic legacy Hub before and after these
   read-only probes and require no change.

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
runtime project/task IDs, modes, normalized paths, and tool evidence. Include
the create and resume task IDs plus whether monitoring occurred. A local
harness result cannot satisfy these live checks.

`flightdeck.runtime-acceptance/v1` remains supported for older evidence and
contains exactly the original three results. Use
`flightdeck.runtime-acceptance/v2` for this Mission release. V2 preserves those
three names:

- `installed_setup_and_exact_path_project_registration`;
- `installed_bulk_bridge_configuration`; and
- `installed_task_search_create_resume_and_no_monitoring`.

V2 adds exactly four Mission results:

- `installed_mission_dispatch_only_default`;
- `installed_mission_watch_only_synchronization`;
- `installed_mission_supervised_fan_in`; and
- `installed_mission_operator_closure`.

The four Mission entries must come from the synthetic fresh-task procedure
above. They must prove default no-monitoring behavior, bounded cursor-aware
watching, criterion-accountable producer-bound dependency fan-in, and
review-ready-before-authorized-close respectively. Source tests and injected
local adapter fixtures remain supporting evidence only.

Required v2 Mission fields are:

- `installed_mission_dispatch_only_default`: non-empty `task_id`,
  `mission_created: false`, and `monitoring_after_receipt: false`;
- `installed_mission_watch_only_synchronization`: `mode: watch_only`, persisted
  Mission record, exact identity, distinct non-empty logical/runtime project
  IDs, non-empty task/host/cursor IDs, and zero follow-ups or external actions;
- `installed_mission_supervised_fan_in`: `mode: supervised`, declared
  dependency, schema-valid required outputs, passed required validation,
  `all_criteria_assigned: true`, `all_criteria_passed: true`,
  `blocked_or_degraded_rejected: true`,
  `handoff_after_required_fan_in: true`, `dependent_handoff_count: 1`,
  `non_artifact_resolver_null: true`,
  `artifact_resolver_binding_verified: true`,
  `artifact_tamper_replay_rejected: true`,
  `producer_provenance_verified: true`,
  `core_materialized_artifact_refs: true`,
  `child_supplied_canonical_ref_rejected: true`,
  `blocked_or_stale_consumer_non_actionable: true`, ignored free text, and zero
  external actions; and
- `installed_mission_operator_closure`: `pre_close_status: review_ready`,
  awaiting operator closure, no automatic close, explicitly authorized close,
  and `post_close_status: complete`.

Every entry also requires `status: passed`. Missing, false, or empty required
fields, plus duplicate or extra result names, remain failed or blocked according
to the evidence validator; they are never inferred from nearby prose.
The prepared pending/unknown, no-duplicate-create, strict non-root dispatch, and
terminal-evidence exclusion cases above are mandatory real-CLI procedural
evidence within the supervised result; they add no new v2 field names and
cannot be inferred from the existing booleans alone.

The evidence JSON must use this top-level provenance contract:

```json
{
  "schema_version": "flightdeck.runtime-acceptance/v2",
  "plugin_name": "flightdeck",
  "plugin_version": "<exact installed manifest version>",
  "candidate_root": "<exact local template root used for comparison>",
  "generated_hub_path": "<exact preserved synthetic Hub path>",
  "runtime_acceptance": []
}
```

The generated path must exist, contain `flightdeck.yaml`, and not contain a
predecessor registry. A v2 result array must contain exactly one object for each
of the original three and four Mission names. A v1 result array still contains
exactly the original three. Stale evidence, a different plugin or version,
duplicate or extra names, missing provenance, a deleted generated Hub, or a
Mission result inferred from local tests must remain unresolved.
