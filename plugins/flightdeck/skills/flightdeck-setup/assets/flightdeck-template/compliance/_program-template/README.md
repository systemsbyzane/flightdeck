# Program compliance workspace

Replace this directory name with a neutral local identifier. Record mission,
boundary, roles, baseline, evidence cutoff, handling constraints, and package
objective in `context/`.

- `source-documents/`: original SSP, assessment, policy, scan, checklist,
  diagram, export, and package-instruction inputs.
- `input-templates/`: preserved workbooks, forms, and upload templates.
- `evidence-index/`: source locations, tiers, sensitivity, and open questions.
- `control-assessments/`: control-part implementation and assessor notes.
- `poam/`: evidence-backed weakness candidates, milestones, and closure needs.
- `working-notes/`: analysis, interviews, conflicts, and unresolved decisions.
- `generated-documents/`: draft human artifacts plus same-basename JSON and
  YAML sidecars.

Start with an inventory. Do not fill a workbook or draft a control claim until
the authorization boundary, template-owned fields, evidence strength, gaps,
and handling constraints are understood.

Real program data is ignored local workspace content and must never be bundled
back into the distributable plugin.
