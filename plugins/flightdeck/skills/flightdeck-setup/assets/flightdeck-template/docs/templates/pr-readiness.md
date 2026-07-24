# PR Readiness Template

Use this before opening or updating a PR.

## Scope

- Repo:
- Branch:
- Change summary:
- Owning layer:

## Design Check

- The owning repo and layer are correct.
- Non-goals are clear.
- API, schema, chart, image, values, or deployment contract changes are named.
- Migration, compatibility, or rollout needs are documented.

## Security Check

- Auth and tenant boundaries are enforced at the owning backend, chart,
  infrastructure, or deployment boundary.
- User-controlled input is validated or safely encoded.
- Secrets are not present in diffs, logs, fixtures, docs, or generated files.
- Failure, loading, empty, and partial states are safe and explicit.
- Supply-chain changes identify image, chart, dependency, and release impact.

## Validation Evidence

List commands and results. Include skipped checks with reasons.

## Review Notes

Call out reviewer focus areas, residual risk, and follow-up work.

