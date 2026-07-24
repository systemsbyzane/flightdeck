# Helm STIG Remediation

Use this reference when a STIG evaluation includes `--chart`, asks for Helm remediation, or involves chart security settings.

## Default Behavior

With a chart path, evaluate chart compliance as well as the running pod. A fresh deployment from the chart is the long-term compliance target. If the pod is stale but the chart renders compliant manifests, the finding can be `Not a Finding` with explanation.

Do not edit chart files unless the user explicitly asks for remediation changes. If the user only provides `--chart`, write or return a remediation plan.

## Chart Checks

Inspect:

```bash
ls -la <chart>/Chart.yaml <chart>/values.yaml <chart>/templates
rg -n "securityContext|runAsNonRoot|allowPrivilegeEscalation|capabilities|seccompProfile|readOnlyRootFilesystem|resources|networkPolicy" <chart>
helm template <release> <chart> -f <values> --namespace <ns>
```

Determine whether the required control is:

1. Already configurable in values.
2. Missing from values but supported by templates.
3. Unsupported by templates and requiring a template change.
4. A security default that should be hard-coded.

## Chart Pattern Discipline

Follow the owning repository's existing library-chart conventions before introducing new values. Prefer numeric users and reusable values.

Standard container hardening values when applicable:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
  seccompProfile:
    type: RuntimeDefault
  readOnlyRootFilesystem: true
```

Do not force `readOnlyRootFilesystem: true` where the workload demonstrably needs writes unless writable volumes are configured for those paths.

## Remediation Plan Format

When producing a plan, use:

```markdown
# STIG V-XXXXXX Helm Remediation

**STIG:** V-XXXXXX - <title>
**Severity:** <severity>
**Chart:** <chart path/name>

## Current State

<what is configured and why it fails or is ambiguous>

## Recommended Changes

### values.yaml

```yaml
<minimal proposed values>
```

### Template Changes

<only if values are not enough>

## Apply Remediation

```bash
helm diff upgrade <release> <chart> -f <values> -n <namespace>
helm upgrade <release> <chart> -f <values> -n <namespace>
```

## Verification

```bash
helm template <release> <chart> -f <values> --namespace <namespace> | rg -n "<setting>"
kubectl get pod <pod> -n <namespace> -o jsonpath='{.spec.containers[*].securityContext}'
```

## Caveats

<rollout, workload, or compatibility notes>
```

If writing a file, use `.stigs/<STIG-ID>_helm-remediation.md` in the project root.

