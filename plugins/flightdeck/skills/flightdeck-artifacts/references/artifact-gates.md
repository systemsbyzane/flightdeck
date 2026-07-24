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

Do not copy the system capabilities into this plugin. If a dependency is
missing, provide the exact capability/preflight blocker.
