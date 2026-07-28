# Database Operations Safety

Read this reference before migrations, backfills, restores, failovers,
production diagnostics, maintenance, or any live database action.

## Authorization And Context

Confirm the exact engine, version, account, project, cluster or instance,
database, environment, role, and target revision. Stop if ambiguity could reach
the wrong data or environment.

Separate permissions for:

- read-only metadata and bounded diagnostics;
- access to sensitive row data;
- DML and data correction;
- DDL and migration;
- maintenance and performance changes;
- backup, restore, replication, failover, or destructive recovery.

A read-only request does not authorize any later category. Functions, stored
procedures, triggers, `EXPLAIN ANALYZE`, locking reads, and vendor tools can
execute work or take locks; verify semantics before using them.

## Migration Design

Prefer expand-and-contract:

1. add backward-compatible schema or dual-read capability;
2. deploy writers that tolerate old and new states;
3. backfill in bounded, observable, resumable batches;
4. verify counts, invariants, lag, errors, and performance;
5. switch reads or constraints deliberately;
6. remove old behavior only after every consumer is compatible.

Assess locks, table rewrites, index build behavior, replication lag, storage
headroom, transaction log growth, maintenance windows, and ORM behavior on the
actual engine version. "Online" DDL can still consume resources or take short
blocking locks.

Make migration identity and ordering deterministic. Prevent concurrent
migration runners. Record applied state and detect drift.

## Backfills And Data Changes

- Define a stable selection key and idempotent update.
- Bound batch size, transaction duration, concurrency, rate, retries, and
  runtime.
- Handle rows created or changed during the backfill.
- Emit progress, error, latency, lock, lag, and saturation signals.
- Define pause, resume, abort, and reconciliation behavior.
- Validate invariants and sampled records without exposing sensitive values.

Do not rely on a down migration for irreversible or lossy data changes. Prefer
a tested roll-forward repair and a separately verified recovery point.

## Production Diagnostics

Start with metadata, dashboards, existing slow-query evidence, and bounded
read-only inspection. Set conservative timeouts and avoid fetching sensitive
rows.

Before running a query, assess:

- whether it executes user code or writes;
- expected rows, scan volume, locks, memory, and duration;
- replica suitability and lag tolerance;
- cancellation and timeout behavior;
- impact on connection capacity and production traffic.

Never run `EXPLAIN ANALYZE` on a write statement merely to inspect its plan.
Use the engine's non-executing plan mode when possible.

## Change Plan

For a live change, record:

- objective, owner, ticket or task, authorization, and exact target;
- preconditions, backups or recovery point, compatibility, and capacity;
- commands or migration artifact and expected effects;
- rollout stages, health signals, abort thresholds, and on-call ownership;
- rollback feasibility or roll-forward repair;
- post-change validation and evidence retention.

Use a canary or bounded slice when the datastore and workload support it.
Never improvise destructive cleanup during diagnosis.

## Backup, Restore, And Failover

Treat restore and failover as mutations with broad blast radius.

- Verify backup identity, timestamp, encryption, completeness, retention, and
  chain dependencies.
- Restore into an isolated target first when the objective allows it.
- Prevent clients from writing to both old and recovered primaries.
- Reconcile credentials, endpoints, replication, jobs, caches, search
  indexes, and downstream consumers.
- Validate application-level invariants, not only database startup.
- Measure achieved RPO and RTO and record data-loss or consistency gaps.

## Completion Evidence

Do not call a database change complete from a successful command alone.
Confirm the intended schema or data state, application compatibility, query
health, locks, error rates, replication, backups, and recovery posture. Report
skipped checks and residual risk.
