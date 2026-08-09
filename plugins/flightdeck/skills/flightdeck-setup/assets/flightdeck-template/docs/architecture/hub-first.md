# Hub-first application contract

## Decision

A Flightdeck application connects to exactly one selected Hub. The Hub is the
only source for its visible projects, coordination destination, durable
operations, and capability declaration. Repository checkouts, Codex project
lists, and cached runtime state are proof sources; none independently define
application membership.

Codex remains the declared compatibility runtime. OpenAI Model Provider (OMP)
is explicitly unavailable until a separately versioned adapter exists.

## Hub snapshot

`bin/flightdeck hub snapshot --hub-root ABSOLUTE_PATH --json` implements
`flightdeck.command.hub-snapshot.v1` and returns
`hub/schemas/hub-snapshot.schema.json`. Clients must require the exact
capability and schema.

The bounded success projection contains the Hub display name and template
version, runtime capability metadata, and each declared project's logical key,
safe label, workload, availability, bridge health, destination, and routing
capability. It never contains paths, runtime UUIDs, local registry data, bridge
handoffs or digests, repository locators, or task identities.

The canonical list is the configured coordinator followed by durable
repository declarations ordered by logical project key. Every project must
have an exact live-list verification; repository members must also have a
verified bridge. Missing, conflicting, drifted, or malformed proof returns a
typed error without a partial project list.

## Operations snapshot

`bin/flightdeck hub operations-snapshot --hub-root ABSOLUTE_PATH --json`
implements `flightdeck.command.operations-snapshot.v1` and returns
`hub/schemas/operations-snapshot.schema.json`. It reads only durable Mission
and Task records. It never reads global recents, prompts, commentary, or an
external task list.

The status vocabulary is closed: `queued`, `working`, `waiting`,
`approval_required`, `blocked`, `review_ready`, `failed_validation`,
`cancelled`, and `reconcile_required`. Unknown or ambiguous state maps to
`reconcile_required`; free-form text never changes status.

Mission skills are derived only from authenticated, task-bound lifecycle
events persisted by MissionSync. Their state is `absent`, `in_progress`,
`succeeded`, or `partial_failure`, with deterministic latest-event
deduplication per child. A routed or selected skill is never reported as used.
Legacy Task records lack that producer and therefore report
`{state: unavailable, items: []}`. The projection never infers skill use from
prompts, titles, labels, command text, or renderer state.

Malformed records, unsafe filesystem entries, invalid capabilities, and record
count overflow fail closed with a typed error and no partial operation list.
The schema excludes paths, runtime project/task/host IDs, bridge handoffs,
prompts, raw protocol errors, evidence bodies, secrets, and customer data.

## Migration and rollback

Future generated or explicitly upgraded Hubs receive the snapshot schemas,
commands, and compatibility declarations. Existing Hubs are unsupported until
upgraded; clients must not guess support. Source installation does not migrate
an existing Hub.

Rollback is additive: clients stop calling the new commands and retain their
prior compatibility path. Do not delete verification, bridge, Mission, or Task
state as a rollback shortcut.
