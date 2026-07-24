# Secure Code Preflight

Use this before opening or updating a PR, especially for auth, tenancy,
compliance, observability, chart, image, infrastructure, and deployment changes.

## Universal Checks

- Identify the owning repo and layer before changing behavior.
- Keep secrets out of files, logs, diffs, screenshots, fixtures, and docs.
- Validate and normalize user-controlled input before using it in queries,
  selectors, shell commands, URLs, LogQL, TraceQL, PromQL, SQL, Helm templates,
  or Kubernetes object names.
- Fail closed when identity, namespace, role, or config state is missing.
- Use stable identifiers for authorization and ownership decisions.
- Preserve auditability for security-sensitive mutations.
- Bound external calls with request-scoped timeouts or clear retry behavior.
- Avoid widening data scope through fallback paths, empty filters, legacy rows,
  cached state, or default global queries.
- Include focused tests or documented validation evidence for new risk paths.

## Backend Checks

- Enforce authorization in backend middleware, handlers, services, or repository
  boundaries as appropriate. Frontend controls are not sufficient.
- Derive tenant namespace or ownership from canonical resource fields before
  returning, mutating, reviewing, deleting, or downloading data.
- Do not leak database-generated types across repository boundaries when the
  repo architecture forbids it.
- Add migrations or compatibility plans for schema, ownership, response
  contract, role, or scope changes.

## Frontend Checks

- Treat RBAC and route gating as user experience controls, not security
  enforcement.
- Do not render privileged or tenant-global content before auth, role, and
  namespace state is resolved.
- Keep runtime configuration in the repo's approved config surface.
- Sanitize return paths, external URLs, restored hashes, and persisted state.
- Represent loading, error, partial, and scoped data states explicitly.

## Chart And Deployment Checks

- Put chart behavior, chart defaults, and image metadata in the chart repo.
- Put application code, Dockerfiles, and base image selection in the image or
  source repo that owns the image.
- Pin versions intentionally and follow the release propagation path from image
  to chart to product to customer or program repo.
- Validate rendered manifests for RBAC, network, secret, image, and security
  context changes.
- Do not add plaintext secrets, kubeconfigs, tokens, or customer-specific
  credentials.

## Infrastructure And Cluster Checks

- Separate desired-state repo changes from live cluster inspection.
- Before applying remote-only work, identify whether it is branch history,
  uncommitted diff, or untracked files.
- Capture commands and outputs needed to reproduce validation.
- Prefer read-only inspection until the target environment and risk are clear.

## PR-Ready Standard

A change is not PR-ready until the repo-specific build, lint, test, coverage,
chart, scan, or deployment checks relevant to the touched files have been run or
the reason they could not run is documented.

