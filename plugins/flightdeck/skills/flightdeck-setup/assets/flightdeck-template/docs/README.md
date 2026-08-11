# Flightdeck Docs

This folder is the shared operating layer for the Flightdeck Hub. It provides
architecture, security, workflow, compliance, review, patching, and validation
guidance for independent repositories and program workspaces without turning
the Hub into a monorepo.

## Start Here

- [Missions](workflows/missions.md) - opt into durable graph coordination for
  verified persistent tasks while keeping direct dispatch receipt-and-stop.
- [Thread routing](workflows/thread-routing.md) - resolve the owning project,
  execution mode, and environment.
- [Planning](workflows/planning.md) - create a right-sized, read-only plan from
  natural intent.
- [CI/CD and delivery](workflows/ci-cd.md) - diagnose or change delivery
  pipelines with exact-revision evidence.
- [Platform and environments](workflows/platform.md) - coordinate
  infrastructure source and live runtime ownership.
- [Database work](workflows/database.md) - design and change persistent data
  safely across schema, query, migration, reliability, and recovery concerns.
- [Plugin lifecycle](workflows/plugin-lifecycle.md) - upgrade the installed
  Flightdeck plugin without regenerating this Hub or changing repositories.
- [Generated-Hub compatibility](workflows/hub-compatibility.md) - verify
  versioned commands and documents before newer installed skills require them.
- [Flightdeck operations](workflows/operations.md) - use the registry, task
  lifecycle, status, routing, and approval model.
- [Control-plane architecture](architecture/control-plane.md) - understand
  ownership, security, validation, and recovery boundaries.
- [Hub-first application contract](architecture/hub-first.md) - consume bounded
  Hub and Operations snapshots without inferring runtime state.
- [Operation projection API](workflows/operation-projection-api.md) - display
  one durable Mission with verified task-bound skill evidence.
- [Repo bridge design](workflows/repo-bridge.md) - make Hub guidance available
  inside independent repository projects.
- [Review readiness](review/codex-review-readiness.md) - prepare a change for
  repository review.
- [Change review](review/change-review.md) - review the exact candidate and
  lead with evidence-backed findings.
- [Design review](architecture/design-review.md) - evaluate non-trivial changes
  before implementation.
- [Manifest architecture](architecture/manifest-architecture.md) - review Helm,
  YAML, workflow, and rendered deployment changes as production code.
- [Secure-code preflight](security/secure-code-preflight.md) - check security
  posture before a review-ready claim.
- [Image compatibility](patching/image-compatibility.md) - preserve downstream
  runtime contracts while patching images or dependencies.
- [Compliance guidance](compliance/README.md) - operate evidence-backed RMF and
  authorization-package workspaces.
- [STIG evaluation](compliance/stig-evaluation.md) - evaluate rules, review
  evidence gaps, handle inherited controls, and prepare CKL output without a
  fixed intake form.

## Templates

- [Task intake](templates/task-intake.md) - define intent, ownership, scope, and
  evidence.
- [Implementation plan](templates/implementation-plan.md) - plan an owning-repo
  change before editing.
- [PR readiness](templates/pr-readiness.md) - complete the final review gate.
- [Validation evidence](templates/validation-evidence.md) - record commands,
  artifacts, results, skipped checks, and residual risk.
- [Repository bridge](templates/repo-bridge.md) - add the minimum Flightdeck
  contract to an independent repository.
- [Compliance templates](compliance/templates/) - start program instructions,
  evidence indexes, control notes, and POA&M analysis.

## Source Of Truth

Repository-specific `AGENTS.md` files remain authoritative for code structure,
commands, tests, generated files, and implementation mechanics. Program
workspaces remain authoritative for their facts and evidence. These Hub docs
define the shared posture: dispatch before owner analysis, design and security
review where risk warrants them, explicit approval boundaries, evidence-backed
validation, and separation between local source changes and live-environment
inspection.
