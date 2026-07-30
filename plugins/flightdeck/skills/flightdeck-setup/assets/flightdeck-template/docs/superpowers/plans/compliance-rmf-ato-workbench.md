# Compliance RMF And ATO Workbench Implementation Plan

**Goal:** Create a compliance workload scaffold and reusable RMF,
authorization-package, assessment, and evidence guidance for isolated program
workspaces.

**Architecture:** The Hub owns reusable compliance method under
`docs/compliance/`. Each `compliance/<program>/` workspace owns its facts,
templates, evidence, internal working records, and deliverables. The program
template carries local instructions that bridge the program project back to the
Hub guidance.

**Tech stack:** Markdown documentation, local filesystem directories, Codex
`AGENTS.md` instructions, user-supplied authorization workbooks, and JSON/YAML
sidecars.

The current method begins at
[compliance documentation](../../compliance/README.md) and
[program workspace guidance](../../compliance/program-workspace-guide.md).

## Task 1: Create Shared Compliance Method

**Files:**

- Create the navigation, RMF operating model, workbook workflow, control
  assessment, evidence analysis, POA&M, policy generation, sidecar, assessor
  quality, sensitivity, and program workspace guides under `docs/compliance/`.

- [ ] Give each guide one clear responsibility, evidence discipline, and
  repeatable workflow.
- [ ] Ground public process claims in applicable public standards while
  treating private platform instructions and program facts as workspace inputs.
- [ ] Link the guides through
  [the compliance index](../../compliance/README.md).

Expected: the shared docs describe method without embedding real program
identities, evidence, or private schema.

## Task 2: Create The Program Workspace Template

**Files:**

- Create: `compliance/README.md`
- Create: `compliance/AGENTS.md`
- Create: `compliance/_program-template/AGENTS.md`
- Create: `compliance/_program-template/README.md`
- Create the standard program subdirectories.

- [ ] Route users into one isolated program workspace and the shared compliance
  docs.
- [ ] Make a copied program folder independently openable as a Codex project.
- [ ] Include directories for context, source documents, input templates,
  polished deliverables, internal working records, control assessments, POA&M
  work, evidence indexes, and working notes.

Expected: `compliance/example-program/` can be created from the template
without carrying facts from another program.

## Task 3: Create Reusable Compliance Templates

**Files:**

- Create templates for program instructions, program README files, control
  assessment notes, evidence indexes, and POA&M analysis under
  `docs/compliance/templates/`.

- [ ] Require every claim to be classified as supported fact, inference,
  assumption, gap, or recommendation.
- [ ] Require evidence locations, program actions, evidence-backed status, and
  handling notes where applicable.
- [ ] Verify templates contain no unfinished markers or real identities.

Expected: templates are synthetic, program-neutral starting points rather than
pre-filled authorization claims.

## Task 4: Update Hub Navigation And Validate

**Files:**

- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/README.md`

- [ ] Link the compliance workload and shared docs from Hub entrypoints.
- [ ] Treat program folders as sensitive evidence and document workspaces, not
  source repositories.
- [ ] Verify that deliverables contain no AI/tool provenance,
  authoring/review-process labels, or unresolved variables, and that required
  JSON/YAML working records stay outside delivery packages.
- [ ] Verify structured files parse, links resolve, source-specific identities
  are absent, and fresh setup generation reproduces the expected workspace.
- [ ] Confirm no external submission, approval, or authorization claim occurs
  without explicit authority.

Expected: the Hub can route compliance work while program facts remain isolated
and publication or submission remains approval-gated.
