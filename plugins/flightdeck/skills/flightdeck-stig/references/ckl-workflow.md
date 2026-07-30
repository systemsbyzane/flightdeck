# CKL And Batch Workflows

Use this reference when the user provides CKL files, asks for STIG Viewer import/export, wants batch evaluation, or asks about the legacy external batch loops.

## Bundled CKL Scripts

Parse CKL to JSON:

```bash
python3 scripts/ckl_parser.py input.ckl -o .stigs/input.json
```

Generate an evaluated CKL from findings JSON and a template CKL:

```bash
python3 scripts/ckl_generator.py findings.json template.ckl output.ckl
```

Expected findings format:

```json
{
  "findings": [
    {
      "vuln_id": "V-242376",
      "status": "Not a Finding",
      "finding_details": ["Evidence bullet"],
      "comments": "Status summary paragraph"
    }
  ]
}
```

The parser preserves asset and STIG metadata, the reusable vulnerability
attribute set, current status, details, comments, and severity overrides. It
omits observation timestamps and records only the input basename so identical
input produces identical JSON across machines.

The generator normalizes common status variants into CKL values and accepts
string, list, or structured finding details. It refuses duplicate IDs, unknown
statuses, and findings that do not exist in the template. Output has no
timestamp by default; use `--timestamp <text>` only when the caller explicitly
needs a stable supplied checklist-update timestamp. CKL comments and finding
details must not expose AI/tool provenance, generation notes, internal
confidence workflow, or review-process labels. `--dry-run`, `--no-timestamp`,
and verbose mode remain available for workflow compatibility.

## Batch Evaluation

For Codex-native batch work:

1. Parse the CKL with `scripts/ckl_parser.py`.
2. Record benchmark, target, applicability, and evidence provenance using
   `references/evidence-contract.md`.
3. Evaluate one vulnerability at a time using `references/evaluator.md`.
4. Persist after each finding to `.stigs/<basename>_evaluations.json`.
5. Track progress in `.stigs/<basename>_progress.json`.
6. Validate iteratively with
   `scripts/evaluation_validator.py <file> --profile draft`.
7. Before final generation, validate with `--profile export`, review every
   warning, and transform approved evaluations into the generator's
   `findings` array.
8. Generate the evaluated CKL with `scripts/ckl_generator.py`.

Keep batches small enough that evidence can be reviewed before continuing.
Do not treat a successfully generated CKL as proof that its conclusions are
supported. Generation validates mechanics; export validation checks evidence
readiness; submission and authorization remain separate approved actions.
