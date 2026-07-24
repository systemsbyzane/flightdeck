# Machine-readable sidecars

Use the same basename for equivalent files, for example:

```text
control-assessments/access-control.json
control-assessments/access-control.yaml
```

Flightdeck-native JSON and YAML sidecars must decode to the same data model.
Doctor accepts safe YAML aliases while comparing the decoded values. It reports
invalid syntax once, without adding a derivative mismatch for a file it could
not parse, and still reports duplicate `.yaml`/`.yml` peers and true semantic
mismatches.

Standardized JSON-only payloads do not need synthetic YAML peers. CycloneDX
documents identified by `bomFormat: CycloneDX` are treated as standalone SBOMs.
Other JSON or YAML artifacts in sidecar directories still produce an orphan
warning when their peer is absent. Keep binary and rendered artifacts separate
from their machine-readable source.
