from __future__ import annotations

import importlib.util
import json
import re
import tempfile
import unittest
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ROOT = SKILL_ROOT.parents[1]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


patch_notes = load_module(
    "flightdeck_patch_notes", SKILL_ROOT / "scripts" / "patch_notes.py"
)
upgrade_planner = load_module(
    "flightdeck_upgrade_planner", SKILL_ROOT / "scripts" / "upgrade_planner.py"
)


class PatchNotesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.releases = [
            {
                "version": "1.0.0+codex.1",
                "date": "2026-01-01",
                "summary": "Baseline.",
                "changes": [{"category": "added", "text": "Baseline capability."}],
                "breaking_changes": [],
                "migration": [],
            },
            {
                "version": "1.0.0+codex.2",
                "date": "2026-01-02",
                "summary": "Second release.",
                "changes": [{"category": "fixed", "text": "Resolved an issue."}],
                "breaking_changes": [],
                "migration": ["Start a fresh task."],
            },
            {
                "version": "1.0.0+codex.3",
                "date": "2026-01-03",
                "summary": "Third release.",
                "changes": [{"category": "changed", "text": "Improved behavior."}],
                "breaking_changes": [],
                "migration": [],
            },
        ]

    def test_known_range_is_complete_and_excludes_installed_release(self) -> None:
        notes = patch_notes.select_range(
            self.releases, "1.0.0+codex.1", "1.0.0+codex.3"
        )
        self.assertTrue(notes["complete_range"])
        self.assertEqual(
            [release["version"] for release in notes["releases"]],
            ["1.0.0+codex.2", "1.0.0+codex.3"],
        )

    def test_unknown_installed_version_never_invents_intermediate_changes(self) -> None:
        notes = patch_notes.select_range(
            self.releases, "0.9.0+codex.9", "1.0.0+codex.3"
        )
        self.assertFalse(notes["complete_range"])
        self.assertEqual(notes["status"], "unknown_from_version")
        self.assertEqual(len(notes["releases"]), 1)
        self.assertIn("intermediate changes are unknown", patch_notes.render_markdown(notes))

    def test_equal_versions_report_current(self) -> None:
        notes = patch_notes.select_range(
            self.releases, "1.0.0+codex.3", "1.0.0+codex.3"
        )
        self.assertEqual(notes["status"], "current")
        self.assertEqual(notes["releases"], [])

    def test_repository_ledger_latest_matches_manifest(self) -> None:
        releases = patch_notes.load_ledger(PLUGIN_ROOT / "releases.json")
        manifest = json.loads(
            (PLUGIN_ROOT / ".codex-plugin" / "plugin.json").read_text(encoding="utf-8")
        )
        self.assertEqual(releases[-1]["version"], manifest["version"])

    def test_latest_cachebuster_is_strict_and_later_than_prerequisite(self) -> None:
        releases = patch_notes.load_ledger(PLUGIN_ROOT / "releases.json")
        pattern = re.compile(r"^0\.1\.0\+codex\.(\d{14})$")
        prior = pattern.fullmatch(releases[-2]["version"])
        latest = pattern.fullmatch(releases[-1]["version"])
        self.assertIsNotNone(prior)
        self.assertIsNotNone(latest)
        assert prior and latest
        self.assertGreater(int(latest.group(1)), int(prior.group(1)))

    def test_manifest_uses_runtime_supported_default_prompt_limit(self) -> None:
        manifest = json.loads(
            (PLUGIN_ROOT / ".codex-plugin" / "plugin.json").read_text(encoding="utf-8")
        )
        prompts = manifest["interface"]["defaultPrompt"]
        self.assertGreater(len(prompts), 0)
        self.assertLessEqual(len(prompts), 3)

    def test_mission_template_capabilities_fail_closed(self) -> None:
        compatibility = json.loads(
            (
                PLUGIN_ROOT
                / "skills"
                / "flightdeck-setup"
                / "assets"
                / "flightdeck-template"
                / "hub"
                / "compatibility.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual(compatibility["template_version"], "1.6.0")
        capabilities = compatibility["capabilities"]
        command_ids = (
            "flightdeck.command.mission-manage.v1",
            "flightdeck.command.mission-plan.v1",
            "flightdeck.command.mission-status.v1",
            "flightdeck.command.mission-sync.v1",
            "flightdeck.command.mission-authoring.v1",
            "flightdeck.command.skill-telemetry.v1",
            "flightdeck.command.operation-authoring.v1",
            "flightdeck.command.operation-projection.v1",
            "flightdeck.command.hub-snapshot.v1",
            "flightdeck.command.operations-snapshot.v1",
            "flightdeck.command.work-control.v1",
        )
        for capability_id in command_ids:
            self.assertEqual(
                capabilities[capability_id]["fallback"],
                {"mode": "stop_and_plan_migration"},
            )
        self.assertEqual(
            capabilities["flightdeck.document.mission-control.v1"]["fallback"],
            {
                "mode": "bundled_reference",
                "reference": "skills/flightdeck-mission/references/mission-contract.md",
            },
        )

    def test_bundled_compatibility_fallback_is_document_only(self) -> None:
        schema = json.loads(
            (
                PLUGIN_ROOT
                / "skills"
                / "flightdeck-setup"
                / "assets"
                / "flightdeck-template"
                / "hub"
                / "schemas"
                / "hub-compatibility.schema.json"
            ).read_text(encoding="utf-8")
        )
        capability_rules = schema["$defs"]["capability"]["allOf"]
        bundled_rule = next(
            rule
            for rule in capability_rules
            if rule.get("if", {})
            .get("properties", {})
            .get("fallback", {})
            .get("properties", {})
            .get("mode", {})
            .get("const")
            == "bundled_reference"
        )
        self.assertEqual(
            bundled_rule["then"]["properties"]["kind"],
            {"const": "document"},
        )


class UpgradePlannerTests(unittest.TestCase):
    def create_marketplace(
        self, root: Path, *, source_type: str = "local", target: str = "1.0.0+codex.2"
    ) -> tuple[dict, dict]:
        plugin_root = root / "plugins" / "flightdeck"
        (root / ".agents" / "plugins").mkdir(parents=True)
        (plugin_root / ".codex-plugin").mkdir(parents=True)
        (root / ".agents" / "plugins" / "marketplace.json").write_text(
            json.dumps(
                {
                    "name": "flightdeck-team",
                    "plugins": [
                        {
                            "name": "flightdeck",
                            "source": {
                                "source": "local",
                                "path": "./plugins/flightdeck",
                            },
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        (plugin_root / ".codex-plugin" / "plugin.json").write_text(
            json.dumps({"name": "flightdeck", "version": target}),
            encoding="utf-8",
        )
        (plugin_root / "releases.json").write_text(
            json.dumps(
                {
                    "schema_version": "flightdeck-releases/v1",
                    "releases": [
                        {
                            "version": target,
                            "summary": "Synthetic target.",
                            "changes": [],
                            "breaking_changes": [],
                            "migration": [],
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        plugins = {
            "installed": [
                {
                    "pluginId": "flightdeck@flightdeck-team",
                    "name": "flightdeck",
                    "marketplaceName": "flightdeck-team",
                    "version": "1.0.0+codex.1",
                    "installed": True,
                    "enabled": True,
                }
            ],
            "available": [],
        }
        marketplaces = {
            "marketplaces": [
                {
                    "name": "flightdeck-team",
                    "root": str(root),
                    "marketplaceSource": {
                        "sourceType": source_type,
                        "source": str(root),
                    },
                }
            ]
        }
        return plugins, marketplaces

    def test_local_marketplace_plan_skips_refresh_and_preserves_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            plugins, marketplaces = self.create_marketplace(Path(directory))
            plan = upgrade_planner.build_plan(
                plugins, marketplaces, "flightdeck", "flightdeck-team"
            )
        self.assertEqual(plan["status"], "update_available")
        self.assertEqual(plan["marketplace_refresh"], "not_required")
        self.assertIsNone(plan["commands"]["marketplace_refresh"])
        self.assertNotIn("marketplace_refresh", plan["approval_required"])
        self.assertIn("generated_hubs", plan["protected_state"])
        self.assertIn("do_not_run_setup_or_bootstrap", plan["invariants"])
        self.assertTrue(plan["target_release_ledger"].endswith("releases.json"))
        self.assertEqual(
            plan["commands"]["install"],
            [
                "codex",
                "plugin",
                "add",
                "flightdeck@flightdeck-team",
                "--json",
            ],
        )

    def test_git_marketplace_plan_requires_approved_refresh(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            plugins, marketplaces = self.create_marketplace(
                Path(directory), source_type="git"
            )
            plan = upgrade_planner.build_plan(
                plugins, marketplaces, "flightdeck", "flightdeck-team"
            )
        self.assertEqual(plan["marketplace_refresh"], "required_before_final_plan")
        self.assertEqual(
            plan["commands"]["marketplace_refresh"],
            [
                "codex",
                "plugin",
                "marketplace",
                "upgrade",
                "flightdeck-team",
                "--json",
            ],
        )
        self.assertIn("marketplace_refresh", plan["approval_required"])

    def test_matching_versions_report_current(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            plugins, marketplaces = self.create_marketplace(
                Path(directory), target="1.0.0+codex.1"
            )
            plan = upgrade_planner.build_plan(
                plugins, marketplaces, "flightdeck", "flightdeck-team"
            )
        self.assertEqual(plan["status"], "current")

    def test_missing_installed_identity_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            _, marketplaces = self.create_marketplace(Path(directory))
            with self.assertRaisesRegex(
                upgrade_planner.PlanError, "exactly one installed plugin"
            ):
                upgrade_planner.build_plan(
                    {"installed": []},
                    marketplaces,
                    "flightdeck",
                    "flightdeck-team",
                )

    def test_target_ledger_must_match_target_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugins, marketplaces = self.create_marketplace(root)
            releases_path = root / "plugins" / "flightdeck" / "releases.json"
            releases = json.loads(releases_path.read_text(encoding="utf-8"))
            releases["releases"][-1]["version"] = "1.0.0+codex.other"
            releases_path.write_text(json.dumps(releases), encoding="utf-8")
            with self.assertRaisesRegex(
                upgrade_planner.PlanError, "does not match the target manifest"
            ):
                upgrade_planner.build_plan(
                    plugins, marketplaces, "flightdeck", "flightdeck-team"
                )


if __name__ == "__main__":
    unittest.main()
