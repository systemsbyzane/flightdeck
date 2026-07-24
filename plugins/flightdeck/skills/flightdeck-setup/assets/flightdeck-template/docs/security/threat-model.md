# Threat Model Template

Use this for security-sensitive changes or when the blast radius is unclear.

## Scope

- Workload:
- Repo:
- Feature or behavior:
- Environment:
- Assets at risk:

## Actors

- Authenticated tenant user:
- Admin or platform operator:
- External unauthenticated user:
- Compromised dependency, image, pod, or token:
- CI, automation, or deployment actor:

## Trust Boundaries

List boundaries crossed by the change, such as browser to API, API to database,
API to Kubernetes, chart to cluster, GitHub Actions to registry, tenant to
tenant, or local Mac to `remote-validation`.

## Data And Secrets

Identify sensitive data, credentials, tokens, kubeconfigs, customer data,
tenant-scoped data, audit records, and generated artifacts touched by the
change.

## Abuse Cases

- Unauthorized read:
- Unauthorized mutation:
- Tenant data exposure:
- Privilege escalation:
- Secret exposure:
- Supply-chain tampering:
- Unsafe default or fallback:
- Denial of service or expensive query:

## Required Controls

List concrete controls in the owning repo, such as backend authorization,
namespace validation, stable subject IDs, input normalization, request timeouts,
manifest validation, image pinning, secret handling, audit events, or explicit
error states.

## Validation Evidence

List tests, scans, command output, rendered manifests, workflow artifacts, or
cluster checks that prove the controls work.

## Residual Risk

State what remains unverified and whether that risk is acceptable for the
current change.

