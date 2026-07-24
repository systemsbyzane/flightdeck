# POA&M Generation Guide

Use this guide to create POA&M-ready analysis from control gaps and weaknesses.

## When To Create A POA&M Candidate

Create a candidate when evidence shows or strongly suggests:

- a required control element is not implemented
- a control is only partially implemented
- implementation exists but evidence is missing or stale enough to block review
- scan, STIG, test, or assessment results show a weakness
- policy or procedure does not match actual implementation
- inherited control responsibility is unclear and affects authorization risk
- a prior POA&M item remains open, recurring, or unsupported by closure evidence

Do not create POA&M items for every unknown. Some unknowns are evidence
requests, not confirmed weaknesses.

## POA&M Candidate Fields

Capture these fields when available:

- weakness ID or local candidate ID
- affected control or control enhancement
- weakness statement
- source of weakness
- affected system, component, environment, or boundary
- risk or impact
- root cause
- remediation plan
- milestones
- milestone owner
- scheduled completion date
- dependencies
- residual risk
- required closure evidence
- status recommendation
- assumptions and gaps

If a required field is not known, mark it as an information gap in the analysis
notes instead of inventing a value.

## Weakness Statement Pattern

```text
[System/component/process] does not currently [required control outcome] for
[scope], as shown by [source evidence]. This may result in [risk/impact] until
[remediation direction] is completed and validated.
```

Keep the statement specific. Avoid generic language such as "control is not
implemented" when the evidence identifies a narrower weakness.

## Milestone Quality

A useful milestone is observable and closable:

- update a named policy or procedure
- implement a named configuration change
- deploy a named technical control
- complete a named scan or STIG remediation
- collect a named evidence artifact
- obtain review or approval from a named role

Avoid milestones that only say "review", "fix", or "monitor" without a concrete
output.

## Closure Evidence

Define closure evidence before calling a POA&M ready. Closure may require:

- updated policy or procedure
- scan or STIG result
- configuration export
- ticket closure with implementation detail
- screenshot or system output
- reviewer approval
- updated SSP or control workbook language

Do not mark closure as supported when the folder contains only a remediation
plan.

