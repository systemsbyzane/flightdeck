# Agent setup runbook

This runbook is mandatory whenever an agent sets up a Flightdeck. Complete it in
order. Setup is fail-closed: do not merge, overlay, repair, or overwrite a
non-empty target. A recognized generated Hub may be validated again as an
idempotent no-op. Configured stable topology and repository declarations are
preserved and validated; drift in other managed template files, or an unmanaged
or partial target, is a hard stop.

## 1. Resolve the target

1. Resolve the requested path to an absolute normalized path.
2. Reject a symlink target, filesystem root, home directory, the plugin source
   tree, an unmanaged existing Git repository, or any unrecognized non-empty
   directory.
3. If the user did not name a target, propose one concrete path and confirm it
   before writing. Do not choose a shared or synchronized folder implicitly.
4. Record the exact target path. Every later project-list check must match this
   path after real-path normalization, not by folder name.
5. Treat configured workload repositories, program payloads, ignored state,
   `flightdeck.yaml`, and `hub/repositories.yaml` as user-owned after generation.
   Validation must inspect their contracts without copying or byte-comparing
   their payload content to the template.

Preview first:

```text
python3 scripts/preflight.py --json
python3 scripts/bootstrap.py --target <absolute-target> --json
```

When the user has asked to create the Hub, apply the preview:

```text
python3 scripts/bootstrap.py --target <absolute-target> --apply --json
```

The bootstrap may initialize a new local Git repository. It never stages,
commits, adds a remote, installs a plugin, registers a project, configures a
secret, publishes, or merges existing content. On a recognized generated Hub
it reruns validation without overwriting files. Treat `runtime_status:
agent_verification_required` as pending work, not setup success.

## 2. Verify local prerequisites

The preflight must confirm usable `python3`, `ruby`, and `git`. Then inspect the
current Codex capabilities:

- a live project-list capability;
- a native add/register/open-project capability, if present;
- a supported Codex or operating-system UI open-folder fallback;
- task-list/search and task-create capabilities for later dispatch;
- the current workspace dependency loader;
- installed `documents`, `pdf`, and `Spreadsheets` artifact capabilities.

For artifact capabilities, call the workspace dependency loader and read the
current capability instructions. Confirm these gates, without copying their
implementations:

- DOCX: render every page to PNG, inspect every page, correct defects, rerender;
- PDF: render every page to images, inspect layout and legibility, iterate;
- XLSX: inspect formulas and key ranges, scan formula errors, render and inspect
  every sheet, correct defects, then export.

If an artifact capability or its bundled runtime is unavailable, name the exact
missing capability or loader result. Core Hub setup may continue, but artifact
work remains blocked and the final setup result must list that blocker.

## 3. Validate the generated Hub

The bootstrap apply result must report Ruby test, structured parsing, Doctor,
de-branding, and setup-link counts. Confirm them, then run from the generated
Hub when an independent check is required:

```text
ruby -Ilib tests/flightdeck_test.rb
bin/flightdeck doctor --json
```

Run from this setup skill:

```text
python3 scripts/scan_debranding.py <absolute-target> --allow-generated-root
python3 scripts/validate_structured.py <absolute-target>
python3 scripts/validate_links.py
```

Parse every Flightdeck control-plane JSON, YAML, and schema file. Do not treat
configured workload repository files, program payloads, or ignored runtime
state as Flightdeck source. Treat Doctor errors, test failures, de-branding
findings, invalid links, or control-plane parse failures as setup failure.
Doctor warnings must be reported with their exact no-fetch limitation.

Edit only stable topology in `flightdeck.yaml`. Never add credentials, live branch
state, task history, findings, evidence, deployment state, or generated program
artifacts.

## 4. Register or open the Hub project

1. Call the live project-list capability and save the result.
2. If exactly one saved project has a real path equal to the target, use its
   opaque runtime project ID. A display-name match is insufficient.
3. Otherwise, use a native project-registration capability when available.
4. If native registration is unavailable, use the supported Codex or
   operating-system UI open-folder mechanism to open the exact target.
5. Refresh the live project list. Success requires an exact normalized real-path
   match; a matching display name is insufficient.
6. If no exact match exists, refresh capability state and retry the same
   register/open path once.
7. Refresh the live project list again and require the exact path match.

Never claim registration from a successful UI action alone. The refreshed live
list is the verification source.

After the second verified failure, stop and give exactly this one manual action,
with the real target substituted:

```text
In Codex, choose File > Open Folder, select "<absolute-target>", then reply "done".
```

Do not add alternative actions or perform Hub-owned work as a fallback.

## 5. Handoff and acceptance boundary

Return:

- exact Hub path and opaque saved runtime project ID returned by the
  exact-path live-list match;
- validation commands and outcomes;
- artifact capability readiness or exact blockers;
- Doctor error/warning counts and no-fetch caveat;
- confirmation that no plugin installation, commit, remote, or external write
  occurred.

The deterministic local harness validates generation and control-plane behavior:

```text
python3 scripts/acceptance_harness.py --json <ignored-report-path>
```

Live Codex registration and task dispatch require an installed plugin and a
fresh task. Do not mark those runtime checks passed from this local harness.
Follow `references/installed-acceptance.md` after installation is separately
authorized.

Repository declarations remain empty until the user supplies verified
provider, ownership, path, default-branch, bridge, and project facts. After the
Hub project is open, a “configure bridge repos” request must route to
`flightdeck-repo-bridge/references/configure-bridge-repos.md`; setup itself must
not invent repository declarations or create implementation tasks.
