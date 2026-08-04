# Flightdeck plugin upgrade contract

## Outcomes

A safe upgrade:

- resolves one installed Flightdeck plugin and its configured marketplace;
- distinguishes the installed version from the marketplace target version;
- explains recorded changes before mutation;
- updates only Codex-managed marketplace or plugin state;
- verifies the installed target version after the update;
- confirms that user-owned Hub and repository state did not change; and
- requires a fresh Codex task before claiming the new skills are loaded.

“In place” means the same logical plugin remains installed while Codex refreshes
its managed bundle. It does not mean editing files inside the plugin cache.

## State ownership

| State | Owner | Upgrade behavior |
| --- | --- | --- |
| Installed plugin bundle | Codex | Replaced through `codex plugin add` |
| Git marketplace snapshot | Codex | Refreshed only when needed and approved |
| Local marketplace source | User or maintainer | Read directly; never refreshed |
| Generated Flightdeck Hub | User | Protected; never regenerated or migrated |
| Hub ignored local state | User | Protected; never cleaned or copied |
| Ignored Mission records, authorized targets, criterion assignments/results, output declarations/materialized refs, event digests, cursors, internal handoff state, and outbox receipts | User | Protected; never rewritten or migrated |
| Attached repositories | Repository owners | Protected; never edited, stashed, or reset |
| Tasks, runtime IDs, evidence, credentials | User and external systems | Out of scope |

Plugin release and generated-template release are separate. Existing Hubs keep
working from their generated files. New plugin skills may coordinate with them,
but a template change does not silently rewrite an existing Hub. New skills
must check the preserved Hub's declared or read-only-inferred capabilities
before requiring Hub-local commands or documents.

Mission behavior first appears in generated-Hub template `1.1.0`. Its declared
surface is:

- `flightdeck.command.mission-manage.v1`;
- `flightdeck.command.mission-plan.v1`;
- `flightdeck.command.mission-status.v1`;
- `flightdeck.command.mission-sync.v1`; and
- `flightdeck.document.mission-control.v1`.

The four command gaps use `stop_and_plan_migration`. They have no bundled or
direct-dispatch behavioral fallback. Only the document gap may use the bundled
`skills/flightdeck-mission/references/mission-contract.md` reference. When the
user asks for a Mission on an older Hub, return the exact managed plan-and-diff
scope and stop; do not claim that ordinary receipt-and-stop dispatch satisfied
the Mission request.

The current Mission wire includes exact six-field authorized targets with a
core-derived scope boundary, ordered criterion IDs/assignments/results,
generation-bound `sync-plan`/`sync-apply` tokens, closed child
`output_declarations`, core-materialized producer-bound artifact/task refs,
persisted `event_digest`, transported-artifact-only action resolver metadata,
and receipt-gated JIT delivery through internal `awaiting_handoff`. Children and
adapters never bootstrap or repair producer identity. Blocked and stale
consumers are non-actionable and the action allowlist has no path for them.
Client-only or unknown JIT outcomes preserve their exact prepared action as
non-deliverable; they never authorize a duplicate create. Non-root dispatch
requires exactly one matching prepared action with the complete parent set, all accepted
automatic refs exactly equal to the complete eligible set, and at least one per
parent; terminal or incompatible evidence
cannot qualify. An
installed skill must use the preserved Hub's
actual compatible command/schema surface. If any required flag or schema field
is absent, stop and propose the compatibility checker's managed migration; a
plugin reinstall cannot safely emulate or retrofit those semantics.

## Read-only preflight

1. Locate the active skill and plugin root. Read `.codex-plugin/plugin.json` and
   `releases.json`.
2. Capture:

   ```sh
   codex plugin marketplace list --json
   codex plugin list --marketplace <marketplace> --available --json
   ```

3. Save command output only in an ignored user-selected location when a durable
   receipt is useful. Do not put machine paths in tracked files.
4. Run:

   ```sh
   python3 scripts/upgrade_planner.py \
     --plugin-list <plugin-list.json> \
     --marketplaces <marketplaces.json> \
     --plugin flightdeck \
     --marketplace <marketplace>
   ```

5. If a generated Hub is open, run the installed setup skill's
   `scripts/hub_compatibility.py` for `flightdeck.command.doctor.v1` before
   invoking Doctor. Capture `bin/flightdeck doctor --json` only for a compatible
   or compatible-inferred result, plus `git status --short` before and after.
   For an incompatible Hub, retain the structured compatibility result and use
   the bundled upgrade contract instead of assuming a Hub-local lifecycle
   document. For attached repositories, use only existing compatible
   status/Doctor surfaces; do not traverse or hash private evidence.
6. Stop before mutation if the installed plugin, marketplace, target manifest,
   or target version cannot be resolved exactly.

The planner emits commands as argument arrays. Display them to the user; do not
execute output by shell interpolation.

## Patch-note rules

The `releases.json` resolved inside the target marketplace snapshot is the
authoritative user-facing ledger. The planner requires its latest exact version
to match the target manifest. Do not use the older installed bundle's ledger to
describe a newer target. Each exact plugin version has a summary, categorized
changes, breaking-change list, and migration notes.

- When both versions are known, include every ledger entry after the installed
  version through the target version.
- When the installed version is unknown, show the target release and label the
  range incomplete.
- When versions match, say the installation is current.
- Do not infer release facts from uncommitted changes, a cache directory, commit
  messages, or marketplace timestamps.
- Empty breaking-change and migration lists mean none are recorded; they do not
  prove compatibility with unsupported customizations.

## Apply

Show the plan and obtain explicit approval for the exact marketplace and plugin.

For a configured Git marketplace:

```sh
codex plugin marketplace upgrade <marketplace> --json
```

Do not run that command for a local marketplace. Re-run preflight after any
refresh so the target version and patch notes reflect the refreshed snapshot.

Then use the supported install command for the same plugin identity:

```sh
codex plugin add flightdeck@<marketplace> --json
```

Do not run `codex plugin remove` first. Do not copy files into the cache. Do not
invoke setup, bootstrap, bridge installation, project dispatch, or Hub migration.

If the preserved Hub lacks a capability needed by newer installed skills,
report that incompatibility separately from plugin installation. Provide the
checker's exact managed-path plan-and-diff scope. Do not repair, regenerate,
overwrite, or migrate the Hub during upgrade.

After a verified plugin upgrade, start a fresh Codex task so the new skill
definitions load. Loading the Mission skill does not add Mission commands to an
older Hub. The separately authorized migration must preserve Git state,
attached repositories, ignored task/Mission state, authorized targets,
core-derived boundaries, criterion assignments/results, output declarations,
core-materialized refs, event digests, internal `awaiting_handoff` state, exact
runtime identities, cursors, action trigger digests/identities, delivery
receipts, evidence, and credentials. It must not synthesize child identity,
rewrite or repair declarations/refs, turn blocked or stale into an actionable
consumer, discard or retry a prepared pending/unknown handoff, create a
dependent from terminal or incompatible evidence, or replay a stale sync plan
token or prepared action against migrated state.

## Verify and report

1. Re-run `codex plugin list --marketplace <marketplace> --available --json`.
2. Require one enabled installed record whose exact version equals the approved
   target.
3. Re-run the preflight Hub and repository checks. A plugin reinstall should not
   change them. If it did, report the exact observed drift and stop.
4. Report:
   - prior and installed versions;
   - marketplace and source type;
   - applied commands and their structured result;
   - patch-note completeness;
   - preservation checks actually performed;
   - remaining unknowns; and
   - the fresh-task requirement.

Do not claim installed-runtime success from source validators or from a
marketplace refresh alone.

## Failure and rollback

- A failed marketplace refresh leaves the installed plugin unchanged; report
  the error and stop.
- A failed reinstall must be verified with `codex plugin list`; do not assume
  either success or rollback.
- Rollback is possible only when the previous exact version is still resolvable
  from an authorized marketplace source or a separately approved trusted source.
- Plan rollback, show its provenance and commands, and obtain explicit approval.
- Never delete a generated Hub, repository, task, evidence, or local state to
  recover a plugin installation.
