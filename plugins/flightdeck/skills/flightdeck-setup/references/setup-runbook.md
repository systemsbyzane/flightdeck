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
6. If the request names a folder containing repositories, resolve it to one
   absolute real path and use it as the authorized discovery root. Reject a
   filesystem root, home directory, symlink root, or missing directory. Do not
   scan or modify repositories outside it. If no repository root is named,
   complete core setup and ask only which folder contains the repositories to
   connect.

Before invoking any command in a non-empty generated Hub, run the read-only
compatibility checker for only the capabilities needed by the request:

```text
python3 scripts/hub_compatibility.py \
  --hub-root <absolute-target> \
  --require flightdeck.command.doctor.v1
```

Repository discovery and connection also require
`flightdeck.command.setup-plan.v1` and
`flightdeck.command.setup-connect.v1`. Bootstrap itself requires a declared Hub
contract before treating a non-empty target as the current managed template.
For `incompatible`, stop before bootstrap or setup and return the structured
result, allowed fallback, and plan-and-diff migration guidance. Never use setup
to repair, merge, regenerate, or overwrite a preserved Hub.

Preview first:

```text
python3 scripts/preflight.py --json
python3 scripts/bootstrap.py --target <absolute-target> \
  [--repositories-root <absolute-repositories-root>] --json
```

When the user has asked to create the Hub, apply the preview:

```text
python3 scripts/bootstrap.py --target <absolute-target> \
  [--repositories-root <absolute-repositories-root>] --apply --json
```

The bootstrap may initialize a new local Git repository. When a repositories
root is supplied, apply may also write portable Hub declarations, ignored local
repository state, ignored reference bridges, and repository-local
`.git/info/exclude` entries for those bridges. Those ordinary setup writes are
authorized by the setup request. It never changes tracked files in an attached
repository, stages, commits, adds a remote, installs a plugin, registers a
project, configures a secret, publishes, or merges existing content. On a
recognized generated Hub it reruns validation without overwriting managed
files. Treat `runtime_status: agent_verification_required` as pending work, not
setup success.

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

## 5. Connect discovered repositories

Skip this section only when the user has not yet supplied a repositories root.
The bootstrap repository preview is read-only and must report every discovered
Git root, dirty state, inferred workload/profile, proposed portable
declaration, bridge target, project-registration status, and blocker.

Setup defaults to an attached checkout and a `reference` bridge:

- the checkout remains at its existing exact path;
- `hub/repositories.yaml` stores stable portable facts and never the attached
  absolute path;
- ignored `hub/state/repositories.yaml` stores the exact machine-local path;
- ignored `AGENTS.override.md` and its repository-local
  `.git/info/exclude` entry are installed automatically;
- dirty, untracked, ignored, branch, and remote state are preserved;
- tracked repository files are not edited.

The default `continue` policy connects independent safe repositories and skips
blocked ones. Stop and report a repository when discovery finds an ID/path
conflict, detached or unverifiable HEAD, credential-bearing or unsupported
origin, an unmanaged `AGENTS.override.md`, bridge drift, or an unsafe local
registration. Never delete, rename, overwrite, reset, clean, stash, fetch,
pull, or switch branches to clear a blocker.

Use local `origin/HEAD` as the verified default branch when available. For an
otherwise safe attached checkout without that ref, record the checked-out
branch with `default_branch_verified: false`, continue setup, and report one
non-blocking provider-metadata warning. Do not claim that fallback is the
provider default. Managed cloning still requires a verified default branch.

The deterministic commands are:

```text
bin/flightdeck setup plan \
  --repositories-root <absolute-repositories-root> \
  --failure-policy continue --json
bin/flightdeck setup connect \
  --repositories-root <absolute-repositories-root> \
  --failure-policy continue --json
```

`setup connect` is the explicit apply. A normal setup request authorizes it
after the read-only plan. `materialized` and `repo-native` are not initial setup
defaults; route later mode changes, migrations, or drift repair through the
repo-bridge skill. `repo-native` always requires separate per-repository
authorization.

Do not assume these commands exist in a preserved Hub. Require compatible or
compatible-inferred results for both setup capability IDs before invoking
them. Missing setup commands are a compatibility stop, not permission to run
the current bootstrap against the existing Hub.

## 6. Register and verify repository projects

For every successfully connected repository, follow the same refreshed
live-list, exact-normalized-path verification used for the Hub:

1. Accept an existing saved project only on an exact real-path match.
2. Otherwise use native registration, then the supported open-folder fallback.
3. Refresh and verify; retry the same path once after refreshing capabilities.
4. Record the opaque runtime ID only from the exact-path live-list match in
   ignored `hub/state/projects.yaml`.

After the second verified failure, give exactly this one action per unresolved
path:

```text
In Codex, choose File > Open Folder, select "<exact-repository-path>", then reply "done".
```

Do not create implementation tasks during setup. Rerun
`bin/flightdeck doctor --json` after project verification.

## 7. Handoff and acceptance boundary

Return:

- exact Hub path and opaque saved runtime project ID returned by the
  exact-path live-list match;
- repository discovery, connection, safe bridge, and exact-path project counts,
  plus concise per-repository blockers;
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
