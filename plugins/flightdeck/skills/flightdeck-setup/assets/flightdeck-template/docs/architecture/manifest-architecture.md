# Helm And YAML Manifest Architecture

Use this guide for changes in `the owning charts repository` or any repo that renders
Kubernetes manifests, Helm values, Kustomize overlays, GitHub workflow YAML, or
deployment YAML.

## Intent

Manifest changes are architecture changes. They define runtime identity,
permissions, networking, storage, image provenance, security posture, and
upgrade behavior. Treat YAML and Helm templates as production code.

## Ownership

- Chart templates, chart defaults, chart values, and chart image metadata belong
  in `the owning charts repository`.
- Product repos pin released chart versions and compose product-level deployment
  definitions.
- Customer or program repos own environment-specific overrides.
- Application code, Dockerfiles, and base image selection belong in the source
  or image repo that owns the image.

## Secure Manifest Design

Before changing a chart or manifest, identify:

- workload identity: ServiceAccount, RBAC, namespace, labels, and selectors
- network exposure: Ingress, Gateway, Service, NetworkPolicy, ports, and TLS
- storage: PVCs, volume mounts, permissions, backup, and migration behavior
- secrets: Secret, ExternalSecret, SOPS, env vars, projected files, and rotation
- images: repository, tag, digest, pull policy, imagePullSecrets, and provenance
- pod security: runAsUser, runAsNonRoot, capabilities, seccomp, read-only root
  filesystem, privilege escalation, and host access
- scheduling: affinity, tolerations, node selectors, topology, resources, and
  disruption budgets
- observability: probes, ServiceMonitor, logs, metrics, traces, and dashboards
- upgrade behavior: immutable fields, hooks, CRDs, data migration, rollback, and
  compatibility

## Helm/YAML Rules

- Keep templates deterministic and readable. Avoid clever templating when a
  plain value or helper is clearer.
- Prefer explicit values and documented defaults over implicit fallbacks.
- Validate every user-provided value before using it in names, labels,
  annotations, selectors, commands, args, URLs, or security-sensitive fields.
- Keep labels and selectors stable across upgrades unless the rollout impact is
  intentional and documented.
- Do not change resource names, selector labels, PVC names, Service names, or
  CRD ownership casually; those are compatibility contracts.
- Avoid defaulting to cluster-wide permissions. Scope RBAC to the namespace and
  verbs the workload actually needs.
- Do not template plaintext secrets into rendered manifests.
- Avoid hooks that mutate live state unless there is a clear upgrade and
  rollback plan.
- Keep chart values backwards-compatible unless the breaking change is explicit,
  coordinated, and documented.

## Validation

For chart changes, run the repo-native validation first:

```bash
make validate
```

For risky templates, also render the affected chart and inspect the result:

```bash
helm template <release> ./charts/<chart> --values <values-file> --namespace <namespace>
```

For workflow YAML changes, run:

```bash
actionlint .github/workflows/<workflow>.yaml
```

Review rendered manifests for:

- unintended namespace, name, selector, label, or annotation changes
- widened RBAC
- plaintext secrets
- privileged pod settings
- missing probes or resources
- image metadata drift
- compatibility with existing deployed releases

## PR-Ready Standard

A manifest change is not ready until the rendered output has been reviewed or
the reason rendering was not possible is documented, security-sensitive fields
have been checked, and the repo's validation command has been run or explicitly
skipped with a reason.

