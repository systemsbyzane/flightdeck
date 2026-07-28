#!/usr/bin/env python3
"""Deterministic tests for the bundled STIG tools."""

from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
FIXTURES = ROOT / "tests" / "fixtures"


class StigToolsTest(unittest.TestCase):
    def run_tool(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", *arguments],
            cwd=ROOT,
            check=False,
            text=True,
            capture_output=True,
        )

    def test_ckl_round_trip_is_deterministic(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-stig-") as directory:
            target = Path(directory)
            first = target / "first.ckl"
            second = target / "second.ckl"
            parsed = target / "parsed.json"
            for output in (first, second):
                result = self.run_tool(
                    str(SCRIPTS / "ckl_generator.py"),
                    str(FIXTURES / "findings.json"),
                    str(FIXTURES / "template.ckl"),
                    str(output),
                )
                self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(
                hashlib.sha256(first.read_bytes()).hexdigest(),
                hashlib.sha256(second.read_bytes()).hexdigest(),
            )
            parsed_result = self.run_tool(
                str(SCRIPTS / "ckl_parser.py"), str(first), "-o", str(parsed)
            )
            self.assertEqual(0, parsed_result.returncode, parsed_result.stderr)
            value = json.loads(parsed.read_text(encoding="utf-8"))
            finding = value["stigs"][0]["vulnerabilities"][0]
            self.assertEqual("NotAFinding", finding["current_status"])
            self.assertIn("Synthetic fixture only", finding["finding_details"])
            self.assertEqual("Synthetic mitigation statement", finding["mitigations"])
            self.assertEqual("System owner", finding["responsibility"])

    def test_summary_extractor_removes_speculation_and_machine_paths(self) -> None:
        result = self.run_tool(
            str(SCRIPTS / "summary_extractor.py"),
            str(FIXTURES / "evaluation.json"),
            "--json",
        )
        self.assertEqual(0, result.returncode, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual("Not a Finding", value["status"])
        self.assertEqual(
            ["The rendered workload manifest sets the required security value."],
            value["finding_details"],
        )
        self.assertNotIn("may", value["status_summary"].lower())
        self.assertNotIn("/Users/", result.stdout)

    def test_generator_preserves_structured_details_without_confidence(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-stig-") as directory:
            target = Path(directory)
            findings = target / "structured.json"
            output = target / "structured.ckl"
            findings.write_text(
                json.dumps(
                    {
                        "findings": [
                            {
                                "vuln_id": "V-000001",
                                "status": "Open",
                                "finding_details": {
                                    "status": "Open",
                                    "confidence": "LOW",
                                    "evidence": ["Synthetic setting is absent."],
                                    "human_review_recommended": True,
                                },
                                "comments": "Synthetic summary.",
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            result = self.run_tool(
                str(SCRIPTS / "ckl_generator.py"),
                str(findings),
                str(FIXTURES / "template.ckl"),
                str(output),
                "--no-timestamp",
            )
            self.assertEqual(0, result.returncode, result.stderr)
            element = ET.parse(output).getroot().find(".//VULN/FINDING_DETAILS")
            self.assertIsNotNone(element)
            details = element.text or ""
            self.assertIn("**Evidence:**", details)
            self.assertIn("**Human Review Recommended:**", details)
            self.assertNotIn("confidence", details.lower())

    def test_generator_rejects_duplicate_template_vulnerability_ids(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-stig-") as directory:
            target = Path(directory)
            template = target / "duplicate.ckl"
            output = target / "output.ckl"
            tree = ET.parse(FIXTURES / "template.ckl")
            first = tree.getroot().find(".//VULN")
            container = tree.getroot().find(".//iSTIG")
            self.assertIsNotNone(first)
            self.assertIsNotNone(container)
            container.append(copy.deepcopy(first))
            tree.write(template, encoding="UTF-8", xml_declaration=True)

            result = self.run_tool(
                str(SCRIPTS / "ckl_generator.py"),
                str(FIXTURES / "findings.json"),
                str(template),
                str(output),
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("duplicate vulnerability ID in template", result.stderr)
            self.assertFalse(output.exists())

    def test_summary_extractor_rejects_unsupported_decided_status(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-stig-") as directory:
            target = Path(directory) / "unsupported.json"
            target.write_text(
                json.dumps(
                    {
                        "status": "Not a Finding",
                        "confidence": "HIGH",
                        "status_summary": "The system implements the control.",
                        "finding_details": ["The required value is configured."],
                        "applicability": {
                            "state": "applicable",
                            "rationale": "The rule applies.",
                        },
                        "evidence": [
                            {
                                "kind": "inherited",
                                "source": "synthetic platform statement",
                                "summary": "The platform supplies the control.",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            result = self.run_tool(
                str(SCRIPTS / "summary_extractor.py"),
                str(target),
                "--json",
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("direct or attributed inherited evidence", result.stderr)

    def test_evaluation_validator_accepts_export_ready_bundle(self) -> None:
        result = self.run_tool(
            str(SCRIPTS / "evaluation_validator.py"),
            str(FIXTURES / "evaluations.json"),
            "--profile",
            "export",
        )
        self.assertEqual(0, result.returncode, result.stderr)
        value = json.loads(result.stdout)
        self.assertTrue(value["ok"])
        self.assertEqual(2, value["counts"]["evaluations"])
        self.assertEqual(0, value["counts"]["errors"])

    def test_evaluation_validator_keeps_drafts_flexible_and_exports_strict(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-stig-") as directory:
            target = Path(directory) / "draft.json"
            target.write_text(
                json.dumps(
                    {
                        "schema_version": "flightdeck.stig-evaluations/v1",
                        "evaluations": [
                            {
                                "vuln_id": "V-000003",
                                "status": "Not Reviewed",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            draft = self.run_tool(
                str(SCRIPTS / "evaluation_validator.py"),
                str(target),
                "--profile",
                "draft",
            )
            export = self.run_tool(
                str(SCRIPTS / "evaluation_validator.py"),
                str(target),
                "--profile",
                "export",
            )
            self.assertEqual(0, draft.returncode, draft.stderr)
            self.assertGreater(json.loads(draft.stdout)["counts"]["warnings"], 0)
            self.assertEqual(1, export.returncode)
            self.assertGreater(json.loads(export.stdout)["counts"]["errors"], 0)

    def test_evaluation_validator_requires_inherited_control_ownership(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-stig-") as directory:
            target = Path(directory) / "inherited.json"
            value = json.loads(
                (FIXTURES / "evaluations.json").read_text(encoding="utf-8")
            )
            value["evaluations"][0]["evidence"] = [
                {
                    "kind": "inherited",
                    "source": "synthetic platform statement",
                    "summary": "The shared platform supplies the control.",
                }
            ]
            target.write_text(json.dumps(value), encoding="utf-8")
            result = self.run_tool(
                str(SCRIPTS / "evaluation_validator.py"),
                str(target),
                "--profile",
                "export",
            )
            self.assertEqual(1, result.returncode)
            codes = {item["code"] for item in json.loads(result.stdout)["errors"]}
            self.assertIn("evidence.inherited.boundary", codes)
            self.assertIn("evidence.inherited.responsible_party", codes)


if __name__ == "__main__":
    unittest.main()
