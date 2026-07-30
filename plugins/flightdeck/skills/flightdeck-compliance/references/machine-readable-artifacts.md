# Structured Compliance Working Records

Structured JSON and YAML can preserve traceability without becoming part of a
submission-facing package.

## Rule

Create a structured working record only when the user, program workflow, or
governing format requires it, or when it materially improves validation. Store
equivalent JSON and YAML under `working-records/`:

```text
deliverables/control-workbook.xlsx
working-records/control-workbook.json
working-records/control-workbook.yaml
```

Do not place working records beside deliverables or inside an archive unless
the user explicitly requests them. Do not record AI, model, Codex, prompt, tool,
render, inspection, or authoring-process provenance in customer-facing
manifests or working records intended for release.

## Minimum Fields

Use these top-level fields unless the user provides a stricter schema:

```yaml
schema_version: "2.0"
record_id: "program-record-local-id"
record_type: "control_workbook | control_assessment | poam_analysis | policy | evidence_index | risk_summary | package_note"
program: "program name"
document_path: "deliverables/control-workbook.xlsx"
prepared_at: "ISO-8601 timestamp when required"
status: "unsubmitted"
sensitivity: "program_sensitive"
inputs:
  - path: "relative/path/to/source"
    type: "policy | diagram | workbook | scan | stig | note | export | template"
    location: "page, sheet, row, section, or label when known"
document_updates:
  fields_authored:
    - "field or section name"
  fields_not_completed:
    - field: "field or section name"
      reason: "evidence gap or template-owned field"
claims:
  supported_facts:
    - claim: "fact"
      evidence_ids:
        - "EV-001"
  reasonable_inferences:
    - inference: "inference"
      basis:
        - "EV-001"
  assumptions:
    - "assumption requiring program confirmation"
  gaps:
    - "missing, stale, conflicting, or insufficient evidence"
evidence_refs:
  - evidence_id: "EV-001"
    path: "relative/path/to/source"
    location: "page, sheet, row, section, or label"
    tier: "direct_current | direct_stale | indirect | assertion | conflict"
open_actions:
  - "program action needed to resolve a documented gap"
```

Use another status only when the program record proves it and the governing
format requires it. Do not imply submission, acceptance, approval,
effectiveness, risk acceptance, or closure from file creation.

Include additional fields when useful, such as:

- `control_ids`
- `poam_candidates`
- `workbook_changes`
- `policy_sections`
- `risk_summary`
- `residual_risk`
- `open_questions`
- `source_hashes`

## Workbook Records

For a control workbook, record only verified changes:

```yaml
workbook_changes:
  source_template: "input-templates/template.xlsx"
  output_workbook: "deliverables/template-filled.xlsx"
  sheets_modified:
    - sheet: "Controls"
      columns_modified:
        - "Implementation Statement"
        - "Evidence"
      rows_modified:
        - "AC-2"
        - "AC-3"
  formulas_preserved: true
  hidden_sheets_preserved: true
  validations_preserved: true
  fields_not_completed:
    - field: "Import Status"
      reason: "template-owned field"
```

Do not claim formula, hidden-sheet, or validation preservation unless the
tooling inspected those properties.

## Sensitivity

Working records must not duplicate secrets, credentials, personal data, or
sensitive raw evidence. Prefer evidence locations. If a source contains
sensitive details, record the reference and handling note instead of the value.

## Consistency And Delivery

The deliverable and working records must agree on scope, evidence, assumptions,
gaps, and fields not completed. Update both after a document revision.

Before delivery:

1. validate the polished document for unresolved variables and internal
   process labels;
2. build the package from an explicit allowlist;
3. exclude `working-records/`, renderings, change summaries, and validation
   reports unless the user requested them;
4. verify the final archive contents, paths, and checksums.
