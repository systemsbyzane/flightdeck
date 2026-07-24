#!/usr/bin/env python3
"""Parse a DISA STIG Viewer CKL checklist into deterministic JSON."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


ATTRIBUTE_MAP = {
    "Vuln_Num": "vuln_id",
    "Rule_ID": "rule_id",
    "STIG_ID": "stig_id",
    "Rule_Ver": "rule_ver",
    "Severity": "severity",
    "Rule_Title": "title",
    "Vuln_Discuss": "description",
    "Check_Content": "check_content",
    "Check_Content_Ref": "check_content_ref",
    "Fix_Text": "fix_text",
    "IA_Controls": "ia_controls",
    "Class": "class",
    "STIGRef": "stig_ref",
    "TargetKey": "target_key",
    "STIG_UUID": "stig_uuid",
    "LEGACY_ID": "legacy_id",
    "CCI_REF": "cci",
    "Weight": "weight",
    "False_Positives": "false_positives",
    "False_Negatives": "false_negatives",
    "Documentable": "documentable",
    "Mitigations": "mitigations",
    "Potential_Impact": "potential_impact",
    "Third_Party_Tools": "third_party_tools",
    "Mitigation_Control": "mitigation_control",
    "Responsibility": "responsibility",
    "Security_Override_Guidance": "security_override_guidance",
}

ASSET_FIELDS = (
    "ROLE",
    "ASSET_TYPE",
    "HOST_NAME",
    "HOST_IP",
    "HOST_MAC",
    "HOST_FQDN",
    "TARGET_COMMENT",
    "TECH_AREA",
    "TARGET_KEY",
    "WEB_OR_DATABASE",
    "WEB_DB_SITE",
    "WEB_DB_INSTANCE",
)


def text(element: ET.Element | None) -> str:
    return element.text if element is not None and element.text else ""


def parse_asset(element: ET.Element | None) -> dict[str, str]:
    if element is None:
        return {}
    return {name.lower(): text(element.find(name)) for name in ASSET_FIELDS}


def parse_stig_info(element: ET.Element | None) -> dict[str, str]:
    output: dict[str, str] = {}
    if element is None:
        return output
    for item in element.findall("SI_DATA"):
        name = text(item.find("SID_NAME")).lower().replace(" ", "_")
        if name:
            output[name] = text(item.find("SID_DATA"))
    return output


def parse_vulnerability(element: ET.Element) -> dict[str, Any]:
    output: dict[str, Any] = {
        "vuln_id": "",
        "rule_id": "",
        "stig_id": "",
        "rule_ver": "",
        "severity": "",
        "title": "",
        "description": "",
        "check_content": "",
        "check_content_ref": "",
        "fix_text": "",
        "ia_controls": "",
        "class": "",
        "stig_ref": "",
        "target_key": "",
        "stig_uuid": "",
        "legacy_id": "",
        "cci": [],
        "weight": "",
        "false_positives": "",
        "false_negatives": "",
        "documentable": "",
        "mitigations": "",
        "potential_impact": "",
        "third_party_tools": "",
        "mitigation_control": "",
        "responsibility": "",
        "security_override_guidance": "",
        "current_status": text(element.find("STATUS")),
        "finding_details": text(element.find("FINDING_DETAILS")),
        "comments": text(element.find("COMMENTS")),
    }
    for item in element.findall("STIG_DATA"):
        source_name = text(item.find("VULN_ATTRIBUTE"))
        target_name = ATTRIBUTE_MAP.get(source_name)
        if not target_name:
            continue
        value = text(item.find("ATTRIBUTE_DATA"))
        if target_name == "cci":
            if value:
                output["cci"].append(value)
        elif target_name == "severity":
            output[target_name] = value.lower()
        else:
            output[target_name] = value
    override = text(element.find("SEVERITY_OVERRIDE"))
    justification = text(element.find("SEVERITY_JUSTIFICATION"))
    if override:
        output["severity_override"] = override.lower()
    if justification:
        output["severity_justification"] = justification
    return output


def parse_ckl(path: Path) -> dict[str, Any]:
    tree = ET.parse(path)
    root = tree.getroot()
    if root.tag != "CHECKLIST":
        raise ValueError(f"expected CHECKLIST root element, found {root.tag}")

    stigs: list[dict[str, Any]] = []
    container = root.find("STIGS")
    if container is not None:
        for item in container.findall("iSTIG"):
            stigs.append(
                {
                    "stig_info": parse_stig_info(item.find("STIG_INFO")),
                    "vulnerabilities": [
                        parse_vulnerability(vulnerability)
                        for vulnerability in item.findall("VULN")
                    ],
                }
            )

    return {
        "schema_version": "flightdeck.ckl/v1",
        "source_file": path.name,
        "asset": parse_asset(root.find("ASSET")),
        "stigs": stigs,
    }


def atomic_json(path: Path, value: dict[str, Any], compact: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".ckl-", suffix=".json", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, sort_keys=True, indent=None if compact else 2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output path (default: .stigs/<input-basename>.json)",
    )
    parser.add_argument("--pretty", action="store_true", help="Accepted compatibility alias")
    parser.add_argument("--compact", action="store_true")
    args = parser.parse_args()

    if not args.input.is_file():
        parser.error(f"input file does not exist: {args.input}")
    try:
        result = parse_ckl(args.input)
    except (ET.ParseError, ValueError) as error:
        parser.error(str(error))
    output = args.output or Path(".stigs") / f"{args.input.stem}.json"
    atomic_json(output, result, args.compact)
    count = sum(len(item["vulnerabilities"]) for item in result["stigs"])
    print(f"Parsed {len(result['stigs'])} STIG(s) and {count} vulnerability record(s).")
    print(f"Output written to: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
