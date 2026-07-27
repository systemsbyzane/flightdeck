# STIG Evidence Contract

Use this reference for applicability decisions, inherited controls,
evidence-gap reviews, structured batches, and export readiness.

## Flexible Intake

Do not require every field before useful work can begin. Start from the rule,
CKL, target, artifact, or evidence the user supplies. Record unknowns and ask
only for the next fact that blocks an honest status.

Use two readiness profiles:

- `draft`: preserve partial work and report evidence gaps as warnings.
- `export`: require the provenance and rationale needed for a reviewable
  checklist or evidence package.

The profiles change validation strictness, not the STIG status.

## Evidence Record

For a structured batch, use:

```json
{
  "schema_version": "flightdeck.stig-evaluations/v1",
  "benchmark": {
    "title": "Synthetic Platform STIG",
    "release": "Release 1"
  },
  "target": {
    "name": "synthetic-service",
    "kind": "workload",
    "revision": "synthetic-revision"
  },
  "evaluations": [
    {
      "vuln_id": "V-000001",
      "status": "Not a Finding",
      "confidence": "HIGH",
      "applicability": {
        "state": "applicable",
        "rationale": "The rule applies to the workload runtime."
      },
      "evidence": [
        {
          "kind": "direct",
          "source": "rendered manifest",
          "summary": "The required value is set on the evaluated container."
        }
      ],
      "finding_details": [
        "The required value is configured."
      ],
      "comments": "The system implements the required control."
    }
  ]
}
```

Keep technical evidence specific enough to reproduce the decision. Keep CKL
comments generic and free of machine-local paths, raw secrets, or target
identifiers that do not belong in the checklist.

## Provenance

Classify each evidence item:

- `direct`: observed configuration, command output, or authoritative artifact
  for the evaluated target.
- `inherited`: a control supplied across a documented platform, service, or
  organizational boundary.
- `declared`: a note, policy statement, interview response, or unverified
  claim that guides follow-up but cannot independently prove a status.

Inherited evidence must identify the boundary, responsible party, and
authoritative source. Do not convert missing workload evidence into inherited
compliance merely because a platform could provide the control.

Record the exact benchmark release, target identity, source revision, and
environment context when available. If the current deployed revision is
unknown, distinguish rendered or repository evidence from observed runtime
evidence.

## Applicability And Status

Decide applicability before status:

- `applicable`: the target owns or consumes the control.
- `not_applicable`: verified architecture excludes the control.
- `unknown`: the boundary or target is not sufficiently understood.

Use status conservatively:

- `Not a Finding` requires applicable scope and positive direct or inherited
  evidence.
- `Open` requires applicable scope and evidence of a failure, missing control,
  or unsupported compensating control.
- `Not Applicable` requires verified `not_applicable` scope, a specific
  rationale, and evidence of the architectural boundary.
- `Not Reviewed` is correct when evidence, access, target identity, or
  applicability remains inconclusive.

Compensating controls do not automatically mean `Not Applicable`. Explain how
the alternate control satisfies the rule intent and preserve human review when
the interpretation is judgment-heavy.

## Evidence-Gap Review

For an existing CKL or batch, report:

1. status conflicts or unsupported conclusions;
2. missing benchmark, target, revision, applicability, or provenance;
3. stale, declared-only, ambiguous, or target-mismatched evidence;
4. duplicate identifiers and noncanonical statuses;
5. CKL comments/details that expose machine-local or sensitive data;
6. the smallest next evidence collection step;
7. whether the batch is draft-safe or export-ready.

Do not silently upgrade a status. Preserve the original value, explain the
gap, and recommend the conservative status when evidence does not support it.

## Remediation Ownership

Keep evaluation separate from remediation:

| Finding surface | Route |
| --- | --- |
| application or service source | `$flightdeck-development` |
| Helm, Kubernetes YAML, or chart defaults | `$flightdeck-charts` |
| build, scan, signing, release, or delivery pipeline | `$flightdeck-ci` |
| cluster, cloud, identity, network, or shared platform | `$flightdeck-platform` |
| program evidence, package language, or POA&M | `$flightdeck-compliance` |

When several owners contribute, create one finding record with explicit
responsibility boundaries and sequence separate owner work. Do not use the Hub
to inspect owner code or live state before dispatch.
