# Platform and environments

Ask about infrastructure, cloud, clusters, platform services, or environments
in natural language. Users do not need to name a skill or select a platform
mode.

## Source and runtime split

Identify the owning layer before acting: infrastructure source, chart or
manifest, application contract, environment configuration, platform service,
or live runtime.

Keep source edits in the owning repository. Use the chart workflow for Helm and
Kubernetes manifest mechanics. Use the matching environment project for
durable live inspection or validation, and record the exact account, project,
subscription, region, cluster, namespace, and revision observed.

## Proportional method

Infer design, diagnosis, implementation, validation, or operational intent.
Evaluate identity, state, secrets, network exposure, data, storage,
availability, capacity, cost, observability, upgrade, blast radius, rollback,
and recovery only where relevant.

Keep declared configuration, generated plans or renders, applied state, and
observed runtime state distinct. A successful plan or render does not prove an
apply occurred.

Read-only inspection does not authorize apply, provider or cluster changes,
secret rotation, data changes, restarts, deployment, or any shared-environment
mutation. Require explicit authorization for every environment write and
capture restoration evidence.
