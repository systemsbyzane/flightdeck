# Evidence Analysis Guide

Use this guide to decide how much confidence a control claim deserves.

## Evidence Tiers

### Tier 1: Direct Current Evidence

Direct current evidence shows the implemented control in the current program
environment. Examples include current scan exports, STIG checklists, validated
configuration output, current diagrams, current policy with approval context,
recent tickets, current inventories, and current eMASS exports.

### Tier 2: Direct Stale Evidence

Direct stale evidence may still be useful but needs review. Examples include an
old SSP, prior POA&M, outdated diagram, superseded policy, old scan, or previous
authorization package.

### Tier 3: Indirect Evidence

Indirect evidence suggests implementation but does not prove it. Examples
include architecture descriptions, generic platform statements, inherited
service descriptions, dependency documentation, or team notes.

### Tier 4: Assertion

Assertion is a statement without supporting evidence. It may guide follow-up,
but it should not be treated as proof.

### Tier 5: Conflict

Conflicting evidence exists when sources disagree on owner, status, boundary,
implementation, date, tool, or applicability. Conflict must be surfaced, not
averaged away.

## Evidence Index Fields

An evidence index should capture:

- evidence ID
- file path
- source type
- source date or observed date
- owner or author when known
- related controls
- relevant pages, sheets, rows, sections, or screenshots
- summary
- evidence tier
- sensitivity notes
- unresolved questions

## Citation Rules

- Cite file paths and locations where practical.
- For spreadsheets, cite workbook, sheet, row, and column when known.
- For PDFs, cite page or section when tooling can identify it.
- For diagrams, cite filename and visible label or page.
- For prepared summaries, cite the source artifacts used to support them.
- Do not cite a document as evidence for a claim it does not actually support.

## Staleness

Treat age as a risk factor, not an automatic failure. A stable policy may remain
valid longer than a vulnerability scan. A network diagram may become stale after
an architecture change. A prior POA&M may be useful for history but not proof of
current closure.

## Conflict Handling

When evidence conflicts:

1. Identify the conflict in notes.
2. Prefer newer direct evidence over older indirect evidence when context
   supports that choice.
3. Preserve older evidence as history when it explains package evolution.
4. Ask for owner clarification when the conflict affects workbook fields,
   POA&M status, boundary, inheritance, or residual risk.

## Unsupported Claims

Unsupported claims should become one of:

- a gap
- an assumption for reviewer confirmation
- a POA&M candidate
- a request for additional evidence
- a recommendation, clearly labeled as not yet approved
