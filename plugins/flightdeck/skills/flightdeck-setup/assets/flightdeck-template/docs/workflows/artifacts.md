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

