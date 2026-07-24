# eMASS Template Workflow

Use this workflow when a program workspace contains an eMASS workbook, customer
control spreadsheet, export, or required upload template.

## Principle

The provided workbook is the format of record. Preserve it unless the user
explicitly asks for a transformed workbook. Codex should fill intended response
fields from program evidence, not redesign the workbook.

## Initial Inspection

Before writing generated values:

- identify every worksheet
- identify header rows, tables, hidden sheets, formulas, merged cells, data
  validation, locked or protected areas, and calculated fields when tooling can
  see them
- identify control identifiers, control text, implementation fields,
  assessment fields, status fields, evidence fields, POA&M fields, and comment
  fields
- identify columns that appear safe for generated content
- identify columns that appear template-owned, formula-owned, or controlled by
  eMASS/customer import logic

If the intended target columns are ambiguous, ask the user before modifying the
workbook.

## Fill Rules

- Preserve sheet names, column names, formulas, validations, hidden sheets, and
  template-owned structure.
- Keep control identifiers exactly as supplied.
- Do not normalize control IDs unless the user asks.
- Do not overwrite formulas or calculated fields.
- Do not delete rows or columns from the input template.
- Put generated content only in intended response columns.
- If a required field lacks evidence, write a bounded gap statement where the
  template permits it and capture the issue in the companion notes.
- Use concise implementation language in cells and put fuller rationale in a
  companion assessment note when the workbook field is too small.
- When a workbook row includes an AP acronym, CCI, CCI definition,
  implementation guidance, or assessment procedure, write the implementation
  and assessment text for that specific row. Parent-control boilerplate is not
  acceptable for row-level assessment workbooks.
- Do not put evidence requests, screenshot instructions, assessment-result
  labels, or "evidence needs to show" language in a Control Implementation
  Narrative field. That field should describe only how the system implements
  the AP/CCI outcome. Put compliance status, test conclusions, evidence paths,
  screenshot locations, policy references, and pending-evidence instructions in
  status fields, Test Results, evidence columns, or companion notes.
- Save output as a new file under the program workspace, normally in
  `generated-documents/`.

## Evidence Mapping

For each filled control row, create or update companion notes that include:

- control ID and title
- generated workbook fields
- source files and locations
- supported facts
- reasonable inferences
- assumptions
- gaps or conflicts
- recommended reviewer action

When the workbook has no column for citations, use the companion note or
evidence index rather than forcing citations into an incompatible field.

## Cell Language Standard

Good workbook language is direct and reviewable:

- answer the specific AP/CCI definition in that row
- state the implementation posture as compliant, non-compliant, or not
  applicable only in assessment, status, or test-result fields when the workbook
  requires that determination
- name the implemented control or process
- name the owner or responsible role when known
- name the system component or boundary where it applies
- state the operational cadence when relevant
- reference evidence outside the workbook when the template supports it
- avoid unsupported absolutes such as "fully compliant" unless the assessment
  record proves that status

## Output Package

For each workbook generation run, produce:

- generated workbook
- same-basename `.json` and `.yaml` sidecars for the generated workbook
- companion assessment notes
- evidence index updates
- change summary listing modified sheets and columns
- unresolved questions
- skipped fields and why they were skipped

The generated workbook is eMASS-ready in structure only when it preserves the
provided eMASS template. Acceptance by eMASS is not claimed until upload and
validation evidence exists.

Use `machine-readable-artifacts.md` for the sidecar structure. The sidecars
should include workbook changes, sheets and columns modified, evidence
references, assumptions, skipped fields, and reviewer actions.

