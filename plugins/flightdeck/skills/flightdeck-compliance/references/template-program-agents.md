# Program Compliance AGENTS.md Template

Copy this content into a `compliance/<program>/AGENTS.md` file when creating a
program workspace manually.

```md
# Program Compliance AGENTS.md

This folder is a single program workspace for DoD RMF, eMASS, and ATO package
work.

## Startup Requirement

Read the local `README.md`, then read the shared hub compliance docs:

- `<hub-root>/docs/compliance/README.md`
- `<hub-root>/docs/compliance/dod-rmf-ato-operating-model.md`
- `<hub-root>/docs/compliance/emass-template-workflow.md`
- `<hub-root>/docs/compliance/control-assessment-methodology.md`
- `<hub-root>/docs/compliance/evidence-analysis-guide.md`
- `<hub-root>/docs/compliance/poam-generation-guide.md`
- `<hub-root>/docs/compliance/policy-generation-guide.md`
- `<hub-root>/docs/compliance/machine-readable-artifacts.md`
- `<hub-root>/docs/compliance/assessor-quality-bar.md`
- `<hub-root>/docs/compliance/artifact-sensitivity-and-handling.md`
- `<hub-root>/docs/compliance/program-workspace-guide.md`

## Program Evidence Boundary

This folder owns the program record. Use only the artifacts, notes, templates,
and user-provided facts in this workspace unless the user explicitly names
another source.

## eMASS Workbook Rules

- Inspect workbooks before editing.
- Preserve workbook structure, columns, formulas, validations, and hidden
  sheets unless the user explicitly asks for a transform.
- Fill only intended response fields.
- Save polished workbook copies under `deliverables/` unless the user gives a
  different path.
- Keep equivalent JSON/YAML working records, change summaries, renderings, and
  validation reports under `working-records/` when required.
- Keep internal records out of delivery packages unless explicitly requested.
- Produce internal notes for assumptions, evidence, fields not completed,
  authored fields, and unresolved questions.
- Resolve every template variable and remove AI/tool provenance, authoring
  notes, and review-workflow labels before delivery.

## Evidence Rules

Classify material claims as supported fact, reasonable inference, assumption,
gap, or recommendation. If the workbook cannot show those labels, put them in
companion notes under `control-assessments/`, `poam/`, or `evidence-index/`.

Do not invent authorization claims, eMASS status, control implementation,
closure evidence, approval, or upload acceptance.

## Sensitive Material

Do not expose secrets, credentials, raw controlled evidence, or customer
material outside this program workspace. Prefer source references over copying
sensitive raw content into prepared summaries.

## Delivery Rules

Treat final files as professional human-authored documents. Run the artifact
deliverable validator after the final render. Build archives from an explicit
allowlist and include only requested files.
```
