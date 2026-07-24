#!/usr/bin/env python3
"""Extract conservative CKL-ready text from a structured STIG evaluation."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


STATUSES = {"Not a Finding", "Open", "Not Applicable", "Not Reviewed"}
CONFIDENCE = {"HIGH", "MEDIUM", "LOW"}
SPECULATION = re.compile(r"\b(?:appears?|likely|probably|presumably|should|may|might|seems?)\b", re.IGNORECASE)
MACHINE_DETAIL = re.compile(
    r"(?:^|[\s`\"'(])/(?:Users|home|private|Volumes|var|opt|tmp)/|"
    r"\b(?:pod|container|node)[/_-][A-Za-z0-9_.-]+\b|"
    r"\bV-[0-9]{3,}\b",
    re.IGNORECASE,
)


def strings(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []
    if isinstance(value, list):
        output: list[str] = []
        for item in value:
            output.extend(strings(item))
        return output
    raise ValueError("finding details must be a string or list of strings")


def conservative_lines(value: Any) -> list[str]:
    output: list[str] = []
    for line in strings(value):
        for sentence in re.split(r"(?<=[.!?])\s+", line):
            sentence = sentence.strip()
            if not sentence or SPECULATION.search(sentence) or MACHINE_DETAIL.search(sentence):
                continue
            output.append(sentence)
    return output


def extract(value: dict[str, Any]) -> dict[str, Any]:
    status = value.get("status")
    if status not in STATUSES:
        raise ValueError(f"status must be one of: {', '.join(sorted(STATUSES))}")
    confidence = str(value.get("confidence", "")).upper()
    if confidence not in CONFIDENCE:
        raise ValueError("confidence must be HIGH, MEDIUM, or LOW")

    summary_source = value.get("status_summary", value.get("comments"))
    summaries = conservative_lines(summary_source)
    details = conservative_lines(value.get("finding_details"))
    if not summaries:
        raise ValueError("evaluation has no conservative CKL-ready status summary")
    if not details:
        raise ValueError("evaluation has no conservative CKL-ready finding details")

    return {
        "schema_version": "flightdeck.stig-summary/v1",
        "status_summary": " ".join(summaries),
        "status": status,
        "confidence": confidence,
        "finding_details": details,
        "human_review_recommended": confidence == "LOW",
    }


def render(value: dict[str, Any]) -> str:
    lines = [
        value["status_summary"],
        "",
        f"**Status:** {value['status']}",
        f"**Confidence:** {value['confidence']}",
        "",
        *[f"- {item}" for item in value["finding_details"]],
    ]
    if value["human_review_recommended"]:
        lines.extend(["", "**Human Review Recommended**"])
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evaluation", type=Path)
    parser.add_argument("-o", "--output", type=Path)
    parser.add_argument("--json", action="store_true", help="Emit normalized JSON")
    args = parser.parse_args()

    try:
        raw = json.loads(args.evaluation.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise ValueError("evaluation must be a JSON object")
        normalized = extract(raw)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        parser.error(str(error))

    content = (
        json.dumps(normalized, indent=2, sort_keys=True) + "\n"
        if args.json
        else render(normalized)
    )
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(content, encoding="utf-8")
    else:
        print(content, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
