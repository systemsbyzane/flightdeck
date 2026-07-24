# Public repository and plugin readiness

The repository is publicly readable and can serve the plugin directly through
Codex's Git marketplace support. A Flightdeck version is release-ready only
when every mandatory item below is satisfied.

## Portable content

- plugin manifest and repo marketplace validate;
- strict source, generated-Hub, and plugin inventories are fully classified by
  the tracked process-parity manifest;
- every skill validates and has accurate interface metadata;
- all visible and hidden distributable text passes the deterministic
  de-branding scan;
- only synthetic fixtures are distributed;
- generated program workspaces ignore real evidence and outputs;
- no credentials, private URLs, live topology, task history, findings, or
  controlled artifacts are present.

## Functional behavior

- typed tasks, workflows, approvals, gates, evidence, checks, risks, blockers,
  repository roles, and transitions have semantic mappings and probes;
- Doctor, status, route plan, repo plan, onboarding, bridge modes, declarative
  bulk bridge planning/application, per-repository receipts, compliance
  sidecars, automation safety, and no-monitoring behavior pass local probes;
- setup generation is atomic, non-merging, idempotent, and fail-closed;
- the preview-first bootstrap refuses unmanaged or managed-template-drifting
  targets, preserves valid configured topology and repository declarations, and
  validates recognized generated Hubs without overwriting them;
- DOCX, PDF, and XLSX integrations verify installed system capabilities and
  their render/inspect/iterate gates without copying implementations;
- STIG evaluation, Helm remediation planning, conservative summary extraction,
  CKL generation, parsing, and deterministic round trip pass.

## Runtime acceptance

After installation, execute the setup skill's
`references/installed-acceptance.md` in a fresh task. Require live exact-path
project verification and a real create/resume dispatch receipt. Confirm the Hub
stops without monitoring. Evidence must match the current Flightdeck runtime
schema, plugin version, candidate root, and preserved synthetic Hub; stale
predecessor evidence is invalid. Local tests cannot satisfy these checks.

## External decisions and dependencies

- No license file is intentionally included in this public source-available
  distribution. Do not add one unless the owner explicitly changes that
  decision.
- Provider metadata and authentication tools are optional runtime dependencies.
- Codex project registration depends on the capabilities available in the
  installed runtime; supported UI open-folder is the fallback.
- Artifact workflows depend on installed `documents`, `pdf`, and
  `Spreadsheets` capabilities and their bundled workspace runtime.
- Remote validation depends on a separately configured, authorized project.

Do not claim plugin readiness while any mandatory local probe is unresolved or
runtime acceptance remains unexecuted. Public GitHub availability and
successful source installation do not replace those acceptance checks.

Run the source-backed local gate with:

```sh
make release-validate \
  SOURCE_HUB=/absolute/path/to/read-only-reference-hub \
  PRIVATE_NEUTRALIZATION_MAP=.flightdeck-local/private-neutralization.json
```

`make validate` remains the self-contained plugin/candidate suite; it cannot
establish source inventory or semantic parity without an explicit read-only
reference. The required private-neutralization map is an ignored local input;
it must not be committed, packaged, installed, or copied into generated Hubs.
