# Program README Template

Copy this content into `compliance/<program>/README.md` and replace bracketed
labels with program-specific values.

```md
# [Program Name] Compliance Workspace

This workspace contains local context, source artifacts, input templates,
working records, and deliverables for [Program Name] DoD RMF, eMASS, and ATO
package work.

## Program Context

- Program or system name: [Program Name]
- Mission owner: [Mission Owner]
- Authorization boundary: [Boundary Summary]
- Primary environment: [Environment]
- Current package objective: [ATO package objective]

## Folder Map

- `context/` - mission, boundary, architecture, deployment environment,
  contacts, assumptions, and constraints
- `source-documents/` - prior SSPs, SARs, POA&Ms, policies, diagrams, scans,
  STIG artifacts, eMASS exports, and package instructions
- `input-templates/` - eMASS workbook templates, customer control matrices, and
  upload formats to fill
- `deliverables/` - polished workbooks, policies, SSP narrative, summaries, and
  package-support documents
- `working-records/` - internal structured records, change summaries,
  validation results, and unresolved decisions excluded from delivery by
  default
- `control-assessments/` - control-by-control implementation and assessment
  notes
- `poam/` - POA&M candidates, weakness analysis, milestones, and closure notes
- `evidence-index/` - source maps and evidence references
- `working-notes/` - scratch analysis, interview notes, and unresolved
  questions

## First Review Prompt

```text
Read this workspace and the linked hub compliance docs. Inventory the context,
source documents, and input templates. Summarize what can be assessed now, what
evidence appears strongest, and what is missing before filling any workbook.
```
```

Replace every bracketed token before using this README in a program workspace.
