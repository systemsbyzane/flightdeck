# Machine-Readable Artifact Sidecars

Every generated compliance artifact should have machine-readable sidecars in
both JSON and YAML.

## Rule

When Codex generates a human-readable artifact, workbook, policy, POA&M
analysis, control note, evidence index, or package-support document, it should
also generate same-basename sidecar files in the same directory:

```text
generated-documents/control-workbook.xlsx
generated-documents/control-workbook.json
generated-documents/control-workbook.yaml

poam/open-weaknesses.md
poam/open-weaknesses.json
poam/open-weaknesses.yaml
```

The sidecars should contain equivalent structured content. JSON is preferred
for programmatic parsing. YAML is preferred for human-readable review and
manual editing.

## Minimum Sidecar Fields

Use these top-level fields unless the user provides a stricter schema:

```yaml
schema_version: "1.0"
artifact_id: "program-artifact-local-id"
artifact_type: "control_workbook | control_assessment | poam_analysis | policy | evidence_index | risk_summary | package_note"
program: "program name"
source_human_artifact: "relative/path/to/generated-artifact.ext"
generated_at: "ISO-8601 timestamp when known"
generated_by: "codex"
status: "draft_for_human_review"
sensitivity: "program_sensitive"
inputs:
  - path: "relative/path/to/source"
    type: "policy | diagram | workbook | scan | stig | note | export | template"
    location: "page, sheet, row, section, or label when known"
outputs:
  fields_generated:
    - "field or section name"
  fields_skipped:
    - field: "field or section name"
      reason: "why it was not generated"
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
    - "assumption requiring owner review"
  gaps:
    - "missing, stale, conflicting, or insufficient evidence"
evidence_refs:
  - evidence_id: "EV-001"
    path: "relative/path/to/source"
    location: "page, sheet, row, section, or label"
    tier: "direct_current | direct_stale | indirect | assertion | conflict"
reviewer_actions:
  - "action for human reviewer"
```

Include additional fields when useful, such as:

- `control_ids`
- `poam_candidates`
- `workbook_changes`
- `policy_sections`
- `risk_summary`
- `residual_risk`
- `open_questions`
- `source_hashes`
- `tooling_notes`

## Workbook Sidecars

For generated eMASS or control workbooks, include:

```yaml
workbook_changes:
  source_template: "input-templates/template.xlsx"
  output_workbook: "generated-documents/template-filled.xlsx"
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
  skipped_columns:
    - column: "Import Status"
      reason: "template-owned field"
```

Do not claim formula, hidden-sheet, or validation preservation unless the
tooling inspected those properties.

## Sensitivity

Sidecars should not duplicate secrets, credentials, personal data, or sensitive
raw evidence. Prefer references to evidence locations. If a source contains
sensitive details, capture the evidence reference and handling note instead of
copying the sensitive value.

## Consistency

The human artifact and sidecars should agree on:

- controls covered
- evidence used
- assumptions
- gaps
- skipped fields
- reviewer actions
- draft status

If a human artifact is revised, regenerate or update the sidecars before
presenting the package as review-ready.

