# Program Workspace Guide

Use this guide to create and operate one compliance program workspace.

## Create A Program Workspace

Copy the template folder:

```bash
cp -R <hub-root>/compliance/_program-template \
  <hub-root>/compliance/example-program
```

Rename `example-program` to the program name you want, using a neutral local program identifier.

## Open In Codex

Open the program folder itself as a Codex project:

`<hub-root>/compliance/<program>/`

The local `AGENTS.md` in that folder bridges the project back to the shared
hub compliance docs.

## Add Program Context

Use these folders consistently:

- `context/`: mission, system scope, boundary, architecture notes, contacts,
  environment, assumptions, and constraints
- `source-documents/`: prior SSPs, SARs, POA&Ms, diagrams, policies, scans,
  STIG artifacts, eMASS exports, and package instructions
- `input-templates/`: eMASS workbooks, control spreadsheets, customer upload
  templates, or package forms to fill
- `deliverables/`: polished workbooks, policies, SSP narrative, summaries, and
  other files intended for submission or external review
- `working-records/`: internal structured records, change summaries,
  validation results, and unresolved decisions that must not ship by default
- `control-assessments/`: control-by-control notes and prepared assessment
  rationale
- `poam/`: POA&M candidates, weakness analysis, milestones, and closure notes
- `evidence-index/`: evidence maps and source indexes
- `working-notes/`: scratch analysis and unresolved questions

## Recommended First Prompt

After opening a program workspace in Codex, start with:

```text
Read this program workspace instructions and the linked hub compliance docs.
Inventory the program context, source documents, and input templates. Then
summarize what you can assess now, what evidence appears strongest, and what
is missing before filling any eMASS workbook.
```

## Working With eMASS Workbooks

Put new workbooks in `input-templates/`. Ask Codex to inspect the workbook
first and report sheets, columns, formulas, validations, and likely target
fields before writing an output copy.

Write polished output files to `deliverables/`, with internal analysis in
`control-assessments/`, `poam/`, `evidence-index/`, or `working-records/`.

Create equivalent JSON and YAML working records only when the user, program
workflow, or governing format requires them. Store them in `working-records/`,
not beside the deliverable, and exclude them from submission packages unless
the user explicitly requests them. Use
`<hub-root>/docs/compliance/machine-readable-artifacts.md` for their structure.

Before delivery, resolve every template token, remove authoring-process
metadata, validate the final content, and build archives from an explicit
file-type allowlist.

## Program Boundaries

Do not reuse facts from one program in another program unless the source
artifact explicitly applies to both. Shared method belongs in `docs/compliance/`;
program facts belong in `compliance/<program>/`.
