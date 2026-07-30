# DoD RMF ATO Operating Model

Use this guide to keep compliance work aligned to DoD RMF and ATO package
practice while working inside a local program workspace.

## Core Outcome

The objective is to support an authorizing official decision with a coherent
record of system scope, implemented controls, inherited controls, assessment
results, weaknesses, POA&M items, residual risk, and continuous monitoring
expectations.

An ATO package should answer:

- what system or capability is being authorized
- what information types, impact levels, mission functions, and environments
  are in scope
- which controls apply and who owns each part of implementation
- what evidence supports implementation and effectiveness claims
- what weaknesses remain and how they will be mitigated
- what risk the AO is being asked to accept
- how the system will be monitored after authorization

## Common Roles

- **AO**: makes the authorization decision and accepts residual risk.
- **SCA**: evaluates controls and provides independent assessment input.
- **ISSM / ISSO**: manages cybersecurity package quality, control responses,
  evidence, POA&M status, and continuous monitoring posture.
- **PM / system owner**: owns mission, scope, resources, delivery, and package
  completeness.
- **System administrator / engineer**: provides technical evidence, scans,
  configuration details, implementation specifics, and remediation input.
- **Common control provider**: owns inherited controls or shared services that
  the system consumes.
- **Mission owner**: owns operational use, mission impact, and mission-specific
  risk.

Do not blur these roles in prepared language. If a control is inherited,
hybrid, common, or system-specific, say so clearly and identify the evidence
that supports the responsibility split.

## RMF Flow

### Prepare

Establish mission context, stakeholders, authorization boundary, environment,
available inherited services, evidence sources, and package constraints.

### Categorize

Identify information types, confidentiality, integrity, availability impact,
mission criticality, deployment environment, and any overlays or program
specific requirements. If categorization is not present in the program record,
mark it as a gap.

### Select

Identify the control baseline, overlays, organization-defined parameters,
tailoring decisions, inheritance, and not-applicable rationale. Do not invent a
baseline when the program has not provided one.

### Implement

Convert architecture, policy, procedure, scan, STIG, configuration, and
operational evidence into implementation statements. Implementation language
should state what exists, where it is enforced, who owns it, and what evidence
supports it.

### Assess

Use assessment procedures and evidence to determine whether implementation
appears satisfied, partially satisfied, not satisfied, not applicable, or not
assessable from the available record. Assessment findings require traceable
evidence or clearly labeled inference.

### Authorize

Package the decision record: SSP/control workbook, SAR or assessment notes,
POA&M, risk summary, inherited control evidence, architecture context,
continuous monitoring plan, and supporting artifacts. Prepared material should
support the authorization decision without claiming to replace or predetermine
that decision.

### Monitor

Track continuous monitoring, recurring scans, POA&M closure, configuration
drift, control inheritance changes, reassessment triggers, incidents,
deployment changes, and annual review expectations.

## Common Package Artifacts

- System Security Plan or control implementation workbook
- control assessment notes or Security Assessment Report input
- POA&M
- risk and residual-risk summary
- architecture diagrams and data flow diagrams
- hardware, software, service, account, and interface inventories
- policy and procedure artifacts
- scan and STIG evidence
- inherited control and common control documentation
- continuous monitoring strategy and cadence

## Decision Discipline

When program evidence is weak, state the risk plainly. A polished package with
unsupported claims creates review risk and authorization risk. A strong package
can contain gaps if those gaps are visible, bounded, assigned, and tracked.
