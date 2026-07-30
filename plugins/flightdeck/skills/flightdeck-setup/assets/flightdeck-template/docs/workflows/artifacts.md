# Artifact workflows

Route DOCX, PDF, and XLSX work through the installed system artifact
capabilities. The Hub coordinates source, output, evidence, and approval
boundaries; it does not replace the artifact implementations.

- DOCX: render every page to PNG, inspect, fix, and repeat.
- PDF: render every page, inspect layout and legibility, fix, and repeat.
- XLSX: inspect key ranges and formulas, scan errors, render every sheet,
  inspect, fix, and export.

Keep Markdown or policy sources authoritative when Word or PDF guides are
rendered outputs. Preserve originals and keep QA intermediates local.

Final documents must read as professional human-authored deliverables. Do not
expose AI, Codex, prompts, tools, generation steps, review workflow, render
notes, internal QA records, or unresolved template variables in content,
metadata, filenames, manifests, or archive entries. Use professional gap
language when a value is not established; never invent it.

Keep polished files in the delivery directory and QA intermediates elsewhere.
Run `make validate-deliverables` after the final render. For a constrained
package, run `python3 scripts/validate-deliverable.py <package> --json` with one
`--allow-extension .ext` per permitted type and `--require-flat-archive` when
the package must be flat. Build archives from an explicit file-type allowlist
and include only the files the user requested.
