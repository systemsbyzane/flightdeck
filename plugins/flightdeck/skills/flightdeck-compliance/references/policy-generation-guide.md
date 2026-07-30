# Policy Generation Guide

Use this guide when drafting policies, procedures, plans, or control narratives
from a program workspace.

## Document Status

Do not describe policy language as approved, signed, published, or enforced
unless the program record proves that status. When the governing template
requires a status and no later status is evidenced, use `unsubmitted`. Do not
add draft, human-review, AI, model, Codex, prompt, or tooling labels to the
document.

## Inputs

Useful policy inputs include:

- existing program policies
- prior SSP language
- customer or organization policy templates
- system architecture and boundary notes
- role and responsibility descriptions
- scan or assessment findings
- interviews and working notes
- control workbook requirements

## Output Standard

A policy or procedure should identify:

- purpose
- scope
- roles and responsibilities
- required activities
- cadence or triggering conditions
- evidence records
- exceptions or deviations
- review and approval expectations
- related controls
- assumptions and source artifacts

## Control Alignment

When drafting for RMF package support:

- link policy sections to relevant controls where possible
- avoid overclaiming technical implementation in policy text
- separate policy requirement from operating procedure
- separate desired future state from current approved program state

## Good Language

Good package-support policy language is specific enough for reviewers:

```text
The program maintains an access review procedure for privileged accounts within
the authorization boundary. The ISSO coordinates the review with system
administrators and retains review evidence with the program security artifacts.
```

If cadence, owner, or tooling is unknown, state “Not established in the
available record” when the document requires an answer, or leave the field
blank when permitted. Record detail in internal working records rather than
inserting a template variable or generic value.

## Internal Working Record

Maintain an internal record listing:

- sources used
- assumptions
- decisions needed from the program owner
- controls supported
- evidence still needed

Keep this record under `working-records/` and out of the deliverable unless the
user or governing template explicitly requests it. Validate the final policy
for unresolved variables and authoring-process metadata before delivery.
