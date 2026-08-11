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
For OMP-backed confirmed Operations, `session.state` is `omp_bound` and exposes
only the stable Flightdeck agent ID. The `execution` object comes exclusively
from authenticated, bounded durable observations accepted by
`flightdeck.command.omp-operation-observation.v1`. It never contains an OMP
session reference, native project identity, task body, raw protocol payload,
reasoning, prompt, credentials, or arbitrary output. `execution-open` is the
read-only recovery source; this projection never polls OMP.

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

Operation detail projects bounded goal, mode, authorization, progress, named
project agents, dependencies, typed validations, artifacts, approvals, result
totals, and explicit non-goals. Changed files and skills remain explicitly
unavailable until an authenticated task-bound producer persists them. Paths,
runtime project identities, prompts, raw evidence, credentials, and untrusted
child text are excluded.

Missing capability or schema is `unsupported_hub_contract`; an identity that
is not bound to an exact created durable Operation is `operation_unavailable`;
malformed or inconsistent durable state fails closed. Clients must not scrape,
synthesize, retry with a substituted identity, or fall back to source identity.
