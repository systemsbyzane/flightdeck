# Backend Review Guidelines

Use these before requesting review on backend changes.

## High-Risk Areas

- backend authorization and tenant scope
- stable identity and ownership decisions
- migrations, SQLC queries, generated code, and model mappings
- API response contracts used by frontend or charts
- observability proxy query construction
- external calls, fan-out, timeouts, and retries
- compliance rollups and assessment semantics

## Preflight

- Enforce authorization in backend code before returning or mutating protected
  data.
- Derive namespace or resource ownership from canonical data before UUID lookup,
  download, delete, review, withdraw, or detail paths.
- Fail closed for missing user, role, namespace, owner, or subject state.
- Use stable subject IDs for ownership, requester, reviewer, and actor checks.
- Include migrations and backfills for schema, ownership, role, scope, or API
  contract changes.
- Regenerate SQLC output after query changes and review generated diffs.
- Keep handlers thin and move business logic into services or repositories as
  appropriate.
- Run `make build`, `make lint`, and relevant tests, or document skipped checks.

