#!/usr/bin/env python3
"""Run deterministic local acceptance probes against a fresh generated Flightdeck."""

from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


SCRIPTS = Path(__file__).resolve().parent
BOOTSTRAP = SCRIPTS / "bootstrap.py"
SETUP = SCRIPTS / "setup_flightdeck.py"
SCANNER = SCRIPTS / "scan_debranding.py"
STRUCTURED = SCRIPTS / "validate_structured.py"
HUB_COMPATIBILITY = SCRIPTS / "hub_compatibility.py"
SETUP_TESTS = SCRIPTS.parent / "tests"
MISSION_TEST = SETUP_TESTS / "test_mission_acceptance.py"
MISSION_FIXTURES = SETUP_TESTS / "mission_fixtures.py"


class HarnessFailure(RuntimeError):
    pass


def run(
    arguments: list[str],
    *,
    cwd: Path,
    expect: int = 0,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        arguments,
        cwd=cwd,
        text=True,
        capture_output=True,
        check=False,
        timeout=300,
        env={**os.environ, "LC_ALL": "C", **(environment or {})},
    )
    if result.returncode != expect:
        raise HarnessFailure(
            f"expected exit {expect}, got {result.returncode}: {' '.join(arguments)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def git(cwd: Path, *arguments: str) -> str:
    return run(["git", *arguments], cwd=cwd).stdout.strip()


def initialize_repository(path: Path) -> None:
    path.mkdir(parents=True)
    git(path.parent, "init", "--quiet", "--initial-branch=main", str(path))
    git(path, "config", "user.name", "Synthetic Acceptance")
    git(path, "config", "user.email", "acceptance@example.invalid")
    (path / "AGENTS.md").write_text(
        "# Synthetic repository instructions\n\n"
        "Repository rules own commands, tests, and layout.\n",
        encoding="utf-8",
    )
    (path / "Containerfile").write_text("FROM scratch\n", encoding="utf-8")
    (path / "workload-owned-invalid.yaml").write_text(
        "synthetic: [\n",
        encoding="utf-8",
    )
    (path / "workload-owned-machine-note.txt").write_text(
        str(Path.home()) + "\n",
        encoding="utf-8",
    )
    git(
        path,
        "add",
        "AGENTS.md",
        "Containerfile",
        "workload-owned-invalid.yaml",
        "workload-owned-machine-note.txt",
    )
    git(path, "commit", "--quiet", "-m", "Synthetic fixture")


def json_command(arguments: list[str], cwd: Path) -> dict[str, Any]:
    result = run(arguments, cwd=cwd)
    value = json.loads(result.stdout)
    if not isinstance(value, dict):
        raise HarnessFailure("expected JSON object")
    return value


def probe(report: dict[str, Any], name: str, condition: bool, evidence: Any) -> None:
    report["probes"].append(
        {"name": name, "status": "passed" if condition else "failed", "evidence": evidence}
    )
    if not condition:
        raise HarnessFailure(f"probe failed: {name}: {evidence}")


def tree_state(root: Path) -> dict[str, str]:
    return {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def mission_stress_report() -> dict[str, Any]:
    spec = importlib.util.spec_from_file_location(
        "flightdeck_mission_fixtures", MISSION_FIXTURES
    )
    if not spec or not spec.loader:
        raise HarnessFailure("mission fixture module is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.run_stress(
        seed=20260803,
        mission_count=100,
        children_per_mission=16,
        replayed_snapshots=10_000,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path, help="Write the report to this ignored local path")
    args = parser.parse_args()

    report: dict[str, Any] = {
        "schema_version": "flightdeck.acceptance/v1",
        "locally_verified": False,
        "probes": [],
        "runtime_acceptance": [
            {
                "name": "installed_setup_and_exact_path_project_registration",
                "status": "not_run_requires_installed_plugin_fresh_task",
            },
            {
                "name": "installed_bulk_bridge_configuration",
                "status": "not_run_requires_installed_plugin_fresh_task",
            },
            {
                "name": "installed_task_search_create_resume_and_no_monitoring",
                "status": "not_run_requires_installed_plugin_fresh_task",
            },
            {
                "name": "installed_mission_dispatch_only_default",
                "status": "not_run_requires_installed_plugin_fresh_task",
            },
            {
                "name": "installed_mission_watch_only_synchronization",
                "status": "not_run_requires_installed_plugin_fresh_task",
            },
            {
                "name": "installed_mission_supervised_fan_in",
                "status": "not_run_requires_installed_plugin_fresh_task",
            },
            {
                "name": "installed_mission_operator_closure",
                "status": "not_run_requires_installed_plugin_fresh_task",
            },
            {
                "name": "installed_mission_skill_telemetry_from_structured_task_events",
                "status": "not_run_requires_installed_plugin_fresh_task",
            },
            {
                "name": "installed_plugin_upgrade_and_preservation_verification",
                "status": "not_run_requires_explicit_plugin_update_authorization",
            },
        ],
    }

    try:
        with tempfile.TemporaryDirectory(prefix="flightdeck-acceptance-") as directory:
            root = Path(directory)
            hub = root / "generated-hub"
            bootstrap_hub = root / "bootstrap-hub"
            source = root / "source-repository"
            initialize_repository(source)

            bootstrap_preview = json_command(
                [
                    "python3",
                    str(BOOTSTRAP),
                    "--target",
                    str(bootstrap_hub),
                    "--json",
                ],
                cwd=root,
            )
            probe(
                report,
                "bootstrap_preview_non_mutating",
                bootstrap_preview.get("status") == "preview"
                and bootstrap_preview.get("would_generate") is True
                and not bootstrap_hub.exists(),
                bootstrap_preview,
            )
            bootstrap_apply = json_command(
                [
                    "python3",
                    str(BOOTSTRAP),
                    "--target",
                    str(bootstrap_hub),
                    "--apply",
                    "--json",
                ],
                cwd=root,
            )
            bootstrap_noop = json_command(
                [
                    "python3",
                    str(BOOTSTRAP),
                    "--target",
                    str(bootstrap_hub),
                    "--apply",
                    "--json",
                ],
                cwd=root,
            )
            probe(
                report,
                "bootstrap_apply_and_idempotent_noop",
                bootstrap_apply.get("status") == "generated_and_validated"
                and bootstrap_apply.get("generated") is True
                and bootstrap_apply["validation"]["doctor"]["errors"] == 0
                and bootstrap_apply["validation"]["setup_links"]["failures"] == 0
                and bootstrap_noop.get("status") == "validated_noop"
                and bootstrap_noop.get("no_op") is True
                and bootstrap_noop.get("generated") is False,
                {"apply": bootstrap_apply, "rerun": bootstrap_noop},
            )

            setup = json_command(
                ["python3", str(SETUP), str(hub), "--no-git", "--json"], cwd=root
            )
            probe(report, "fresh_generation", setup.get("generated") is True, setup)

            mission_tests = run(
                [
                    "python3",
                    "-m",
                    "unittest",
                    "discover",
                    "-s",
                    str(SETUP_TESTS),
                    "-p",
                    MISSION_TEST.name,
                    "-v",
                ],
                cwd=root,
                environment={"FLIGHTDECK_ACCEPTANCE_HUB": str(hub)},
            )
            mission_test_output = mission_tests.stdout + mission_tests.stderr
            mission_test_count_match = re.search(r"Ran (\d+) tests?", mission_test_output)
            mission_test_count = (
                int(mission_test_count_match.group(1))
                if mission_test_count_match
                else 0
            )
            mission_stress = mission_stress_report()
            report["mission_acceptance"] = {
                "evidence_class": "local_generated_hub_cli_with_injected_codex_ui",
                "live_runtime_verified": False,
                "test_count": mission_test_count,
                "stress": mission_stress,
            }
            probe(
                report,
                "mission_injected_adapter_contract_and_bounded_stress",
                mission_test_count >= 26
                and "OK" in mission_test_output
                and mission_stress["missions"] == 100
                and mission_stress["total_children"] == 1600
                and mission_stress["replayed_snapshots"] == 10_000
                and mission_stress["duplicates"]
                + mission_stress["out_of_order"]
                == 10_000
                and mission_stress["dedupe_window"] <= 1024
                and mission_stress["snapshot_bytes"] < 250_000
                and mission_stress["elapsed_seconds"] < 10.0,
                report["mission_acceptance"],
            )

            artifact_guidance = " ".join(
                (hub / "docs/workflows/artifacts.md")
                .read_text(encoding="utf-8")
                .split()
            ).casefold()
            compliance_guidance = " ".join(
                (hub / "docs/compliance/README.md")
                .read_text(encoding="utf-8")
                .split()
            ).casefold()
            compliance_schema = json.loads(
                (
                    hub
                    / "hub"
                    / "schemas"
                    / "compliance-artifact.schema.json"
                ).read_text(encoding="utf-8")
            )
            probe(
                report,
                "generated_professional_deliverable_contract",
                "professional human-authored deliverables" in artifact_guidance
                and "unresolved template variables" in artifact_guidance
                and "explicit file-type allowlist" in artifact_guidance
                and "must not identify ai, codex" in compliance_guidance
                and (hub / "compliance/_program-template/deliverables").is_dir()
                and (hub / "compliance/_program-template/working-records").is_dir()
                and compliance_schema["properties"]["status"]["const"]
                == "unsubmitted"
                and "generated_by" not in compliance_schema["properties"]
                and "reviewer_actions" not in compliance_schema["properties"],
                {
                    "artifact_guidance": "docs/workflows/artifacts.md",
                    "compliance_guidance": "docs/compliance/README.md",
                    "schema": "hub/schemas/compliance-artifact.schema.json",
                },
            )

            clean_deliverable = root / "clean-deliverable.txt"
            clean_deliverable.write_text(
                "Available records do not establish the account-review cadence.\n",
                encoding="utf-8",
            )
            dirty_deliverable = root / "assessment-draft.txt"
            dirty_deliverable.write_text(
                "Generated by Codex. Program: [Program Name]\n",
                encoding="utf-8",
            )
            clean_report = json_command(
                [
                    "python3",
                    str(hub / "scripts" / "validate-deliverable.py"),
                    str(clean_deliverable),
                    "--json",
                ],
                cwd=root,
            )
            dirty_result = run(
                [
                    "python3",
                    str(hub / "scripts" / "validate-deliverable.py"),
                    str(dirty_deliverable),
                    "--json",
                ],
                cwd=root,
                expect=1,
            )
            dirty_report = json.loads(dirty_result.stdout)
            dirty_codes = {
                item["code"] for item in dirty_report.get("findings", [])
            }
            probe(
                report,
                "artifact_deliverable_hygiene_gate",
                clean_report.get("ok") is True
                and dirty_report.get("ok") is False
                and {
                    "ai_provenance",
                    "presentation_filename",
                    "unresolved_placeholder",
                }.issubset(dirty_codes),
                {
                    "clean": clean_report,
                    "dirty_codes": sorted(dirty_codes),
                },
            )

            compatibility_before = tree_state(hub)
            compatibility = json_command(
                [
                    "python3",
                    str(HUB_COMPATIBILITY),
                    "--hub-root",
                    str(hub),
                    "--require",
                    "flightdeck.command.setup-plan.v1",
                    "--require",
                    "flightdeck.command.setup-connect.v1",
                    "--require",
                    "flightdeck.document.change-review.v1",
                    "--require",
                    "flightdeck.command.mission-manage.v1",
                    "--require",
                    "flightdeck.command.mission-plan.v1",
                    "--require",
                    "flightdeck.command.mission-status.v1",
                    "--require",
                    "flightdeck.command.mission-list.v1",
                    "--require",
                    "flightdeck.command.mission-sync.v1",
                    "--require",
                    "flightdeck.command.skill-telemetry.v1",
                    "--require",
                    "flightdeck.command.mission-authoring.v1",
                    "--require",
                    "flightdeck.command.operation-authoring.v1",
                    "--require",
                    "flightdeck.command.operation-projection.v1",
                    "--require",
                    "flightdeck.command.hub-snapshot.v1",
                    "--require",
                    "flightdeck.command.operations-snapshot.v1",
                    "--require",
                    "flightdeck.command.operations-snapshot-detail-identity.v1",
                    "--require",
                    "flightdeck.command.omp-operation-execution.v1",
                    "--require",
                    "flightdeck.command.omp-operation-observation.v1",
                    "--require",
                    "flightdeck.document.mission-control.v1",
                ],
                cwd=root,
            )
            probe(
                report,
                "generated_hub_capability_contract_is_declared_probed_and_read_only",
                compatibility.get("status") == "compatible"
                and compatibility.get("compatible") is True
                and compatibility.get("read_only") is True
                and compatibility.get("hub", {})
                .get("identity", {})
                .get("template_version")
                == "1.8.0"
                and not compatibility.get("requirements", {}).get("missing")
                and tree_state(hub) == compatibility_before,
                compatibility,
            )

            planning_guidance = " ".join(
                (hub / "docs/workflows/planning.md")
                .read_text(encoding="utf-8")
                .split()
            ).casefold()
            review_guidance = " ".join(
                (hub / "docs/review/change-review.md")
                .read_text(encoding="utf-8")
                .split()
            ).casefold()
            routing_guidance = " ".join(
                (hub / "docs/workflows/thread-routing.md")
                .read_text(encoding="utf-8")
                .split()
            ).casefold()
            hub_instructions = " ".join(
                (hub / "AGENTS.md").read_text(encoding="utf-8").split()
            ).casefold()
            probe(
                report,
                "generated_adaptive_plan_and_findings_first_review_guidance",
                "users do not need to name a skill" in planning_guidance
                and "planning-only request is read-only" in planning_guidance
                and "right-sized coordination planning" in routing_guidance
                and "lead with actionable findings" in review_guidance
                and "review is read-only by default" in review_guidance
                and "natural-language planning-only request" in hub_instructions
                and "natural-language review request" in hub_instructions,
                {
                    "planning": "docs/workflows/planning.md",
                    "review": "docs/review/change-review.md",
                    "instructions": "AGENTS.md",
                },
            )

            ci_guidance = " ".join(
                (hub / "docs/workflows/ci-cd.md")
                .read_text(encoding="utf-8")
                .split()
            ).casefold()
            platform_guidance = " ".join(
                (hub / "docs/workflows/platform.md")
                .read_text(encoding="utf-8")
                .split()
            ).casefold()
            probe(
                report,
                "generated_ci_cd_and_platform_coordination_guidance",
                "users do not need to name a skill" in ci_guidance
                and "latest run and current checkout may differ" in ci_guidance
                and "first causal failure" in ci_guidance
                and "each external action requires explicit authorization" in ci_guidance
                and "users do not need to name a skill" in platform_guidance
                and "source and runtime split" in platform_guidance
                and "successful plan or render does not prove an apply occurred"
                in platform_guidance
                and "every environment write" in platform_guidance
                and "natural pipeline" in hub_instructions
                and "natural infrastructure" in hub_instructions,
                {
                    "ci_cd": "docs/workflows/ci-cd.md",
                    "platform": "docs/workflows/platform.md",
                    "instructions": "AGENTS.md",
                },
            )

            database_guidance = " ".join(
                (hub / "docs/workflows/database.md")
                .read_text(encoding="utf-8")
                .split()
            ).casefold()
            probe(
                report,
                "generated_database_engineering_and_operations_guidance",
                "users do not need to name a skill" in database_guidance
                and "conceptual questions" in database_guidance
                and "expand-and-contract" in database_guidance
                and "treat production reads as potentially expensive"
                in database_guidance
                and "successful migration command, backup job, or database startup"
                in database_guidance
                and "natural database" in hub_instructions
                and "diagnostics do not authorize ddl, dml, migrations"
                in hub_instructions,
                {
                    "database": "docs/workflows/database.md",
                    "instructions": "AGENTS.md",
                },
            )

            stig_guidance = " ".join(
                (hub / "docs/compliance/stig-evaluation.md")
                .read_text(encoding="utf-8")
                .split()
            ).casefold()
            probe(
                report,
                "generated_adaptive_stig_evidence_guidance",
                "users do not need to name a skill" in stig_guidance
                and "fixed intake form" in stig_guidance
                and "direct, inherited, and merely declared" in stig_guidance
                and "decide applicability before assigning" in stig_guidance
                and "draft evidence profile" in stig_guidance
                and "export profile" in stig_guidance
                and "ckl file creation does not prove" in stig_guidance
                and "natural stig" in hub_instructions
                and "dispatch repository, program, ci/cd, platform, or environment-owned"
                in hub_instructions,
                {
                    "stig": "docs/compliance/stig-evaluation.md",
                    "instructions": "AGENTS.md",
                },
            )

            lifecycle_guidance = " ".join(
                (hub / "docs/workflows/plugin-lifecycle.md")
                .read_text(encoding="utf-8")
                .split()
            ).casefold()
            probe(
                report,
                "generated_plugin_lifecycle_preservation_guidance",
                "separate lifecycles" in lifecycle_guidance
                and "protected state" in lifecycle_guidance
                and "without removing it first" in lifecycle_guidance
                and "does not run setup or bootstrap" in lifecycle_guidance
                and "existing hubs stay on their generated template version"
                in lifecycle_guidance
                and "natural flightdeck update" in hub_instructions
                and "marketplace refresh, plugin reinstall, and rollback require explicit authorization"
                in hub_instructions,
                {
                    "lifecycle": "docs/workflows/plugin-lifecycle.md",
                    "instructions": "AGENTS.md",
                },
            )

            attached_root = root / "attached-repositories"
            attached = attached_root / "synthetic-attached"
            initialize_repository(attached)
            hub_before_setup_plan = tree_state(hub)
            attached_before_setup_plan = tree_state(attached)
            setup_plan = json_command(
                [
                    str(hub / "bin/flightdeck"),
                    "setup",
                    "plan",
                    "--repositories-root",
                    str(attached_root),
                    "--json",
                ],
                cwd=hub,
            )
            probe(
                report,
                "setup_repository_discovery_read_only",
                setup_plan["read_only"] is True
                and setup_plan["summary"]["discovered"] == 1
                and setup_plan["summary"]["ready"] == 1
                and tree_state(hub) == hub_before_setup_plan
                and tree_state(attached) == attached_before_setup_plan,
                setup_plan["summary"],
            )
            attached_agents = (attached / "AGENTS.md").read_text(encoding="utf-8")
            setup_connect = json_command(
                [
                    str(hub / "bin/flightdeck"),
                    "setup",
                    "connect",
                    "--repositories-root",
                    str(attached_root),
                    "--json",
                ],
                cwd=hub,
            )
            declaration_text = (hub / "hub/repositories.yaml").read_text(
                encoding="utf-8"
            )
            local_registry_text = (hub / "hub/state/repositories.yaml").read_text(
                encoding="utf-8"
            )
            probe(
                report,
                "setup_attached_reference_bridge_portable",
                setup_connect["ok"] is True
                and setup_connect["summary"]["connected"] == 1
                and "placement: attached" in declaration_text
                and str(attached) not in declaration_text
                and str(attached) in local_registry_text
                and (attached / "AGENTS.override.md").is_file()
                and (attached / "AGENTS.md").read_text(encoding="utf-8")
                == attached_agents
                and git(attached, "diff", "--name-only") == "",
                setup_connect["summary"],
            )
            bridge_registry_before_noop = (
                hub / "hub/state/bridges.yaml"
            ).read_bytes()
            setup_noop = json_command(
                [
                    str(hub / "bin/flightdeck"),
                    "setup",
                    "connect",
                    "--repositories-root",
                    str(attached_root),
                    "--json",
                ],
                cwd=hub,
            )
            probe(
                report,
                "setup_connect_idempotent_and_preserves_tracked_files",
                setup_noop["ok"] is True
                and setup_noop["changed"] is False
                and setup_noop["bridge_receipt"]["repositories"][0]["bridge"]["status"]
                == "noop"
                and (hub / "hub/state/bridges.yaml").read_bytes()
                == bridge_registry_before_noop
                and git(attached, "diff", "--name-only") == "",
                setup_noop["summary"],
            )

            nested_validator_root = root / ".flightdeck-local" / "nested-validator-root"
            nested_validator_root.mkdir(parents=True)
            (nested_validator_root / "sample.json").write_text(
                '{"synthetic": true}\n', encoding="utf-8"
            )
            structured_nested = json_command(
                ["python3", str(STRUCTURED), str(nested_validator_root), "--json"],
                cwd=root,
            )
            private_token = "private-fixture-token"
            private_map = root / "private-neutralization.json"
            private_map.write_text(
                json.dumps(
                    {
                        "schema_version": "flightdeck.private-neutralization/v1",
                        "source_control_token": "legacy-fixture-hub",
                        "replacements": {
                            private_token: "neutral-fixture-token",
                        },
                        "deny_tokens": ["private-fixture-owner"],
                    },
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            (nested_validator_root / "prohibited-plaintext.txt").write_text(
                private_token + "\n", encoding="utf-8"
            )
            (nested_validator_root / "prohibited-hex.txt").write_text(
                private_token.encode("utf-8").hex() + "\n", encoding="utf-8"
            )
            (nested_validator_root / "prohibited-base64.txt").write_text(
                base64.b64encode(private_token.encode("utf-8")).decode("ascii")
                + "\n",
                encoding="utf-8",
            )
            (nested_validator_root / "prohibited-reconstructed.py").write_text(
                'value = "".join(("private", "fixture", "token"))\n',
                encoding="utf-8",
            )
            scan_nested = run(
                [
                    "python3",
                    str(SCANNER),
                    str(nested_validator_root),
                    "--private-neutralization-map",
                    str(private_map),
                ],
                cwd=root,
                expect=1,
            )
            probe(
                report,
                "validators_scan_root_inside_ignored_named_parent",
                structured_nested["counts"]["json"] == 1
                and structured_nested["ok"] is True
                and scan_nested.stdout.count("prohibited private token profile") == 4
                and "(plaintext)" in scan_nested.stdout
                and "(hex)" in scan_nested.stdout
                and "(base64)" in scan_nested.stdout
                and "(reconstructed)" in scan_nested.stdout,
                {
                    "structured": structured_nested,
                    "scanner": scan_nested.stdout.strip(),
                },
            )

            structured = json_command(
                ["python3", str(STRUCTURED), str(hub), "--json"], cwd=root
            )
            probe(
                report,
                "generated_structured_files",
                structured.get("ok") is True and structured["counts"]["schemas"] > 0,
                structured,
            )

            nonempty = run(
                ["python3", str(SETUP), str(hub), "--no-git"],
                cwd=root,
                expect=2,
            )
            probe(
                report,
                "nonempty_target_refused",
                "target must be absent or empty" in nonempty.stderr,
                nonempty.stderr.strip(),
            )

            tests = run(["ruby", "-Ilib", "tests/flightdeck_test.rb"], cwd=hub)
            probe(report, "generated_ruby_tests", "0 failures" in tests.stdout, tests.stdout.strip())

            initial_doctor = json_command([str(hub / "bin/flightdeck"), "doctor", "--json"], cwd=hub)
            probe(
                report,
                "fresh_doctor",
                initial_doctor["summary"]["errors"] == 0,
                initial_doctor["summary"],
            )

            route = json_command(
                [
                    str(hub / "bin/flightdeck"),
                    "route",
                    "plan",
                    "--workload",
                    "development",
                    "--work-type",
                    "implementation",
                    "--json",
                ],
                cwd=hub,
            )
            probe(
                report,
                "route_contract",
                route["dispatch_required"]
                and route["stop_after_dispatch"]
                and route["dispatch_receipt"]["monitoring_permitted"] is False,
                route["dispatch_receipt"],
            )

            plan = json_command(
                [
                    str(hub / "bin/flightdeck"),
                    "repo",
                    "plan",
                    "--workload",
                    "development",
                    "--provider",
                    "git",
                    "--repo",
                    source.as_uri(),
                    "--owner",
                    "synthetic",
                    "--default-branch",
                    "main",
                    "--json",
                ],
                cwd=hub,
            )
            probe(report, "repository_plan_read_only", plan["plan_read_only"] is True, plan)

            reference = json_command(
                [
                    str(hub / "bin/flightdeck"),
                    "repo",
                    "onboard",
                    "--workload",
                    "development",
                    "--provider",
                    "git",
                    "--repo",
                    source.as_uri(),
                    "--id",
                    "synthetic-reference",
                    "--name",
                    "synthetic-reference",
                    "--owner",
                    "synthetic",
                    "--default-branch",
                    "main",
                    "--bridge-mode",
                    "reference",
                ],
                cwd=hub,
            )
            probe(
                report,
                "clone_origin_branch_sha_clean",
                reference["verification"]["clean"]
                and reference["verification"]["branch"] == "main"
                and len(reference["verification"]["sha"]) >= 7
                and reference["verification"]["origin"] == source.as_uri(),
                reference["verification"],
            )
            probe(
                report,
                "registration_remains_unclaimed",
                reference["project_registration"]["verified"] is False,
                reference["project_registration"],
            )

            materialized_path = hub / "development" / "synthetic-materialized"
            initialize_repository(materialized_path)
            materialized = json_command(
                [
                    str(hub / "bin/flightdeck"),
                    "repo",
                    "onboard",
                    "--workload",
                    "development",
                    "--provider",
                    "existing-local",
                    "--repo",
                    str(materialized_path),
                    "--id",
                    "synthetic-materialized",
                    "--bridge-mode",
                    "materialized",
                ],
                cwd=hub,
            )
            materialized_text = (
                materialized_path / materialized["bridge"]["target"]
            ).read_text(encoding="utf-8")
            probe(
                report,
                "materialized_bridge_portable",
                str(hub) not in materialized_text
                and str(materialized_path) not in materialized_text
                and materialized["bridge"]["portable"] is True,
                materialized["bridge"],
            )

            native_path = hub / "development" / "synthetic-native"
            initialize_repository(native_path)
            original = (native_path / "AGENTS.md").read_text(encoding="utf-8")
            native = json_command(
                [
                    str(hub / "bin/flightdeck"),
                    "repo",
                    "onboard",
                    "--workload",
                    "development",
                    "--provider",
                    "existing-local",
                    "--repo",
                    str(native_path),
                    "--id",
                    "synthetic-native",
                    "--bridge-mode",
                    "repo-native",
                    "--acknowledge-repo-native",
                ],
                cwd=hub,
            )
            native_text = (native_path / "AGENTS.md").read_text(encoding="utf-8")
            probe(
                report,
                "repo_native_preserves_authority_without_absolute_paths",
                native_text.startswith(original.rstrip())
                and str(hub) not in native_text
                and str(native_path) not in native_text
                and "Repository rules own" in native_text,
                native["bridge"],
            )

            declarations = {
                "api_version": "flightdeck.dev/v1alpha1",
                "kind": "RepositoryDeclarations",
                "schema": "hub/schemas/repository-declarations.schema.json",
                "repositories": [
                    {
                        "id": "synthetic-reference",
                        "workload": "development",
                        "provider": "git",
                        "locator": source.as_uri(),
                        "local_path": "development/synthetic-reference",
                        "owner": "synthetic",
                        "default_branch": "main",
                        "default_branch_verified": True,
                        "bridge": {"profile": "application", "mode": "reference"},
                        "codex_project": {
                            "expectation": "saved_exact_path",
                            "logical_key": "synthetic-reference",
                        },
                    },
                    {
                        "id": "synthetic-materialized",
                        "workload": "development",
                        "provider": "existing-local",
                        "locator": "development/synthetic-materialized",
                        "local_path": "development/synthetic-materialized",
                        "owner": "local",
                        "default_branch": "main",
                        "default_branch_verified": True,
                        "bridge": {"profile": "application", "mode": "materialized"},
                        "codex_project": {
                            "expectation": "saved_exact_path",
                            "logical_key": "synthetic-materialized",
                        },
                    },
                    {
                        "id": "synthetic-native",
                        "workload": "development",
                        "provider": "existing-local",
                        "locator": "development/synthetic-native",
                        "local_path": "development/synthetic-native",
                        "owner": "local",
                        "default_branch": "main",
                        "default_branch_verified": True,
                        "bridge": {"profile": "application", "mode": "repo-native"},
                        "codex_project": {
                            "expectation": "saved_exact_path",
                            "logical_key": "synthetic-native",
                        },
                    },
                ],
            }
            (hub / "hub/repositories.yaml").write_text(
                json.dumps(declarations, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            projects = {
                "api_version": "flightdeck.dev/v1alpha1",
                "kind": "CodexProjectVerifications",
                "projects": {
                    "synthetic-reference": {
                        "logical_key": "synthetic-reference",
                        "runtime_project_id": "opaque-runtime-project-reference-001",
                        "path": str(hub / "development/synthetic-reference"),
                        "verified": True,
                        "verification_source": "live_project_list_exact_path",
                        "verified_at": "2026-01-01T00:00:00Z",
                    }
                },
            }
            (hub / "hub/state/projects.yaml").write_text(
                json.dumps(projects, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            before_bulk_plan = tree_state(hub)
            bulk_plan = json_command(
                [
                    str(hub / "bin/flightdeck"),
                    "bridge",
                    "plan",
                    "--all",
                    "--failure-policy",
                    "continue",
                    "--json",
                ],
                cwd=hub,
            )
            after_bulk_plan = tree_state(hub)
            probe(
                report,
                "bulk_bridge_plan_read_only",
                before_bulk_plan == after_bulk_plan
                and bulk_plan["read_only"] is True
                and bulk_plan["summary"]["noop"] == 3,
                bulk_plan["summary"],
            )
            project_states = {
                item["repository_id"]: item["project_registration"]["status"]
                for item in bulk_plan["repositories"]
            }
            probe(
                report,
                "bulk_project_registration_pending_and_verified",
                project_states["synthetic-reference"] == "verified"
                and project_states["synthetic-materialized"] == "pending"
                and project_states["synthetic-native"] == "pending",
                project_states,
            )
            verified_project = next(
                item["project_registration"]
                for item in bulk_plan["repositories"]
                if item["repository_id"] == "synthetic-reference"
            )
            probe(
                report,
                "logical_project_key_differs_from_runtime_project_id",
                verified_project["logical_key"] == "synthetic-reference"
                and verified_project["runtime_project_id"]
                == "opaque-runtime-project-reference-001"
                and verified_project["logical_key"]
                != verified_project["runtime_project_id"],
                verified_project,
            )
            bulk_apply = json_command(
                [
                    str(hub / "bin/flightdeck"),
                    "bridge",
                    "install",
                    "--all",
                    "--failure-policy",
                    "continue",
                    "--json",
                ],
                cwd=hub,
            )
            probe(
                report,
                "bulk_bridge_idempotent_per_repo_receipt",
                bulk_apply["ok"] is True
                and bulk_apply["complete"] is False
                and bulk_apply["summary"]["noop"] == 3
                and len(bulk_apply["repositories"]) == 3
                and (hub / bulk_apply["receipt_path"]).is_file(),
                bulk_apply["summary"],
            )

            reference_override = hub / "development/synthetic-reference/AGENTS.override.md"
            valid_reference = reference_override.read_text(encoding="utf-8")
            reference_override.write_text("unmanaged conflicting content\n", encoding="utf-8")
            conflict_result = run(
                [
                    str(hub / "bin/flightdeck"),
                    "bridge",
                    "install",
                    "--all",
                    "--failure-policy",
                    "continue",
                    "--json",
                ],
                cwd=hub,
                expect=1,
            )
            conflict = json.loads(conflict_result.stdout)
            conflict_receipts = {
                item["repository_id"]: item for item in conflict["repositories"]
            }
            probe(
                report,
                "bulk_bridge_conflict_refusal_with_continue_policy",
                conflict["ok"] is False
                and conflict_receipts["synthetic-reference"]["bridge"]["status"] == "blocked"
                and conflict_receipts["synthetic-materialized"]["bridge"]["status"] == "noop"
                and reference_override.read_text(encoding="utf-8")
                == "unmanaged conflicting content\n",
                conflict["summary"],
            )
            reference_override.write_text(valid_reference, encoding="utf-8")
            json_command(
                [
                    str(hub / "bin/flightdeck"),
                    "bridge",
                    "install",
                    "--all",
                    "--failure-policy",
                    "continue",
                    "--json",
                ],
                cwd=hub,
            )

            routed = json_command(
                [
                    str(hub / "bin/flightdeck"),
                    "route",
                    "plan",
                    "--workload",
                    "development",
                    "--work-type",
                    "implementation",
                    "--repo-id",
                    "synthetic-reference",
                    "--json",
                ],
                cwd=hub,
            )
            probe(
                report,
                "owning_repository_dispatch_receipt",
                routed["project_key"] == "synthetic-reference"
                and routed["runtime_project_id"]
                == "opaque-runtime-project-reference-001"
                and routed["dispatch_ready"] is True
                and routed["dispatch_receipt"]["required"]
                and routed["stop_after_dispatch"],
                {
                    "project_key": routed["project_key"],
                    "runtime_project_id": routed["runtime_project_id"],
                    "receipt": routed["dispatch_receipt"],
                },
            )
            child_prompt_requirements = routed["child_prompt_requirements"]
            child_prompt_text = " ".join(child_prompt_requirements)
            probe(
                report,
                "route_skill_composition_is_fluid_and_dynamic",
                "lead Flightdeck skill" in child_prompt_text
                and "owning workload" in child_prompt_text
                and "new evidence crosses domains" in child_prompt_text
                and "before domain-specific mutation" in child_prompt_text
                and "do not preload speculative skills" in child_prompt_text
                and "expand authorization" in child_prompt_text,
                {"child_prompt_requirements": child_prompt_requirements},
            )
            handoff = routed["bridge_handoff"]
            original_checkout = Path(handoff["original_checkout_path"])
            worktree = root / "synthetic-worktree"
            git(original_checkout, "worktree", "add", "--detach", str(worktree), "HEAD")
            target_in_worktree = worktree / handoff["bridge_target_relative_path"]
            target_digest = hashlib.sha256(
                Path(handoff["bridge_target_path"]).read_bytes()
            ).hexdigest()
            artifact_digests_match = all(
                hashlib.sha256(Path(artifact["path"]).read_bytes()).hexdigest()
                == artifact["sha256"]
                for artifact in handoff["artifacts"]
            )
            probe(
                report,
                "worktree_bridge_handoff_uses_verified_original_checkout",
                handoff["status"] == "verified"
                and handoff["mode"] == "reference"
                and handoff["worktree_policy"]
                == "read_verified_bridge_from_original_checkout_when_ignored_target_absent"
                and handoff["copy_into_worktree"] is False
                and not target_in_worktree.exists()
                and target_digest == handoff["bridge_target_sha256"]
                and artifact_digests_match
                and "AGENTS.md" in handoff["instruction_order"][0]
                and "original_checkout_path"
                in child_prompt_text,
                {
                    "target_absent_in_worktree": not target_in_worktree.exists(),
                    "target_digest_matches": target_digest
                    == handoff["bridge_target_sha256"],
                    "artifact_digests_match": artifact_digests_match,
                    "handoff": handoff,
                },
            )

            legacy_projects = {
                "api_version": "flightdeck.dev/v1alpha1",
                "kind": "CodexProjectVerifications",
                "projects": {
                    "synthetic-reference": {
                        "project_id": "synthetic-reference",
                        "path": str(hub / "development/synthetic-reference"),
                        "verified": True,
                    }
                },
            }
            (hub / "hub/state/projects.yaml").write_text(
                json.dumps(legacy_projects, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            legacy_result = run(
                [
                    str(hub / "bin/flightdeck"),
                    "route",
                    "plan",
                    "--workload",
                    "development",
                    "--work-type",
                    "implementation",
                    "--repo-id",
                    "synthetic-reference",
                    "--json",
                ],
                cwd=hub,
                expect=1,
            )
            probe(
                report,
                "legacy_project_self_equality_rejected",
                "runtime_project_id" in legacy_result.stderr,
                legacy_result.stderr.strip(),
            )
            (hub / "hub/state/projects.yaml").write_text(
                json.dumps(projects, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            run(
                [
                    str(hub / "bin/flightdeck"),
                    "task",
                    "new",
                    "development",
                    "synthetic-change",
                    "--title",
                    "Synthetic change",
                    "--outcome",
                    "Preserve the synthetic contract",
                    "--workload",
                    "development",
                ],
                cwd=hub,
            )
            duplicate = run(
                [
                    str(hub / "bin/flightdeck"),
                    "task",
                    "new",
                    "development",
                    "synthetic-change",
                    "--title",
                    "Duplicate",
                    "--outcome",
                    "Must fail",
                    "--workload",
                    "development",
                ],
                cwd=hub,
                expect=1,
            )
            probe(
                report,
                "task_non_destructive_duplicate_refusal",
                "task already exists" in duplicate.stderr,
                duplicate.stderr.strip(),
            )
            gate = run(
                [
                    str(hub / "bin/flightdeck"),
                    "task",
                    "transition",
                    "synthetic-change",
                    "scoped",
                ],
                cwd=hub,
                expect=1,
            )
            probe(
                report,
                "task_transition_gate",
                "feature-intent-complete" in gate.stderr,
                gate.stderr.strip(),
            )

            doctor = json_command([str(hub / "bin/flightdeck"), "doctor", "--json"], cwd=hub)
            probe(
                report,
                "post_onboarding_doctor_no_errors",
                doctor["summary"]["errors"] == 0,
                doctor["summary"],
            )
            probe(
                report,
                "doctor_no_fetch_caveat",
                doctor["no_fetch"] is True,
                {"no_fetch": doctor["no_fetch"]},
            )

            managed_validation = run(["make", "validate"], cwd=hub)
            post_onboarding_structured = json_command(
                ["python3", str(STRUCTURED), str(hub), "--json"],
                cwd=root,
            )
            probe(
                report,
                "post_onboarding_validation_respects_control_plane_boundary",
                "Flightdeck validation passed." in managed_validation.stdout
                and post_onboarding_structured.get("ok") is True
                and not any(
                    "workload-owned-invalid.yaml" in failure
                    for failure in post_onboarding_structured["failures"]
                ),
                {
                    "make_validate": managed_validation.stdout.strip(),
                    "structured": post_onboarding_structured,
                },
            )

            scan = run(
                ["python3", str(SCANNER), str(hub), "--allow-generated-root"],
                cwd=root,
            )
            probe(report, "generated_debranding", "0 finding(s)" in scan.stdout, scan.stdout.strip())

        report["locally_verified"] = all(
            item["status"] == "passed" for item in report["probes"]
        )
    except (HarnessFailure, OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        report["failure"] = str(error)

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["locally_verified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
