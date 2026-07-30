# STIG Summary Extractor

Use this when the user asks for a STIG summary, CKL comments/details, copy/paste output, or `/stig-summary`.

## Goal

Extract the most recent STIG evaluation into conservative, CKL-ready text:

```text
<Status Summary paragraph>

**Status:** <Not a Finding|Open|Not Applicable|Not Reviewed>
**Confidence:** <HIGH|MEDIUM|LOW>

<Finding Details bullets>
```

## Rules

- Prefer too little over too much.
- Keep only verified evidence.
- The extractor rejects decided statuses unless applicability and at least one
  direct evidence item or properly attributed inherited evidence item supports
  them.
- Remove speculation such as "appears", "likely", "probably", "should", and "may".
- Do not add data that was not in the evaluation.
- Do not include raw command output unless the user asks for audit details.
- For CKL fields, use generic terms such as "the system", "the database", or "the application".
- Do not imply that successful CKL generation, an inherited-control label, or
  a completed checklist proves compliance.
- Keep AI/tool provenance, generator notes, confidence workflow, and
  review-process labels out of CKL comments and finding details. Preserve
  evidence limitations in the internal evaluation record.

## Container-Era Language

Useful phrasing:

| Legacy STIG issue | CKL-ready phrasing |
| --- | --- |
| No SSH daemon | Administrative access is provided through Kubernetes API access with RBAC controls. |
| No local users | Authentication is handled by the identity provider rather than local system accounts. |
| Immutable filesystem | Container images are immutable; updates are applied by rebuilding and redeploying images. |
| No package manager | Runtime package installation is not available; required packages are included at build time. |
| Service mesh encryption | Pod-to-pod traffic is encrypted by service mesh mTLS. |
| NetworkPolicy | Network isolation is enforced by Kubernetes NetworkPolicy. |

Only use these statements when verified.
