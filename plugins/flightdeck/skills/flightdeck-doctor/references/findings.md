# Doctor findings

| Code family | Meaning |
| --- | --- |
| `workflow.*`, `provider.*`, `registry.*` | Configuration or local registry is missing or invalid |
| `repo.*` | Checkout, Git, instructions, dirty, upstream, ahead, or behind issue |
| `bridge.*` | Bridge record, digest, mode, reference, or override protection drift |
| `task.*` | Task record or lifecycle validation failure |
| `compliance.*` | Required JSON/YAML sidecar orphan, parse failure, duplicate peer, or true semantic mismatch |
| `handoff.*` | Generated handoff contains unresolved placeholders or unreadable text |
| `automation.*` | Template is active or violates explicit-enable policy |

Doctor never fetches. Ahead and behind values reflect the current local remote
tracking refs and may be stale.

Doctor treats CycloneDX JSON documents as standardized standalone SBOMs. Safe
YAML aliases are resolved for sidecar comparison, and a parse failure is not
reported again as a derivative mismatch.

Prioritize errors, then security or evidence-integrity warnings, then ordinary
dirty/ahead/behind drift. Do not mutate the workspace in a Doctor run.
