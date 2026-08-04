# Generated-Hub compatibility

The installed Flightdeck plugin and a generated Hub have separate lifecycles.
New skills must not assume that a preserved Hub contains commands or documents
added after that Hub was generated.

## Identity and capabilities

New Hubs publish `hub/compatibility.json`. It identifies the generated-template
version and stable, versioned capability IDs. Each capability defines a
read-only probe, the managed paths that implement it, and an allowed fallback.

Use the installed `flightdeck-setup` skill's
`scripts/hub_compatibility.py` before a newer skill requires a Hub-local command
or document. Request only the capabilities needed for the current operation.
The checker is read-only and emits one of:

- `compatible`: the Hub declares and satisfies every requested capability;
- `compatible_inferred`: an older Hub has no contract, but read-only probes
  verified every requested capability; or
- `incompatible`: at least one capability is missing, invalid, or unavailable.

An inferred result verifies only the requested surface. It does not assign a
template version to an older Hub or claim full template parity.

## Safe fallback

Never invoke a capability reported missing. Use only the fallback named in the
compatibility result:

- `bundled_reference`: use the installed skill's bundled method and state that
  the Hub-local document was unavailable;
- `manual_exact_path_handoff`: return a self-contained owner handoff only after
  normal route or registration verification failed;
- `compatibility_report_only`: report the blocker without substituting a
  mutating command; or
- `stop_and_plan_migration`: stop before setup, bootstrap, bridge installation,
  or any other Hub write.

Fallback never weakens owner dispatch, approval, or no-monitoring boundaries.

## Plan-and-diff migration

An incompatibility does not authorize migration. The checker returns the exact
managed paths related to missing capabilities and a read-only migration plan.
To adopt a newer Hub template:

1. preserve the existing Hub, ignored state, tasks, evidence, and attached
   repositories;
2. obtain separate authorization for migration planning;
3. generate the target template only at a separate empty path;
4. diff the reported managed paths and compatibility contract while excluding
   user-owned runtime and workload state;
5. review the exact file-level plan, validation, backup, and rollback; and
6. obtain separate authorization before applying any reviewed migration.

Plugin upgrade never performs these steps and never regenerates, overwrites, or
mutates an existing Hub.
