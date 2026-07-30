---
name: flightdeck-artifacts
description: Route DOCX, PDF, and XLSX creation or editing through installed system artifact capabilities with mandatory visual quality gates. Use for Word documents, PDFs, spreadsheets, control workbooks, or artifact package validation in a Flightdeck.
---

# Flightdeck Artifacts

This skill coordinates artifact work; it does not bundle artifact
implementations. Require the current installed system capability for the target:

- DOCX or Word: `documents`
- PDF: `pdf`
- XLSX or spreadsheet: `Spreadsheets`

Call the Codex workspace dependency loader (`load_workspace_dependencies`) and
run the preflight required by the selected capability. If a required capability
or bundled runtime is unavailable, report the blocker; do not substitute an
unapproved library or copy another skill's implementation.

For DOCX, render every page to PNG, inspect at full size, fix defects, and
repeat after each meaningful change. For PDF, render every page to images,
inspect layout and legibility, and iterate. For XLSX, inspect formulas and key
ranges, scan formula errors, render every sheet, visually inspect, repair, and
export only after the latest pass.

Read `references/artifact-gates.md`. Keep Markdown or policy sources
authoritative when a human-readable Word or PDF guide is generated from them.
Preserve originals. Separate internal QA records from polished deliverables,
return only the requested final files, and run the bundled deliverable validator
before delivery.
