# Development gates

## Design

- intended outcome and non-goals
- owning layer and repositories
- API, data, identity, authorization, and audit boundaries
- compatibility, migrations, rollout, rollback, and failure states

## Implementation

- repo instructions read
- branch, SHA, and dirty state recorded
- smallest coherent change
- input validation and fail-closed authorization
- focused allowed and denied-path tests

## Review

- repo-native build, lint, tests, and static checks
- cross-repo contract reconciliation
- secret and migration review
- exact candidate diff
- skipped checks and residual risk

Commit, push, pull request, review request, and runtime mutation are separate
approval gates.

