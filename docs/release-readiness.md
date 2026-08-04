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
- ordinary dispatch remains receipt-and-stop by default and creates no Mission;
  explicit Mission records support `dispatch_only`, `watch_only`, and
  `supervised` without widening the recorded authorization boundary;
- generated-Hub Mission tests cover durable state, exact project/host/task and
  pending-client identity, 1/8/9/16 and bounded high-count waits, cursor replay,
  unchanged timeout, completion-before-wait, interruption, per-target host
  errors, required/optional fan-in, cycles, same-checkout conflicts, two-phase
  crash replay, concurrent supervisors, action/retry/duration/forwarded-size
  budgets, capability/schema drift, core-derived authorized-target boundaries,
  criterion assignment/disposition/coverage, generation-bound sync plan tokens,
  closed child output declarations, exact-receipt core materialization of
  canonical producer provenance and event digests, transported-artifact resolver
  direction, tamper/replay rejection, JIT `awaiting_handoff` receipts,
  prepared pending/unknown preservation without duplicate create, strict
  complete-parent/type-compatible non-root dispatch, terminal-evidence
  exclusion, blocked/stale non-actionability, and operator-only close;
- child titles, summaries, commentary, free text, secrets, and raw evidence are
  never persisted or interpreted as authority; children emit only closed
  bounded declarations and supervised handoffs contain only refs materialized
  by core from the exact producer receipt;
- compliance, patching, development, CI/CD, platform/runtime, research, and
  DOCX/PDF/XLSX Mission scenarios exercise their owning companion skills,
  output envelopes, and denied external actions using synthetic data only;
- setup generation is atomic, non-merging, idempotent, and fail-closed;
- the preview-first bootstrap refuses unmanaged or managed-template-drifting
  targets, preserves valid configured topology and repository declarations, and
  validates recognized generated Hubs without overwriting them;
- DOCX, PDF, and XLSX integrations verify installed system capabilities and
  their render/inspect/iterate gates without copying implementations;
- adaptive STIG evaluation, evidence/applicability and inherited-control
  validation, draft-versus-export readiness, Helm remediation planning,
  conservative summary extraction, CKL generation, parsing, and deterministic
  round trip pass.
- the release ledger latest version matches the plugin manifest, patch-note
  ranges never invent unknown history, and upgrade planning distinguishes local
  from Git marketplace refresh behavior;
- the plugin lifecycle contract uses a supported same-plugin reinstall without
  uninstalling first, protects generated Hubs and repositories, and keeps Hub
  migration separate and explicit.
- generated Hubs publish a versioned capability contract; installed skills
  check requested Hub-local commands and documents before use, and incompatible
  preserved Hubs return a read-only plan-and-diff migration scope without
  regeneration or mutation.

## Runtime acceptance

After installation, execute the setup skill's
`references/installed-acceptance.md` in a fresh task. Require live exact-path
project verification and a real create/resume dispatch receipt. Confirm the Hub
stops without monitoring. Evidence must match the current Flightdeck runtime
schema, plugin version, candidate root, and preserved synthetic Hub; stale
predecessor evidence is invalid. Local tests cannot satisfy these checks.

Installed Mission acceptance separately proves the unchanged ordinary
dispatch path, then opts in to fresh `watch_only` and `supervised` Missions.
It must record real task/host/project identities, pending create outcomes,
batched waits and cursors, criterion coverage/results, producer provenance,
resolver direction and tamper rejection, dependency handoffs, child-authored
canonical-ref rejection, prepared client-only/unknown preservation without
duplicate create, strict non-root dispatch eligibility, terminal-evidence
exclusion, blocked/stale non-actionability, restart/replay,
and explicit operator close without persisting child free text or executing an
external action. Injected local observations and generated-Hub CLI results are source
evidence only, not installed-runtime evidence. Use the backward-compatible
exact-three v1 evidence only for the direct-dispatch contract; a Mission-ready
release requires v2 with the same three results plus exact results for default
dispatch, watch-only synchronization, supervised fan-in, and operator closure.

An installed plugin-upgrade check is also runtime acceptance. With explicit
authorization, record the exact prior and target versions, marketplace source,
structured refresh/reinstall results, unchanged synthetic Hub and attached
repository state, and a fresh task that exposes the target skills. Source tests
or patch-note output alone cannot satisfy it.

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

Run the self-contained public gate with:

```sh
make public-validate
```

This gate intentionally uses only repository-owned validation surfaces. It is
suitable for a clean public CI runner, but it does not substitute for the
system plugin/skill validators, private source parity, or installed acceptance.

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
