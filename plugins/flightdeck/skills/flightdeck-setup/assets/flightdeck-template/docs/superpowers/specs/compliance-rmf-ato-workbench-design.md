# Compliance RMF And ATO Workbench Design

## Intent

Create a repeatable RMF, assessment, and authorization-package workflow in
`<hub-root>` that lets each program workspace use its own evidence, diagrams,
policies, prior POA&Ms, workbooks, and templates while relying on shared Hub
guidance for consistent assessment quality.

A user can create `compliance/example-program/`, add program context, open that
folder as a Codex project, and produce reviewer-ready control workbooks, POA&M
material, policy drafts, evidence indexes, and assessment notes from the
available record.

## Current Context

Flightdeck is a coordination Hub, not a Git monorepo. It separates shared
guidance under `docs/` from owning repositories and workspace-specific facts.
The compliance workflow follows the same model:

- shared assessment, security, and evidence method lives under
  `docs/compliance/`
- program workspaces live under `compliance/<program>/`
- each program folder can be opened as an independent Codex project
- local program instructions bridge back to the shared method

A compliance workspace is primarily an evidence and document workspace. The
program folder owns the facts; the Hub docs own the method.

## Source Anchors

Use current public RMF, control-catalog, control-assessment, secure-configuration,
and authorization guidance for shared process. Use program-provided artifacts
for program-specific facts.

Private or restricted platform instructions, portal schema, customer templates,
and authorization artifacts are program inputs. Do not invent private fields,
roles, upload requirements, or acceptance criteria when the workspace does not
provide them.

## Goals

- Make compliance a first-class Flightdeck workload.
- Provide reusable RMF, assessment, evidence, POA&M, policy, and
  authorization-package guidance.
- Make every `compliance/<program>/` folder self-contained enough to open as a
  Codex project.
- Standardize how a task inventories context, maps evidence to controls, fills
  supplied workbooks, and produces supporting drafts.
- Generate equivalent `.json` and `.yaml` sidecars alongside human-readable
  outputs.
- Preserve exact columns, formulas, validation, hidden content, and expected
  structure in supplied workbooks when tooling can inspect them.
- Tie every claim to evidence, inference, assumption, gap, or recommendation.
- Require human review before upload, submission, approval, risk acceptance, or
  closure.

## Non-Goals

- Do not automate live portal upload or package submission.
- Do not claim compatibility with a private format unless that format is
  supplied and inspected.
- Do not turn the Hub into a monorepo or build a large custom application.
- Do not replace authorization, assessment, security, program, system-owner, or
  mission-owner judgment.
- Do not generate unsupported claims to make a package appear complete.
- Do not mix facts or evidence between program workspaces.

## Workload Structure

The reusable shape is:

```text
compliance/
  AGENTS.md
  README.md
  _program-template/
    AGENTS.md
    README.md
    context/
    source-documents/
    input-templates/
    generated-documents/
    control-assessments/
    poam/
    evidence-index/
    working-notes/

docs/compliance/
  README.md
  dod-rmf-ato-operating-model.md
  emass-template-workflow.md
  control-assessment-methodology.md
  evidence-analysis-guide.md
  poam-generation-guide.md
  policy-generation-guide.md
  machine-readable-artifacts.md
  assessor-quality-bar.md
  artifact-sensitivity-and-handling.md
  program-workspace-guide.md
  templates/
```

The retained filenames map to existing Flightdeck documents; their reusable
rules apply only where the selected program and authorization context require
them.

## Program Workspace Contract

Treat each `compliance/<program>/` folder as the authoritative local record for
that program:

- `context/`: mission, scope, boundary, architecture, roles, environment,
  assumptions, inherited services, and constraints
- `source-documents/`: prior plans, assessments, POA&Ms, diagrams, policies,
  procedures, scans, secure-configuration output, inherited-control material,
  and earlier authorization artifacts
- `input-templates/`: supplied workbooks, control matrices, upload templates,
  and package forms
- `generated-documents/`: generated workbook drafts, policies, narratives,
  summaries, support documents, and their sidecars
- `control-assessments/`: control-by-control analysis, implementation
  statements, assessment notes, and gaps
- `poam/`: weakness candidates, risk rationale, milestones, ownership,
  completion targets, and closure-evidence notes
- `evidence-index/`: references to files, pages, sheets, sections, screenshots,
  and generated mappings
- `working-notes/`: scratch analysis, interview notes, review comments, and
  unresolved questions

Local instructions require the owning task to read
[the compliance index](../../compliance/README.md), inspect only the selected
program folder, and preserve evidence boundaries in every output.

## Shared Compliance Guides

- [RMF and authorization operating model](../../compliance/dod-rmf-ato-operating-model.md)
  defines lifecycle stages, roles, artifacts, and decision points.
- [Authorization workbook workflow](../../compliance/emass-template-workflow.md)
  preserves supplied templates and records changes.
- [Control assessment methodology](../../compliance/control-assessment-methodology.md)
  separates objectives, parameters, responsibility, implementation, tests, and
  gaps.
- [Evidence analysis](../../compliance/evidence-analysis-guide.md) classifies
  quality, freshness, conflict, and citation strength.
- [POA&M generation](../../compliance/poam-generation-guide.md) requires a
  weakness, affected control, risk, root cause, source, milestones, owner,
  completion target, residual risk, and closure evidence.
- [Policy generation](../../compliance/policy-generation-guide.md) produces
  drafts with source context, assumptions, and required owner review.
- [Machine-readable artifacts](../../compliance/machine-readable-artifacts.md)
  defines equivalent same-basename JSON/YAML sidecars.
- [Assessor quality](../../compliance/assessor-quality-bar.md) requires
  evidence-weighted, reviewer-ready analysis.
- [Artifact handling](../../compliance/artifact-sensitivity-and-handling.md)
  prevents credentials, privacy data, controlled material, and raw sensitive
  evidence from leaking into unrelated folders or prompts.
- [Program workspace guidance](../../compliance/program-workspace-guide.md)
  explains creation, organization, and operation.

## Authorization Workbook Workflow

When the user supplies an authorization or control workbook:

1. Inspect the workbook before editing.
2. Identify sheets, tables, columns, formulas, validations, hidden content, and
   protected fields when tooling can see them.
3. Identify fields intended for generated content.
4. Ask before changing ambiguous required fields unless the user explicitly
   names them.
5. Build an evidence map from the selected program workspace.
6. Fill fields only from supported facts.
7. Label weak, stale, conflicting, or missing evidence as gaps.
8. Preserve workbook structure and template-owned fields.
9. Produce an assessment note listing inputs, generated fields, skipped fields,
   assumptions, gaps, and unresolved questions.
10. Save the output in the program workspace at the authorized path.
11. Save equivalent same-basename `.json` and `.yaml` sidecars with changes,
    evidence references, assumptions, gaps, skipped fields, and reviewer
    actions.

The result is a draft for human review, not proof of upload acceptance or an
authorization decision.

## Evidence And Claim Discipline

Classify every control assertion:

- **Supported fact:** directly backed by a named artifact and precise location.
- **Reasonable inference:** derived from evidence but not directly stated;
  label the inference and its basis.
- **Assumption:** needed to proceed but unproved; require owner review.
- **Gap:** required evidence is missing, stale, conflicting, or insufficient.
- **Recommendation:** proposed language or action that is not approved program
  state.

Record the classification in control notes and sidecars even when a supplied
workbook has no suitable column.

## Default Operating Posture

Combine:

- package-author discipline for clear, usable control, policy, POA&M, and
  narrative drafts
- assessor discipline for challenging unsupported claims and identifying gaps
- decision-support discipline for summarizing inheritance, compensating
  controls, operational impact, residual risk, and open decisions

When those perspectives conflict, evidence quality and authorization risk take
priority over apparent package completeness.

## Validation

The design is implemented when:

- compliance workload instructions and navigation exist
- the reusable program template contains the required isolated directories
- shared compliance guides describe repeatable evidence-backed method
- Hub navigation links to both the workload and shared docs
- generated content contains no real identity or unfinished markers
- public method is distinguished from private program and platform details
- supplied workbooks are preserved instead of replaced with a generic shape
- generated artifacts include equivalent JSON and YAML sidecars
- no external submission, approval, risk acceptance, or closure occurs without
  explicit authority

## Rollback

Remove the compliance scaffold and shared compliance documentation, then remove
their Hub navigation links. Program evidence or generated outputs must be
archived or removed only through a separately authorized, scoped operation.
Independent repository history and environment state are unaffected.
