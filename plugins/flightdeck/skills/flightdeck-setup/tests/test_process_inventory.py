from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "process_inventory.py"
SPEC = importlib.util.spec_from_file_location("process_inventory", SCRIPT)
assert SPEC and SPEC.loader
PROCESS_INVENTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROCESS_INVENTORY)


class ProcessInventoryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.source = root / "source"
        self.plugin = root / "plugin"
        self.candidate = (
            self.plugin
            / "skills"
            / "flightdeck-setup"
            / "assets"
            / "flightdeck-template"
        )
        self.source.mkdir()
        self.candidate.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        self.write(self.source / "docs/known.md")
        self.write(self.source / "hub/reporting/guide.md")
        self.write(self.source / "hub/reports/generated.json")
        self.write(self.candidate / "docs/known.md")
        self.write(self.candidate / "hub/reporting/guide.md")
        self.write_manifest(self.manifest())

    @staticmethod
    def write(path: Path, content: str = "synthetic\n") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def manifest(self) -> dict[str, object]:
        return {
            "schema_version": "process-parity/v1",
            "capabilities": [
                {
                    "id": "known-guide",
                    "status": "generalized",
                    "source_count": 1,
                    "source_paths": ["docs/known.md"],
                    "candidate_paths": ["docs/known.md"],
                },
                {
                    "id": "reporting-guide",
                    "status": "matched",
                    "source_count": 1,
                    "source_paths": ["hub/reporting/guide.md"],
                    "candidate_paths": ["hub/reporting/guide.md"],
                },
                {
                    "id": "plugin-contract",
                    "status": "added",
                    "source_count": 0,
                    "source_paths": [],
                    "candidate_paths": [],
                    "plugin_count": 1,
                    "plugin_paths": ["process-parity.json"],
                },
            ],
            "exclusions": [
                {
                    "id": "generated-report",
                    "status": "intentionally_excluded",
                    "source_count": 1,
                    "source_paths": ["hub/reports/**"],
                    "candidate_paths": [],
                    "reason": "Generated output is not reusable process authority.",
                }
            ],
            "plugin_exclusions": [],
        }

    def write_manifest(self, manifest: dict[str, object]) -> None:
        self.write(
            self.plugin / "process-parity.json",
            json.dumps(manifest, indent=2) + "\n",
        )

    def report(self) -> dict[str, object]:
        return PROCESS_INVENTORY.build_report(
            source=self.source,
            candidate=self.candidate,
            plugin=self.plugin,
        )

    def test_precise_exclusion_does_not_hide_neighbor(self) -> None:
        report = self.report()
        self.assertTrue(report["ok"])
        self.assertEqual(
            report["counts"],
            {
                "source": 3,
                "candidate": 2,
                "plugin": 3,
                "mapped": 2,
                "excluded": 1,
                "unresolved": 0,
            },
        )
        classifications = {
            item["path"]: item["status"] for item in report["source"]["classification"]
        }
        self.assertEqual(classifications["hub/reporting/guide.md"], "matched")
        self.assertEqual(
            classifications["hub/reports/generated.json"],
            "intentionally_excluded",
        )

    def test_unknown_source_file_fails_closed(self) -> None:
        self.write(self.source / "docs/unknown.md")
        report = self.report()
        self.assertFalse(report["ok"])
        self.assertIn("unresolved_source", report["failures"])
        self.assertEqual(report["source"]["unresolved"], ["docs/unknown.md"])

    def test_unknown_candidate_file_fails_closed(self) -> None:
        self.write(self.candidate / "docs/unknown.md")
        report = self.report()
        self.assertFalse(report["ok"])
        self.assertIn("unclassified_candidate", report["failures"])
        self.assertEqual(report["candidate"]["unclassified"], ["docs/unknown.md"])
        self.assertIn(
            "skills/flightdeck-setup/assets/flightdeck-template/docs/unknown.md",
            report["plugin"]["unclassified"],
        )

    def test_unknown_plugin_file_fails_closed(self) -> None:
        self.write(self.plugin / "skills/unknown/SKILL.md")
        report = self.report()
        self.assertFalse(report["ok"])
        self.assertIn("unclassified_plugin", report["failures"])
        self.assertEqual(
            report["plugin"]["unclassified"],
            ["skills/unknown/SKILL.md"],
        )

    def test_missing_candidate_path_fails_closed(self) -> None:
        (self.candidate / "docs/known.md").unlink()
        report = self.report()
        self.assertFalse(report["ok"])
        self.assertIn("missing_candidate_path", report["failures"])

    def test_duplicate_mapping_id_is_invalid(self) -> None:
        manifest = self.manifest()
        manifest["capabilities"][1]["id"] = "known-guide"
        self.write_manifest(manifest)
        with self.assertRaisesRegex(PROCESS_INVENTORY.InventoryError, "duplicate"):
            PROCESS_INVENTORY.load_manifest(self.plugin / "process-parity.json")

    def test_unknown_status_is_invalid(self) -> None:
        manifest = self.manifest()
        manifest["capabilities"][0]["status"] = "close-enough"
        self.write_manifest(manifest)
        with self.assertRaisesRegex(PROCESS_INVENTORY.InventoryError, "status"):
            PROCESS_INVENTORY.load_manifest(self.plugin / "process-parity.json")


if __name__ == "__main__":
    unittest.main()
