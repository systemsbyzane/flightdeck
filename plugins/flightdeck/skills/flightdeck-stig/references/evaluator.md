# STIG Evaluator

Evaluate STIG rules against Kubernetes workloads with evidence collection and conservative status decisions.

## Inputs To Extract

- STIG ID, title, severity, check procedure, expected state, fix text, and CCI references.
- Target pod, namespace, and container.
- Optional Helm chart path.
- Optional notes as inline text or a file path.
- Output format: `text`, `json`, or `checklist`.

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
- `Not Applicable`: verified absence of the component, architecture makes the control irrelevant, or verified compensating controls satisfy the intent.
- `Not Reviewed`: cannot complete verification because of permissions, missing access, ambiguity, or inconclusive evidence.

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
```

## JSON Output

When `--output-format json` is requested, produce an object shaped for downstream CKL tooling:

```json
{
  "vuln_id": "V-XXXXXX",
  "status": "Not a Finding",
  "status_summary": "The system is compliant. Evidence shows the required control is implemented.",
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

