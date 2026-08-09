# Operation authoring API

## Capability and compatibility

`flightdeck.command.operation-authoring.v1` is the only plugin-owned producer
contract for client authoring of a durable planned Operation. A client must read
the selected Hub's regular non-symlink `hub/compatibility.json`, require that
exact capability, and verify its managed paths before enabling this UI. A Hub
without it is explicitly unsupported: do not infer support from template
version, Mission commands, titles, or other output, and do not migrate or
regenerate it automatically.

This v1 creates one complete Mission-backed Operation record only. It does not
dispatch, create, resume, or observe child tasks; mint task identity; report
skills; infer changed files; or claim work success. The normal read-only
`flightdeck.mission-list/v1` projection can display the created record using
`mission_id`, `title`, `mode`, `state`, timestamps, generation, and progress.
The client must retain its separate Mission lifecycle/telemetry capability
checks and may not infer either from this API.

All requests are one regular non-symlink `.json` file of at most 262,144 bytes.
Every request/result is a closed, versioned JSON object. Request files, result
fields, and persisted state exclude raw project paths, prompts, commands,
credentials, tool payloads, evidence bodies, customer data, task IDs, and
skill-use claims. Core derives opaque IDs, project binding, authorization
boundary, and immutable plan fields.

## Commands

| Operation | Command | Request schema | Success schema |
| --- | --- | --- | --- |
| Catalog | `bin/flightdeck operation authoring-catalog --request FILE --json` | `operation-authoring-catalog-request` | `operation-authoring-catalog-result` |
| Plan | `bin/flightdeck operation authoring-plan --request FILE --json` | `operation-authoring-plan-request` | `operation-authoring-plan-result` |
| Launch | `bin/flightdeck operation authoring-launch --request FILE --json` | `operation-authoring-launch-request` | `operation-authoring-launch-result` |
| Guidance | `bin/flightdeck operation authoring-guidance --request FILE --json` | `operation-authoring-guidance-request` | `operation-authoring-guidance-result` |
| Recover | `bin/flightdeck operation authoring-operation --request FILE --json` | `operation-authoring-operation-request` | `operation-authoring-operation-result` |

Each short schema name above resolves under `hub/schemas/` with suffix
`.schema.json`; shared types are in `operation-authoring-types.schema.json`.
Failures use `operation-authoring-error-result.schema.json`, with only a
stable error code and a bounded message.

## Exact client sequence

1. Submit the catalog request `{ "schema_version": "flightdeck.operation-authoring.catalog-request/v1" }`.
   Each eligible target has a server-minted `target_id`, logical project key,
   opaque runtime project ID, path digest, opaque host ID, mode, access mode,
   and display-safe label. The client returns the complete identity tuple; a
   display label is never identity.
2. Submit a closed proposal with title, work intent, 1–50 success criteria,
   1–50 non-goals, Mission mode, and 1–50 exact selected catalog targets.
   Core validates the current target binding and returns server-authored
   `operation_id`, `plan_id`, `plan_generation`, `plan_digest`, `plan_token`,
   the complete planned Operation, and bounded warnings.
3. Render that returned plan for review. Launch uses the unchanged proposal,
   server `operation_id`, and all five exact confirmation values. The client
   never mints an Operation ID, Mission ID, target identity, or plan field.
4. On `created`, use the returned `mission_id` / `snapshot_operation_id` only
   to reconcile the existing read-only Operations snapshot. A replay of the
   byte-equivalent launch returns the same created result with `replayed:true`.
5. On response loss or `unknown_outcome`, do not retry or substitute a new ID.
   Submit only an operation recovery request with the original `operation_id`.
   `created`, `not_created`, and `unresolved` are the only recovery outcomes.

The producer atomically persists a bounded unresolved launch record before the
Mission record, then validates an exact persisted binding and fingerprint.
Post-commit response loss is therefore recovery-only. Records are local,
restart-safe, SHA-256 filename-bound, capped at 10,000 operations and 65,536
bytes each; each Operation has at most 100 guidance entries. Store corruption,
foreign identity, malformed data, and ambiguous binding fail closed.

Guidance is accepted only for an exact, created, nonterminal persisted
Operation. It is redacted before durable storage, capped at 1,024 characters,
timestamped, and idempotent by Operation plus content digest. Guidance before
creation, after `review_ready`, `failed_validation`, `runtime_failure`,
`cancelled`, or `complete`, or for a foreign/malformed Operation is rejected.

Stable errors include `unsupported_hub_contract`, `malformed_request`,
`future_version`, `unsupported_version`, `catalog_invalid`,
`ineligible_target`, `stale_or_mismatched_plan`, `conflicting_operation`,
`unknown_outcome`, `persistence_failed`, `operation_not_found`,
`operation_store_invalid`, `operation_identity_conflict`, `terminal_operation`,
and `guidance_limit_exceeded`.
