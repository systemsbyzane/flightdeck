---
name: flightdeck-upgrade
description: Plan, explain, apply, and verify a supported Flightdeck plugin upgrade without regenerating a Hub or changing attached repositories. Use when a user asks to upgrade or update Flightdeck, reinstall a newer Flightdeck plugin build, check whether an update is available, preserve existing Flightdeck state during an update, roll back an attempted plugin update, or asks what changed in Flightdeck, for Flightdeck patch notes, or for changes between Flightdeck versions.
---

# Flightdeck Upgrade

Treat plugin lifecycle and generated-Hub lifecycle as separate boundaries.
Updating the installed plugin may replace cached plugin files; it must not run
setup against an existing Hub, migrate Hub files, or alter attached repositories.
Natural Flightdeck upgrade and patch-note intent triggers this skill;
explicit invocation is optional.

Read `references/upgrade-contract.md` completely before an upgrade, rollback,
or preservation claim. Patch-note-only requests are read-only and may use the
release ledger immediately.

When a generated Hub is in scope, run the installed setup skill's read-only
`scripts/hub_compatibility.py` for `flightdeck.command.doctor.v1` or
`flightdeck.document.plugin-lifecycle.v1` before requiring Hub-local Doctor or
lifecycle documents. Record incompatibility as preserved-Hub evidence and use
the bundled upgrade contract; never use plugin upgrade to repair or migrate it.

## Patch Notes

For an upgrade, run the planner first and use its `target_release_ledger` path.
This ensures notes come from the offered marketplace build rather than the
older installed bundle. For a current-version-only question, use
`releases.json` at the plugin root relative to this skill. Render recorded
changes with:

```sh
python3 scripts/patch_notes.py \
  --releases <target-release-ledger> \
  --from-version <installed-version>
```

Omit `--from-version` for the latest release. Do not invent changes for an
unknown version or treat Git history as user-facing release provenance.

## Upgrade

1. Capture `codex plugin marketplace list --json` and
   `codex plugin list --marketplace <marketplace> --available --json`.
2. Run `scripts/upgrade_planner.py` against those captures. Planning is
   read-only; do not refresh a marketplace or reinstall during preflight.
3. Render patch notes from the planner's exact `target_release_ledger`. Show
   the installed version, target version, patch notes, protected-state
   boundary, exact proposed commands, unknowns, and rollback limits.
4. Obtain explicit approval before any marketplace refresh or plugin reinstall.
5. For a Git marketplace, refresh its snapshot with the supported marketplace
   upgrade command. Do not refresh a local marketplace.
6. Re-run the planner, then reinstall the same logical plugin with
   `codex plugin add flightdeck@<marketplace> --json`. Do not remove it first,
   edit the plugin cache, or run setup.
7. Verify the installed version and compare the read-only Hub/repository state
   captured in preflight. Report any drift immediately.
8. Tell the user to start a fresh Codex task so the new skill definitions load.

An existing generated Hub remains on its current template. Hub migration is a
separate, explicit plan-and-diff workflow and is never implied by plugin upgrade.

## Authorization

Patch-note rendering, version inspection, planning, Doctor, and Git-status
checks are read-only. Marketplace refresh, plugin reinstall, rollback, and any
Hub migration require explicit approval. Never commit, publish, deploy, or
delete old state as part of this skill unless separately authorized.
