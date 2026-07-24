---
name: flightdeck-compliance
description: Coordinate evidence-backed compliance program workspaces and draft artifacts. Use for control assessments, evidence indexes, RMF or ATO support, eMASS-style workbooks, OSCAL, policies, POA&M candidates, sidecar validation, or package quality review.
---

# Flightdeck Compliance

Work only in the resolved program workspace. Program evidence and generated
artifacts remain outside tracked plugin content.

Inventory boundary, baseline, roles, common-control providers, evidence cutoff,
handling authority, requested deliverables, and available evidence. Classify
each claim as supported fact, reasonable inference, assumption, gap, or
recommendation. Missing or inaccessible evidence remains a gap.

Preserve source templates and workbook structure. Generate same-basename JSON
and YAML sidecars with typed semantic parity. Keep identifiers as strings.
Create POA&M candidates only for supported weaknesses; unknowns may be evidence
requests. Never invent implementation, effectiveness, dates, owners,
authorization, acceptance, risk approval, or closure evidence.

Use the artifact or STIG skill for those file types. Read
`references/method-index.md` first, then the linked method that matches the
requested artifact. Use the bundled `template-*` references for program
workspace scaffolding, evidence indexes, control notes, and POA&M analysis.
Outputs are drafts until authorized human review.
