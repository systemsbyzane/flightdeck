# Control Assessment Methodology

Use this method to assess controls from a program workspace and generate
implementation, assessment, and gap language.

## Assessment Steps

1. Identify the control ID, title, control text, enhancements, parameters, and
   expected assessment objective.
2. Determine responsibility: inherited, common, hybrid, system-specific,
   planned, not applicable, or unknown.
3. Locate evidence in the program workspace.
4. Classify evidence quality using `evidence-analysis-guide.md`.
5. Draft implementation language from supported facts.
6. Draft assessment language that separates fact, inference, assumption, and
   gap.
7. Identify POA&M candidates for missing or ineffective control elements.
8. Record source references in the evidence index or companion notes.

## Responsibility Categories

- **Inherited**: the program relies on a common control provider or authorized
  service for implementation.
- **Common**: a shared organizational control applies to multiple systems.
- **Hybrid**: some control elements are inherited and some are implemented by
  the program.
- **System-specific**: the program owns implementation inside its boundary.
- **Planned**: implementation is expected but not yet complete.
- **Not applicable**: the control does not apply and the rationale is
  supported by scope or architecture.
- **Unknown**: the available record does not establish responsibility.

Unknown is better than false certainty.

## Implementation Statement Pattern

Use this pattern when the workbook or SSP field expects implementation detail:

```text
The [system/component/team] implements [control capability] by [mechanism or
process] for [scope/boundary]. [Owner/role] performs [operation/cadence] using
[tool/procedure] and retains evidence in [location/artifact] when known.
```

Adjust to fit the exact workbook field. If the source record only supports part
of the statement, include only the supported part and move assumptions into
notes.

## AP/CCI-Level Specificity

When the workbook provides assessment procedure acronyms, CCIs, CCI
definitions, implementation guidance, or assessment procedure text, draft the
implementation narrative for that exact row. Do not reuse a parent-control or
family-level narrative across all rows.

For each row, the generated narrative must answer:

- what specific CCI outcome is implemented
- which program component, process, role, or inherited provider implements it
- what is still unknown if the row cannot be fully supported

Evidence expectations for the row belong in Test Results, evidence columns, or
companion notes. Do not place screenshot requests, evidence-folder paths, or
assessment-result labels in a Control Implementation Narrative field unless the
template explicitly defines that narrative field as an assessment-result field.

Examples:

- `AC-02a` should define allowed and prohibited account types. It should not
  merely say the system uses Keycloak.
- `AC-02b` should identify account managers or the gap in account-manager
  assignment evidence.
- `AC-02d.02` should address group and role membership specification.
- `AC-03` should identify the enforcement mechanism for approved access, such
  as Keycloak claims, application authorization, OPA, Kubernetes RBAC, or
  inherited enforcement, as supported by evidence.

If all rows in a control have nearly identical text, treat that as a quality
failure unless the CCI definitions are genuinely identical. Use the parent
control narrative only as context; the row narrative must still be tailored to
the row's CCI definition and assessment procedure.

## Assessment Result Pattern

Use this pattern when generating assessor notes:

```text
Available evidence supports [satisfied/partially satisfied/not satisfied/not
assessable] for [control/control part] because [evidence summary]. Remaining
gaps are [gap list]. Recommended reviewer action is [action].
```

Do not use "satisfied" when only policy exists and implementation evidence is
missing, unless the assessment instruction explicitly accepts policy as the
required evidence for that field.

## Organization-Defined Parameters

For organization-defined parameters:

- use values from the workbook, SSP, policy, overlay, customer instruction, or
  program-provided guidance
- preserve the exact parameter value where provided
- mark missing values as gaps
- do not invent frequency, role, threshold, retention, severity, or timing
  values

## Assessment Methods

When evidence supports it, label the assessment method:

- **Examine**: documents, diagrams, policies, procedures, configurations,
  screenshots, scans, tickets, inventories, logs, or exports.
- **Interview**: stakeholder-provided explanation or meeting notes.
- **Test**: command output, validation run, scan result, technical check, or
  observed behavior.

If only interview-style evidence exists, do not present it as tested technical
evidence.

