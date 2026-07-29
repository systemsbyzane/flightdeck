---
name: flightdeck-db
description: Coordinate safe, reliable database work through Flightdeck. Use whenever a request discusses databases, DBs, data stores, SQL, relational or non-relational persistence, schema or table design, queries or indexes, transactions or locking, ORMs, connection pools, migrations or backfills, replication or failover, backup or restore, data retention, database security, performance, incidents, operational changes, or runtime-discovered migration-version, schema-version, database-compatibility, or persistence errors during another workflow. Natural database intent should trigger this skill; explicit invocation is optional.
---

# Flightdeck Database

Apply database guidance at the depth the request needs. Keep conceptual answers
lightweight; route repository-owned or live-state work before inspecting it.

Classify the request as conceptual guidance, design, review, implementation,
migration, performance diagnosis, incident analysis, or an operational action.
Ask only for context that changes the safe answer: engine and version,
deployment model, workload shape, data sensitivity, consumers, availability
requirements, and recovery objectives.

This skill can become applicable after another workflow starts. When new
evidence reveals database work, preserve the active task and authorization
boundary while applying this method before any database action.

Read `references/database-method.md` for substantive design, review, query,
schema, performance, security, or reliability work. Also read
`references/operations-safety.md` before migrations, backfills, restores,
failovers, production diagnostics, maintenance, or any live database action.

## Ownership And Routing

In a generated Hub, resolve and dispatch the owning repository, service,
platform, environment, or program before inspecting its code, schema, data, or
runtime. Combine this database method with `$flightdeck-development` for
application persistence, `$flightdeck-charts` for manifests,
`$flightdeck-platform` for managed services and environments, `$flightdeck-ci`
for migration delivery, and `$flightdeck-compliance` for program evidence or
retention requirements.

For a conceptual question that does not require owner evidence, answer directly
without creating work. After owner dispatch, return the receipt without
monitoring.

## Database Posture

Prioritize correctness and recoverability before speed:

- encode invariants with database constraints and explicit transactions;
- design from observed access patterns and measured query plans;
- keep migrations backward-compatible, bounded, observable, and resumable;
- use parameterized queries, least privilege, encryption, and deliberate
  tenant isolation;
- size pools and indexes against database capacity and write cost;
- define RPO/RTO, backup retention, restore testing, failover, and rollback or
  roll-forward behavior;
- distinguish schema source, generated plan, applied migration, replicated
  state, and observed runtime evidence.

Do not assume relational advice fits document, key-value, graph, time-series,
or distributed databases. Name consistency, durability, partitioning, and
failure-model tradeoffs explicitly.

## Safety And Output

Treat production reads as potentially expensive and reads such as `EXPLAIN
ANALYZE`, functions, or stored procedures as potentially mutating. A diagnostic
request does not authorize DDL, DML, migrations, maintenance, failover,
restore, restart, credential changes, or data access beyond the stated scope.
Never expose secrets or sensitive row data.

Return the recommendation or finding first, then assumptions, evidence, data
and compatibility risks, migration or rollout sequence, validation, recovery,
and unresolved decisions. For a quick question, include only the relevant
subset.
