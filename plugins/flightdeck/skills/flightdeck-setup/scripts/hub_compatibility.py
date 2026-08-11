#!/usr/bin/env python3
"""Check a preserved generated Hub against requested Flightdeck capabilities."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Any


SCHEMA_VERSION = "flightdeck.hub-compatibility/v1"
RESULT_SCHEMA_VERSION = "flightdeck.hub-compatibility-result/v1"
SKILL_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TARGET_CONTRACT = (
    SKILL_ROOT / "assets" / "flightdeck-template" / "hub" / "compatibility.json"
)
COMMAND_TIMEOUT = 30
CONTRACT_SCHEMA = "hub/schemas/hub-compatibility.schema.json"
CAPABILITY_ID = re.compile(
    r"^flightdeck\.(command|document)\.[a-z0-9-]+\.v[0-9]+$"
)
FALLBACK_MODES = {
    "bundled_reference",
    "compatibility_report_only",
    "manual_exact_path_handoff",
    "stop_and_plan_migration",
}


class ContractError(ValueError):
    """A compatibility contract is missing required structure."""


def relative_path(value: Any, *, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ContractError(f"{field} must be a non-empty relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts:
        raise ContractError(f"{field} must be a contained relative path")
    return value


def load_contract(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ContractError(f"contract is unreadable: {error.__class__.__name__}") from error
    except json.JSONDecodeError as error:
        raise ContractError(f"contract is invalid JSON: {error.msg}") from error
    if not isinstance(value, dict):
        raise ContractError("contract root must be an object")
    if value.get("schema_version") != SCHEMA_VERSION:
        raise ContractError(f"contract must use {SCHEMA_VERSION}")
    if value.get("schema") != CONTRACT_SCHEMA:
        raise ContractError(f"contract schema must be {CONTRACT_SCHEMA}")
    if value.get("product") != "flightdeck":
        raise ContractError("contract product must be flightdeck")
    if not isinstance(value.get("template_version"), str) or not value["template_version"]:
        raise ContractError("contract template_version must be a non-empty string")
    runtime = value.get("runtime_capabilities")
    adapters = runtime.get("adapters") if isinstance(runtime, dict) else None
    codex = adapters.get("codex") if isinstance(adapters, dict) else None
    omp = adapters.get("omp") if isinstance(adapters, dict) else None
    controls = codex.get("optional_controls") if isinstance(codex, dict) else None
    channels = codex.get("structured_channels") if isinstance(codex, dict) else None
    if (
        set(runtime or {}) != {"primary_runtime", "adapters"}
        or runtime.get("primary_runtime") != "codex"
        or set(adapters or {}) != {"codex", "omp"}
        or not isinstance(codex, dict)
        or set(codex) != {"available", "optional_controls", "structured_channels"}
        or codex.get("available") is not True
        or channels != ["flightdeck.runtime.work-recommendation/v1"]
        or not isinstance(controls, list)
        or len(controls) != len(set(controls))
        or any(control not in {"model", "reasoning_effort"} for control in controls)
        or not isinstance(omp, dict)
        or set(omp) != {"available"}
        or omp.get("available") is not False
    ):
        raise ContractError("contract runtime_capabilities are invalid")
    capabilities = value.get("capabilities")
    if not isinstance(capabilities, dict) or not capabilities:
        raise ContractError("contract capabilities must be a non-empty object")
    for capability_id, capability in capabilities.items():
        match = CAPABILITY_ID.fullmatch(capability_id) if isinstance(capability_id, str) else None
        if match is None:
            raise ContractError("capability IDs must use the versioned flightdeck command or document namespace")
        if not isinstance(capability, dict):
            raise ContractError(f"capability {capability_id} must be an object")
        kind = capability.get("kind")
        if kind not in {"command", "document"}:
            raise ContractError(f"capability {capability_id} has an unsupported kind")
        if match.group(1) != kind:
            raise ContractError(f"capability {capability_id} kind must match its ID")
        if not isinstance(capability.get("description"), str) or not capability["description"]:
            raise ContractError(f"capability {capability_id} description is required")
        if not isinstance(capability.get("declaration_required", False), bool):
            raise ContractError(
                f"capability {capability_id} declaration_required must be a boolean"
            )
        probe = capability.get("probe")
        if not isinstance(probe, dict):
            raise ContractError(f"capability {capability_id} probe must be an object")
        if kind == "command":
            if not isinstance(probe.get("help_contains"), str) or not probe["help_contains"]:
                raise ContractError(f"capability {capability_id} requires probe.help_contains")
            if "path" in probe:
                raise ContractError(f"capability {capability_id} command probe cannot use path")
        if kind == "document":
            relative_path(probe.get("path"), field=f"capability {capability_id} probe.path")
            if "help_contains" in probe:
                raise ContractError(f"capability {capability_id} document probe cannot use help_contains")
        managed_paths = capability.get("managed_paths")
        if not isinstance(managed_paths, list) or not managed_paths:
            raise ContractError(f"capability {capability_id} managed_paths must be a non-empty array")
        if len(managed_paths) != len(set(managed_paths)):
            raise ContractError(f"capability {capability_id} managed_paths must be unique")
        for index, managed_path in enumerate(managed_paths):
            relative_path(
                managed_path,
                field=f"capability {capability_id} managed_paths[{index}]",
            )
        fallback = capability.get("fallback")
        if not isinstance(fallback, dict) or fallback.get("mode") not in FALLBACK_MODES:
            raise ContractError(f"capability {capability_id} fallback.mode is required")
        if fallback["mode"] == "bundled_reference":
            relative_path(
                fallback.get("reference"),
                field=f"capability {capability_id} fallback.reference",
            )
        elif "reference" in fallback:
            raise ContractError(
                f"capability {capability_id} fallback.reference requires bundled_reference mode"
            )
    return value


def command_help(hub_root: Path) -> tuple[str | None, str | None]:
    executable = hub_root / "bin" / "flightdeck"
    if not executable.is_file():
        return None, "Hub command entrypoint is missing"
    if not os.access(executable, os.X_OK):
        return None, "Hub command entrypoint is not executable"
    try:
        result = subprocess.run(
            [str(executable), "help"],
            cwd=hub_root,
            text=True,
            capture_output=True,
            check=False,
            timeout=COMMAND_TIMEOUT,
            env={**os.environ, "LC_ALL": "C"},
        )
    except subprocess.TimeoutExpired:
        return None, f"Hub help command timed out after {COMMAND_TIMEOUT} seconds"
    except OSError as error:
        return None, f"Hub help command could not start: {error.__class__.__name__}"
    if result.returncode != 0:
        return None, f"Hub help command exited {result.returncode}"
    return result.stdout, None


def requested_capabilities(raw: list[str], target: dict[str, Any]) -> list[str]:
    values: list[str] = []
    for item in raw:
        values.extend(part.strip() for part in item.split(",") if part.strip())
    if not values:
        values = sorted(target["capabilities"])
    unknown = sorted(set(values) - set(target["capabilities"]))
    if unknown:
        raise ContractError("unknown requested capabilities: " + ", ".join(unknown))
    return sorted(set(values))


def migration_plan(
    missing: list[dict[str, Any]],
    *,
    target_contract: Path,
) -> dict[str, Any]:
    if not missing:
        return {
            "required": False,
            "authorized": False,
            "automatic_changes": False,
            "mode": "not_required",
            "target_contract": str(target_contract),
            "managed_paths_to_compare": [],
            "excluded_user_state": [],
            "steps": [],
            "prohibited": [],
        }

    managed_paths = sorted(
        {
            path
            for item in missing
            for path in item.get("managed_paths", [])
        }
        | {"hub/compatibility.json"}
    )
    return {
        "required": True,
        "authorized": False,
        "automatic_changes": False,
        "mode": "plan_and_diff",
        "target_contract": str(target_contract),
        "managed_paths_to_compare": managed_paths,
        "excluded_user_state": [
            "attached repositories",
            "compliance program workspaces and evidence",
            "hub/reports",
            "hub/state",
            "hub/tasks",
            "workload repository contents",
        ],
        "steps": [
            "Keep the preserved Hub read-only and retain its ignored and user-owned state.",
            "Obtain separate authorization for Hub migration planning.",
            "Generate the target template only at a separate empty path.",
            "Diff the reported managed paths and compatibility contract against that separate candidate.",
            "Review the exact file changes, validation plan, backup, and rollback before any apply.",
            "Obtain separate authorization before applying a reviewed migration to the preserved Hub.",
        ],
        "prohibited": [
            "Do not run setup or bootstrap against the preserved Hub.",
            "Do not regenerate, overwrite, or mutate the preserved Hub automatically.",
            "Do not treat plugin installation or upgrade as Hub migration authorization.",
        ],
    }


def compatibility_result(
    *,
    hub_root: Path,
    target_contract_path: Path,
    required: list[str],
    target: dict[str, Any],
    require_contract: bool = False,
) -> dict[str, Any]:
    hub_contract_path = hub_root / "hub" / "compatibility.json"
    hub_exists = hub_root.is_dir()
    hub_contract: dict[str, Any] | None = None
    contract_state = "absent"
    contract_error: str | None = None
    if hub_contract_path.is_file():
        try:
            hub_contract = load_contract(hub_contract_path)
            contract_state = "declared"
        except ContractError as error:
            contract_state = "invalid"
            contract_error = str(error)

    requires_command = any(
        target["capabilities"][capability_id]["kind"] == "command"
        for capability_id in required
    )
    help_text = help_error = None
    if hub_exists and contract_state != "invalid" and requires_command:
        help_text, help_error = command_help(hub_root)

    available: list[dict[str, Any]] = []
    missing: list[dict[str, Any]] = []
    if require_contract and contract_state != "declared":
        reason = "Hub compatibility contract is missing"
        if contract_state == "invalid":
            reason = f"Hub compatibility contract is invalid: {contract_error}"
        missing.append(
            {
                "id": "flightdeck.hub-contract.v1",
                "kind": "identity",
                "description": "Versioned generated-Hub identity and capability declaration.",
                "reason": reason,
                "fallback": {"mode": "stop_and_plan_migration"},
                "managed_paths": ["hub/compatibility.json"],
            }
        )
    for capability_id in required:
        capability = target["capabilities"][capability_id]
        failure: str | None = None
        if not hub_exists:
            failure = "Hub root is unavailable"
        elif contract_state == "invalid":
            failure = f"Hub compatibility contract is invalid: {contract_error}"
        elif hub_contract is not None and capability_id not in hub_contract["capabilities"]:
            failure = "capability is not declared by the Hub compatibility contract"
        elif hub_contract is None and capability.get("declaration_required", False):
            failure = "capability requires an explicit Hub compatibility declaration"
        elif capability["kind"] == "command":
            signature = capability["probe"]["help_contains"]
            if help_text is None:
                failure = help_error or "Hub command help is unavailable"
            elif signature not in help_text:
                failure = f"Hub help does not advertise the required command signature: {signature.strip()}"
        else:
            document = capability["probe"]["path"]
            if not (hub_root / document).is_file():
                failure = f"required Hub document is missing: {document}"

        item = {
            "id": capability_id,
            "kind": capability["kind"],
            "description": capability["description"],
        }
        if failure:
            missing.append(
                {
                    **item,
                    "reason": failure,
                    "fallback": capability["fallback"],
                    "managed_paths": capability["managed_paths"],
                }
            )
        else:
            available.append(
                {
                    **item,
                    "verification": (
                        "declared_and_probed"
                        if hub_contract is not None
                        else "legacy_probe_only"
                    ),
                }
            )

    compatible = not missing
    status = "incompatible"
    if compatible:
        status = "compatible" if hub_contract is not None else "compatible_inferred"
    hub_identity = {
        "product": hub_contract.get("product") if hub_contract else "flightdeck",
        "template_version": hub_contract.get("template_version") if hub_contract else None,
        "contract_state": contract_state,
        "contract_path": str(hub_contract_path),
    }
    if contract_error:
        hub_identity["contract_error"] = contract_error

    fallback_modes = sorted(
        {item["fallback"]["mode"] for item in missing if item.get("fallback")}
    )
    return {
        "schema_version": RESULT_SCHEMA_VERSION,
        "read_only": True,
        "compatible": compatible,
        "status": status,
        "hub": {
            "root": str(hub_root),
            "identity": hub_identity,
        },
        "target": {
            "contract_path": str(target_contract_path),
            "template_version": target["template_version"],
        },
        "requirements": {
            "requested": required,
            "available": available,
            "missing": missing,
        },
        "fallback": {
            "allowed_modes": fallback_modes,
            "instructions": [
                "Do not invoke a capability reported missing.",
                "Use only the fallback declared for that capability.",
                "Preserve owner dispatch, approval, and no-monitoring boundaries.",
            ],
        },
        "migration": migration_plan(missing, target_contract=target_contract_path),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hub-root", required=True, type=Path)
    parser.add_argument(
        "--require",
        action="append",
        default=[],
        help="Required capability ID; repeat or provide a comma-separated list",
    )
    parser.add_argument(
        "--target-contract",
        type=Path,
        default=DEFAULT_TARGET_CONTRACT,
        help="Target compatibility contract; defaults to the bundled generated-Hub template",
    )
    parser.add_argument(
        "--require-contract",
        action="store_true",
        help="Require a declared generated-Hub compatibility identity instead of legacy inference",
    )
    args = parser.parse_args()

    try:
        target_contract_path = args.target_contract.expanduser().resolve(strict=True)
        target = load_contract(target_contract_path)
        required = requested_capabilities(args.require, target)
    except (ContractError, OSError) as error:
        print(
            json.dumps(
                {
                    "schema_version": RESULT_SCHEMA_VERSION,
                    "read_only": True,
                    "compatible": False,
                    "status": "checker_error",
                    "error": str(error),
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 2

    hub_root = args.hub_root.expanduser().resolve(strict=False)
    result = compatibility_result(
        hub_root=hub_root,
        target_contract_path=target_contract_path,
        required=required,
        target=target,
        require_contract=args.require_contract,
    )
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["compatible"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
