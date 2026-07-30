# Artifact capability and quality gates

Before authoring, call `load_workspace_dependencies` and use the runtime paths
returned for the current workspace. Do not assume system Python or Node
packages are equivalent to the bundled artifact runtime.

## DOCX

Require the installed `documents` capability and its bundled workspace runtime.
Preserve existing structure for edits. For creation or meaningful edits,
render to page PNGs, inspect every page at full size, repair layout defects, and
repeat after every meaningful change.

## PDF

Require the installed `pdf` capability. Use text extraction only for content
inspection, never as layout proof. Render every page to images, inspect
typography, spacing, tables, charts, headers, footers, and glyphs, then iterate.

## XLSX

Require the installed `Spreadsheets` capability and its artifact authoring
runtime. Preserve formulas, validation, hidden sheets, and existing formatting
when editing. Inspect key ranges and formulas, scan errors, render every sheet,
inspect the images, repair clipping or readability defects, and export once.

## Deliverable presentation

Treat every final document, workbook, checklist, manifest, and package as a
professional human-authored deliverable. Do not expose the authoring process in
titles, headings, body text, headers, footers, comments, custom properties,
filenames, package manifests, or archive entries. In particular, do not add:

- AI, model, ChatGPT, or Codex authorship or provenance;
- `generated_by`, `draft_for_human_review`, “ready for human review,” or similar
  workflow labels;
- render, inspection, prompt, tooling, or generation notes;
- unresolved template expressions, bracketed variables, replacement markers,
  `TBD`, `TODO`, or placeholder prose.

Resolve each template variable from evidence. When a value is not established,
leave the field blank if the format permits or use professional gap language
such as “Not established in the available record.” Never invent the value.

Keep source templates, working notes, structured QA records, renderings, change
summaries, and validation reports outside the delivery directory. Build
archives from an explicit file-type allowlist and include only the files the
user requested. Preserve source-mandated metadata only when the governing
format requires it; do not add tool provenance.

After the final render, run:

```bash
python3 scripts/validate_deliverable.py <deliverable-or-package> --json
```

For a constrained package, repeat `--allow-extension .ext` for each permitted
type. Use `--require-flat-archive` when entries must be at the archive root.
Treat any finding or unavailable content inspection as a delivery blocker.

Do not copy the system capabilities into this plugin. If a dependency is
missing, provide the exact capability/preflight blocker.
