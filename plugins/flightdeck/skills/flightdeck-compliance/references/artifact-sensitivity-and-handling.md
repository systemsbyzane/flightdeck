# Artifact Sensitivity And Handling

Compliance workspaces may contain controlled, proprietary, privacy-sensitive,
security-sensitive, export-controlled, credential-bearing, or customer-sensitive
material. Handle them as local program records.

## Local Handling Rules

- Keep program artifacts inside the relevant `compliance/<program>/` folder.
- Do not copy artifacts into unrelated workloads or repos.
- Do not commit or expose secrets, tokens, credentials, kubeconfigs, private
  keys, access keys, or copied cluster secrets.
- Do not include sensitive raw evidence in prepared summaries when a reference
  is sufficient.
- Redact secrets from prepared outputs when they appear in source material.
- Preserve original files. Put polished files under `deliverables/`; put
  internal analysis under `working-records/`, `control-assessments/`, `poam/`,
  or `evidence-index/`.

## Sensitive Evidence

Treat these as sensitive by default:

- eMASS exports or screenshots
- POA&Ms
- SSPs and SARs
- network diagrams
- data flow diagrams
- vulnerability scans
- STIG checklists
- account, asset, interface, and software inventories
- incident, audit, log, and finding records
- customer-provided templates or package instructions

## Output Discipline

Prepared outputs should avoid unnecessary sensitive detail. Prefer references
such as:

```text
Evidence: source-documents/scan-summary.xlsx, Vulnerabilities sheet, rows 14-31.
```

Do not copy full credential values, private hostnames, personal data, or
classified markings into narrative summaries unless the user explicitly confirms
the handling context is appropriate.

The same rule applies to machine-readable `.json` and `.yaml` working records.
They should reference sensitive evidence by path and location instead of
duplicating the sensitive raw value, and they must stay outside delivery
packages unless explicitly requested.

## Public And Restricted Sources

Public RMF guidance can be cited normally. Restricted eMASS, RMF Knowledge
Service, CAC-only, customer, or program-specific guidance must be treated as
local source material and not generalized across programs unless the user
explicitly provides permission and scope.

## If A Secret Is Found

Stop using the secret value in prepared text. Record that sensitive material
was present, identify the file path if necessary for local remediation, and ask
the user how they want to handle rotation or cleanup.
