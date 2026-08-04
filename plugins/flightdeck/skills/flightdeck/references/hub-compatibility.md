# Preserved-Hub compatibility gate

Locate the generated Hub without modifying it. Before requiring a Hub-local
command or document, run the installed setup skill's checker with only the
capability IDs needed for the operation:

```text
python3 <flightdeck-setup-skill>/scripts/hub_compatibility.py \
  --hub-root <absolute-hub-root> \
  --require <capability-id>
```

The checker is read-only. Accept `compatible` or `compatible_inferred` for the
requested surface. An inferred result means that an older Hub passed the
requested probes; it does not assign a generated-template version or prove
full template parity.

For `incompatible`, do not invoke missing commands or read assumed documents.
Use only the fallback returned for each missing capability. A bundled-reference
fallback may replace a missing Hub-local method document, but it does not
replace a missing ownership or authorization check. A manual exact-path handoff
is allowed only after normal route or project registration cannot be verified.

Return the structured compatibility result and its managed-path migration
scope. Migration is a separate plan-and-diff workflow: preserve the existing
Hub, obtain migration-planning authorization, generate a target candidate only
at a separate empty path, diff the reported managed paths, and obtain separate
apply authorization. Never run setup or bootstrap against the preserved Hub,
regenerate it, overwrite it, or treat plugin upgrade as migration approval.
