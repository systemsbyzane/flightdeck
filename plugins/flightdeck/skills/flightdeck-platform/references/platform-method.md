# Platform method

## Context and ownership

Name the source owner and the live-state owner separately. Pin every command or
observation to the applicable account, project, subscription, region, cluster,
namespace, workspace, or state backend. Stop when context is ambiguous enough
to risk the wrong environment.

## Design and diagnosis

Trace the requested outcome through only the relevant layers:

- identity, policy, and trust boundaries;
- networking, DNS, ingress, egress, TLS, and service discovery;
- secrets, key management, rotation, and exposure;
- data, storage, backups, retention, migration, and recovery;
- compute, scheduling, autoscaling, quotas, and capacity;
- logs, metrics, traces, alerts, and operator visibility;
- state backends, locking, drift, imports, and destructive replacements;
- dependencies, upgrade order, availability, and rollback.

Prefer reversible changes and explicit failure behavior. Separate current
observations from desired configuration.

## Source validation

Use repository-native formatting, lint, tests, policy checks, schema checks,
plans, and renders. Inspect destructive or replacement actions, identity and
permission changes, network exposure, secret paths, data movement, and
downstream consumers.

Treat a generated infrastructure plan as candidate evidence only. Recreate it
from the exact reviewed source and inputs before apply when repository policy
requires that boundary.

## Live validation

Begin with read-only discovery. Record time, context, exact source or artifact
revision, and observed state. When mutation is authorized, define:

- intended change and blast radius;
- preconditions and backups;
- rollout and health signals;
- abort threshold;
- rollback or restoration procedure;
- post-change verification.

Do not broaden a diagnostic request into cleanup, upgrade, restart, failover,
apply, or deployment.

## Cross-layer coordination

Create one owner unit for each repository or environment that must change.
Sequence infrastructure, platform services, manifests, application contracts,
delivery pipelines, and runtime validation explicitly. Reconcile results only
after the user asks Flightdeck to consolidate completed owner work.
