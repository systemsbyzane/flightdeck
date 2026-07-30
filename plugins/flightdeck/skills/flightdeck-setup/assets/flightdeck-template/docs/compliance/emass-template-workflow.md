# eMASS Template Workflow

Use this workflow when a program workspace contains an eMASS workbook, customer
control spreadsheet, export, or required upload template.

## Principle

The provided workbook is the format of record. Preserve it unless the user
explicitly asks for a transformed workbook. Fill intended response fields from
program evidence; do not redesign the workbook.

## Initial Inspection

Before writing values:

- identify every worksheet
- identify header rows, tables, hidden sheets, formulas, merged cells, data
  validation, locked or protected areas, and calculated fields when tooling can
  see them
- identify control identifiers, control text, implementation fields,
  assessment fields, status fields, evidence fields, POA&M fields, and comment
  fields
- identify columns intended for authored response content
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
- Put authored content only in intended response columns.
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
- Save the polished output as a new file under `deliverables/`.

## Evidence Mapping

For each filled control row, create or update companion notes that include:

- control ID and title
- authored workbook fields
- source files and locations
- supported facts
- reasonable inferences
- assumptions
- gaps or conflicts
- required program action

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

Produce the requested workbook under `deliverables/`. Maintain assessment
notes, evidence-index updates, a change summary, unresolved questions, and
fields not completed under the applicable internal folders or
`working-records/`; do not place them beside the workbook unless requested.

The workbook is eMASS-ready in structure only when it preserves the provided
template. Acceptance by eMASS is not claimed until upload and validation
evidence exists.

Resolve all template variables in the output. When evidence does not establish
a value, leave the field blank if allowed or write a professional bounded gap
statement. Do not use `TBD`, bracketed variables, authoring notes, or
AI/tool/review-process labels. Run the artifact deliverable validator after the
final workbook render.

Use `machine-readable-artifacts.md` when a structured working record is
required. It should include verified workbook changes, evidence references,
assumptions, and fields not completed, and it must remain outside the delivery
package unless explicitly requested.
