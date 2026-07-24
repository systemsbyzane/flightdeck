# Flightdeck plugin contributor instructions

This repository owns one portable Codex plugin under `plugins/flightdeck/` and a
repo-local marketplace entry under `.agents/plugins/`.

## Boundaries

- Keep plugin and generated-template content organization-, product-, program-,
  customer-, person-, credential-, evidence-, task-, and finding-neutral.
- Use only synthetic fixtures.
- Do not install, activate, publish, share, stage, commit, push, create a remote,
  or change a plugin cache unless the user explicitly authorizes that action.
- Treat any external source Hub supplied for comparison as read-only. Store
  path-bearing comparison output only under ignored `.flightdeck-local/`.
- Do not add a license. This private personal-use distribution intentionally
  does not require one.

## Change rules

- Follow the plugin-creator and skill-creator system skills for manifest,
  marketplace, skill metadata, and validation changes.
- Keep skill bodies concise; put detailed reusable method in one-level
  `references/`, deterministic logic in `scripts/`, and the generated Hub under
  the setup skill's `assets/`.
- Preserve the coordinator boundary: dispatch owner work before analysis and
  return the project/task receipt without monitoring.
- Preserve explicit approval gates for commits, remote writes, publication,
  deployment, shared-environment mutation, external communication, compliance
  submission, risk acceptance, and closure.
- Never weaken a source workflow or schema merely to make parity pass. Update
  the neutral mapping and functional probe together.

## Required validation

Run the plugin validator, every skill quick validator, all Ruby and Python
tests, structured JSON/YAML/schema parsing, fresh setup generation, generated
Doctor, de-branding scan, setup-link validation, deterministic STIG round trip,
local acceptance harness, semantic parity comparison, and `git status`.

Live Codex project registration and task dispatch are installed-plugin,
fresh-task acceptance checks. Do not claim them from local harness output.
