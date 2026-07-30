# Program instructions

Read the Hub `AGENTS.md`, then these shared method files before work:

- `../../docs/compliance/README.md`
- `../../docs/compliance/dod-rmf-ato-operating-model.md`
- `../../docs/compliance/emass-template-workflow.md`
- `../../docs/compliance/control-assessment-methodology.md`
- `../../docs/compliance/evidence-analysis-guide.md`
- `../../docs/compliance/poam-generation-guide.md`
- `../../docs/compliance/policy-generation-guide.md`
- `../../docs/compliance/machine-readable-artifacts.md`
- `../../docs/compliance/assessor-quality-bar.md`
- `../../docs/compliance/artifact-sensitivity-and-handling.md`
- `../../docs/compliance/program-workspace-guide.md`

- Default to read-only evidence review.
- Cite every substantive conclusion to local evidence.
- Separate observation, inference, unknowns, and authorization.
- Keep required JSON and YAML working records semantically equivalent and
  outside the delivery directory.
- Treat rendered Word, PDF, and spreadsheet files as outputs, not policy.
- Require explicit human approval for submission, publication, external
  communication, risk acceptance, effectiveness claims, and closure.
- Never invent evidence, owners, dates, effectiveness, authorization, or closure.
- Preserve source templates, formulas, validations, hidden sheets, identifiers,
  and template-owned fields. Inspect before writing.
- Use the installed DOCX, PDF, XLSX, or STIG capability and complete its render,
  inspect, and iterate gates for those artifact types.
- Treat final files as professional human-authored documents. Do not expose AI,
  Codex, prompts, tools, authoring steps, review workflow, internal QA notes, or
  unresolved template variables.
- Put polished files under `deliverables/`; put internal structured records,
  renderings, change summaries, and validation results under
  `working-records/`.
- Validate the final content and build packages from an explicit allowlist that
  includes only the requested file types.
- Run `make validate-deliverables` before returning or packaging files from
  `deliverables/`.
