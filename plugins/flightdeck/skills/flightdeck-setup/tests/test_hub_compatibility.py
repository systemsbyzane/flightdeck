#!/usr/bin/env python3
"""Tests for read-only generated-Hub compatibility checks."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "hub_compatibility.py"
TEMPLATE = ROOT / "assets" / "flightdeck-template"


def tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(candidate for candidate in root.rglob("*") if candidate.is_file()):
        digest.update(str(path.relative_to(root)).encode("utf-8"))
        digest.update(path.read_bytes())
    return digest.hexdigest()


class HubCompatibilityTest(unittest.TestCase):
    def run_checker(
        self,
        hub: Path,
        *requirements: str,
        require_contract: bool = False,
        target_contract: Path | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
        arguments = [sys.executable, str(CHECKER), "--hub-root", str(hub)]
        if require_contract:
            arguments.append("--require-contract")
        if target_contract is not None:
            arguments.extend(["--target-contract", str(target_contract)])
        for requirement in requirements:
            arguments.extend(["--require", requirement])
        result = subprocess.run(
            arguments,
            text=True,
            capture_output=True,
            check=False,
            timeout=30,
        )
        return result, json.loads(result.stdout)

    def test_current_template_declares_and_satisfies_setup_and_review(self) -> None:
        result, report = self.run_checker(
            TEMPLATE,
            "flightdeck.command.setup-plan.v1",
            "flightdeck.command.setup-connect.v1",
            "flightdeck.document.change-review.v1",
            "flightdeck.command.mission-authoring.v1",
            "flightdeck.command.skill-telemetry.v1",
            "flightdeck.command.operation-authoring.v1",
            "flightdeck.command.operation-projection.v1",
            "flightdeck.command.hub-snapshot.v1",
            "flightdeck.command.operations-snapshot.v1",
            "flightdeck.command.work-control.v1",
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("compatible", report["status"])
        self.assertTrue(report["compatible"])
        self.assertEqual("1.6.0", report["hub"]["identity"]["template_version"])
        self.assertEqual([], report["requirements"]["missing"])

    def test_preserved_hub_without_mission_authoring_is_selectable_but_unsupported(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-compatibility-") as directory:
            hub = Path(directory) / "preserved-hub"
            shutil.copytree(TEMPLATE, hub)
            contract_path = hub / "hub" / "compatibility.json"
            contract = json.loads(contract_path.read_text(encoding="utf-8"))
            contract["template_version"] = "1.1.0"
            del contract["capabilities"]["flightdeck.command.mission-authoring.v1"]
            contract_path.write_text(json.dumps(contract, indent=2) + "\n", encoding="utf-8")
            before = tree_digest(hub)

            result, report = self.run_checker(
                hub,
                "flightdeck.command.mission-authoring.v1",
            )

            self.assertEqual(1, result.returncode, result.stderr)
            self.assertEqual("incompatible", report["status"])
            self.assertEqual("1.1.0", report["hub"]["identity"]["template_version"])
            missing = report["requirements"]["missing"]
            self.assertEqual(["flightdeck.command.mission-authoring.v1"], [item["id"] for item in missing])
            self.assertEqual("stop_and_plan_migration", missing[0]["fallback"]["mode"])
            self.assertIn("lib/flightdeck/mission_authoring.rb", report["migration"]["managed_paths_to_compare"])
            self.assertFalse(report["migration"]["automatic_changes"])
            self.assertEqual(before, tree_digest(hub))

    def test_legacy_hub_missing_setup_command_returns_migration_plan(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-compatibility-") as directory:
            hub = Path(directory) / "legacy-hub"
            (hub / "bin").mkdir(parents=True)
            entrypoint = hub / "bin" / "flightdeck"
            entrypoint.write_text(
                "#!/usr/bin/env python3\n"
                "print('bin/flightdeck doctor [--json]\\n"
                "bin/flightdeck status [--json]\\n"
                "bin/flightdeck route plan --workload NAME')\n",
                encoding="utf-8",
            )
            entrypoint.chmod(0o755)
            before = tree_digest(hub)

            result, report = self.run_checker(
                hub,
                "flightdeck.command.setup-plan.v1",
            )

            self.assertEqual(1, result.returncode, result.stderr)
            self.assertEqual("incompatible", report["status"])
            self.assertFalse(report["compatible"])
            self.assertEqual("absent", report["hub"]["identity"]["contract_state"])
            missing = report["requirements"]["missing"]
            self.assertEqual(["flightdeck.command.setup-plan.v1"], [item["id"] for item in missing])
            self.assertEqual("stop_and_plan_migration", missing[0]["fallback"]["mode"])
            self.assertIn("lib/flightdeck/setup_store.rb", report["migration"]["managed_paths_to_compare"])
            self.assertFalse(report["migration"]["automatic_changes"])
            self.assertEqual(before, tree_digest(hub))

    def test_legacy_hub_missing_change_review_uses_bundled_reference_fallback(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-compatibility-") as directory:
            hub = Path(directory) / "legacy-hub"
            shutil.copytree(TEMPLATE, hub)
            (hub / "hub" / "compatibility.json").unlink()
            (hub / "docs" / "review" / "change-review.md").unlink()
            before = tree_digest(hub)

            result, report = self.run_checker(
                hub,
                "flightdeck.document.change-review.v1",
            )

            self.assertEqual(1, result.returncode, result.stderr)
            missing = report["requirements"]["missing"]
            self.assertEqual("bundled_reference", missing[0]["fallback"]["mode"])
            self.assertEqual(
                "skills/flightdeck-review/references/review-method.md",
                missing[0]["fallback"]["reference"],
            )
            self.assertIn(
                "docs/review/change-review.md",
                report["migration"]["managed_paths_to_compare"],
            )
            self.assertEqual(before, tree_digest(hub))

    def test_legacy_hub_can_be_compatible_for_an_inferred_surface(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-compatibility-") as directory:
            hub = Path(directory) / "legacy-hub"
            shutil.copytree(TEMPLATE, hub)
            (hub / "hub" / "compatibility.json").unlink()

            result, report = self.run_checker(
                hub,
                "flightdeck.command.doctor.v1",
                "flightdeck.document.change-review.v1",
            )

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual("compatible_inferred", report["status"])
            self.assertIsNone(report["hub"]["identity"]["template_version"])
            self.assertFalse(report["migration"]["required"])

    def test_contract_can_be_required_for_managed_template_validation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-compatibility-") as directory:
            hub = Path(directory) / "legacy-hub"
            shutil.copytree(TEMPLATE, hub)
            (hub / "hub" / "compatibility.json").unlink()

            result, report = self.run_checker(
                hub,
                "flightdeck.command.doctor.v1",
                require_contract=True,
            )

            self.assertEqual(1, result.returncode, result.stderr)
            self.assertEqual("incompatible", report["status"])
            self.assertIn(
                "flightdeck.hub-contract.v1",
                [item["id"] for item in report["requirements"]["missing"]],
            )
            self.assertTrue(report["migration"]["required"])

    def test_target_contract_requires_a_precise_bundled_fallback(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-compatibility-") as directory:
            contract_path = Path(directory) / "compatibility.json"
            contract = json.loads(
                (TEMPLATE / "hub" / "compatibility.json").read_text(encoding="utf-8")
            )
            del contract["capabilities"]["flightdeck.document.change-review.v1"][
                "fallback"
            ]["reference"]
            contract_path.write_text(json.dumps(contract), encoding="utf-8")

            result, report = self.run_checker(
                TEMPLATE,
                "flightdeck.document.change-review.v1",
                target_contract=contract_path,
            )

            self.assertEqual(2, result.returncode, result.stderr)
            self.assertEqual("checker_error", report["status"])
            self.assertIn("fallback.reference", report["error"])


if __name__ == "__main__":
    unittest.main()
