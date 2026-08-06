# Mission client snapshot contract

`flightdeck.command.mission-client-snapshot.v1` is the only plugin-owned
read-only surface for a desktop client that needs a bounded view of one Mission:

```text
bin/flightdeck mission client-snapshot --hub-root ABSOLUTE_PATH \
  --mission MISSION_ID --parent-chat-id OPAQUE_ID --json
```

It requires the exact declared capability and emits only the closed
`flightdeck.mission-client-snapshot/v1` result defined by
`hub/schemas/mission-client-snapshot.schema.json`. The selected Hub and schema
must be regular files; absent capability, malformed records, and unknown
identity return a closed error with `manual_recovery_required`.

Before a snapshot can expose any Mission metadata, the Mission must have a
creation-time `client_snapshot_binding` written by an operator through
`mission new --parent-chat-id`. Core stores only the SHA-256 digest, never the
raw parent-chat ID; the binding cannot be added or changed after creation.
Mission authoring and existing unbound Missions remain snapshot-ineligible and
return the closed `identity_unresolved` response. The invoking client presents
its opaque parent-chat ID, and core compares its digest to the persisted
binding before it loads the status projection, owner routes, task bindings, or
lifecycle events.

The success result contains:

- provenance binding the supplied opaque parent-chat ID to the Mission ID and
  its persisted owner routes;
- a sanitized node summary with only node ID, project label, lifecycle status,
  and an opaque base64url task binding; and
- one lifecycle event per exact persisted opaque task ID, including its node,
  status, optional revision, and optional event ID.

No raw project path, Mission outcome, artifact reference, outbox entry,
credential, dispatch action, or recovery command is returned. The snapshot
cannot create, dispatch, retry, reconcile, mutate, or close a Mission.

`dispatch_pending`, `dispatch_unknown`, a pending client receipt, an absent
binding, or a parent-chat mismatch fail
closed as `identity_unresolved`; clients must preserve the original receipt and
use the existing operator-controlled recovery path. They must never retry,
guess a task ID, or synthesize a replacement binding.
