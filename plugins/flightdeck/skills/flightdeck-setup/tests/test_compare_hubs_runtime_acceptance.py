#!/usr/bin/env python3
"""Focused validation for installed runtime-acceptance v1/v2 evidence."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).parents[1] / "scripts"
SCRIPT = SCRIPTS / "compare_hubs.py"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("compare_hubs_runtime", SCRIPT)
assert SPEC and SPEC.loader
COMPARE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = COMPARE
SPEC.loader.exec_module(COMPARE)


def base_results() -> list[dict[str, object]]:
    return [
        {
            "name": "installed_setup_and_exact_path_project_registration",
            "status": "passed",
            "exact_path_match": True,
            "runtime_project_id": "opaque-runtime-project",
        },
        {
            "name": "installed_bulk_bridge_configuration",
            "status": "passed",
            "logical_project_key": "synthetic-project",
            "runtime_project_id": "opaque-runtime-project",
            "no_implementation_task_created": True,
        },
        {
            "name": "installed_task_search_create_resume_and_no_monitoring",
            "status": "passed",
            "create_task_id": "opaque-task",
            "resume_task_id": "opaque-task",
            "runtime_project_id_used": True,
            "monitoring_after_receipt": False,
        },
    ]


def mission_results() -> list[dict[str, object]]:
    return [
        {
            "name": "installed_mission_dispatch_only_default",
            "status": "passed",
            "task_id": "opaque-direct-task",
            "mission_created": False,
            "monitoring_after_receipt": False,
        },
        {
            "name": "installed_mission_watch_only_synchronization",
            "status": "passed",
            "mode": "watch_only",
            "mission_record_persisted": True,
            "exact_identity_verified": True,
            "logical_project_key": "synthetic-project",
            "runtime_project_id": "opaque-runtime-project",
            "task_id": "opaque-watch-task",
            "host_id": "opaque-host",
            "cursor": "opaque-cursor",
            "follow_up_count": 0,
            "external_action_count": 0,
        },
        {
            "name": "installed_mission_supervised_fan_in",
            "status": "passed",
            "mode": "supervised",
            "declared_dependency": True,
            "required_outputs_schema_valid": True,
            "required_validation_passed": True,
            "all_criteria_assigned": True,
            "all_criteria_passed": True,
            "blocked_or_degraded_rejected": True,
            "handoff_after_required_fan_in": True,
            "dependent_handoff_count": 1,
            "non_artifact_resolver_null": True,
            "artifact_resolver_binding_verified": True,
            "artifact_tamper_replay_rejected": True,
            "producer_provenance_verified": True,
            "core_materialized_artifact_refs": True,
            "child_supplied_canonical_ref_rejected": True,
            "blocked_or_stale_consumer_non_actionable": True,
            "free_text_ignored": True,
            "external_action_count": 0,
        },
        {
            "name": "installed_mission_operator_closure",
            "status": "passed",
            "pre_close_status": "review_ready",
            "awaiting_operator_closure": True,
            "automatic_closure": False,
            "explicit_close_authorized": True,
            "post_close_status": "complete",
        },
    ]


class RuntimeAcceptanceEvidenceTest(unittest.TestCase):
    def evidence(self, version: str, *, mission: bool = False) -> dict[str, object]:
        results = base_results()
        if mission:
            results.extend(mission_results())
        return {"schema_version": version, "runtime_acceptance": results}

    def test_v1_remains_exact_three_and_valid(self) -> None:
        evidence = self.evidence(COMPARE.RUNTIME_ACCEPTANCE_V1)
        self.assertEqual([], COMPARE.validate_runtime_acceptance_results(evidence))

        evidence["runtime_acceptance"].append(mission_results()[0])
        failures = COMPARE.validate_runtime_acceptance_results(evidence)
        self.assertTrue(any("exactly the three" in item for item in failures), failures)

    def test_v2_requires_exactly_base_three_plus_four_mission_results(self) -> None:
        evidence = self.evidence(COMPARE.RUNTIME_ACCEPTANCE_V2, mission=True)
        self.assertEqual([], COMPARE.validate_runtime_acceptance_results(evidence))

        evidence["runtime_acceptance"].pop()
        failures = COMPARE.validate_runtime_acceptance_results(evidence)
        self.assertTrue(any("exactly the seven" in item for item in failures), failures)
        self.assertTrue(any("operator_closure" in item for item in failures), failures)

    def test_v2_dispatch_requires_receipt_no_mission_and_no_monitoring(self) -> None:
        for field, bad_value in (
            ("task_id", ""),
            ("mission_created", True),
            ("monitoring_after_receipt", True),
        ):
            with self.subTest(field=field):
                evidence = self.evidence(COMPARE.RUNTIME_ACCEPTANCE_V2, mission=True)
                result = next(
                    item
                    for item in evidence["runtime_acceptance"]
                    if item["name"] == "installed_mission_dispatch_only_default"
                )
                result[field] = bad_value
                failures = COMPARE.validate_runtime_acceptance_results(evidence)
                self.assertTrue(any("no Mission record" in item for item in failures))

    def test_v2_watch_requires_exact_identity_cursor_and_zero_actions(self) -> None:
        for field, bad_value in (
            ("mode", "supervised"),
            ("mission_record_persisted", False),
            ("exact_identity_verified", False),
            ("runtime_project_id", "synthetic-project"),
            ("task_id", ""),
            ("host_id", ""),
            ("cursor", ""),
            ("follow_up_count", 1),
            ("external_action_count", 1),
        ):
            with self.subTest(field=field):
                evidence = self.evidence(COMPARE.RUNTIME_ACCEPTANCE_V2, mission=True)
                result = next(
                    item
                    for item in evidence["runtime_acceptance"]
                    if item["name"] == "installed_mission_watch_only_synchronization"
                )
                result[field] = bad_value
                failures = COMPARE.validate_runtime_acceptance_results(evidence)
                self.assertTrue(any("persist exact identity" in item for item in failures))

    def test_v2_supervised_requires_valid_fan_in_exactly_once_and_ignores_free_text(self) -> None:
        for field, bad_value in (
            ("mode", "watch_only"),
            ("declared_dependency", False),
            ("required_outputs_schema_valid", False),
            ("required_validation_passed", False),
            ("all_criteria_assigned", False),
            ("all_criteria_passed", False),
            ("blocked_or_degraded_rejected", False),
            ("handoff_after_required_fan_in", False),
            ("dependent_handoff_count", 0),
            ("dependent_handoff_count", 2),
            ("non_artifact_resolver_null", False),
            ("artifact_resolver_binding_verified", False),
            ("artifact_tamper_replay_rejected", False),
            ("producer_provenance_verified", False),
            ("core_materialized_artifact_refs", False),
            ("child_supplied_canonical_ref_rejected", False),
            ("blocked_or_stale_consumer_non_actionable", False),
            ("free_text_ignored", False),
            ("external_action_count", 1),
        ):
            with self.subTest(field=field, bad_value=bad_value):
                evidence = self.evidence(COMPARE.RUNTIME_ACCEPTANCE_V2, mission=True)
                result = next(
                    item
                    for item in evidence["runtime_acceptance"]
                    if item["name"] == "installed_mission_supervised_fan_in"
                )
                result[field] = bad_value
                failures = COMPARE.validate_runtime_acceptance_results(evidence)
                self.assertTrue(any("declared dependent exactly once" in item for item in failures))

    def test_v2_closure_requires_review_ready_wait_and_explicit_close(self) -> None:
        for field, bad_value in (
            ("pre_close_status", "complete"),
            ("awaiting_operator_closure", False),
            ("automatic_closure", True),
            ("explicit_close_authorized", False),
            ("post_close_status", "review_ready"),
        ):
            with self.subTest(field=field):
                evidence = self.evidence(COMPARE.RUNTIME_ACCEPTANCE_V2, mission=True)
                result = next(
                    item
                    for item in evidence["runtime_acceptance"]
                    if item["name"] == "installed_mission_operator_closure"
                )
                result[field] = bad_value
                failures = COMPARE.validate_runtime_acceptance_results(evidence)
                self.assertTrue(any("explicit close alone" in item for item in failures))

    def test_unknown_schema_duplicate_names_and_failed_status_fail_closed(self) -> None:
        evidence = self.evidence("flightdeck.runtime-acceptance/v3", mission=True)
        evidence["runtime_acceptance"][1]["name"] = evidence["runtime_acceptance"][0]["name"]
        evidence["runtime_acceptance"][2]["status"] = "failed"

        failures = COMPARE.validate_runtime_acceptance_results(evidence)

        self.assertTrue(any("schema_version" in item for item in failures))
        self.assertTrue(any("duplicate assertion names" in item for item in failures))
        self.assertTrue(any("status must be 'passed'" in item for item in failures))


if __name__ == "__main__":
    unittest.main()
