#!/usr/bin/env python3
"""Merge findings into a CKL template with deterministic output."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


STATUS_MAP = {
    "not a finding": "NotAFinding",
    "notafinding": "NotAFinding",
    "pass": "NotAFinding",
    "passed": "NotAFinding",
    "compliant": "NotAFinding",
    "open": "Open",
    "fail": "Open",
    "failed": "Open",
    "non compliant": "Open",
    "noncompliant": "Open",
    "not applicable": "Not_Applicable",
    "notapplicable": "Not_Applicable",
    "n a": "Not_Applicable",
    "na": "Not_Applicable",
    "not reviewed": "Not_Reviewed",
    "notreviewed": "Not_Reviewed",
    "unknown": "Not_Reviewed",
    "pending": "Not_Reviewed",
}


def normalize_status(value: Any) -> str:
    normalized = str(value or "").strip().lower().replace("_", " ").replace("-", " ")
    normalized = " ".join(normalized.replace("/", " ").split())
    result = STATUS_MAP.get(normalized)
    if not result:
        raise ValueError(f"unsupported finding status: {value!r}")
    return result


def format_value(value: Any, bullets: bool = False) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        lines = [format_value(item) for item in value]
        return "\n".join(f"- {line}" if bullets and line and not line.startswith("-") else line for line in lines)
    if isinstance(value, dict):
        return "\n".join(f"{key}: {format_value(item)}" for key, item in sorted(value.items()))
    return str(value)


def format_finding_details(value: Any) -> str:
    """Render strings, lists, and structured evaluation details for CKL."""
    if not isinstance(value, dict):
        return format_value(value, bullets=isinstance(value, list))

    lines: list[str] = []
    processed = {"confidence"}
    if "status" in value:
        lines.append(f"**Status:** {value['status']}")
        processed.add("status")
    if "evidence" in value:
        lines.append("")
        lines.append("**Evidence:**")
        evidence = value["evidence"]
        if isinstance(evidence, dict):
            for key, item in sorted(evidence.items()):
                rendered = "Verified" if isinstance(item, dict) else format_value(item)
                lines.append(f"- {key}: {rendered}")
        else:
            for item in evidence if isinstance(evidence, list) else [evidence]:
                lines.append(f"- {format_value(item)}")
        processed.add("evidence")
    if "verification" in value:
        lines.extend(["", f"**Verification:** {format_value(value['verification'])}"])
        processed.add("verification")
    if value.get("human_review_recommended") or value.get("needs_human_review"):
        note = value.get("review_notes", "See evidence and analysis above.")
        lines.extend(["", f"**Human Review Recommended:** {format_value(note)}"])
        processed.update(
            {"human_review_recommended", "needs_human_review", "review_notes"}
        )
    for key, item in sorted(value.items()):
        if key in processed:
            continue
        lines.extend(["", f"**{key.replace('_', ' ').title()}:** {format_value(item)}"])
    return "\n".join(lines).strip()


def load_findings(path: Path) -> dict[str, dict[str, Any]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    findings = data.get("findings")
    if not isinstance(findings, list):
        raise ValueError("findings JSON must contain a findings array")
    output: dict[str, dict[str, Any]] = {}
    for finding in findings:
        if not isinstance(finding, dict) or not finding.get("vuln_id"):
            raise ValueError("each finding must contain vuln_id")
        vuln_id = str(finding["vuln_id"])
        if vuln_id in output:
            raise ValueError(f"duplicate finding ID: {vuln_id}")
        normalize_status(finding.get("status"))
        output[vuln_id] = finding
    return output


def vulnerability_id(element: ET.Element) -> str | None:
    for item in element.findall("STIG_DATA"):
        if (item.findtext("VULN_ATTRIBUTE") or "") == "Vuln_Num":
            return item.findtext("ATTRIBUTE_DATA")
    return None


def update_element(element: ET.Element, finding: dict[str, Any], timestamp: str | None) -> None:
    values = {
        "STATUS": normalize_status(finding.get("status")),
        "FINDING_DETAILS": format_finding_details(finding.get("finding_details")),
        "COMMENTS": format_value(finding.get("comments")),
    }
    if timestamp:
        suffix = f"CKL generated: {timestamp}"
        values["COMMENTS"] = f"{values['COMMENTS']}\n\n{suffix}".strip()
    for name, value in values.items():
        child = element.find(name)
        if child is None:
            child = ET.SubElement(element, name)
        child.text = value


def atomic_xml(tree: ET.ElementTree, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".ckl-", suffix=".xml", dir=path.parent)
    os.close(descriptor)
    try:
        tree.write(temporary, encoding="UTF-8", xml_declaration=True)
        with open(temporary, "rb+") as handle:
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("findings_json", type=Path)
    parser.add_argument("template_ckl", type=Path)
    parser.add_argument("output_ckl", type=Path)
    parser.add_argument("--timestamp", help="Explicit timestamp text to append to comments")
    parser.add_argument(
        "--no-timestamp",
        action="store_true",
        help="Accepted compatibility alias; deterministic output is already the default",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    try:
        findings = load_findings(args.findings_json)
        tree = ET.parse(args.template_ckl)
        if tree.getroot().tag != "CHECKLIST":
            raise ValueError("template root must be CHECKLIST")
        updated: set[str] = set()
        template_ids: set[str] = set()
        for element in tree.getroot().iter("VULN"):
            vuln_id = vulnerability_id(element)
            if vuln_id and vuln_id in template_ids:
                raise ValueError(
                    f"duplicate vulnerability ID in template: {vuln_id}"
                )
            if vuln_id:
                template_ids.add(vuln_id)
            if vuln_id in findings:
                update_element(element, findings[vuln_id], args.timestamp)
                updated.add(vuln_id)
                if args.verbose:
                    print(f"Updated: {vuln_id} -> {findings[vuln_id].get('status')}")
        missing = sorted(set(findings) - updated)
        if missing:
            raise ValueError(f"findings did not match template IDs: {', '.join(missing)}")
    except (OSError, ET.ParseError, json.JSONDecodeError, ValueError) as error:
        parser.error(str(error))

    if not args.dry_run:
        atomic_xml(tree, args.output_ckl)
        print(f"Output written to: {args.output_ckl}")
    elif args.verbose:
        print("Dry run - no output file written")
    print(f"Updated {len(updated)} vulnerability record(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
