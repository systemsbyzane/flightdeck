---
name: flightdeck-stig
description: Evaluate and document STIG compliance and deterministically parse or generate CKL files in a portable Flightdeck. Use for pasted STIG rules, Kubernetes or chart evidence, CKL import or export, batch findings, or CKL-ready comments and details.
---

# Flightdeck STIG

Read `references/evaluator.md` before evaluating any rule,
`references/ckl-workflow.md` for CKL or batch work,
`references/helm-remediation.md` for chart evaluation or remediation planning,
and `references/summary-extractor.md` for CKL-ready summaries.

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
```

Do not edit charts or mutate environments during evaluation unless the user
separately asks for remediation. A chart path authorizes evaluation and a plan,
not edits or rollout. Return CKL-ready status summary, finding details,
technical evidence, confidence, and any required manual verification.
