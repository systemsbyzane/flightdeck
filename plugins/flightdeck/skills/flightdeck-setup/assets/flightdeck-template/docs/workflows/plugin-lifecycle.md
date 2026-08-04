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
- ignored Hub-local repository, bridge, project, task, report, or runtime state;
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

## Failure and rollback

A failed refresh should leave the installed plugin unchanged. A failed
reinstall is ambiguous until the installed version is checked.

Rollback is available only when the prior exact plugin build remains available
from an authorized trusted source. It is planned and approved separately.
Never delete a Hub, repository, task, evidence, or ignored local state to
recover the plugin.
