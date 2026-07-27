---
name: flightdeck-stig
description: Evaluate, review, and plan remediation for STIG compliance while deterministically parsing or generating CKL files in a portable Flightdeck. Use for natural STIG intent, pasted rules, evidence or applicability questions, inherited controls, Kubernetes or chart checks, evidence-gap reviews, CKL import or export, batch findings, or CKL-ready comments and details.
---

# Flightdeck STIG

Treat natural STIG intent as sufficient; explicit invocation is optional.
Adapt the depth to the request instead of requiring a fixed intake form.

Read `references/evaluator.md` before evaluating any rule,
`references/evidence-contract.md` for evidence, applicability, inherited
controls, or export readiness,
`references/ckl-workflow.md` for CKL or batch work,
`references/helm-remediation.md` for chart evaluation or remediation planning,
and `references/summary-extractor.md` for CKL-ready summaries.

Determine whether the request is a quick rule evaluation, evidence-gap review,
batch or CKL workflow, export-readiness check, or remediation plan. Ask only
for information that blocks an honest next step. Missing context normally
produces a draft with explicit gaps, not a refusal.

Collect read-only evidence only: local file inspection, rendered chart output,
safe cluster reads, and non-mutating in-container inspection. Notes guide what
to verify but are not evidence. Redact secrets and sensitive values.

Use exactly one status: `Not a Finding`, `Open`, `Not Applicable`, or
`Not Reviewed`. Reserve `Not Applicable` for verified architectural
inapplicability and `Not Reviewed` for inconclusive or inaccessible evidence.

Use the bundled deterministic scripts:

```text
python3 scripts/ckl_parser.py input.ckl -o parsed.json
python3 scripts/ckl_generator.py findings.json template.ckl output.ckl
python3 scripts/summary_extractor.py evaluation.json
python3 scripts/evaluation_validator.py evaluations.json --profile draft
python3 scripts/evaluation_validator.py evaluations.json --profile export
```

Use `draft` while evidence is still developing; it reports readiness gaps
without forcing every optional field. Use `export` only when the user asks for
a final CKL/evidence package or a release-readiness decision.

For repository, chart, CI/CD, platform, environment, or program-owned
inspection, follow the Flightdeck coordinator boundary and dispatch to the
owner before analysis. Route remediation to the applicable focused skill. A
STIG finding does not itself authorize source edits, pipeline execution,
deployment, shared-environment mutation, compliance submission, risk
acceptance, or closure.

Do not edit charts or mutate environments during evaluation unless the user
separately asks for remediation. A chart path authorizes evaluation and a plan,
not edits or rollout. Return CKL-ready status summary, finding details,
technical evidence, applicability rationale, confidence, unresolved evidence
gaps, and any required manual verification.
