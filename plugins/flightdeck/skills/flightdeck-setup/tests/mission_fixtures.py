"""Deterministic Mission fixtures for local acceptance and stress tests.

This module is deliberately test-only.  It models the installed Codex UI port
with injected observations so source validation never opens projects, creates
real tasks, waits on live threads, or mutates an external environment.
"""

from __future__ import annotations

import copy
import hashlib
import json
import random
import re
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


EXPECTED_CAPABILITY = "flightdeck.codex-ui-observer/v1"
EXPECTED_OBSERVATION_SCHEMA = "flightdeck.mission-observation/v1"
WAIT_BATCH_SIZE = 8
MAX_WAIT_TARGETS = 50
MAX_ACTIONS_PER_CYCLE = 100
MAX_RETRIES = 3
MAX_FORWARDED_BYTES = 4096
MAX_CYCLE_SECONDS = 2.0
STALE_AFTER_MISSES = 2

MODES = {"dispatch_only", "watch_only", "supervised"}
OBSERVED_STATES = {
    "running",
    "completed",
    "needs_approval",
    "blocked",
    "failed",
    "interrupted",
    "runtime_error",
    "review_ready",
}

FORBIDDEN_ACTIONS = {
    "commit",
    "push",
    "pull_request",
    "pull_request_comment",
    "publish",
    "deploy",
    "environment_mutation",
    "external_communication",
    "compliance_submission",
    "risk_acceptance",
    "closure",
}

DOMAIN_CONTRACTS: dict[str, dict[str, Any]] = {
    "compliance": {
        "companion": "flightdeck-compliance",
        "reference_semantics": "metadata_only",
        "unresolved_consumer_policy": "stop_or_colocate",
        "outputs": {
            "control_assessment_ref",
            "evidence_index_ref",
            "poam_candidate_ref",
            "artifact_ref",
        },
        "denied": {"compliance_submission", "risk_acceptance", "closure"},
    },
    "patching": {
        "companion": "flightdeck-patching",
        "reference_semantics": "metadata_only",
        "unresolved_consumer_policy": "stop_or_colocate",
        "outputs": {
            "scan_ref",
            "sbom_ref",
            "image_digest_ref",
            "runtime_validation_ref",
        },
        "denied": {"deploy", "risk_acceptance", "closure"},
    },
    "development": {
        "companion": "flightdeck-development",
        "reference_semantics": "metadata_only",
        "unresolved_consumer_policy": "stop_or_colocate",
        "outputs": {"contract_ref", "test_ref", "validation_ref"},
        "denied": {"pull_request", "deploy", "closure"},
    },
    "ci_cd": {
        "companion": "flightdeck-ci",
        "reference_semantics": "metadata_only",
        "unresolved_consumer_policy": "stop_or_colocate",
        "outputs": {"failure_ref", "patch_ref", "check_ref"},
        "denied": {"publish", "deploy", "closure"},
    },
    "platform_runtime": {
        "companion": "flightdeck-platform",
        "reference_semantics": "metadata_only",
        "unresolved_consumer_policy": "stop_or_colocate",
        "outputs": {"plan_ref", "render_ref", "runtime_observation_ref"},
        "denied": {"environment_mutation", "deploy", "closure"},
    },
    "research": {
        "companion": "flightdeck-research",
        "reference_semantics": "metadata_only",
        "unresolved_consumer_policy": "stop_or_colocate",
        "outputs": {"source_ledger_ref", "decision_brief_ref"},
        "denied": {"external_communication", "closure"},
    },
    "documents": {
        "companion": "flightdeck-artifacts",
        "reference_semantics": "metadata_only",
        "unresolved_consumer_policy": "stop_or_colocate",
        "outputs": {
            "docx_ref",
            "pdf_ref",
            "xlsx_ref",
            "render_inspection_ref",
        },
        "denied": {"publish", "external_communication", "closure"},
    },
}

_SAFE_IDENTIFIER = re.compile(r"\A[a-z][a-z0-9_-]{0,62}\Z")
_SAFE_TITLE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9 .,:_/-]{0,126}\Z")
_SAFE_REFERENCE = re.compile(r"\Aref://[a-z0-9][a-z0-9._/-]{0,239}\Z")
_SECRET_MARKERS = (
    "authorization: bearer",
    "begin private key",
    "api_key=",
    "access_token=",
    "password=",
    "secret=",
)


class ContractError(ValueError):
    """Raised when a synthetic input violates the Mission contract."""


class SimulatedCrash(RuntimeError):
    """Raised at an injected two-phase boundary."""


def _safe_identifier(value: Any, field_name: str) -> str:
    if not isinstance(value, str) or not _SAFE_IDENTIFIER.fullmatch(value):
        raise ContractError(f"{field_name} is not a safe identifier")
    return value


def _safe_title(value: Any) -> str:
    if not isinstance(value, str) or not _SAFE_TITLE.fullmatch(value):
        raise ContractError("title contains untrusted control text")
    return value


def _canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _contains_secret(value: Any) -> bool:
    lowered = json.dumps(value, sort_keys=True).casefold()
    return any(marker in lowered for marker in _SECRET_MARKERS)


def _validate_reference(value: Any) -> str:
    if not isinstance(value, str) or not _SAFE_REFERENCE.fullmatch(value):
        raise ContractError("output reference must be a compact ref:// value")
    if _contains_secret(value):
        raise ContractError("secret-bearing output reference rejected")
    return value


def _topological(nodes: dict[str, dict[str, Any]]) -> list[str]:
    visiting: set[str] = set()
    visited: set[str] = set()
    ordered: list[str] = []

    def visit(node_id: str) -> None:
        if node_id in visited:
            return
        if node_id in visiting:
            raise ContractError("mission dependency cycle")
        visiting.add(node_id)
        for dependency in nodes[node_id]["dependencies"]:
            if dependency not in nodes:
                raise ContractError(f"unknown dependency: {dependency}")
            visit(dependency)
        visiting.remove(node_id)
        visited.add(node_id)
        ordered.append(node_id)

    for node_id in sorted(nodes):
        visit(node_id)
    return ordered


@dataclass
class InjectedCodexUI:
    """Scripted Codex UI observations and idempotent action effects."""

    capability: str = EXPECTED_CAPABILITY
    observation_schema: str = EXPECTED_OBSERVATION_SCHEMA
    waits: list[Any] = field(default_factory=list)
    create_calls: list[dict[str, Any]] = field(default_factory=list)
    follow_up_calls: list[dict[str, Any]] = field(default_factory=list)
    project_rechecks: list[dict[str, Any]] = field(default_factory=list)
    wait_calls: list[list[dict[str, Any]]] = field(default_factory=list)
    action_calls: list[dict[str, Any]] = field(default_factory=list)
    unique_effects: dict[str, dict[str, Any]] = field(default_factory=dict)

    def create_thread(self, node_id: str, *, pending: bool = False) -> dict[str, str]:
        request = {"node_id": node_id, "pending": pending}
        self.create_calls.append(copy.deepcopy(request))
        if pending:
            return {"clientThreadId": f"client-{node_id}-001"}
        return {
            "threadId": f"thread-{node_id}-001",
            "hostId": "host-synthetic",
        }

    def follow_up_task(self, request: dict[str, Any]) -> None:
        self.follow_up_calls.append(copy.deepcopy(request))

    def recheck_project(
        self,
        *,
        logical_project_key: str,
        runtime_project_id: str,
        project_path: str,
    ) -> dict[str, Any]:
        if runtime_project_id == logical_project_key:
            raise ContractError("runtime project identity must remain distinct")
        if not project_path.startswith("/"):
            raise ContractError("project recheck requires an exact absolute path")
        result = {
            "logical_project_key": logical_project_key,
            "runtime_project_id": runtime_project_id,
            "project_path": project_path,
            "source": "refreshed_live_project_list_exact_path",
            "verified": True,
        }
        self.project_rechecks.append(copy.deepcopy(result))
        return result

    def wait_threads(self, targets: list[dict[str, Any]]) -> Any:
        for target in targets:
            if set(target) - {"threadId", "hostId", "afterCursor"}:
                raise ContractError("wait target has unknown adapter fields")
            if not target.get("threadId") or not target.get("hostId"):
                raise ContractError("wait target requires exact thread and host identity")
        self.wait_calls.append(copy.deepcopy(targets))
        if not self.waits:
            return {"timedOut": True, "observations": []}
        response = self.waits.pop(0)
        if isinstance(response, BaseException):
            raise response
        return copy.deepcopy(response)

    def deliver(self, action: dict[str, Any]) -> dict[str, Any]:
        self.action_calls.append(copy.deepcopy(action))
        key = action["dedupe_key"]
        if key not in self.unique_effects:
            self.unique_effects[key] = copy.deepcopy(action)
        return {"dedupe_key": key, "status": "delivered"}


class DurableMission:
    """A compact, lock-protected synthetic Mission state machine."""

    def __init__(
        self,
        mission_id: str,
        *,
        title: str,
        mode: str,
        nodes: Iterable[dict[str, Any]],
        now: float = 0.0,
    ) -> None:
        self._lock = threading.RLock()
        mission_id = _safe_identifier(mission_id, "mission_id")
        title = _safe_title(title)
        if mode not in MODES:
            raise ContractError("unsupported mission mode")

        normalized_nodes: dict[str, dict[str, Any]] = {}
        for raw in nodes:
            node_id = _safe_identifier(raw.get("id"), "node id")
            domain = raw.get("domain")
            if domain not in DOMAIN_CONTRACTS:
                raise ContractError(f"unsupported mission domain: {domain}")
            dependencies = [
                _safe_identifier(item, "dependency")
                for item in raw.get("dependencies", [])
            ]
            allowed_outputs = set(raw.get("allowed_outputs", []))
            if not allowed_outputs:
                allowed_outputs = set(DOMAIN_CONTRACTS[domain]["outputs"])
            if not allowed_outputs.issubset(DOMAIN_CONTRACTS[domain]["outputs"]):
                raise ContractError("node output type is not allowed by its domain")
            normalized_nodes[node_id] = {
                "id": node_id,
                "domain": domain,
                "companion": DOMAIN_CONTRACTS[domain]["companion"],
                "dependencies": dependencies,
                "required": bool(raw.get("required", True)),
                "checkout": raw.get("checkout"),
                "mutation": bool(raw.get("mutation", False)),
                "allowed_outputs": sorted(allowed_outputs),
                "dispatch": None,
                "observed": {
                    "state": "pending_dispatch",
                    "status_code": None,
                    "sequence": -1,
                    "cursor": None,
                    "observed_at": None,
                    "misses": 0,
                    "loaded_state": None,
                    "output_refs": [],
                },
            }

        order = _topological(normalized_nodes)
        self._reject_checkout_conflicts(normalized_nodes, order)
        self.state: dict[str, Any] = {
            "schema_version": "flightdeck.mission/v1",
            "id": mission_id,
            "title": title,
            "mode": mode,
            "status": "running",
            "operator_closed": False,
            "created_at": now,
            "nodes": normalized_nodes,
            "order": order,
            "seen_observations": [],
            "outbox": [],
            "action_receipts": [],
            "metrics": {
                "duplicates": 0,
                "out_of_order": 0,
                "unchanged_timeouts": 0,
                "host_errors": 0,
                "retries": 0,
                "forwarded_bytes": 0,
            },
        }

    @staticmethod
    def _reject_checkout_conflicts(
        nodes: dict[str, dict[str, Any]], order: list[str]
    ) -> None:
        ancestors: dict[str, set[str]] = {node_id: set() for node_id in nodes}
        for node_id in order:
            for dependency in nodes[node_id]["dependencies"]:
                ancestors[node_id].add(dependency)
                ancestors[node_id].update(ancestors[dependency])
        mutators = [node for node in nodes.values() if node["mutation"] and node["checkout"]]
        for index, left in enumerate(mutators):
            for right in mutators[index + 1 :]:
                if left["checkout"] != right["checkout"]:
                    continue
                if (
                    left["id"] not in ancestors[right["id"]]
                    and right["id"] not in ancestors[left["id"]]
                ):
                    raise ContractError("parallel mutation conflict on the same checkout")

    @classmethod
    def from_snapshot(cls, snapshot: dict[str, Any]) -> "DurableMission":
        instance = cls.__new__(cls)
        instance._lock = threading.RLock()
        instance.state = copy.deepcopy(snapshot)
        return instance

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return copy.deepcopy(self.state)

    def snapshot_bytes(self) -> bytes:
        return _canonical_bytes(self.snapshot())

    def write_snapshot(self, path: Path) -> None:
        path.write_bytes(self.snapshot_bytes() + b"\n")

    def record_dispatch(self, node_id: str, receipt: dict[str, Any]) -> None:
        with self._lock:
            node = self._node(node_id)
            allowed = {
                "logical_project_key",
                "runtime_project_id",
                "checkout_path",
                "thread_id",
                "client_thread_id",
                "host_id",
                "dispatch_state",
            }
            if set(receipt) - allowed:
                raise ContractError("dispatch receipt has unknown fields")
            logical = _safe_identifier(receipt.get("logical_project_key"), "logical project key")
            runtime = receipt.get("runtime_project_id")
            if not isinstance(runtime, str) or not runtime or runtime == logical:
                raise ContractError("runtime project identity must be opaque and distinct")
            checkout = receipt.get("checkout_path")
            if not isinstance(checkout, str) or not checkout.startswith("/"):
                raise ContractError("dispatch checkout must be an exact absolute path")
            thread_id = receipt.get("thread_id")
            client_id = receipt.get("client_thread_id")
            dispatch_state = receipt.get("dispatch_state", "confirmed")
            if dispatch_state not in {"confirmed", "pending_unknown"}:
                raise ContractError("unsupported dispatch state")
            host_id = receipt.get("host_id")
            existing = node["dispatch"]

            if existing is not None and existing.get("dispatch_state") == "pending_unknown":
                if dispatch_state != "confirmed" or not thread_id or not client_id:
                    raise ContractError(
                        "pending dispatch reconciliation requires original client and resolved thread identity"
                    )
                if client_id != existing.get("client_thread_id"):
                    raise ContractError("pending dispatch client identity conflict")
                for field in ("logical_project_key", "runtime_project_id", "checkout_path"):
                    if receipt.get(field) != existing.get(field):
                        raise ContractError("pending dispatch routing identity conflict")
                if not isinstance(host_id, str) or not host_id:
                    raise ContractError("resolved dispatch requires host identity")
                compact = {
                    "logical_project_key": logical,
                    "runtime_project_id": runtime,
                    "checkout_path": checkout,
                    "thread_id": thread_id,
                    "host_id": host_id,
                    "dispatch_state": "confirmed",
                }
            elif existing is not None:
                compact = copy.deepcopy(receipt)
                if existing != compact:
                    raise ContractError("dispatch identity conflict")
            elif dispatch_state == "pending_unknown":
                if not client_id or thread_id or host_id:
                    raise ContractError(
                        "pending dispatch requires client identity without thread or host identity"
                    )
                compact = copy.deepcopy(receipt)
            else:
                if not thread_id or client_id:
                    raise ContractError("confirmed dispatch requires exactly one thread identity")
                if not isinstance(host_id, str) or not host_id:
                    raise ContractError("confirmed dispatch requires host identity")
                compact = copy.deepcopy(receipt)

            if _contains_secret(compact):
                raise ContractError("secret-bearing dispatch receipt rejected")
            node["dispatch"] = compact
            node["observed"]["state"] = (
                "dispatch_pending"
                if compact["dispatch_state"] == "pending_unknown"
                else "dispatched"
            )

    def monitor(
        self,
        adapter: InjectedCodexUI,
        *,
        now: float,
        max_targets: int = MAX_WAIT_TARGETS,
        crash_at: str | None = None,
    ) -> dict[str, Any]:
        started = time.monotonic()
        with self._lock:
            if self.state["mode"] == "dispatch_only":
                return {"monitored": False, "reason": "dispatch_only", "batches": []}
            if adapter.capability != EXPECTED_CAPABILITY:
                raise ContractError("Codex UI capability drift")
            if adapter.observation_schema != EXPECTED_OBSERVATION_SCHEMA:
                raise ContractError("Codex UI observation schema drift")
            targets = self._wait_targets()
            bounded = len(targets) > max_targets
            targets = targets[:max_targets]

        batches = [targets[index : index + WAIT_BATCH_SIZE] for index in range(0, len(targets), WAIT_BATCH_SIZE)]
        accepted = 0
        for batch in batches:
            if time.monotonic() - started > MAX_CYCLE_SECONDS:
                break
            try:
                response = adapter.wait_threads(batch)
            except InterruptedError:
                return {
                    "monitored": True,
                    "interrupted": True,
                    "bounded": bounded,
                    "batches": [len(item) for item in batches],
                }
            if not isinstance(response, dict):
                raise ContractError("malformed wait envelope")
            if response.get("timedOut") is True and not response.get("observations"):
                with self._lock:
                    self.state["metrics"]["unchanged_timeouts"] += 1
                continue
            observations = response.get("observations")
            if not isinstance(observations, list):
                raise ContractError("malformed observation envelope")
            for observation in observations:
                if self.apply_observation(observation, now=now):
                    accepted += 1

        with self._lock:
            self._mark_missing(now)
            self._derive_status()
            self._plan_actions()
            if crash_at == "after_plan":
                raise SimulatedCrash("after_plan")
        delivered = self.deliver_outbox(adapter, crash_at=crash_at)
        return {
            "monitored": True,
            "bounded": bounded,
            "targets": len(targets),
            "batches": [len(item) for item in batches],
            "accepted": accepted,
            "delivered": delivered,
            "status": self.state["status"],
        }

    def _wait_targets(self) -> list[dict[str, Any]]:
        targets: list[dict[str, Any]] = []
        for node_id in self.state["order"]:
            node = self.state["nodes"][node_id]
            dispatch = node["dispatch"]
            if dispatch is None or dispatch.get("dispatch_state") != "confirmed":
                continue
            target = {
                "threadId": dispatch["thread_id"],
                "hostId": dispatch["host_id"],
            }
            if node["observed"]["cursor"] is not None:
                target["afterCursor"] = node["observed"]["cursor"]
            targets.append(target)
        return targets

    def apply_observation(self, observation: Any, *, now: float) -> bool:
        if not isinstance(observation, dict):
            raise ContractError("malformed observation")
        allowed = {
            "schema_version",
            "node_id",
            "host_id",
            "thread_id",
            "sequence",
            "cursor",
            "state",
            "status_code",
            "outcome_code",
            "loaded_state",
            "dedupe_key",
            "output_refs",
            "error",
            "summary",
            "free_text",
        }
        if set(observation) - allowed:
            raise ContractError("observation has unknown fields")
        if observation.get("schema_version") != EXPECTED_OBSERVATION_SCHEMA:
            raise ContractError("observation schema drift")
        node_id = observation.get("node_id")
        with self._lock:
            node = self._node(node_id)
            dispatch = node["dispatch"]
            if dispatch is None:
                raise ContractError("observation precedes dispatch")
            if dispatch.get("dispatch_state") != "confirmed":
                raise ContractError("pending dispatch is not observable before reconciliation")
            if observation.get("host_id") != dispatch["host_id"]:
                self.state["metrics"]["host_errors"] += 1
                return False
            if dispatch.get("thread_id") and observation.get("thread_id") != dispatch["thread_id"]:
                self.state["metrics"]["host_errors"] += 1
                return False
            sequence = observation.get("sequence")
            if not isinstance(sequence, int) or sequence < 0:
                raise ContractError("observation sequence must be non-negative")
            dedupe_key = observation.get("dedupe_key")
            if not isinstance(dedupe_key, str) or not dedupe_key:
                raise ContractError("observation dedupe key required")
            if dedupe_key in self.state["seen_observations"]:
                self.state["metrics"]["duplicates"] += 1
                return False
            if sequence <= node["observed"]["sequence"]:
                self.state["metrics"]["out_of_order"] += 1
                return False
            state = observation.get("state")
            if state not in OBSERVED_STATES:
                raise ContractError("unknown child state")
            status_code = _safe_identifier(
                observation.get("status_code"), "observation status code"
            )
            outcome_code = observation.get("outcome_code")
            final_state = state in {"review_ready", "failed"}
            if final_state and outcome_code != status_code:
                raise ContractError("final observation status code must equal outcome code")
            if not final_state and outcome_code is not None:
                raise ContractError("nonterminal observation cannot carry outcome code")
            loaded_state = observation.get("loaded_state", "loaded")
            if loaded_state not in {"loaded", "notLoaded"}:
                raise ContractError("unknown loaded state")
            output_refs = self._validated_outputs(node, observation.get("output_refs", []))
            if state not in {"review_ready", "failed"} and output_refs:
                raise ContractError("nonterminal observation cannot carry child output")
            if _contains_secret(observation):
                raise ContractError("secret-bearing child output rejected")

            # Only the compact allowlist below is persisted.  Child summary,
            # commentary, error/free text, and evidence bodies are display-only.
            node["observed"].update(
                {
                    "state": state,
                    "status_code": status_code,
                    "sequence": sequence,
                    "cursor": observation.get("cursor"),
                    "observed_at": now,
                    "misses": 0 if loaded_state == "loaded" else node["observed"]["misses"] + 1,
                    "loaded_state": loaded_state,
                    "output_refs": output_refs,
                }
            )
            self.state["seen_observations"].append(dedupe_key)
            if len(self.state["seen_observations"]) > 1024:
                self.state["seen_observations"] = self.state["seen_observations"][-1024:]
            return True

    @staticmethod
    def _validated_outputs(node: dict[str, Any], outputs: Any) -> list[dict[str, str]]:
        if not isinstance(outputs, list):
            raise ContractError("output references must be an array")
        normalized: list[dict[str, str]] = []
        for output in outputs:
            if not isinstance(output, dict) or set(output) != {"type", "ref"}:
                raise ContractError("output reference envelope is malformed")
            output_type = output["type"]
            if output_type not in node["allowed_outputs"]:
                raise ContractError("child output type is not allowlisted")
            normalized.append({"type": output_type, "ref": _validate_reference(output["ref"])})
        if len(_canonical_bytes(normalized)) > MAX_FORWARDED_BYTES:
            raise ContractError("forwarded output budget exceeded")
        return normalized

    def _mark_missing(self, now: float) -> None:
        for node in self.state["nodes"].values():
            observed = node["observed"]
            if (
                node["dispatch"] is None
                or node["dispatch"].get("dispatch_state") != "confirmed"
                or observed["state"] in {"completed", "review_ready", "failed"}
            ):
                continue
            if observed["observed_at"] is None or observed["observed_at"] < now:
                observed["misses"] += 1

    def _derive_status(self) -> None:
        if self.state["operator_closed"]:
            self.state["status"] = "complete"
            return
        required = [node for node in self.state["nodes"].values() if node["required"]]
        states = [node["observed"]["state"] for node in required]
        if any(state == "runtime_error" for state in states):
            self.state["status"] = "runtime_failure"
        elif any(state == "failed" for state in states):
            self.state["status"] = "failed_validation"
        elif any(state == "needs_approval" for state in states):
            self.state["status"] = "needs_approval"
        elif any(state in {"blocked", "interrupted"} for state in states):
            self.state["status"] = "blocked"
        elif any(node["observed"]["misses"] >= STALE_AFTER_MISSES for node in required):
            self.state["status"] = "stale"
        elif required and all(state in {"completed", "review_ready"} for state in states):
            self.state["status"] = "review_ready"
        else:
            self.state["status"] = "running"

    def _plan_actions(self) -> None:
        if self.state["mode"] != "supervised":
            return
        existing = {item["dedupe_key"] for item in self.state["outbox"]}
        planned = 0
        for node_id in self.state["order"]:
            if planned >= MAX_ACTIONS_PER_CYCLE:
                break
            node = self.state["nodes"][node_id]
            if node["observed"]["state"] != "dispatched":
                continue
            dependencies = [self.state["nodes"][item] for item in node["dependencies"]]
            required = [item for item in dependencies if item["required"]]
            if not required or not all(
                item["observed"]["state"] in {"completed", "review_ready"}
                for item in required
            ):
                continue
            output_refs = [
                output
                for dependency in dependencies
                for output in dependency["observed"]["output_refs"]
            ]
            payload = {"target_node": node_id, "output_refs": output_refs}
            payload_size = len(_canonical_bytes(payload))
            if payload_size > MAX_FORWARDED_BYTES:
                continue
            key = hashlib.sha256(_canonical_bytes(payload)).hexdigest()
            if key in existing:
                continue
            self.state["outbox"].append(
                {
                    "dedupe_key": key,
                    "kind": "resume_declared_dependency",
                    "target_node": node_id,
                    "output_refs": output_refs,
                    "status": "pending",
                    "attempts": 0,
                }
            )
            existing.add(key)
            planned += 1

    def deliver_outbox(
        self, adapter: InjectedCodexUI, *, crash_at: str | None = None
    ) -> int:
        delivered = 0
        with self._lock:
            actions = [item for item in self.state["outbox"] if item["status"] == "pending"]
        for action in actions[:MAX_ACTIONS_PER_CYCLE]:
            if action["attempts"] >= MAX_RETRIES:
                continue
            receipt = adapter.deliver(action)
            if crash_at == "after_deliver_before_ack":
                raise SimulatedCrash("after_deliver_before_ack")
            with self._lock:
                current = next(
                    item for item in self.state["outbox"] if item["dedupe_key"] == action["dedupe_key"]
                )
                current["attempts"] += 1
                current["status"] = "acknowledged"
                self.state["metrics"]["retries"] += max(0, current["attempts"] - 1)
                self.state["metrics"]["forwarded_bytes"] += len(
                    _canonical_bytes(current["output_refs"])
                )
                if not any(
                    item["dedupe_key"] == receipt["dedupe_key"]
                    for item in self.state["action_receipts"]
                ):
                    self.state["action_receipts"].append(receipt)
                delivered += 1
        return delivered

    def request_action(self, action: str) -> None:
        if action in FORBIDDEN_ACTIONS:
            raise ContractError("external action requires separate authorization")
        raise ContractError("unknown action")

    def close(self, note: str, *, operator: bool) -> None:
        with self._lock:
            if not operator:
                raise ContractError("only an operator may close a mission")
            if self.state["status"] not in {"review_ready", "complete"}:
                raise ContractError("mission is not review-ready")
            if not _SAFE_TITLE.fullmatch(note):
                raise ContractError("closure note is untrusted")
            self.state["operator_closed"] = True
            self.state["status"] = "complete"

    def _node(self, node_id: Any) -> dict[str, Any]:
        if not isinstance(node_id, str) or node_id not in self.state["nodes"]:
            raise ContractError("unknown mission node")
        return self.state["nodes"][node_id]


def node(
    node_id: str,
    *,
    domain: str = "development",
    dependencies: Iterable[str] = (),
    required: bool = True,
    checkout: str | None = None,
    mutation: bool = False,
    allowed_outputs: Iterable[str] = (),
) -> dict[str, Any]:
    return {
        "id": node_id,
        "domain": domain,
        "dependencies": list(dependencies),
        "required": required,
        "checkout": checkout,
        "mutation": mutation,
        "allowed_outputs": list(allowed_outputs),
    }


def receipt(
    node_id: str,
    *,
    pending: bool = False,
    reconcile_pending: bool = False,
    host_id: str = "host-synthetic",
    checkout_path: str | None = None,
) -> dict[str, Any]:
    value = {
        "logical_project_key": f"project-{node_id}",
        "runtime_project_id": f"opaque-runtime-{node_id}-001",
        "checkout_path": checkout_path or f"/synthetic/checkouts/{node_id}",
        "dispatch_state": "pending_unknown" if pending else "confirmed",
    }
    if pending and reconcile_pending:
        raise ValueError("pending and reconcile_pending are mutually exclusive")
    if pending:
        value["client_thread_id"] = f"client-{node_id}-001"
    elif reconcile_pending:
        value["client_thread_id"] = f"client-{node_id}-001"
        value["thread_id"] = f"thread-{node_id}-001"
        value["host_id"] = host_id
    else:
        value["thread_id"] = f"thread-{node_id}-001"
        value["host_id"] = host_id
    return value


def observation(
    node_id: str,
    sequence: int,
    state: str,
    *,
    cursor: str | None = None,
    host_id: str = "host-synthetic",
    loaded_state: str = "loaded",
    status_code: str | None = None,
    outputs: Iterable[dict[str, str]] = (),
    dedupe_key: str | None = None,
    **untrusted: Any,
) -> dict[str, Any]:
    value: dict[str, Any] = {
        "schema_version": EXPECTED_OBSERVATION_SCHEMA,
        "node_id": node_id,
        "host_id": host_id,
        "sequence": sequence,
        "cursor": cursor or f"cursor-{node_id}-{sequence}",
        "state": state,
        "status_code": status_code or state.replace("runtime_error", "runtime_failure"),
        "loaded_state": loaded_state,
        "dedupe_key": dedupe_key or f"event-{node_id}-{sequence}",
        "output_refs": list(outputs),
    }
    if state in {"review_ready", "failed"}:
        value["outcome_code"] = value["status_code"]
    value["thread_id"] = f"thread-{node_id}-001"
    value.update(untrusted)
    return value


def dispatch_all(mission: DurableMission, *, pending: set[str] | None = None) -> None:
    pending = pending or set()
    for node_id in mission.state["order"]:
        mission.record_dispatch(node_id, receipt(node_id, pending=node_id in pending))


def ordinary_dispatch(adapter: InjectedCodexUI) -> dict[str, Any]:
    """Model the pre-Mission default: return a receipt and never monitor."""

    return {
        "dispatch_required": True,
        "stop_after_dispatch": True,
        "monitoring_permitted": False,
        "mission_created": False,
        "adapter_wait_calls": len(adapter.wait_calls),
        "adapter_action_calls": len(adapter.action_calls),
    }


def consumer_resolution(
    domain: str,
    *,
    consumer_resolved: bool,
    same_task_validation_available: bool,
    fresh_project_recheck_verified: bool = False,
) -> dict[str, Any]:
    """Return a non-mutating decision for typed-reference consumption."""

    if domain not in DOMAIN_CONTRACTS:
        raise ContractError(f"unsupported mission domain: {domain}")
    contract = DOMAIN_CONTRACTS[domain]
    base = {
        "domain": domain,
        "reference_semantics": contract["reference_semantics"],
        "content_transport_authorized": False,
        "active_graph_expansion": False,
        "new_mission_proposal": False,
    }
    if consumer_resolved and not fresh_project_recheck_verified:
        return {**base, "action": "stop", "reason": "fresh_project_recheck_required"}
    if consumer_resolved:
        return {**base, "action": "use_declared_consumer"}
    if same_task_validation_available:
        return {
            **base,
            "action": "co_locate_validation",
            "validation_scope": "producer_task",
        }
    return {**base, "action": "stop", "reason": "consumer_not_resolved"}


def resolve_typed_reference(
    binding: dict[str, Any] | None,
    *,
    producer_host_id: str,
    consumer_host_id: str,
    authorization_boundary: str,
) -> dict[str, Any]:
    """Validate a metadata-only resolver binding without transporting content."""

    base = {
        "reference_semantics": "metadata_only",
        "content_transported": False,
        "external_action": False,
    }
    if not isinstance(binding, dict):
        return {**base, "resolved": False, "reason": "resolver_binding_required"}
    if binding.get("authorization_boundary") != authorization_boundary:
        return {**base, "resolved": False, "reason": "resolver_boundary_mismatch"}
    kind = binding.get("kind")
    if kind == "same_host":
        host_id = binding.get("host_id")
        if host_id != producer_host_id or host_id != consumer_host_id:
            return {**base, "resolved": False, "reason": "same_host_mismatch"}
        if not binding.get("workspace_ref"):
            return {**base, "resolved": False, "reason": "workspace_ref_required"}
        return {**base, "resolved": True, "kind": kind}
    if kind == "external":
        if binding.get("approved") is not True or not binding.get("system"):
            return {**base, "resolved": False, "reason": "external_resolver_not_approved"}
        return {**base, "resolved": True, "kind": kind}
    return {**base, "resolved": False, "reason": "unsupported_resolver_binding"}


def run_stress(
    *,
    seed: int,
    mission_count: int,
    children_per_mission: int,
    replayed_snapshots: int,
) -> dict[str, Any]:
    """Run the bounded deterministic load/replay profile used by release gates."""

    started = time.monotonic()
    missions: list[DurableMission] = []
    for mission_index in range(mission_count):
        mission = DurableMission(
            f"mission-{mission_index}",
            title=f"Synthetic mission {mission_index}",
            mode="watch_only",
            nodes=[node(f"child-{index}") for index in range(children_per_mission)],
        )
        dispatch_all(mission)
        missions.append(mission)

    replay = missions[0]
    replay.apply_observation(observation("child-0", 100, "running"), now=1.0)
    randomizer = random.Random(seed)
    for index in range(replayed_snapshots):
        if randomizer.randrange(2):
            event = observation(
                "child-0",
                100,
                "failed",
                dedupe_key="event-child-0-100",
            )
        else:
            event = observation(
                "child-0",
                randomizer.randrange(0, 100),
                "failed",
                dedupe_key=f"reordered-{index}",
            )
        replay.apply_observation(event, now=2.0)

    elapsed = time.monotonic() - started
    metrics = replay.state["metrics"]
    return {
        "seed": seed,
        "missions": mission_count,
        "children_per_mission": children_per_mission,
        "total_children": sum(len(item.state["nodes"]) for item in missions),
        "replayed_snapshots": replayed_snapshots,
        "duplicates": metrics["duplicates"],
        "out_of_order": metrics["out_of_order"],
        "dedupe_window": len(replay.state["seen_observations"]),
        "snapshot_bytes": len(replay.snapshot_bytes()),
        "elapsed_seconds": round(elapsed, 6),
        "limits": {
            "wait_batch_size": WAIT_BATCH_SIZE,
            "wait_targets": MAX_WAIT_TARGETS,
            "actions_per_cycle": MAX_ACTIONS_PER_CYCLE,
            "retries": MAX_RETRIES,
            "forwarded_bytes": MAX_FORWARDED_BYTES,
            "cycle_seconds": MAX_CYCLE_SECONDS,
        },
    }
