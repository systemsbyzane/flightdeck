# STIG Evaluator

Evaluate STIG rules against Kubernetes workloads with evidence collection and conservative status decisions.

## Adaptive Intake

Extract what is available:

- STIG ID, benchmark release, title, severity, check procedure, expected state,
  fix text, and CCI references.
- Target type and identity, source revision, environment, and applicable
  workload, namespace, or container.
- Optional chart path, evidence artifacts, notes, and output format.

Do not turn this list into a mandatory questionnaire. Begin with supplied
context, state unknowns, and request only the next fact required to distinguish
`Open`, `Not Applicable`, or `Not Reviewed`.

Read `evidence-contract.md` for applicability, inherited controls, structured
batch records, and draft-versus-export readiness.

## Evidence Collection

Use read-only commands and keep complete command outputs for the technical audit trail. Useful patterns:

```bash
kubectl get pod <pod> -n <ns> -o yaml
kubectl describe pod <pod> -n <ns>
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.securityContext}'
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.containers[*].securityContext}'
kubectl exec -n <ns> <pod> -c <container> -- stat -c '%a %U:%G' /path
kubectl exec -n <ns> <pod> -c <container> -- ps aux
kubectl exec -n <ns> <pod> -c <container> -- netstat -tuln
kubectl get networkpolicy -n <ns> -o yaml
kubectl get rolebinding -n <ns> -o yaml
kubectl auth can-i --list --as=system:serviceaccount:<ns>:<serviceaccount>
helm template <release> <chart> -f <values> --namespace <ns>
```

Avoid dumping secrets. If inspecting environment or config files, filter and redact sensitive names and values.

## Notes Are Not Evidence

Use notes to guide checks, not to support findings directly.

Example:

- Notes claim service mesh mTLS is enabled.
- Verify with actual Istio/Linkerd resources such as `PeerAuthentication`, `DestinationRule`, or equivalent policy.
- Cite the verified resource, not the note.

## Status Decisions

Use CKL status labels exactly:

- `Not a Finding`: verified compliant implementation.
- `Open`: verified failure, missing security control, or no verified compensating control.
- `Not Applicable`: verified absence of the component or verified architecture makes the control irrelevant.
- `Not Reviewed`: cannot complete verification because of permissions, missing access, ambiguity, or inconclusive evidence.

Do not use `Not a Finding` without positive direct or inherited evidence. Do
not use `Not Applicable` without a specific applicability rationale and
evidence for the boundary. A compensating control requires explicit
rule-intent analysis and normally warrants human review.

## Confidence

Include confidence in text reports, but omit it from CKL JSON fields unless explicitly requested.

- `HIGH`: direct value match or clear binary evidence.
- `MEDIUM`: evidence is valid but requires interpretation or architectural context.
- `LOW`: significant judgment required, evidence partial, or container-era interpretation is debatable. Include human review guidance.

## Container-Era Interpretation

Many STIGs assume VMs or bare metal. For Kubernetes, map legacy controls carefully:

| Legacy concept | Kubernetes equivalent |
| --- | --- |
| SSH administration | `kubectl exec` with RBAC and API audit logs |
| Local user accounts | service accounts, fixed numeric UIDs, external IdP |
| Host firewall | NetworkPolicy and service mesh policy |
| SELinux/AppArmor | pod/container `securityContext` and PSA |
| Package updates | immutable image rebuild and redeploy |
| Local syslog | stdout/stderr plus cluster log aggregation |
| systemd service controls | container entrypoint and Kubernetes controller |

Use `Not Applicable` only when the mismatch is real and evidence supports it.

## Report Format

For text output, return:

```markdown
## STIG Evaluation Report

**STIG ID:** V-XXXXXX | **Status:** <Not a Finding|Open|Not Applicable|Not Reviewed> | **Confidence:** <HIGH|MEDIUM|LOW>
**Title:** <title>
**Severity:** <CAT I/II/III or high/medium/low>
**Target:** <pod or chart target>
**Applicability:** <applicable|not_applicable|unknown> - <rationale>

## Status Summary (For STIG Comments)

<2-4 concise sentences. Use generic terms like "the system", "the database", or "the application". Do not include pod names, STIG IDs, or raw command output.>

## Finding Details (For STIG Details Field)

**Status:** <status>
**Confidence:** <confidence>

**Evidence:**
- <verified fact and verification method>
- <verified fact and verification method>

<For Open: include Risk and Remediation Required.>
<For Not Applicable: include Compensating Controls and Justification.>
<For Not Reviewed: include Reason and Manual Verification Required.>
<For LOW confidence: include Human Review Recommended.>

## Technical Details (For Reference)

**Commands Run:**
```bash
<commands>
```

**Raw Evidence:**
```text
<redacted command output>
```

**Analysis:**
<comparison between expected and observed state>

**Evidence Gaps:**
<missing provenance, revision, access, applicability, or manual review>
```

## JSON Output

When `--output-format json` is requested, produce an object shaped for downstream CKL tooling:

```json
{
  "vuln_id": "V-XXXXXX",
  "status": "Not a Finding",
  "status_summary": "The system is compliant. Evidence shows the required control is implemented.",
  "confidence": "HIGH",
  "applicability": {
    "state": "applicable",
    "rationale": "The rule applies to the evaluated workload."
  },
  "evidence": [
    {
      "kind": "direct",
      "source": "rendered workload manifest",
      "summary": "The required setting is configured."
    }
  ],
  "finding_details": [
    "Required setting is enabled",
    "Configuration was verified from the rendered workload manifest"
  ],
  "technical_evidence": {
    "commands_run": [],
    "analysis": ""
  }
}
```

Keep `status_summary` and `finding_details` CKL-ready:

- No pod names, node names, container names, database names, file paths, line numbers, or STIG ID references.
- No raw JSON structures.
- No unverified claims.
- Plain strings only in `finding_details`.
