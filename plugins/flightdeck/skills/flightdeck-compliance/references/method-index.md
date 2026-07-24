# Compliance Docs

This folder is the shared operating layer for DoD RMF, eMASS, and ATO package
work in the `Flightdeck` hub. Use it from program-specific workspaces under:

`<hub-root>/compliance/<program>/`

Each program workspace owns its facts: diagrams, prior POA&Ms, policies,
spreadsheets, eMASS exports, interviews, scans, STIG artifacts, SSP text, and
customer templates. These docs own the repeatable method for turning that
context into reviewer-ready control language and package artifacts.

## Start Here

- `program-workspace-guide.md` - create and operate a program workspace.
- `dod-rmf-ato-operating-model.md` - understand the ATO package lifecycle,
  roles, artifacts, and decision points.
- `emass-template-workflow.md` - fill a provided eMASS workbook without
  corrupting the template or inventing private schema.
- `control-assessment-methodology.md` - assess controls from evidence.
- `evidence-analysis-guide.md` - classify, cite, and challenge evidence.
- `poam-generation-guide.md` - generate POA&M-ready weakness and milestone
  language.
- `policy-generation-guide.md` - draft policy and procedure artifacts from
  program context.
- `machine-readable-artifacts.md` - generate JSON and YAML sidecars alongside
  human-readable artifacts.
- `assessor-quality-bar.md` - maintain AO/SCA-quality discipline.
- `artifact-sensitivity-and-handling.md` - handle sensitive assessment material
  safely.

## Source Anchors

Use current public sources where possible, and treat customer or
program-provided artifacts as the source of truth for program-specific fields.

- NIST SP 800-37 Rev. 2:
  `https://csrc.nist.gov/pubs/sp/800/37/r2/final`
- NIST SP 800-53 Rev. 5:
  `https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final`
- NIST SP 800-53A Rev. 5:
  `https://csrc.nist.gov/pubs/sp/800/53/a/r5/final`
- DoD CIO public library:
  `https://dodcio.defense.gov/library/`
- DoD Cyber Exchange STIG/SRG entrypoint:
  `https://public.cyber.mil/stigs/`

Some eMASS, RMF Knowledge Service, and customer-specific instructions are
restricted. Do not infer those details. Use the workbook, export, screenshot,
package instruction, or user-provided guidance in the program workspace.

## Operating Rule

Generated compliance artifacts are drafts for human review. They are not
authorization decisions, accepted eMASS uploads, approved policy, or verified
control effectiveness unless the program record proves that status.

Every generated artifact should also produce same-basename `.json` and `.yaml`
sidecars in the same directory.

