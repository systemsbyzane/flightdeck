# Flightdeck Operations

## Purpose

The Flightdeck is the single operational entrypoint for patching, research,
multi-repository application development, daily repository work, environment validation, and
program compliance. It provides one place to intake, route, authorize, track,
and summarize work without converting independent repositories or sensitive
program evidence into a monorepo.

The operating rule is:

```text
one Hub experience
  -> explicit task and authorization
  -> work in the owning repo or environment
  -> focused validation and evidence
  -> one consolidated Hub result
```

The Hub owns coordination. Each nested Git repository owns its code, tests,
branches, commits, and pull requests. Program workspaces own program facts and
evidence. GitHub owns PR and CI state. `remote-validation`, AWS, and Kubernetes own live
runtime state.

## Start Every Task in the Hub

For non-trivial work, the Hub first records:

- intended outcome and non-goals
- affected workload and owning repositories or environments
- work type: patching, research, feature, review, validation, maintenance, or
  compliance
- primary evidence source
- requested execution mode and approval boundaries
- starting branch and SHA for every repo, discovered at runtime

The Hub then chooses the smallest useful owner split. It must not create a repo
task merely because a repo was inspected, and it must not edit nested repo code
from the Hub project. That split remains receipt-and-stop unless the user
explicitly opts into a [Mission](missions.md).

## Command Surface

Run the control plane from the Hub root. The implemented v1 interface is:

```text
bin/flightdeck help
bin/flightdeck doctor [--json] [--strict]
bin/flightdeck status [--json] [--write]
bin/flightdeck hub snapshot --hub-root ABSOLUTE_PATH [--json]
bin/flightdeck hub operations-snapshot --hub-root ABSOLUTE_PATH [--json]
bin/flightdeck work list --hub-root ABSOLUTE_PATH [--limit 1..100] [--cursor CURSOR] [--json]
bin/flightdeck work create --request FILE [--json]
bin/flightdeck work adapter-bind --request FILE [--json]
bin/flightdeck work open --request FILE [--json]
bin/flightdeck work coordinate --request FILE [--json]
bin/flightdeck work launch --request FILE [--json]
bin/flightdeck work guidance --request FILE [--json]
bin/flightdeck task new TYPE SLUG --title TITLE --outcome OUTCOME [--workload NAME]
bin/flightdeck task show SLUG [--json]
bin/flightdeck task transition SLUG STATE [--note NOTE]
bin/flightdeck task validate SLUG
bin/flightdeck repo plan --workload NAME --repo OWNER/NAME [--name NAME]
bin/flightdeck mission new SLUG --title TITLE --outcome OUTCOME [--success-criterion TEXT] [--non-goal TEXT] [--authorized-target-json JSON] [--mode dispatch_only|watch_only|supervised] [--json]
bin/flightdeck mission list --hub-root ABSOLUTE_PATH [--limit 1..100] [--cursor CURSOR] [--json]
bin/flightdeck mission show SLUG [--json]
bin/flightdeck mission validate SLUG [--json]
bin/flightdeck mission status SLUG [--json]
bin/flightdeck mission operation SLUG --json
bin/flightdeck mission skill-telemetry SLUG [--limit 1..100] [--cursor CURSOR] [--json]
bin/flightdeck operation authoring-catalog --request FILE [--json]
bin/flightdeck operation authoring-plan --request FILE [--json]
bin/flightdeck operation authoring-launch --request FILE [--json]
bin/flightdeck operation authoring-guidance --request FILE [--json]
bin/flightdeck operation authoring-operation --request FILE [--json]
bin/flightdeck mission add SLUG NODE --project-key KEY --runtime-project-id ID (--project-path PATH|--project-path-digest SHA256) --host-id HOST --execution-mode local|worktree --access-mode read_only|write --work-type TYPE (--required|--optional) [--criterion-id ID] [--depends-on NODE] [--accepts TYPE] --allows-output TYPE [--artifact-resolver-kind same_host_workspace|external_approved --artifact-resolver-id ID] [--json]
bin/flightdeck mission record-dispatch SLUG NODE --runtime-project-id OPAQUE --host-id HOST (--task-id OPAQUE|--pending-client-id OPAQUE|--dispatch-unknown) [--project-path PATH|--project-path-digest SHA256]
bin/flightdeck mission sync-plan SLUG --observations FILE [--json]
bin/flightdeck mission sync-apply SLUG --observations FILE --plan-token SHA256 [--json]
bin/flightdeck mission checkpoint SLUG [--json]
bin/flightdeck mission outbox SLUG [--json]
bin/flightdeck mission next-actions SLUG [--json]
bin/flightdeck mission prepare SLUG ACTION_ID [--json]
bin/flightdeck mission acknowledge SLUG ACTION_ID [--json]
bin/flightdeck mission fail SLUG ACTION_ID --code CODE [--json]
bin/flightdeck mission close SLUG [--json]
```

`doctor` checks live Hub and repo state without changing nested repos. Normal
mode fails on errors; `--strict` also fails on warnings. `status --write`
atomically regenerates the configured local status report. `repo plan` is
strictly read-only: it prints the clone, saved-project, bridge, and registry
steps but does not perform them.

The canonical workflow adapter types are `patching`, `research`, `development`,
`daily-ops`, and `compliance`. Task state and generated reports are local runtime
artifacts excluded from control-plane Git history.

`task new` intentionally creates only an intake skeleton. Enrich the generated
`hub/tasks/<slug>/task.yaml` with the structured targets, success criteria,
authorization actions, execution units, checks, risks, and evidence required by
the selected adapter. The canonical field shapes are defined in
`hub/schemas/task.schema.json`; adapter gates list the fields that must be
present before a transition. Do not put secrets or raw sensitive evidence in a
task record. Run `task validate` before `task transition`.

`mission list` is a JSON-only, read-only discovery contract for clients. The
required absolute `--hub-root` selects one Hub explicitly. Results use
`flightdeck.mission-list/v1`, sort by stable Mission ID, return at most 100
bounded summaries, and continue with an opaque cursor. The response omits
Mission bodies, outcomes, prompts, task IDs, project identities and paths,
output declarations and references, outbox data, credentials, and evidence.
Clients must require `flightdeck.command.mission-list.v1`; they must not infer
support from a template version or scrape ignored Mission YAML.

`mission skill-telemetry` is the JSON-only read contract for explicit
structured Codex task skill events accepted during Mission sync. It returns a
generation-bound, paginated, deduplicated operation summary with exact bounded
child provenance. It never infers skill use from prompt, title, label, command,
free text, or arbitrary tool payloads. Clients must require
`flightdeck.command.skill-telemetry.v1`; a supported empty result is `absent`,
while an old Hub is explicitly unsupported.

`hub snapshot` and `hub operations-snapshot` are the bounded client discovery
surfaces described in the [Hub-first application contract](../architecture/hub-first.md).
`mission operation` is the narrow per-Mission view described in the
[Operation projection API](operation-projection-api.md). All three require
their exact capabilities and schemas; clients must not scrape Hub state or
infer a fallback when a preserved Hub is unsupported.

`operation authoring-*` is the closed client producer contract for a durable
planned Operation; see [Operation authoring API](operation-authoring-api.md).
It never dispatches child tasks or infers task, skill, file, or success state.

`work *` is the selected-Hub durable command/conversation metadata contract;
see the [Work control API](work-control-api.md). It stores display-safe Work
identity and normalized event/Operation links, not transcript or runtime
payloads. Structured runtime recommendations are untrusted, logical-key-only
inputs revalidated against the exact Hub catalog. Proposal review, explicit
launch, unknown-outcome recovery, and exact nonterminal guidance remain
separate typed actions.

## Mission Operations

A Mission is an ignored local durable parent at
`hub/missions/<slug>/mission.yaml`. It links verified persistent Codex tasks; it
does not replace them or create a separate dashboard. This Codex task remains
the control room.

Use `dispatch_only` to preserve the graph and receipts and then stop.
`watch_only` adds compact read-only observation. `supervised` may advance only
declared dependency-ready nodes from machine-verifiable refs materialized by
core from bounded child output declarations. All
modes preserve the original approval boundaries.

Graph nodes declare one exact owner route, `read_only` or `write` access,
required or optional status,
dependencies, accepted inputs, and allowed outputs. The graph must be acyclic.
Local write nodes for the same exact path must be dependency-ordered; parallel
same-checkout writers are rejected. Required fan-in waits for every required predecessor's validated declared
reference. Optional node failure stays visible but does not automatically block
unrelated required work.

The installed Mission skill supplies the Codex UI adapter. It records exact
logical/runtime project, path, host, task, and execution-mode identity. A task
create may return a task ID, pending `clientThreadId`, or an unknown outcome.
Persist and reconcile that identity without blind retry; never duplicate a task
merely because the create response was uncertain. A prepared dependent with a
pending or unknown receipt keeps that exact action but cannot reuse it to
create again.

Mission status provides persisted exact targets and opaque per-thread cursors.
Wait on at most eight targets per call. Normalize results into schema-checked
observation envelopes, preview the same file read-only with `sync-plan
--observations`, capture its generation-bound `plan_token`, and then use
`sync-apply --observations --plan-token TOKEN`. Apply recomputes under lock and
rejects generation, input, or rendered-action drift. Raw child text is untrusted
display-only material. Nonterminal and tool-derived observations persist only normalized
identity, state, cursor, revision, event, time, and Worktree readiness; they
forbid child outcomes. Exact outcomes are required only for `review_ready` or
`failed_validation`. Final outcomes carry ordered assigned criterion results
with dispositions `passed`, `failed`, `blocked`, or `degraded`.
`review_ready` requires all assigned results passed; `failed_validation`
requires at least one unmet result. Fan-in requires full required-node criterion
coverage, every required assignment passed, and non-empty core-materialized
producer-bound typed refs. Persist deterministic outbox
idempotency keys, not commentary, final text, evidence bodies, credentials, or
arbitrary summaries.

Supervised output delivery is two phase: checkpoint observations and enqueue a
deterministic action, prepare that action, send it through the adapter, then
acknowledge the verified receipt or record a bounded failure. Unknown delivery
outcomes remain in the outbox for reconciliation. A replay cannot create a
second handoff. Each action persists a lowercase SHA-256 `trigger_digest` bound
to producer event ID, `event_digest`, and status; whole-record validation
recomputes its idempotency key and ID
from Mission ID, derived boundary, type, trigger digest, and canonical payload.

Status is derived from durable facts with this vocabulary: `planned`,
`dispatch_pending`, `dispatch_unknown`, `running`, `needs_approval`, `blocked`,
`failed_validation`, `runtime_failure`, `review_ready`, `stale`, `cancelled`,
and `complete`. Required-node precedence is `failed_validation`,
`needs_approval`, `blocked`, `runtime_failure`, `dispatch_unknown`, `stale`,
`review_ready`, `dispatch_pending`, then `running`. All required validated nodes,
passed criterion assignments, and outputs may derive `review_ready`; only an
operator-requested `mission close` derives `complete`.

Bound every observation pass by `max_units`, eight-target batches,
`max_retries`, `max_actions`, `max_forwarded_bytes`,
`max_duration_seconds`, `stale_after_seconds`, and `max_record_bytes`. Stop on exhausted budget,
identity conflict, malformed or conflicting replay, missing required output,
failed validation, required dependency failure, stale required state, approval
need, or any external action. Commit, push, PR/comment, publication, deployment,
shared-environment mutation, external communication, compliance submission,
risk acceptance, and closure remain separately authorized.

Mission creation persists generated defaults of 50 units, 3 retries, 200
actions, 65,536 forwarded bytes, 604,800 seconds duration, a 3,600-second stale
threshold, and a 2,097,152-byte record. Declare all graph nodes before runtime
work; any dispatch, observation, or outbox state freezes the graph. Create or
record a non-root only through exactly one matching prepared dependency action. That
  action names every parent, includes all accepted automatic refs, and provides
  exactly the complete eligible set with at least one ref per parent; terminal
  or incompatible refs cannot start a dependent. A newly
discovered owner requires a separately proposed and user-approved Mission.

`watch_only` and `supervised` creation also requires repeatable
`--success-criterion`, optional repeatable `--non-goal`, and repeatable exact
six-field `--authorized-target-json`. Core assigns ordered `criterion-001` IDs,
nodes declare repeatable `--criterion-id`, and required nodes must cover all
criteria before dispatch. Core derives and revalidates the `scope-<48hex>`
boundary from canonical Mission ID, target, criterion, and non-goal data; it
pins equality and grants no authority. Observations carry normalized
display-only status codes; final codes equal `outcome.code`.

Typed references are control-plane records, not artifact transport. Prove the
consumer can resolve them through an authorized same-host shared workspace or
already-approved external artifact system before dispatch, co-locate compatible
work when independence is not required, or stop. Prepare the core dependency
action before creating a still-planned consumer. Dependency readiness without
that exact prepared, complete, compatible action cannot dispatch a non-root.
After prepare, record the exact
JIT task/runtime/host receipt as internal `awaiting_handoff`, which status
projects as `running`/`handing_off`; deliver references, then acknowledge to
transition it to ordinary running. A client-only result preserves the prepared
action and `dispatch_pending` receipt; it is non-deliverable and never
authorizes another create. Reconcile using both the original client ID and
resolved task ID to enter `awaiting_handoff`. An unknown result also preserves
the prepared action. Either unresolved action may be failed; once failed it is
non-actionable and never retried. Blocked and
stale consumers remain non-actionable. All declared dependencies must be ready, and the
live exact-path project/runtime/host identity is refreshed immediately before
consumer creation. The core action payload contains exactly `node_id`, the
complete declared `dependency_node_ids`, `output_refs`, and
`artifact_resolver`; it includes all accepted automatic refs and at least one
from every parent, exactly equaling the complete eligible accepted set. Partial,
early, terminal-only, or incompatible payloads are
rejected. Final children
emit only closed artifact, own-task, or terminal check/review declarations; they
never author task bindings, resolver identity, or canonical refs. After the
exact task receipt, core persists declarations, materialized refs, and event
digest. Automatic refs use canonical `artifact:` or `codex-task:` namespaces.
Artifact namespaces include resolver, producer, unpadded base64url exact
persisted task binding, lowercase SHA matching the declaration digest, and
artifact ID. `check:` and `review:`
are terminal/operator evidence only. Action resolver metadata is present only
when that action transports an artifact and is null otherwise. This controls
provenance; it does not transport content.
An independent review must use a persistent runtime task distinct from the
producer under review.

## Task Lifecycle

All workflows use this common phase vocabulary:

```text
intake -> scoped -> designed -> authorized -> executing -> integration_ready
       -> validation_ready -> validating -> review_ready -> closed
```

Exceptional states are `blocked`, `cancelled`, and `rollback_required`.

Each adapter selects the smallest applicable subset. For example, research and
daily operations do not need a separate integration phase, while multi-repository application
uses `integration_ready` and `validation_ready` to coordinate multiple owning
repositories and the runtime candidate. The adapter file is authoritative for
allowed transitions.

- `intake`: capture the request without asserting ownership or solution.
- `scoped`: resolve owners, boundaries, evidence, dependencies, and non-goals.
- `designed`: record the coherent change or research approach and its risks.
- `authorized`: record allowed mutations and explicit external-action gates.
- `executing`: perform only authorized work in owning contexts.
- `integration_ready`: owning repo work is internally complete and its
  contracts, branch, SHA, checks, and handoff evidence are available.
- `validation_ready`: dependencies are reconciled and the exact validation
  candidate and authorized environment are known.
- `validating`: run required checks and collect evidence for the exact result.
- `review_ready`: checks pass or skips and residual risks are explicit.
- `closed`: consolidate results, artifacts, decisions, and follow-up work.

No adapter may skip authorization or validation. Reopening work should resume
the existing task instead of creating a duplicate task with contradictory
state.

## Automatic Project Routing

The user starts work in Flightdeck and describes the outcome. The Hub must
infer the workflow and owning context; the user does not need to name a project
or request a thread.

For every request:

1. Classify the work as read-only, implementation, compliance,
   runtime-validation, or coordination.
2. Resolve the workload and owning repo, program workspace, or environment from
   `flightdeck.yaml` and live evidence.
3. Run `bin/flightdeck route plan` when the resolved IDs are known.
4. Search recent tasks in the resolved project and resume a matching objective.
5. If no match exists, create the owning task automatically.
6. Return the task ID and execution mode immediately without polling or reading
   child progress.

This is a fail-closed gate. Before step 5 completes, the Hub may inspect only
Hub policy, registry, routing output, saved-project state, and recent task
metadata required for dispatch. It must not inspect target code or artifacts,
resolve detailed workbook contents, hash evidence, create temporary analysis
scripts, invoke project-specific analysis, or start implementation.

Keep intake, cross-repo design, sequencing, and approvals in the Hub. For
ordinary dispatch, stop the Hub turn after the receipt. The operator monitors
child tasks directly. Read or consolidate results only when the operator later
asks to resume, check a completed task, or coordinate follow-up work. Explicit
Mission observation is the bounded exception defined above; it must follow the
selected mode, normalized-envelope, cursor, outbox, budget, and stop contracts.

Use Local mode for read-only audits, research against an intentional checkout,
current-branch work, and program workspaces. Use Worktree mode for isolated
repository implementation. Use matching remote projects for durable VM or
cluster work.

Do not use a bounded subagent as a shortcut around project routing. Use one only
when the user explicitly requests synchronous parallel work and the task is
coordination-only. Possible examples are:

- inspect a Dockerfile and identify the owning target
- trace an image through charts and product pins
- research one advisory or architecture path
- compare two configurations
- review a small candidate diff
- validate a proposed security finding

Use a persistent project task when the work belongs to a project or durable
project context is useful. Typical examples are:

- implementation or review fixes in an owning repository
- work that will continue across turns
- an isolated Codex Worktree
- independent work in multiple affected repositories
- a durable remote build or cluster-validation session

Use Local mode to continue an intentional current checkout branch. Use
Worktree mode for isolated implementation, and record its base ref and exact
SHA. For cross-repo work, use one persistent task per repo that actually owns a
change; keep the Hub task as coordinator.

### Project registration and launch failure

A persistent task requires a saved Codex project. If the checkout exists but is
missing from the live project list, the Hub registers it automatically, then
re-lists projects before launch. Use the available project-registration API
when present; otherwise open the path in Codex and verify that it appears in
`list_projects`. Require an exact normalized real-path match, capture the opaque
runtime project ID from that record, and use it for launch. The Hub's stable
logical key and the project's display name are not runtime identity.

If registration or task creation fails, retry once only after refreshing live
project state. Then return a self-contained handoff with the exact project,
mode, title, paths, requirements, checks, prohibited actions, and return
contract. This is an observed-failure fallback, not the normal workflow.

Do not use polling as failure detection. A successful create/resume response is
the dispatch receipt. Return it immediately.

Before creating a task, always search for and resume a matching existing task
when one already owns the objective.

## Approval Gates

Authorization belongs in the task record and does not expand merely because the
task is persistent or automated.

| Action | Default |
| --- | --- |
| Read local repos, Hub docs, and task evidence | Automatic |
| Read GitHub or authorized environments | Automatic when access is already in scope |
| Use bounded research and review subagents | Only when explicitly requested for synchronous Hub-only work |
| Generate local plans, reports, and drafts | Automatic |
| Edit files inside the explicitly requested owning repo | Allowed by the implementation request |
| Run focused local tests, builds, lint, and scans | Automatic when non-destructive |
| Clone an identified owning repo into the selected workload | Allowed by an explicit implementation or onboarding request |
| Commit | Explicit task authorization |
| Push or update a remote branch | Explicit task authorization |
| Open or update a PR or request review | Explicit task authorization |
| Mutate a shared VM, cluster, registry, or cloud environment | Explicit environment authorization |
| Retain a validation deployment | Explicit owner and expiry |
| Submit a compliance package or make an authorization claim | Human approval and program authority |
| Contact people or modify external records | Explicit approval |

Secrets, tokens, credentials, kubeconfigs, and sensitive program evidence must
never be copied into task records, prompts, logs, or control-plane history.

## Repo Bridge Operation

Nested repos do not inherit Hub instructions. `hub/bridges/manifest.yaml` maps
configured repositories to local templates for patching, development, charts,
and environment work.

An installed bridge is a machine-local `AGENTS.override.md` excluded through
the nested repo's `.git/info/exclude`. Because an override can supersede the
same-directory tracked file, every template requires the tracked `AGENTS.md` to
be read completely before work. Mandatory behavior needed by other developers,
cloud tasks, or GitHub `@codex review` belongs in the owning repo's committed
`AGENTS.md`, not only in a local bridge.

Ignored bridges do not appear in a newly created Codex Worktree. Before owner
dispatch, the read-only route plan verifies the bridge registry and emits a
`bridge_handoff` containing the original checkout, exact target and artifact
paths, and SHA-256 digests. Include it completely in the child prompt. The
child reads its active-checkout repository instructions first, then verifies
and reads the ignored bridge from the original checkout without copying it.

Bridge templates contain stable policy only. Current branches, SHAs, PRs,
versions, images, scans, and deployments must always be discovered live.

## Scenario One: Patch a Container Image From a Repository Never Cloned

Request example:

> Patch the fixable critical vulnerabilities in this container image.

### 1. Discover ownership before cloning

The Hub resolves:

- image name, tag, digest, scan source, vulnerable package, and fixed version
- the repo, Dockerfile, build context, and target that build the image
- whether the organization owns, forks, mirrors, or only consumes the image
- consuming charts, product pins, program overrides, and airgap propagation

Clone only when a source repo actually owns the patch. If the organization merely consumes
a third-party image, the correct change may be an upstream tag or digest update
in the owning chart or product repo. If no patched upstream exists, decide
explicitly whether to create a organization-owned fork or wrapper image.

### 2. Onboard the owning repo

For a new organization-owned image repo, the Hub:

1. clones it under `<hub-root>/patching/<repo>`
2. verifies the default branch, remotes, and clean starting state
3. registers stable ownership and path information
4. installs the patching bridge without overwriting existing instructions
5. adds `/AGENTS.override.md` to that repo's `.git/info/exclude`
6. verifies tracked repo instructions and active bridge behavior
7. registers the checkout as a saved Codex project and verifies it in the live
   project list
8. searches for an existing matching task and launches a Worktree task when no
   match exists

An external fork normally uses the organization fork as `origin` and the original
project as `upstream`; remote roles must be verified rather than assumed.

### 3. Route implementation

The Hub creates or resumes a persistent task in the saved image-repo project
only after the user requests implementation. Use a Worktree for isolation unless
the request intentionally continues the current branch.

Create additional persistent tasks only when another repo owns a required
change:

```text
Hub patch task
  -> image source task
  -> charts metadata task, if required
  -> product or program pin task, if required
  -> authorized runtime validation task
```

### 4. Patch and validate

The source task preserves runtime contracts, applies the smallest safe change,
builds, tests, generates an updated SBOM when supported, rescans, and records
the exact digest. The Hub reconciles downstream references and validates the
exact candidate in an isolated authorized environment.

Completion evidence includes before/after findings, Dockerfile or source diff,
runtime-contract comparison, digest, SBOM, focused checks, runtime smoke
results, downstream changes, skipped checks, and residual vulnerabilities.

## Scenario Two: Research a Multi-Service Deployment in a Restricted Environment

Request example:

> Research how several services are deployed on Kubernetes in a restricted
> environment.

### 1. Define the decision and evidence boundary

The default scope is an end-to-end deployment trace covering source
composition, packaging, install order, registries, trust, identity, secrets,
networking, charts, environment values, upgrades, and validation. The Hub asks
for clarification only when a different interpretation would materially change
the result.

### 2. Dispatch the owning research task

Create or resume the environment-composition project task and return its ID without
monitoring. That task can trace:

- the edge or disconnected composition entrypoints
- application, data, and analytics chart dependencies and values
- image mirroring, ECR, bundles, manifests, checksums, and install order
- IAM, workload identity, certificates, trust stores, secrets, RBAC, and
  networking
- live AWS or EKS state only when that environment is authorized and available

Use bounded workers only if the user explicitly requests synchronous parallel
research inside that project task. The Hub does not wait for or poll the
environment task after dispatch.

### 3. Separate declared and observed state

Every material claim is labeled as source configuration, live observation,
external documentation, inference, assumption, or gap. Repo configuration does
not prove the current cluster. A live inspection must record account, cluster,
context, time, and non-secret evidence without placing credentials in the Hub.

### 4. Preserve durable research

The Hub stores a source ledger, deployment flow, ownership map, security
boundaries, contradictions, confidence, freshness, open questions, and linked
follow-up tasks. Research that identifies a real defect may propose a linked
repo task, but it does not authorize a code or environment mutation by itself.

## Scenario Three: Secure multi-repository application Feature Before GitHub Review

Request example:

> Add this multi-repository application feature securely and make the candidate ready for
> GitHub `@codex review`.

No process can guarantee that an independent reviewer finds zero issues. The
Hub reduces that risk by making GitHub review a final independent check rather
than the first serious review of the candidate.

### 1. Design and threat-model the feature

The Hub records user outcome, non-goals, API and data contracts,
authentication, authorization, tenant and namespace boundaries, stable subject
identity, migrations, audit behavior, UI states, accessibility, deployment
impact, abuse cases, compatibility, and rollback.

### 2. Route to owning repos

After design and authorization, create or resume only the required saved-project
tasks:

```text
Hub feature task
  -> backend task: API, authorization, data, audit, tests
  -> frontend task: UI, client contract, states, accessibility, tests
  -> charts task: values, manifests, RBAC, secrets, deployment, if affected
  -> remote-validation task: exact-SHA build and integration validation, if authorized
```

The backend is the privileged enforcement boundary. Frontend role gating is
advisory user experience and cannot substitute for backend authorization.

### 3. Reconcile the integration contract

Before PR readiness, the Hub compares backend routes and frontend clients,
request and response types, role semantics, tenancy, errors, migrations,
configuration, chart values, image metadata, and tests. Contract drift returns
the owning task to execution.

### 4. Review the exact candidate

Run repo-native checks, focused tests, builds, lint, static analysis, security
diff review, independent correctness review, migration review, manifest review,
secret scanning, and test-gap review as applicable. Validate the exact pushed
candidate SHA against the current PR base and record any intentionally skipped
check with owner, reason, impact, and follow-up.

Requirements that GitHub `@codex review` must apply need to be committed in each
owning repo's `AGENTS.md`; local overrides are invisible to GitHub review.

The Hub marks the feature `review_ready` only after contracts align, required
checks pass, exact-candidate runtime evidence is captured or explicitly waived,
and residual risk is named. Commit, push, PR update, and review request remain
separate authorization gates.

## Scenario Four: New Program, OSCAL, and Control Narrative Workbook

Request example:

> Set up Program X compliance, generate the required OSCAL documents, and fill
> the control narrative workbook.

Compliance is an adapter, not the Hub's core data model. It must work when
evidence is local, available through an approved system, held by another role,
inaccessible to Codex, requested but pending, or missing.

### 1. Create an isolated program workspace

Create the program from `compliance/_program-template` and record the system
boundary, environment variants, baseline, organization-defined parameters,
common-control providers, evidence cutoff, data markings, deliverables, and
responsible program roles. Real program directories are excluded from the Hub
control-plane Git boundary.

Before processing artifacts, confirm that Codex and the current environment are
authorized for their sensitivity. Do not copy evidence into the Hub merely to
make it locally accessible.

### 2. Track available and unavailable evidence honestly

Classify evidence as:

```text
local | externally_accessible | externally_held | requested | inaccessible | missing
```

An approved connector or program-provided export can supply external evidence.
Externally held, inaccessible, and missing evidence becomes an explicit gap or
collection action; it must never be replaced by an invented narrative.

### 3. Select deliverables rather than generating everything

Inspect the workbook structure and determine which OSCAL models and schema
version are required. Possible deliverables include profile, component
definition, SSP, assessment plan, assessment results, and POA&M. Generate only
the artifacts the program needs, preserving the source workbook, formulas,
hidden sheets, validation, formatting, and identifiers.

### 4. Separate authoring from assessment

Technical research workers may trace implementation through application, data,
analytics, charts, program composition, and authorized live evidence. For each workbook
row, the author maps the control, enhancement, assessment procedure, CCI,
responsibility, environment, implementation, evidence, inheritance,
organization-defined parameters, and gaps.

An independent QA pass checks requirement coverage, program applicability,
evidence currency, responsibility, unsupported claims, inherited-control
support, and status justification. The author does not approve its own result.

### 5. Validate generated artifacts

Validate OSCAL against the selected official schema, internal references and
UUIDs, workbook structure, evidence paths and hashes, and machine-readable
sidecars. JSON is canonical; YAML must be derived mechanically and parse to the
same typed structure. Identifiers such as CCIs remain strings.

The Hub may produce review-ready drafts and a gap list. It may not claim eMASS
acceptance, control effectiveness, authorization, or POA&M closure without the
required evidence and human program authority.

## Daily Operating Result

Regardless of adapter, the Hub returns one concise status containing:

- current lifecycle state
- active and completed repo, research, or environment tasks
- exact branches and SHAs discovered for this run
- checks and evidence collected
- blocked dependencies and missing evidence
- residual risk and required follow-up
- actions waiting for operator approval
- confirmation that no unauthorized commit, push, PR, deployment, submission,
  or external communication occurred

This keeps the operator in one Hub experience while preserving correct code,
environment, evidence, and authority boundaries underneath.
