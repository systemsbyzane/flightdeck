# Flightdeck Control Plane Implementation Plan

**Goal:** Build a Hub-only documentation and instruction layer for
design-first, secure, evidence-backed work.

**Architecture:** The Hub owns shared workflow, design, security, compliance,
review, and validation guidance. Independent repositories retain their own Git
histories and implementation rules. Repository bridges make Hub guidance
available to owning projects without relying on implicit instruction
inheritance.

**Tech stack:** Markdown documentation, Codex `AGENTS.md` instructions, and the
local filesystem rooted at `<hub-root>`.

The current executable design is documented in
[control-plane architecture](../../architecture/control-plane.md) and
[Flightdeck operations](../../workflows/operations.md).

## Task 1: Create The Hub Documentation Structure

**Files:**

- Create: `docs/README.md`
- Create: `docs/architecture/README.md`
- Create: `docs/security/README.md`
- Create: `docs/workflows/README.md`

- [ ] Create the architecture, security, workflow, template, and retained
  design-record directories.
- [ ] Add concise indexes that state what each documentation area owns and link
  to its detailed guides.

Expected: [the documentation index](../../README.md) provides one entrypoint to
the shared operating method.

## Task 2: Add Design And Security Guides

**Files:**

- Create: `docs/architecture/design-review.md`
- Create: `docs/architecture/decision-record-template.md`
- Create: `docs/security/secure-code-preflight.md`
- Create: `docs/security/threat-model.md`

- [ ] Add design-review guidance for intent, owner, non-goals, evidence,
  design, security model, validation, and rollback.
- [ ] Add a decision template for context, decision, alternatives, security
  impact, validation, and consequences.
- [ ] Add secure-code guidance for application, deployment, infrastructure, and
  live-environment checks.
- [ ] Add a threat-model template for actors, trust boundaries, data, abuse
  cases, controls, evidence, and residual risk.

Expected: risky changes can use
[design review](../../architecture/design-review.md),
[secure-code preflight](../../security/secure-code-preflight.md), and
[threat modeling](../../security/threat-model.md) without copying policy into
each repository.

## Task 3: Add Routing And Repository Bridge Guidance

**Files:**

- Create: `docs/workflows/thread-routing.md`
- Create: `docs/workflows/repo-bridge.md`
- Create: `docs/templates/repo-bridge.md`

- [ ] Document when to use the Hub, an owning repository project, Worktree
  mode, an environment project, source-control context, and security tooling.
- [ ] Define reference, materialized, and repository-native bridge levels.
- [ ] Add a reusable `AGENTS.md` section with the minimum design, security,
  routing, environment-separation, and evidence contract.

Expected: [thread routing](../../workflows/thread-routing.md) dispatches owner
work before analysis, and [repo bridge design](../../workflows/repo-bridge.md)
preserves repository authority.

## Task 4: Add Reusable Templates

**Files:**

- Create: `docs/templates/task-intake.md`
- Create: `docs/templates/implementation-plan.md`
- Create: `docs/templates/pr-readiness.md`
- Create: `docs/templates/validation-evidence.md`

- [ ] Capture outcome, workload, owner, work type, evidence, assumptions,
  non-goals, risks, and validation in task intake.
- [ ] Capture starting state, affected files, security notes, planned checks,
  and rollback in implementation plans.
- [ ] Add review-readiness checks for design, security, tests, and reviewer
  notes.
- [ ] Record commands, artifacts, security evidence, skipped checks, and
  residual risk in validation evidence.

Expected: the [template index](../../README.md#templates) gives every owning
project the same handoff vocabulary.

## Task 5: Update Hub Entry Points

**Files:**

- Modify: `AGENTS.md`
- Modify: `README.md`

- [ ] Add the dispatch boundary, task intake, design-first posture, security
  validation, approval gates, and bridge contract to root instructions.
- [ ] Add documentation navigation, the operating model, workload roots, and
  common command entrypoints to the root README.

Expected: a new operator can identify the owner and next safe action from the
Hub root without opening repository code.

## Task 6: Validate The Hub Change

**Inspect:**

- `AGENTS.md`
- `README.md`
- `docs/**/*.md`

- [ ] Confirm no independent repository or program workspace was modified by
  the Hub-only pass.
- [ ] Scan tracked Hub files for unfinished markers and source-specific
  identities.
- [ ] Parse structured files and verify all documentation links and expected
  files.
- [ ] Run the plugin validator, skill validators, automated tests, fresh setup
  generation, generated Doctor, de-branding scan, setup-link validation, and
  the local acceptance harness.
- [ ] Inspect `git status` and distinguish this plan's files from concurrent or
  pre-existing work.

Expected: validation is non-destructive and all failures identify the exact
file or boundary that needs correction.

## Task 7: Roll Out Repository Bridges

**Candidate files:**

- Modify: `<repo-root>/AGENTS.md`
- When present, modify: `<repo-root>/AGENTS.override.md`

- [ ] Read every applicable repository instruction file before adding a
  bridge.
- [ ] Plan the bridge and review its target, mode, digests, and exclusions.
- [ ] Install the bridge only with authorization and without overwriting
  existing instructions.
- [ ] Start a fresh repository task and verify that repository rules remain
  primary while the Hub references are available.

Expected: the repository task reads its own instructions first and the verified
Hub bridge second. A Worktree reads ignored bridge material from the original
registered checkout named by the handoff.

## Task 8: Add Workload-Specific Guidance

**Files:**

- Create: `docs/architecture/manifest-architecture.md`
- Create: `docs/patching/README.md`
- Create: `docs/patching/image-compatibility.md`
- Update the relevant Hub and workload entrypoints.

- [ ] Treat deployment templates, workflow YAML, and rendered manifests as
  production code, including identity, permissions, networking, secrets,
  storage, images, scheduling, observability, hooks, and upgrade behavior.
- [ ] Require image and dependency patches to preserve documented runtime
  contracts unless a breaking change is intentional and coordinated.
- [ ] Link workload entrypoints to the required guides before implementation.

Expected: [manifest architecture](../../architecture/manifest-architecture.md)
and [image compatibility](../../patching/image-compatibility.md) are applied by
the owning repository rather than inferred by the Hub.
