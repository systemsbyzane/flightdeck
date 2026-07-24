# Frontend Review Guidelines

Use these before requesting review on frontend changes.

## High-Risk Areas

- RBAC, route guards, and privileged UI
- tenant scope, namespace parsing, and observability queries
- runtime config, redirects, return paths, and external URLs
- persisted state, loading states, and stale auth-derived state
- API contract alignment with backend responses
- accessibility and semantic interaction patterns

## Preflight

- Treat frontend RBAC as user experience only; confirm backend enforcement for
  privileged operations.
- Do not render privileged or tenant-global content until user, role, namespace,
  and config state are resolved.
- Escape and validate user-controlled values before constructing LogQL, TraceQL,
  PromQL, URLs, route fragments, or query strings.
- Keep deployment-specific values in runtime config or approved typed helpers.
- Sanitize persisted state and route restoration before use.
- Represent loading, error, empty, partial, and scoped states explicitly.
- Use semantic controls and preserve keyboard and screen-reader behavior.
- Run `pnpm build` and relevant tests, or document skipped checks.

