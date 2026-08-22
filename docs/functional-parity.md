# Functional parity contract

Parity means equivalent neutral behavior, not filename or path presence. The
comparison tool accepts a source Hub and a generated candidate as arguments and
stores reports outside distributable content.

Strict inventory runs before semantic claims. The tracked
`plugins/flightdeck/process-parity.json` manifest classifies every selected
source process surface, every generated candidate file, and every plugin
distribution file. See `docs/process-parity.md`. Unknown, ambiguous, missing,
or count-drifting surfaces fail closed.

The canonical source-backed gate is:

```sh
make release-validate \
  SOURCE_HUB=/absolute/path/to/read-only-reference-hub \
  PRIVATE_NEUTRALIZATION_MAP=.flightdeck-local/private-neutralization.json
```

The reference is read-only; all path-bearing reports stay under ignored
`.flightdeck-local/`. Source-specific vocabulary and neutralization rules live
only in the required ignored map. They are runtime inputs to comparison and
de-branding, never distributable plugin content.

Every mandatory surface needs:

1. an explicit neutral mapping;
2. semantic comparison of its machine-readable contract;
3. a functional probe with a deterministic pass condition;
4. a classification of `matched`, `generalized`, `added`,
   `intentionally_excluded`, or `unresolved`.

Mandatory surfaces are:

- registry and schema semantics;
- task types, execution units, evidence, checks, approvals, gates, risks,
  blockers, policies, and lifecycle history;
- workflow states, transitions, roles, gates, approval boundaries, and expected
  evidence;
- CLI command behavior and read-only/state-changing boundaries;
- transition enforcement and non-destructive task creation;
- Doctor finding categories, stable identities, repository state, no-fetch
  caveat, compliance parity, bridge integrity, and automation safety;
- route, registration, onboarding, task receipt, and no-monitoring contracts;
- reference, materialized, and repo-native bridge behavior;
- declarative repositories, bulk read-only planning, safe/idempotent apply,
  per-repository receipts, natural-language setup triggers, and exact project
  verification states, including a stable logical key that deliberately differs
  from the opaque runtime project ID and rejection of the legacy self-equality
  record;
- setup, artifact capability preflight, and acceptance runbooks;
- active Hub skill triggers and automation method;
- adaptive STIG evaluation, evidence/applicability validation,
  draft-versus-export readiness, remediation routing, Helm planning, summary
  extraction, and CKL tools;
- exact-version plugin upgrade planning, deterministic patch notes,
  preservation boundaries, supported reinstall commands, approval gates, and
  generated-Hub lifecycle separation;
- reusable architecture, security, patching, review, compliance, template, and
  workflow method, including the documentation index, Codex UI model, and
  retained neutral control-plane and compliance workbench design history.

Organization-specific topology, repositories, program facts, credentials, live
tasks, evidence, generated findings, and controlled artifacts are mandatory
exclusions, not parity gaps. Runtime Codex UI registration and dispatch remain
unresolved until installed fresh-task acceptance is actually executed and its
evidence proves exact-path ID capture, create-versus-resume, and the
no-monitoring boundary. A locally tested upgrade planner cannot prove that an
installed upgrade succeeded or that refreshed skills loaded in a new task.
