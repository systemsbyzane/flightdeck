# Database Work

Use this workflow whenever the request concerns a database, DB, data store,
schema, table, query, index, transaction, ORM, connection pool, migration,
backfill, replication, backup, restore, retention, performance, incident, or
operational change. Users do not need to name a skill.

## Adaptive Workflow

1. Identify whether the user needs conceptual guidance, design, review,
   implementation, migration, diagnosis, incident analysis, or an operation.
2. Ask only for context that changes the safe answer: engine and version,
   topology, environment, workload, sensitivity, consumers, availability, RPO,
   and RTO.
3. Resolve the owning application repository, chart, delivery pipeline,
   platform service, environment, or program before inspecting owner state.
4. Dispatch owner investigation or implementation and return the receipt
   without monitoring.
5. Keep source intent, generated plans, applied migrations, primary and replica
   state, backups, and observed runtime evidence distinct.
6. Require separate authorization for each live data or environment action.

Conceptual questions that need no owner evidence can be answered directly and
briefly.

## Engineering Baseline

- Encode durable invariants with constraints, deliberate types, tenant-aware
  keys, and explicit transaction boundaries.
- Select isolation, locking, retry, and idempotency behavior from actual
  concurrency requirements.
- Design queries and indexes from representative access patterns and measured
  plans. Account for write amplification, storage, and maintenance cost.
- Bound pools, queries, batches, retries, and timeouts against database
  capacity.
- Use parameterized queries, least-privilege identities, encryption, secret
  management, auditability, retention, and deliberate tenant isolation.
- Define backup retention, restore tests, replication and failover behavior,
  monitoring, RPO, and RTO.
- Apply relational advice to non-relational stores only when their consistency,
  partitioning, and failure models support it.

## Migration And Operations Safety

Prefer expand-and-contract changes: add compatible state, deploy tolerant
consumers, backfill in bounded resumable batches, verify, switch deliberately,
then remove old behavior after every consumer is compatible.

Assess locks, rewrites, index builds, replication lag, storage headroom,
transaction logs, maintenance windows, and engine-version behavior. Use
observable stages, abort thresholds, and roll-forward repair when rollback is
lossy or unrealistic.

Treat production reads as potentially expensive. Functions, stored procedures,
locking reads, and `EXPLAIN ANALYZE` may execute work or mutate state. A
diagnostic request does not authorize DDL, DML, migrations, backfills,
maintenance, failover, restore, restart, credential changes, or access to
sensitive rows.

## Completion Evidence

A successful migration command, backup job, or database startup is not enough.
Verify intended schema or data state, application compatibility, invariants,
query health, locks, errors, replication, backup state, and recoverability.
Report skipped checks and residual risk.
