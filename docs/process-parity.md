# Strict process parity and exclusions

Flightdeck preserves the reusable operating process of the reference Hub while
excluding its private operational state. This document is the human-readable
audit. The machine-enforced mapping is
[`plugins/flightdeck/process-parity.json`](../plugins/flightdeck/process-parity.json),
and the deterministic validator is
[`process_inventory.py`](../plugins/flightdeck/skills/flightdeck-setup/scripts/process_inventory.py).

## Inventory boundary

The source reference currently has no committed index. Its root ignore policy
is therefore the authoritative allowlist. The validator runs the equivalent of:

```text
git -C <source-root> ls-files -co --exclude-standard
```

The current selected baseline is 112 files:

- 100 active substantive process surfaces;
- 8 structural program-workspace placeholders;
- 4 reusable design-history plan/spec documents.

All 112 selected files require a mapped or generalized Flightdeck counterpart.
None may disappear through an exclusion. Any newly selected source path,
unclassified generated-Hub path, unclassified plugin-distribution path,
ambiguous mapping, missing candidate, invalid status, duplicate capability ID,
or count drift fails the strict inventory.

Exact source paths, absolute roots, and source-specific comparison reports are
written only under ignored `.flightdeck-local/`. The tracked manifest uses
neutral capability IDs and generalized selectors so distributable content does
not reveal source identities.

Source-specific vocabulary follows the same boundary. The comparator and
de-branding scanner accept an ignored external JSON map with this synthetic
shape:

```json
{
  "schema_version": "flightdeck.private-neutralization/v1",
  "source_control_token": "legacy-fixture-hub",
  "replacements": {
    "private-fixture-product": "product"
  },
  "deny_tokens": [
    "private-fixture-owner"
  ]
}
```

Replacement sources, the source control token, and explicit deny tokens are all
treated as prohibited distributable vocabulary. Validation checks plaintext,
hex, base64, and simple reconstructed forms. The map must remain Git-ignored
and outside plugin, template, and generated-Hub content.

## Reusable capability mapping

| Capability | Flightdeck counterpart |
|---|---|
| Distribution boundary | Generated-Hub ignore policy plus de-branding and strict inventory |
| Coordination entrypoints | Hub `AGENTS.md`, README, Makefile, registry, and CLI |
| Runtime and regression suite | `lib/flightdeck/`, `bin/flightdeck`, and generated Ruby tests |
| Workload guidance | Neutral development, charts, patching, research, environment, operations, and compliance roots |
| Architecture and workflow method | Generated `docs/` hierarchy, including the guide index and Codex UI workflow |
| Design history | Neutral control-plane and compliance workbench plans/specifications under `docs/superpowers/` |
| Task and workflow contracts | Schemas, typed adapters, gates, approvals, checks, evidence, risk, and lifecycle history |
| Repository onboarding | Provider-aware planning, verified clone/existing-local adapters, and atomic ignored registry updates |
| Project identity and dispatch | Exact normalized path verification, separate logical/runtime IDs, search/resume-before-create, receipt, and no monitoring |
| Repository bridges | Reference, materialized, and repo-native modes; read-only bulk plan; fail-closed apply; per-repository receipts |
| Doctor and operations | Stable finding codes, no-fetch repository state, task/schema checks, bridge integrity, sidecar checks, and disabled automation policy |
| Automation patterns | Disabled YAML specifications plus a separate approval-gated real-schedule method |
| Development and charts | Owner dispatch, secure design/review gates, manifest rendering, and rollback evidence |
| Patching | Ownership, compatibility contracts, scans, rebuild evidence, immutable digests, SBOMs, and downstream validation |
| Research | Source ledger, freshness, fact/inference separation, contradictions, gaps, and decision briefs |
| Artifact workflows | Routing to installed Word, PDF, and spreadsheet capabilities with render/inspect/iterate gates |
| Compliance and POA&M | Isolated program workspaces, evidence classification, workbook preservation, supported weakness candidates, sidecars, and human review |
| STIG | Adaptive read-only evaluation, evidence provenance, applicability and inherited-control checks, draft/export readiness, remediation routing, summaries, and deterministic CKL round trips |
| Setup | Preview-first credential-free bootstrap, atomic empty-target generation, idempotent validation-only reruns, and exact project registration |
| Plugin lifecycle | Exact installed/target version planning, deterministic release notes, supported same-plugin reinstall, preservation checks, and explicit separation from generated-Hub migration |

Semantic parity remains a second gate. The strict inventory proves that every
surface is classified and present; `compare_hubs.py` separately probes schema,
workflow, CLI, Doctor, bridge, task, artifact, STIG, documentation, de-branding,
and local acceptance behavior.

## Required exclusions

The source allowlist deliberately omits the following data classes. They are
not functional parity gaps:

- independent owning repositories and their Git histories;
- organization, product, program, customer, person, and machine identities;
- credentials, provider secrets, authenticated URLs, and local connection
  configuration;
- real program evidence, workbooks, controlled documents, and generated
  compliance artifacts;
- live task, report, run, cache, bridge, project, finding, and automation
  execution history;
- vulnerability scan outputs and generated handoff packets;
- VM, cluster, image, deployment, and other live runtime state;
- ignored local tools or caches that have not been deliberately generalized;
- risk acceptance, authorization decisions, submission receipts, and closure
  claims.

Flightdeck includes the reusable process for handling these classes, not the
private instances.

## Installed-runtime boundary

Local validation can prove generation, schemas, CLI behavior, bridge
idempotence, transition gates, no-fetch Doctor behavior, de-branding, artifact
gates, deterministic CKL tools, release-ledger integrity, and read-only upgrade
planning. It cannot prove live Codex project registration, real task
creation/resume behavior, or an installed plugin update.

Installed runtime evidence remains unresolved unless a fresh task records the
exact plugin version, current candidate root, a preserved synthetic generated
Hub, exact-path project match, distinct logical and opaque runtime IDs, bridge
configuration behavior, task create/resume identity, and confirmation that the
Hub stopped without monitoring. Stale or cross-plugin evidence must fail.
Installed upgrade acceptance separately requires explicit authorization,
before/after exact versions, structured command results, preserved synthetic
Hub and repository state, and a fresh task that loads the target build.

## Audit command

Write all path-bearing evidence to ignored local state:

```text
python3 plugins/flightdeck/skills/flightdeck-setup/scripts/process_inventory.py \
  --source <read-only-source-root> \
  --candidate plugins/flightdeck/skills/flightdeck-setup/assets/flightdeck-template \
  --plugin plugins/flightdeck \
  --json .flightdeck-local/parity/process-inventory.json
```

The report includes source, generated candidate, and plugin file counts,
classification totals, unresolved items, and deterministic path-list digests.
