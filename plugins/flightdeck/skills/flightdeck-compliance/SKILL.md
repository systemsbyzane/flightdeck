---
name: flightdeck-compliance
description: Coordinate evidence-backed compliance program workspaces and professional artifacts. Use for control assessments, evidence indexes, RMF or ATO support, eMASS-style workbooks, OSCAL, policies, POA&M candidates, structured-record validation, or package quality review.
---

# Flightdeck Compliance

Work only in the resolved program workspace. Program evidence and prepared
artifacts remain outside tracked plugin content.

Inventory boundary, baseline, roles, common-control providers, evidence cutoff,
handling authority, requested deliverables, and available evidence. Classify
each claim as supported fact, reasonable inference, assumption, gap, or
recommendation. Missing or inaccessible evidence remains a gap.

Preserve source templates and workbook structure. Generate same-basename JSON
and YAML working records with typed semantic parity only when the user,
program workflow, or governing format requires them. Keep those records outside
the delivery directory. Keep identifiers as strings. Create POA&M candidates
only for supported weaknesses; unknowns may be evidence requests. Never invent
implementation, effectiveness, dates, owners, authorization, acceptance, risk
approval, or closure evidence.

Use the artifact or STIG skill for those file types. Read
`references/method-index.md` first, then the linked method that matches the
requested artifact. Use the bundled `template-*` references for program
workspace scaffolding, evidence indexes, control notes, and POA&M analysis.

Human-facing deliverables must read as complete professional documents. Follow
the artifact presentation gate: do not expose AI or tool provenance, authoring
or review workflow labels, internal QA notes, or unresolved template variables.
Use neutral document status such as `unsubmitted` only when a status field is
required, and claim submission, approval, acceptance, effectiveness, or closure
only from the program record.
