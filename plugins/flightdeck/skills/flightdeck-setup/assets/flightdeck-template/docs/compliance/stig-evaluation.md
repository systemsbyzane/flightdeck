# STIG Evaluation

Use this workflow for a pasted STIG rule, a CKL, evidence questions,
applicability review, inherited controls, or remediation planning. Users do not
need to name a skill or complete a fixed intake form.

## What The User Experiences

A user can start with requests such as:

```text
Evaluate this STIG rule against the chart.
Review this CKL for unsupported statuses and evidence gaps.
Is this control inherited from the platform?
Plan remediation for the open STIG findings.
Make this batch ready for CKL export.
```

Flightdeck infers the workflow and asks only for context that blocks an honest
next step. A quick rule review can remain lightweight. A final evidence package
receives stricter provenance and consistency checks.

## Adaptive Workflow

1. Identify the benchmark release, rule, target, and requested outcome from
   available context.
2. Decide whether work is a quick evaluation, evidence-gap review, CKL batch,
   export-readiness check, or remediation plan.
3. Resolve ownership before inspecting repository code, program evidence, or
   live environment state.
4. Collect read-only evidence and distinguish direct, inherited, and merely
   declared information.
5. Decide applicability before assigning one conservative CKL status.
6. Return the status, confidence, evidence, rationale, gaps, and smallest next
   verification step.
7. Route remediation separately and preserve every approval boundary.

Missing context normally produces a useful draft with explicit gaps. It does
not force the user through a questionnaire or pretend that an unsupported
status is complete.

## Evidence And Applicability

Keep benchmark release, target identity, source revision, and environment
context explicit when available. Do not treat notes, interviews, policies, or
completed checklist fields as proof by themselves.

Classify evidence:

- direct evidence comes from the evaluated target or an authoritative target
  artifact;
- inherited evidence crosses a documented platform, service, or
  organizational boundary and names the responsible party;
- declared information guides follow-up but does not independently support a
  conclusion.

Use `Not a Finding` only with positive direct or inherited evidence. Use
`Not Applicable` only with verified architectural inapplicability and a
specific rationale. Use `Not Reviewed` when identity, access, applicability,
freshness, or evidence is inconclusive.

Rendered, applied, and observed runtime states are different. A compliant chart
render does not prove the running revision, and a generated CKL does not prove
that its findings are supported.

## Draft And Export Readiness

During iterative work, use the draft evidence profile. It preserves partial
evaluations and reports missing provenance or rationale as gaps.

Use the export profile only when the user requests a final checklist, evidence
package, or readiness decision. Export readiness requires:

- benchmark and target provenance;
- canonical statuses and unique identifiers;
- status-to-applicability consistency;
- direct or properly attributed inherited evidence for decided statuses;
- a specific rationale for `Not Applicable`;
- review reasons for `Not Reviewed`;
- CKL-ready comments and finding details.

Export readiness is a quality gate, not compliance submission or authorization.

## Remediation Routing

Route application source to development owners, Helm and Kubernetes YAML to
chart owners, delivery controls to CI/CD owners, shared infrastructure to
platform owners, and package language or POA&M work to the program compliance
workspace.

Evaluation remains read-only by default. A remediation request may authorize
scoped local source edits in the owning project, but it does not authorize
pipeline execution, publication, deployment, environment mutation, compliance
submission, risk acceptance, or closure.
