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
- Save generated workbook copies under `generated-documents/` unless the user
  gives a different path.
- Generate same-basename `.json` and `.yaml` sidecars alongside generated
  workbook copies and other generated artifacts.
- Produce companion notes for assumptions, evidence, skipped fields, generated
  fields, and unresolved questions.

## Evidence Rules

Classify material claims as supported fact, reasonable inference, assumption,
gap, or recommendation. If the workbook cannot show those labels, put them in
companion notes under `control-assessments/`, `poam/`, or `evidence-index/`.

Do not invent authorization claims, eMASS status, control implementation,
closure evidence, approval, or upload acceptance.

## Sensitive Material

Do not expose secrets, credentials, raw controlled evidence, or customer
material outside this program workspace. Prefer source references over copying
sensitive raw content into generated summaries.
```

