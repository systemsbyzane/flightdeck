# Flightdeck plugin lifecycle

The installed Flightdeck plugin and this generated Hub have separate
lifecycles. A plugin update refreshes Codex-managed plugin files. It does not
rewrite this repository.

## Natural requests

Use ordinary language:

```text
What changed in the latest Flightdeck version?
```

```text
Upgrade my Flightdeck plugin without changing this Hub or my repositories.
Show me the patch notes before applying anything.
```

The installed `$flightdeck-upgrade` skill handles these requests. Explicit
skill invocation is optional.

## Protected state

Plugin upgrade must not change:

- this generated Hub or its Git state;
- ignored Hub-local repository, bridge, project, task, report, or runtime state,
  including Mission authorized targets, derived boundaries, criterion
  assignments/results, cursors, and outbox receipts;
- attached or managed repository contents;
- Codex tasks or saved runtime project identities;
- evidence, credentials, artifacts, environments, or scheduled jobs.

Preflight may run Doctor and Git-status checks to record observable state.
The installed skill first checks that this Hub exposes the required Doctor
capability. It must not clean, stash, reset, hash private evidence, assume a
newer command or document, or repair findings.

## Upgrade boundary

The supported flow is:

1. inspect configured marketplaces and the installed plugin version;
2. resolve the exact marketplace target;
3. render recorded patch notes;
4. show commands, preservation checks, unknowns, and rollback limits;
5. obtain explicit approval;
6. refresh a Git marketplace when necessary;
7. reinstall the same logical plugin without removing it first;
8. verify the exact installed version and preserved Hub/repository state; and
9. start a fresh Codex task so updated skills load.

Local marketplaces do not need a marketplace refresh. The upgrade workflow
does not edit a plugin cache directly and does not run setup or bootstrap.

## Hub-template changes

Existing Hubs stay on their generated template version. Improvements to the
template are available to newly generated Hubs, but they are not applied here
automatically.

New Hubs publish `hub/compatibility.json`. Newer installed skills use the
read-only checker described in [generated-Hub compatibility](hub-compatibility.md)
before requiring Hub-local commands or documents. Older Hubs without the
identity may be probed for the exact requested surface, but an inferred result
does not claim full template parity.

Adopting a future Hub migration requires a separate explicit workflow with a
preview, exact file diff, preservation plan, validation, and rollback. A plugin
upgrade never authorizes that migration.

Mission commands first appear in generated-Hub template `1.1.0`. A newer
installed Mission skill checks the Hub's `flightdeck.command.mission-manage.v1`,
`flightdeck.command.mission-plan.v1`,
`flightdeck.command.mission-status.v1`,
`flightdeck.command.mission-sync.v1`, and
`flightdeck.document.mission-control.v1` capabilities before use.

Template `1.2.0` introduces two independent typed desktop-client capabilities:
`flightdeck.command.mission-list.v1` for bounded read-only list views and
`flightdeck.command.mission-authoring.v1` for guided catalog, preview, confirmed
create, and recovery. A client must require the exact capability it needs from
the regular `hub/compatibility.json` manifest rather than infer support from
the four older Mission capabilities or run Doctor/status as a capability probe.

Template `1.6.1` adds
`flightdeck.command.operations-snapshot-detail-identity.v1`. It preserves the
existing Mission/task snapshot source identity and exposes a separate canonical
detail identity only when a persisted Operation-authoring record reconciles
exactly with its Mission. Legacy and Task records report detail unavailable;
malformed, foreign, duplicate, or mismatched authoring identity fails closed.

For a preserved Hub that needs both desktop surfaces, the later separately
authorized migration must compare the exact managed paths returned by the
compatibility checker for both capabilities, plus `hub/compatibility.json`.
That comparison does not include ignored Mission records, operations, tasks,
reports, attached repositories, or client dispatch state. Neither capability
enables managed local dispatch: source-path reconciliation, lock-publication,
exclusive ownership, and unknown provider outcomes stay fail-closed client
gates until independently proven.

If a Mission command is missing, the only valid behavior is
`stop_and_plan_migration` with the exact managed paths from the compatibility
checker. Do not run setup, regenerate the Hub, edit ignored Mission state, or
silently use ordinary dispatch while claiming the requested Mission ran. The
bundled Mission reference may explain a missing document, but it cannot replace
missing command behavior.

The current Mission interface includes six-field authorized targets,
core-derived boundaries, ordered criterion accountability, sync plan tokens,
closed child output declarations, core-materialized producer-bound refs and
event digests, transported-artifact-only resolver metadata, and exact-receipt
JIT delivery through internal `awaiting_handoff`. Children/adapters never
bootstrap or repair provenance. A client-only/unknown JIT result preserves the
prepared action without authorizing duplicate create, and a non-root dispatch
requires the exact prepared complete compatible handoff; terminal evidence is
ineligible. Blocked/stale states are non-actionable. If
the preserved Hub lacks any
required command or schema field, stop for migration; an installed plugin must
not emulate the newer behavior or rewrite ignored Mission state.

After upgrading the plugin, start a fresh Codex task so Mission skill metadata
loads. An existing Hub still requires a separately approved plan-and-diff
migration before it can execute Mission commands.

## Failure and rollback

A failed refresh should leave the installed plugin unchanged. A failed
reinstall is ambiguous until the installed version is checked.

Rollback is available only when the prior exact plugin build remains available
from an authorized trusted source. It is planned and approved separately.
Never delete a Hub, repository, task, evidence, or ignored local state to
recover the plugin.
