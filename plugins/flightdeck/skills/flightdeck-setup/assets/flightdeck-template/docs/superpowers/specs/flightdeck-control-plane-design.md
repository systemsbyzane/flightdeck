# Flightdeck Control Plane Design

## Intent

Turn `<hub-root>` into a professional operating Hub for design-first,
security-aware, evidence-backed work across independent repositories,
workspaces, and environments without converting the Hub into a monorepo.

This record defines the documentation and instruction layer. The executable
registry, task, routing, bridge, and recovery design lives in
[control-plane architecture](../../architecture/control-plane.md).

## Current Context

The Hub may contain or reference several independent Git repositories. Each
repository owns its history and its applicable `AGENTS.md` rules. Compliance
program folders are evidence and document workspaces rather than source
repositories, and each owns its own facts.

Codex instruction discovery begins at the selected project root. An independent
repository opened as its own project must not be assumed to inherit the Hub
instructions. The Hub therefore dispatches to exact saved projects and uses a
verified bridge when shared guidance is required.

## Goals

- Provide clear shared guidance for workflow, architecture, security, review,
  patching, compliance, and validation.
- Route repository edits and owner analysis into the actual owning project.
- Make design review and secure implementation the default posture when risk
  warrants them.
- Make shared guidance available through a non-destructive repository bridge
  without replacing repository rules.
- Keep durable content neutral and keep machine-local facts in ignored state.

## Non-Goals

- Do not combine independent repositories into one Git history.
- Do not replace repository-specific `AGENTS.md` files.
- Do not place raw evidence, credentials, mutable runtime state, or generated
  task state in the Hub's durable documentation.
- Do not create skills for one-off procedures that have not stabilized.
- Do not treat a successful dispatch as proof that implementation or validation
  completed.

## Design

The shared documentation surface contains:

- `docs/architecture/` for design review, decision records, deployment
  architecture, and control-plane boundaries
- `docs/security/` for secure-code preflight and threat modeling
- `docs/workflows/` for routing, operations, onboarding, bridge management, and
  environment handoffs
- `docs/review/` for review readiness and evidence packets
- `docs/patching/` for image and dependency compatibility
- `docs/compliance/` for assessment, evidence, authorization-package, and
  program-workspace method
- `docs/templates/` for intake, plans, bridges, review, and validation evidence
- `docs/superpowers/specs/` and `docs/superpowers/plans/` for retained design
  and implementation records

Root `AGENTS.md` remains the Hub-scope policy. Repository instructions control
implementation mechanics; Hub guidance controls cross-project coordination,
shared approval boundaries, and evidence posture. The stricter security and
authorization rule wins.

Root `README.md` and [the docs index](../../README.md) are the human navigation
entrypoints.

## Repository Bridge

The bridge has three levels:

1. **Reference bridge**: install ignored machine-local instructions that point
   to the Hub and record required file digests.
2. **Materialized bridge pack**: install an ignored copy of the required guides
   when a stable local reference is insufficient.
3. **Repository-native policy**: add explicitly authorized tracked rules when
   policy must travel with the repository.

Use Level 1 first. Promote only when portability, reviewability, or mandatory
enforcement requires it.

Repository and local override files must be inspected before installation.
Existing instructions are never overwritten. Route planning verifies bridge
mode, target, and digests before dispatch. Because ignored files do not appear
in a new Worktree, the task reads repository instructions in the Worktree and
then reads verified bridge material from the original registered checkout.

See [repo bridge design](../../workflows/repo-bridge.md) and
[thread routing](../../workflows/thread-routing.md).

## Security Model

The shared layer reinforces:

- server-side authorization rather than interface-only controls
- stable identity and explicit scope for ownership decisions
- explicit secret and sensitive-evidence handling
- least-privilege deployment and artifact ownership boundaries
- secure manifest defaults and intentional image compatibility
- dispatch before owner-specific code, workbook, or evidence analysis
- validation evidence before review-ready or closure claims
- separation of local source changes from live-environment inspection
- explicit approval before external writes, publication, deployment,
  compliance submission, risk acceptance, or closure

Repository security rules remain authoritative where they are more specific.

## Validation

The design is implemented when:

- Hub docs exist and link to current files
- root instructions and README expose the coordinator and approval boundaries
- repository bridges preserve repository authority and exact-path identity
- generated state and sensitive evidence remain outside durable Hub history
- no independent repository is modified by Hub-only validation
- structured files parse, automated tests pass, fresh setup generation works,
  generated Doctor is non-mutating, and de-branding and link scans pass
- all incomplete checks and residual risks are reported rather than hidden

## Rollback

The documentation layer is additive. Remove its Hub docs and root navigation
updates to return to the prior operating surface. Remove installed bridges only
through an explicit, scoped bridge operation. Independent repository history,
program evidence, and environment state require no cleanup when the Hub-only
change respected its boundaries.
