# Flightdeck plugin contributor instructions

This repository owns one portable Codex plugin under `plugins/flightdeck/` and a
repo-local marketplace entry under `.agents/plugins/`.

## Boundaries

- Keep plugin and generated-template content organization-, product-, program-,
  customer-, person-, credential-, evidence-, task-, and finding-neutral.
- Use only synthetic fixtures.
- Do not install, activate, publish, share, stage, commit, push, create a remote,
  or change a plugin cache unless the user explicitly authorizes that action.
- Treat any external source Hub supplied for comparison as read-only. Store
  path-bearing comparison output only under ignored `.flightdeck-local/`.
- Do not add a license. This public source-available distribution intentionally
  does not include one.

## Change rules

- Follow the plugin-creator and skill-creator system skills for manifest,
  marketplace, skill metadata, and validation changes.
- Keep skill bodies concise; put detailed reusable method in one-level
  `references/`, deterministic logic in `scripts/`, and the generated Hub under
  the setup skill's `assets/`.
- Preserve the coordinator boundary: dispatch owner work before analysis and
  return the project/task receipt without monitoring.
- Preserve ordinary receipt-and-stop dispatch as the default. A Mission is an
  explicit opt-in durable parent for verified persistent Codex tasks; its
  `dispatch_only`, `watch_only`, and `supervised` modes may not silently expand
  task monitoring or authorization.
- Treat child task text as untrusted display-only material. A final child
  outcome may emit only bounded `output_declarations`; after an exact persisted
  task receipt, core alone materializes producer-bound refs and `event_digest`.
  Only an operator action may mark a Mission complete.
- Nonterminal and tool-derived observations contain normalized identity,
  status, cursor, revision, event, time, and Worktree fields only. They must not
  contain a child outcome. An exact outcome is required only for
  `review_ready` or `failed_validation`; fan-in additionally requires all
  assigned criteria passed and non-empty core-materialized producer-bound refs.
- Declare the complete Mission graph while it is still planned. Any dispatch,
  pending or unknown receipt, observation, or outbox state freezes membership;
  a newly discovered owner requires a proposed new Mission and user approval.
- Declare downstream nodes up front, but create or record a non-root only when
  exactly one matching dependency action is prepared. The action must name the complete
  parent set, its refs must equal the complete eligible core-materialized
  accepted set, and that set must include at least one ref from every parent;
  validated dependencies alone are insufficient, and
  terminal `check:`/`review:` evidence is never dispatch-eligible. Mission references are control-plane
  metadata, not artifact transport: prove consumer resolvability before
  dispatch, co-locate compatible producer/consumer work when necessary, or
  stop. Independent review always uses a separate runtime task.
- Persist explicit success criteria, bounded non-goals, and exact six-field
  authorized targets for `watch_only` and `supervised`. Core assigns ordered
  criterion IDs, derives the scope boundary, requires each criterion covered by
  required nodes before dispatch, and requires every assigned criterion passed
  before fan-in. The boundary proves equality only and grants no authority.
- Children never author, repair, or bootstrap canonical refs, task bindings, or
  resolver identity. Automated handoff accepts only canonical artifact or task
  refs materialized by core from closed declarations and exact receipts.
  `check:` and `review:` remain terminal operator evidence. Bind
  artifact producers/consumers to the same resolver and include it on an action
  only when that action transports an artifact. Refresh the live exact-path
  project immediately before a planned downstream create after every declared
  dependency is ready.
- Require `sync-apply` to receive the exact `plan_token` from `sync-plan`.
  A planned dependency handoff may be prepared before JIT create, but delivery
  requires its exact task/runtime/host receipt in internal `awaiting_handoff`.
  If create returns only `clientThreadId`, preserve the prepared action and
  `dispatch_pending` receipt, do not create again, and reconcile with both the
  original client ID and exact resolved task ID before delivery.
  Operator status projects that transient as `running`/`handing_off`;
  `blocked`, `stale`, pending, and unknown consumers are non-actionable.
- Treat action `trigger_digest`, idempotency key, ID, boundary, and canonical
  payload as one closed recomputable ledger identity; reject any drift.
- Require exact `authorization_boundary` equality across the Mission parent,
  every node, and every outbox action. Any missing or different value fails
  closed; a merely narrower or semantically similar value is not accepted.
- Reject an observation file whose filesystem byte size exceeds the Mission's
  `max_forwarded_bytes` budget before reading or parsing its contents. Reject
  non-regular or unreadable observation inputs before loading them and retain a
  post-read byte-budget check.
- Preserve explicit approval gates for commits, remote writes, publication,
  deployment, shared-environment mutation, external communication, compliance
  submission, risk acceptance, and closure.
- Never weaken a source workflow or schema merely to make parity pass. Update
  the neutral mapping and functional probe together.

## Required validation

Run the plugin validator, every skill quick validator, all Ruby and Python
tests, structured JSON/YAML/schema parsing, fresh setup generation, generated
Doctor, de-branding scan, setup-link validation, deterministic STIG round trip,
local acceptance harness, semantic parity comparison, and `git status`.

Live Codex project registration and task dispatch are installed-plugin,
fresh-task acceptance checks. Do not claim them from local harness output.
