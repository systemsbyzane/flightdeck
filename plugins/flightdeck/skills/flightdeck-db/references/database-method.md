# Database Method

Use this method for database design, review, implementation, security,
performance, and reliability questions. Apply only the sections relevant to the
request.

## Establish Context

Identify the database engine and version, deployment model, authoritative
schema and migration source, environment, workload, data classification,
tenancy boundary, consumers, availability target, RPO, and RTO. State unknowns
instead of assuming a production topology or consistency model.

Keep these states distinct:

- intended schema and configuration in source;
- generated migration or provider plan;
- applied migration history and runtime configuration;
- primary, replica, and backup state;
- observed query behavior and operational evidence.

## Model Data And Invariants

- Give every record a stable identity appropriate to its domain and access
  pattern. Do not expose sequential identifiers when unpredictability is a
  security requirement.
- Choose types that preserve meaning. Define time zones, precision, collation,
  encoding, null semantics, and units explicitly.
- Enforce durable invariants with `NOT NULL`, uniqueness, checks, foreign keys,
  or the datastore's equivalent. Application validation improves errors but
  does not replace concurrency-safe constraints.
- Normalize to protect consistency; denormalize only for measured access
  patterns with a clear synchronization owner.
- Make tenant isolation part of keys, constraints, authorization, indexes, and
  tests. Row-level security can add defense in depth but does not repair an
  ambiguous ownership model.
- Define deletion, retention, archival, legal hold, and audit behavior. Soft
  deletion needs uniqueness, query, restore, and purge semantics.

## Transactions And Concurrency

- Define the transaction boundary around the business invariant, not around
  an arbitrary repository method.
- Select an isolation level from actual anomaly tolerance. Document lost
  update, write skew, phantom, and stale-read behavior where relevant.
- Keep transactions short and order locks consistently. Avoid network calls or
  unbounded user interaction while locks are held.
- Make retried operations idempotent. Handle deadlocks, serialization
  failures, timeouts, duplicate delivery, and partial failure explicitly.
- Use an outbox or another durable coordination pattern when database state and
  message publication must agree. Do not claim atomicity across independent
  systems without a real protocol.

## Query And Index Design

- Start from representative query shapes, cardinality, selectivity, ordering,
  and write volume. Avoid designing indexes from column names alone.
- Capture a query plan safely and compare estimated with actual rows when an
  authorized, bounded execution is appropriate.
- Align composite index order with filtering, joining, and ordering behavior.
  Account for partial, covering, expression, or specialized indexes supported
  by the selected engine.
- Price every index in write amplification, storage, cache pressure, vacuum or
  compaction cost, and migration time. Remove only after usage and dependency
  evidence.
- Prevent unbounded scans, N+1 access, large offsets, oversized result sets,
  implicit casts, and functions that defeat useful indexes. Prefer stable
  keyset pagination when access patterns allow it.
- Bound timeouts, batch sizes, and memory. Treat ORM-generated SQL as production
  code and inspect the actual statements and plans.

## Connections And Capacity

- Bound application pool size from database connection capacity, workload
  concurrency, number of replicas, and proxy or serverless behavior. More
  connections can reduce throughput.
- Use acquisition, statement, lock, idle-in-transaction, and cancellation
  timeouts appropriate to the engine and request.
- Detect leaked connections, long transactions, saturation, replica lag, hot
  keys or partitions, cache churn, lock waits, deadlocks, and storage growth.
- Scale after measuring the bottleneck. Separate CPU, memory, I/O, network,
  connection, lock, and query-shape limits.

## Security And Privacy

- Use parameterized queries and safe identifier allowlists. Never concatenate
  untrusted input into SQL, query languages, or administrative commands.
- Use distinct least-privilege identities for applications, migrations,
  backup, replication, observability, and administration.
- Keep credentials out of source, logs, plans, command history, and generated
  artifacts. Prefer short-lived or centrally managed credentials.
- Protect transport and storage with supported encryption and managed keys.
  Plan rotation and failure behavior.
- Minimize sensitive data in lower environments, logs, traces, analytics, and
  backups. Use masking or synthetic fixtures.
- Audit privileged access, schema changes, security changes, exports, and
  recovery actions without logging secret or sensitive row values.

## Reliability And Recovery

- Define backup scope, frequency, retention, encryption, isolation, monitoring,
  and ownership from RPO/RTO and data criticality.
- Test restores into an isolated target. A successful backup job does not prove
  restorability, acceptable recovery time, or application consistency.
- Understand replication mode, lag, read consistency, failover election,
  split-brain protections, fencing, and client reconnection behavior.
- Monitor service-level signals plus storage, connections, queries, locks,
  replication, backups, maintenance, and data-growth forecasts.
- Treat high availability and disaster recovery as separate capabilities.
  Document regional or provider failure assumptions.

## Non-Relational And Distributed Stores

Do not project relational rules blindly. Evaluate access patterns, partition or
shard keys, hotspot risk, consistency guarantees, conflict resolution,
secondary-index limits, item or document bounds, compaction, tombstones,
quorums, and rebalancing. Model duplication and asynchronous repair as owned
system behavior.

## Review Output

Lead with correctness, data-loss, security, availability, and migration
findings. Then report:

1. engine, version, topology, workload, and assumptions;
2. invariant and transaction behavior;
3. query, index, pool, and capacity evidence;
4. security, privacy, retention, and tenant boundaries;
5. migration, compatibility, rollout, and rollback or roll-forward plan;
6. backup, restore, failover, monitoring, and residual risk;
7. exact validation performed and skipped.
