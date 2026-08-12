# Operation projection API

`bin/flightdeck operation detail --request FILE --json` is the typed,
read-only projection for one exact durable authored Operation. Clients must
require both `flightdeck.command.operation-detail.v1` and
`flightdeck.command.operations-snapshot-detail-identity.v1`, then validate the
request, result, or error against the declared `operation-detail-*.schema.json`
contract. They must not read ignored Mission or Operation-authoring state.

The Operations snapshot `operation_id` remains the typed `mission:` or `task:`
source identity and is not accepted by Operation detail. A client may open
detail only when `detail.availability` is `available`, passing the unchanged
canonical `detail.operation_id` in a
`flightdeck.operation-detail.request/v1` request. That identity has the closed
form `operation-<24 lowercase hex>`. An `unavailable` detail cannot be repaired
or reconstructed from a prefix, title, list position, renderer input, Mission
or task ID, or any runtime or project identity.
For adapter-backed confirmed Operations, `session.state` is `execution_bound` and exposes
only the stable Flightdeck agent ID. The `execution` object comes exclusively
from authenticated, bounded durable observations accepted by
`flightdeck.command.operation-observation.v1`. It never contains an adapter
session reference, native project identity, task body, raw protocol payload,
reasoning, prompt, credentials, or arbitrary output. `execution-open` is the
read-only recovery source; this projection never polls an execution adapter.

The projection exposes the persisted operation ID, title, mode, lifecycle,
logical child identity, child state, safe output references, and an opaque
resolved Codex task ID. A pending create exposes no pending client identity.
Paths, runtime project identities, prompts, raw evidence, credentials, and
untrusted child text are excluded.

The snapshot producer exposes canonical detail identity only after the
persisted Operation-authoring record, Mission identity, authoring binding, and
immutable fingerprint reconcile exactly. Legacy and non-authored Mission
records and all Task records report detail unavailable. Malformed, duplicate,
foreign, or mismatched authoring records fail the snapshot closed without a
partial operation list.

Clients that need the clickable reliability and visibility projection must also
require `flightdeck.command.operation-detail.v2` and send the same canonical ID
in `flightdeck.operation-detail.request/v2`. V2 preserves the v1 result without
changing it and adds an exact `authored_operation` classification; the separate
`mission:` source identity; project and authorization scope; configured
heartbeat threshold; success criteria; graph dependencies; stable Flightdeck
agent identity and binding availability; sanitized current activity; the last
authenticated durable observation; and typed validation, approval, artifact,
evidence, and result summaries. Missing producers use explicit `unavailable`
envelopes.

An unbound execution agent is `queued`; a bound agent without an accepted
observation is `starting`. Only a signed, sequence-exact accepted observation
can produce working, waiting, approval-required, review-ready, failed, or
needs-recovery state. A nonterminal observation becomes `stalled` only when its
age is strictly greater than the persisted positive
`spec.budgets.stale_after_seconds`; terminal observations never become stale.
Local adapter state cannot synthesize a durable completion. Changed files and
checks remain explicitly unavailable until an authenticated bounded producer
persists those contracts. Paths, runtime project identities, prompts, raw
evidence, credentials, adapter session references, and untrusted child text are
excluded.

A typed pre-bind start failure is not an adapter observation: detail keeps
`last_observation` unavailable, keeps binding `unbound`, and projects the
bounded failure summary as current activity. A retryable failure is
`needs_recovery`; a non-retryable failure is `failed`. The Operations snapshot
uses its existing reconcile/failed status and sanitized activity fields. Only
`flightdeck.command.operation-start-recovery.v1` can record or recover this
state, and only its exact retry-bind transition may later produce a binding.

Missing capability or schema is `unsupported_hub_contract`; an identity that
is not bound to an exact created durable Operation is `operation_unavailable`;
malformed or inconsistent durable state fails closed. Clients must not scrape,
synthesize, retry with a substituted identity, or fall back to source identity.
