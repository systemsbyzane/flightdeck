# Planning method

## Depth selection

Choose the least ceremony that still makes execution safe.

- Compact: one owner, low risk, known approach, no migration or shared-runtime
  effect.
- Standard: several components, meaningful dependencies, compatibility or
  security concerns, or non-obvious validation.
- Expanded: several owners, contract changes, data migration, CI/CD or platform
  changes, shared-environment impact, compliance consequences, or difficult
  rollback.

The user may ask for more or less detail at any time. Depth changes
presentation, not authorization.

## Evidence

Prefer current repository instructions, source, tests, configuration, workflow
definitions, schemas, and supplied requirements. Separate observed facts from
assumptions and unknowns. For changing external facts, verify through an
authorized current source before depending on them.

In a Hub, ownership planning may use only Hub policy, registry, routing,
bridge metadata, and saved-project state. Repository-specific analysis belongs
in the owning project.

## Plan content

Include only the fields that affect execution:

- intended outcome and non-goals;
- owner or owning layer;
- ordered steps and dependencies;
- affected contracts or trust boundaries;
- validation and completion evidence;
- rollout, migration, or rollback where applicable;
- explicit approval gates;
- unresolved decisions and the evidence needed to resolve them.

Use one owner per implementation unit. For cross-repository work, sequence
producer and consumer contract changes explicitly and keep runtime validation
separate from source authoring.

## Quality checks

Before returning the plan, verify that it:

- solves the stated outcome rather than merely listing files;
- is specific enough to execute but does not invent facts;
- distinguishes required work from optional follow-up;
- names validation proportional to risk;
- preserves compatibility and failure behavior;
- leaves commits, publication, deployment, external communication, compliance
  submission, risk acceptance, and closure behind explicit gates.
