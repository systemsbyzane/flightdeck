#!/usr/bin/env python3
"""Validate draft or export-ready Flightdeck STIG evaluation records."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


SCHEMA = "flightdeck.stig-evaluations/v1"
STATUSES = {
    "not a finding": "Not a Finding",
    "notafinding": "Not a Finding",
    "open": "Open",
    "not applicable": "Not Applicable",
    "notapplicable": "Not Applicable",
    "not reviewed": "Not Reviewed",
    "notreviewed": "Not Reviewed",
}
CONFIDENCE = {"HIGH", "MEDIUM", "LOW"}
APPLICABILITY = {"applicable", "not_applicable", "unknown"}
EVIDENCE_KINDS = {"direct", "inherited", "declared"}


def text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def normalize_status(value: Any) -> str | None:
    normalized = text(value).lower().replace("_", " ").replace("-", " ")
    return STATUSES.get(" ".join(normalized.split()))


def nonempty_details(value: Any) -> bool:
    if isinstance(value, str):
        return bool(value.strip())
    return isinstance(value, list) and any(text(item) for item in value)


def validate(document: Any, profile: str) -> dict[str, Any]:
    errors: list[dict[str, str]] = []
    warnings: list[dict[str, str]] = []

    def issue(
        code: str,
        path: str,
        message: str,
        *,
        export_required: bool = False,
        structural: bool = False,
    ) -> None:
        target = errors if structural or (export_required and profile == "export") else warnings
        target.append({"code": code, "path": path, "message": message})

    if not isinstance(document, dict):
        issue("document.type", "$", "evaluation bundle must be a JSON object", structural=True)
        evaluations: list[Any] = []
    else:
        if document.get("schema_version") != SCHEMA:
            issue(
                "schema.version",
                "$.schema_version",
                f"schema_version must be {SCHEMA}",
                structural=True,
            )
        benchmark = document.get("benchmark")
        if not isinstance(benchmark, dict):
            issue(
                "benchmark.type",
                "$.benchmark",
                "benchmark must be an object for export provenance",
                export_required=True,
            )
        else:
            for field in ("title", "release"):
                if not text(benchmark.get(field)):
                    issue(
                        f"benchmark.{field}",
                        f"$.benchmark.{field}",
                        f"benchmark {field} is required for export provenance",
                        export_required=True,
                    )
        target = document.get("target")
        if not isinstance(target, dict):
            issue(
                "target.type",
                "$.target",
                "target must be an object for export provenance",
                export_required=True,
            )
        else:
            for field in ("name", "kind", "revision"):
                if not text(target.get(field)):
                    issue(
                        f"target.{field}",
                        f"$.target.{field}",
                        f"target {field} is required for export provenance",
                        export_required=True,
                    )
        raw_evaluations = document.get("evaluations")
        if not isinstance(raw_evaluations, list):
            issue(
                "evaluations.type",
                "$.evaluations",
                "evaluations must be an array",
                structural=True,
            )
            evaluations = []
        else:
            evaluations = raw_evaluations

    seen: set[str] = set()
    normalized_statuses: dict[str, int] = {}
    for index, evaluation in enumerate(evaluations):
        prefix = f"$.evaluations[{index}]"
        if not isinstance(evaluation, dict):
            issue("evaluation.type", prefix, "evaluation must be an object", structural=True)
            continue
        vuln_id = text(evaluation.get("vuln_id"))
        if not vuln_id:
            issue(
                "evaluation.vuln_id",
                f"{prefix}.vuln_id",
                "vuln_id is required",
                structural=True,
            )
        elif vuln_id in seen:
            issue(
                "evaluation.duplicate",
                f"{prefix}.vuln_id",
                f"duplicate vulnerability ID: {vuln_id}",
                structural=True,
            )
        seen.add(vuln_id)

        status = normalize_status(evaluation.get("status"))
        if status is None:
            issue(
                "evaluation.status",
                f"{prefix}.status",
                "status must be Not a Finding, Open, Not Applicable, or Not Reviewed",
                structural=True,
            )
        else:
            normalized_statuses[status] = normalized_statuses.get(status, 0) + 1

        confidence = text(evaluation.get("confidence")).upper()
        if confidence and confidence not in CONFIDENCE:
            issue(
                "evaluation.confidence",
                f"{prefix}.confidence",
                "confidence must be HIGH, MEDIUM, or LOW",
                structural=True,
            )
        elif not confidence:
            issue(
                "evaluation.confidence",
                f"{prefix}.confidence",
                "confidence is required for export review",
                export_required=True,
            )

        applicability = evaluation.get("applicability")
        applicability_state = ""
        applicability_rationale = ""
        if not isinstance(applicability, dict):
            issue(
                "applicability.type",
                f"{prefix}.applicability",
                "applicability must be an object for export review",
                export_required=True,
            )
        else:
            applicability_state = text(applicability.get("state"))
            applicability_rationale = text(applicability.get("rationale"))
            if applicability_state not in APPLICABILITY:
                issue(
                    "applicability.state",
                    f"{prefix}.applicability.state",
                    "state must be applicable, not_applicable, or unknown",
                    export_required=True,
                )

        evidence = evaluation.get("evidence", [])
        qualifying_evidence = 0
        if not isinstance(evidence, list):
            issue(
                "evidence.type",
                f"{prefix}.evidence",
                "evidence must be an array",
                structural=True,
            )
            evidence = []
        for evidence_index, item in enumerate(evidence):
            evidence_prefix = f"{prefix}.evidence[{evidence_index}]"
            if not isinstance(item, dict):
                issue(
                    "evidence.item",
                    evidence_prefix,
                    "evidence item must be an object",
                    structural=True,
                )
                continue
            kind = text(item.get("kind"))
            if kind not in EVIDENCE_KINDS:
                issue(
                    "evidence.kind",
                    f"{evidence_prefix}.kind",
                    "kind must be direct, inherited, or declared",
                    structural=True,
                )
            if kind in {"direct", "inherited"}:
                qualifying_evidence += 1
            for field in ("source", "summary"):
                if not text(item.get(field)):
                    issue(
                        f"evidence.{field}",
                        f"{evidence_prefix}.{field}",
                        f"evidence {field} is required for export review",
                        export_required=True,
                    )
            if kind == "inherited":
                for field in ("boundary", "responsible_party"):
                    if not text(item.get(field)):
                        issue(
                            f"evidence.inherited.{field}",
                            f"{evidence_prefix}.{field}",
                            f"inherited evidence requires {field}",
                            export_required=True,
                        )

        if status in {"Not a Finding", "Open"} and applicability_state != "applicable":
            issue(
                "status.applicability",
                f"{prefix}.applicability.state",
                f"{status} requires applicable scope",
                export_required=True,
            )
        if status == "Not Applicable":
            if applicability_state != "not_applicable":
                issue(
                    "status.not_applicable",
                    f"{prefix}.applicability.state",
                    "Not Applicable requires not_applicable scope",
                    export_required=True,
                )
            if not applicability_rationale:
                issue(
                    "status.not_applicable_rationale",
                    f"{prefix}.applicability.rationale",
                    "Not Applicable requires a specific rationale",
                    export_required=True,
                )
        if status in {"Not a Finding", "Open", "Not Applicable"} and qualifying_evidence == 0:
            issue(
                "status.evidence",
                f"{prefix}.evidence",
                f"{status} requires direct or inherited evidence",
                export_required=True,
            )
        if status == "Not Reviewed" and not (
            text(evaluation.get("review_reason"))
            or nonempty_details(evaluation.get("finding_details"))
        ):
            issue(
                "status.review_reason",
                f"{prefix}.review_reason",
                "Not Reviewed requires a reason or finding detail",
                export_required=True,
            )
        if not nonempty_details(evaluation.get("finding_details")):
            issue(
                "evaluation.finding_details",
                f"{prefix}.finding_details",
                "finding details are required for export",
                export_required=True,
            )
        if not text(evaluation.get("comments")):
            issue(
                "evaluation.comments",
                f"{prefix}.comments",
                "CKL-ready comments are required for export",
                export_required=True,
            )
        if status == "Open" and not isinstance(evaluation.get("remediation_owner"), dict):
            warnings.append(
                {
                    "code": "remediation.owner",
                    "path": f"{prefix}.remediation_owner",
                    "message": "record a remediation owner or explicitly leave ownership unresolved",
                }
            )

    return {
        "schema_version": "flightdeck.stig-validation/v1",
        "profile": profile,
        "ok": not errors,
        "counts": {
            "evaluations": len(evaluations),
            "errors": len(errors),
            "warnings": len(warnings),
            "statuses": dict(sorted(normalized_statuses.items())),
        },
        "errors": errors,
        "warnings": warnings,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evaluation_bundle", type=Path)
    parser.add_argument("--profile", choices=("draft", "export"), default="draft")
    parser.add_argument("-o", "--output", type=Path)
    args = parser.parse_args()
    try:
        document = json.loads(args.evaluation_bundle.read_text(encoding="utf-8"))
        result = validate(document, args.profile)
    except (OSError, json.JSONDecodeError) as error:
        parser.error(str(error))
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
