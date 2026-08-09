# Operation projection API

`bin/flightdeck mission operation SLUG --json` is the typed, read-only display
projection for one durable Mission. Clients must require
`flightdeck.command.operation-projection.v1` and validate
`hub/schemas/operation.schema.json`. They must not read ignored Mission state or
infer child state from prose.

The projection exposes the persisted operation ID, title, mode, lifecycle,
logical child identity, child state, safe output references, and an opaque
resolved Codex task ID. A pending create exposes no pending client identity.
Paths, runtime project identities, prompts, raw evidence, credentials, and
untrusted child text are excluded.

`verified_skills` contains only authenticated task-bound lifecycle events
persisted by MissionSync. It reports `absent`, `in_progress`, `succeeded`, or
`partial_failure` and deterministically deduplicates replayed evidence. Routed
or selected skills are not usage. `files_changed` remains explicitly
`not_collected`.

Use `logical_project_key` only to join the already verified project catalog.
Open a child only when `session.state` is `resolved`, using `task_id` through
the Client/App Server task API. Missing capability or schema is unsupported;
clients must not scrape or synthesize a fallback.
