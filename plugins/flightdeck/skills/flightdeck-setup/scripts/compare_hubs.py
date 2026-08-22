#!/usr/bin/env python3
"""Compare mandatory Flightdeck behavior using neutral mappings and functional probes."""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from scan_debranding import (
    PrivateNeutralization,
    load_private_neutralization,
)

PRIVATE_NEUTRALIZATION = PrivateNeutralization()
SOURCE_CONTROL_TOKEN = "source-hub"

ROUTING_CONST_OVERRIDES = {
    (
        "properties.routing.properties.project_registration_policy",
        "automatic",
    ): "capability_detect_then_verify",
    (
        "properties.routing.properties.dynamic_repository_policy",
        "clone_register_launch",
    ): "resolve_clone_verify_bridge_register_launch",
    (
        "properties.routing.properties.launch_failure_policy",
        "manual_handoff_after_verified_failure",
    ): "one_manual_action_after_verified_retry",
}

EXPECTED_SKILLS = {
    "flightdeck",
    "flightdeck-setup",
    "flightdeck-doctor",
    "flightdeck-repo-bridge",
    "flightdeck-plan",
    "flightdeck-review",
    "flightdeck-ci",
    "flightdeck-platform",
    "flightdeck-db",
    "flightdeck-development",
    "flightdeck-charts",
    "flightdeck-patching",
    "flightdeck-research",
    "flightdeck-compliance",
    "flightdeck-artifacts",
    "flightdeck-stig",
    "flightdeck-automations",
    "flightdeck-upgrade",
}

TEXT_SUFFIXES = {
    ".md",
    ".txt",
    ".json",
    ".yaml",
    ".yml",
    ".rb",
    ".py",
    ".sh",
    ".toml",
    ".xml",
    ".ckl",
    "",
}

def configure_private_neutralization(path: Path | None) -> None:
    global PRIVATE_NEUTRALIZATION
    global SOURCE_CONTROL_TOKEN
    PRIVATE_NEUTRALIZATION = load_private_neutralization(path)
    SOURCE_CONTROL_TOKEN = (
        PRIVATE_NEUTRALIZATION.source_control_token or "source-hub"
    )


def neutral_string(value: str) -> str:
    output = value
    for source, replacement in PRIVATE_NEUTRALIZATION.replacements:
        output = re.sub(re.escape(source), replacement, output, flags=re.IGNORECASE)
    output = re.sub(
        re.escape(SOURCE_CONTROL_TOKEN),
        "flightdeck",
        output,
        flags=re.IGNORECASE,
    )
    output = re.sub(
        r"\bflightdeckRegistry\b",
        "flightdeckRegistry",
        output,
        flags=re.IGNORECASE,
    )
    output = re.sub(r"\bcodex_project_id\b", "codex_project_key", output)
    output = re.sub(r"\bdefault_project_id\b", "default_project_key", output)
    output = re.sub(r"\bproject_id\b", "runtime_project_id", output)
    output = re.sub(
        r"\bdefault_coordination_project\b",
        "default_coordination_project_key",
        output,
    )
    output = re.sub(r"\bcoordination_project\b", "coordination_project_key", output)
    output = output.replace("flightdeck.organization.dev", "flightdeck.dev")
    output = output.replace("remote_host_checks_in_scope", "remote_environment_checks_in_scope")
    return output


def neutral(value: Any) -> Any:
    if isinstance(value, dict):
        return {neutral_string(str(key)): neutral(item) for key, item in value.items()}
    if isinstance(value, list):
        return [neutral(item) for item in value]
    if isinstance(value, str):
        return neutral_string(value)
    return value


def run(
    arguments: list[str],
    *,
    cwd: Path,
    timeout: int = 300,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        cwd=cwd,
        text=True,
        capture_output=True,
        check=False,
        timeout=timeout,
        env={**os.environ, "LC_ALL": "C"},
    )


def copy_source_test_snapshot(
    source: Path,
    candidate: Path,
    destination: Path,
) -> tuple[int, str]:
    """Copy source control-plane files without local Hub payloads."""
    result = run(["git", "ls-files", "-z"], cwd=source, timeout=60)
    if result.returncode != 0:
        raise ValueError(
            "source Hub tracked-file inventory failed: "
            f"{result.stderr.strip() or result.returncode}"
        )
    names = [name for name in result.stdout.split("\0") if name]
    if not names:
        candidate_intersection = {
            path.relative_to(candidate).as_posix()
            for path in sorted(candidate.rglob("*"))
            if path.is_file() and (source / path.relative_to(candidate)).is_file()
        }
        source_control_plane = {
            path.relative_to(source).as_posix()
            for relative_root in (
                "lib",
                "tests",
                "hub/automations",
                "hub/schemas",
                "hub/templates",
                "hub/workflows",
            )
            for path in sorted((source / relative_root).rglob("*"))
            if path.is_file() and path.name != ".DS_Store"
        }
        source_control_plane.update(
            path.relative_to(source).as_posix()
            for path in sorted(source.glob("*hub.yaml"))
            if path.is_file()
        )
        if (source / "AGENTS.md").is_file():
            source_control_plane.add("AGENTS.md")
        names = sorted(candidate_intersection | source_control_plane)
        mode = "candidate_managed_intersection"
    else:
        mode = "tracked_current_worktree"
    if not names:
        raise ValueError("source Hub has no safe control-plane files")
    for name in names:
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"unsafe tracked source path: {name}")
        source_path = source / relative
        destination_path = destination / relative
        destination_path.parent.mkdir(parents=True, exist_ok=True)
        if source_path.is_symlink():
            target = os.readlink(source_path)
            target_path = Path(target)
            if target_path.is_absolute() or ".." in target_path.parts:
                raise ValueError(f"unsafe tracked source symlink: {name}")
            destination_path.symlink_to(target)
        elif source_path.is_file():
            shutil.copy2(source_path, destination_path)
        else:
            raise ValueError(f"tracked source path is not a regular file: {name}")
    return len(names), mode


def atomic_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".flightdeck-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def require_ignored_output(path: Path) -> None:
    if ".flightdeck-local" not in path.resolve().parts:
        raise ValueError(f"comparison output must be under .flightdeck-local: {path}")


def load_yaml(path: Path) -> Any:
    script = (
        "value=YAML.safe_load(File.read(ARGV.fetch(0)),"
        " permitted_classes:[Date,Time], permitted_symbols:[], aliases:false);"
        "puts JSON.generate(value)"
    )
    result = run(
        ["ruby", "-rjson", "-ryaml", "-rdate", "-e", script, str(path)],
        cwd=path.parent,
    )
    if result.returncode != 0:
        raise ValueError(f"invalid YAML {path}: {result.stderr.strip()}")
    return json.loads(result.stdout)


def load_structured(path: Path) -> Any:
    if path.suffix.lower() == ".json":
        return json.loads(path.read_text(encoding="utf-8"))
    return load_yaml(path)


def walk_schema(
    value: Any,
    path: tuple[str, ...] = (),
    *,
    required: dict[str, set[str]],
    enums: dict[str, set[str]],
    consts: dict[str, Any],
    strict: set[str],
    types: dict[str, str],
    refs: dict[str, str],
    properties: dict[str, set[str]],
    constraints: dict[str, dict[str, Any]],
    combinators: dict[str, dict[str, int]],
) -> None:
    if isinstance(value, dict):
        key = ".".join(path) or "$"
        if isinstance(value.get("required"), list):
            required[key] = {neutral_string(str(item)) for item in value["required"]}
        if isinstance(value.get("enum"), list):
            enums[key] = {neutral_string(str(item)) for item in value["enum"]}
        if "const" in value:
            consts[key] = neutral(value["const"])
        if value.get("additionalProperties") is False:
            strict.add(key)
        if isinstance(value.get("type"), str):
            types[key] = value["type"]
        if isinstance(value.get("$ref"), str):
            refs[key] = value["$ref"]
        if isinstance(value.get("properties"), dict):
            properties[key] = {
                neutral_string(str(property_name))
                for property_name in value["properties"]
            }
        constraint_values = {
            name: neutral(value[name])
            for name in (
                "format",
                "maxItems",
                "maxLength",
                "maxProperties",
                "maximum",
                "minItems",
                "minLength",
                "minProperties",
                "minimum",
                "pattern",
                "uniqueItems",
            )
            if name in value
        }
        if constraint_values:
            constraints[key] = constraint_values
        combinator_values = {
            name: len(value[name])
            for name in ("allOf", "anyOf", "oneOf")
            if isinstance(value.get(name), list)
        }
        if combinator_values:
            combinators[key] = combinator_values
        for child_key, child in value.items():
            walk_schema(
                child,
                path + (neutral_string(str(child_key)),),
                required=required,
                enums=enums,
                consts=consts,
                strict=strict,
                types=types,
                refs=refs,
                properties=properties,
                constraints=constraints,
                combinators=combinators,
            )
    elif isinstance(value, list):
        for index, child in enumerate(value):
            walk_schema(
                child,
                path + (str(index),),
                required=required,
                enums=enums,
                consts=consts,
                strict=strict,
                types=types,
                refs=refs,
                properties=properties,
                constraints=constraints,
                combinators=combinators,
            )


def schema_signature(path: Path) -> dict[str, Any]:
    data = neutral(load_structured(path))
    required: dict[str, set[str]] = {}
    enums: dict[str, set[str]] = {}
    consts: dict[str, Any] = {}
    strict: set[str] = set()
    types: dict[str, str] = {}
    refs: dict[str, str] = {}
    properties: dict[str, set[str]] = {}
    constraints: dict[str, dict[str, Any]] = {}
    combinators: dict[str, dict[str, int]] = {}
    walk_schema(
        data,
        required=required,
        enums=enums,
        consts=consts,
        strict=strict,
        types=types,
        refs=refs,
        properties=properties,
        constraints=constraints,
        combinators=combinators,
    )
    return {
        "required": required,
        "enums": enums,
        "consts": consts,
        "strict": strict,
        "types": types,
        "refs": refs,
        "properties": properties,
        "constraints": constraints,
        "combinators": combinators,
        "defs": set((data.get("$defs") or {}).keys()),
    }


def compare_schema(source: Path, candidate: Path) -> tuple[bool, dict[str, Any]]:
    left = schema_signature(source)
    right = schema_signature(candidate)
    missing_required: dict[str, list[str]] = {}
    for path, values in left["required"].items():
        missing = values - right["required"].get(path, set())
        if missing:
            missing_required[path] = sorted(missing)
    missing_enums: dict[str, list[str]] = {}
    for path, values in left["enums"].items():
        missing = values - right["enums"].get(path, set())
        if missing:
            missing_enums[path] = sorted(missing)
    missing_properties: dict[str, list[str]] = {}
    for path, values in left["properties"].items():
        missing = values - right["properties"].get(path, set())
        if missing:
            missing_properties[path] = sorted(missing)
    mismatched_consts: dict[str, dict[str, Any]] = {}
    for path, value in left["consts"].items():
        actual = right["consts"].get(path)
        expected = ROUTING_CONST_OVERRIDES.get((path, str(value)), value)
        provider_generalized = (
            path == "$defs.repository.properties.provider"
            and value == "github"
            and right["refs"].get(path) == "#/$defs/id"
        )
        if provider_generalized:
            continue
        if actual != expected:
            mismatched_consts[path] = {"source": value, "expected": expected, "candidate": actual}
    missing_strict = sorted(left["strict"] - right["strict"])
    missing_defs = sorted(left["defs"] - right["defs"])
    accepted_constraint_generalizations: dict[str, str] = {}
    mismatched_constraints: dict[str, dict[str, Any]] = {}
    for path, value in left["constraints"].items():
        actual = right["constraints"].get(path)
        if actual == value:
            continue
        candidate_root = candidate.parents[2]
        repository_store = candidate_root / "lib" / "flightdeck" / "repository_store.rb"
        store_text = (
            repository_store.read_text(encoding="utf-8")
            if repository_store.is_file()
            else ""
        )
        if (
            candidate.name == "flightdeck.schema.json"
            and path == "$defs.repository.properties.remote_url"
            and value.get("pattern", "").startswith("^https://github")
            and all(
                anchor in store_text
                for anchor in (
                    "reject_embedded_credentials!",
                    "unsupported remote URL scheme",
                    "hosted_url",
                )
            )
        ):
            accepted_constraint_generalizations[path] = (
                "Hosted-source URL pattern maps to provider-aware argument-safe runtime "
                "validation for hosted, generic Git, and existing-local adapters."
            )
            continue
        if (
            candidate.name == "flightdeck.schema.json"
            and path == "properties.repositories"
            and value == {"minProperties": 1}
            and actual is None
            and (candidate.parent / "local-repositories.schema.json").is_file()
        ):
            accepted_constraint_generalizations[path] = (
                "The portable bootstrap registry may start empty; typed dynamic repository "
                "records are validated separately before atomic onboarding."
            )
            continue
        mismatched_constraints[path] = {"source": value, "candidate": actual}
    mismatched_combinators = {
        path: {"source": value, "candidate": right["combinators"].get(path)}
        for path, value in left["combinators"].items()
        if right["combinators"].get(path) != value
    }
    accepted_reference_generalizations: dict[str, str] = {}
    mismatched_refs = {}
    for path, value in left["refs"].items():
        actual = right["refs"].get(path)
        if actual == value:
            continue
        if (
            candidate.name == "task.schema.json"
            and path == "$defs.executionUnit.properties.runtime_project_id"
            and value == "#/$defs/id"
            and actual == "#/$defs/runtimeProjectId"
        ):
            accepted_reference_generalizations[path] = (
                "The source project identifier maps to a distinct opaque runtime "
                "projectId type; the additive logical_project_key retains Hub identity."
            )
            continue
        mismatched_refs[path] = {"source": value, "candidate": actual}
    passed = not any(
        (
            missing_required,
            missing_enums,
            missing_properties,
            mismatched_consts,
            mismatched_constraints,
            mismatched_combinators,
            mismatched_refs,
            missing_strict,
            missing_defs,
        )
    )
    return passed, {
        "source_required_contracts": len(left["required"]),
        "candidate_required_contracts": len(right["required"]),
        "source_enum_contracts": len(left["enums"]),
        "candidate_enum_contracts": len(right["enums"]),
        "missing_required": missing_required,
        "missing_enum_values": missing_enums,
        "missing_properties": missing_properties,
        "mismatched_constants": mismatched_consts,
        "mismatched_constraints": mismatched_constraints,
        "accepted_constraint_generalizations": accepted_constraint_generalizations,
        "accepted_reference_generalizations": accepted_reference_generalizations,
        "mismatched_combinators": mismatched_combinators,
        "mismatched_references": mismatched_refs,
        "missing_strict_objects": missing_strict,
        "missing_definitions": missing_defs,
    }


def workflow_signature(path: Path) -> dict[str, Any]:
    data = neutral(load_yaml(path))
    roles = {}
    for name, role in (data.get("default_repo_roles") or {}).items():
        roles[name] = {
            "required": role.get("required"),
            "condition": role.get("condition"),
            "execution_context": role.get("execution_context"),
            "persistent_task": role.get("persistent_task"),
            "responsibility_count": len(role.get("responsibilities") or []),
        }
    gates = {}
    for name, gate in (data.get("gates") or {}).items():
        gates[name] = {
            "blocking": gate.get("blocking"),
            "required_fields": sorted(gate.get("required_fields") or []),
            "requirement_count": len(gate.get("requires") or []),
        }
    approvals = {
        name: {"policy": value.get("policy"), "rationale_present": bool(value.get("rationale"))}
        for name, value in (data.get("approval_boundaries") or {}).items()
    }
    evidence = {
        name: {
            "category": value.get("category"),
            "required": value.get("required"),
            "producer_role": value.get("producer_role"),
            "description_present": bool(value.get("description")),
        }
        for name, value in (data.get("expected_evidence") or {}).items()
    }
    states = {
        name: {
            "entry_gates": sorted((value or {}).get("entry_gates") or []),
            "exit_gates": sorted((value or {}).get("exit_gates") or []),
            "terminal": bool((value or {}).get("terminal")),
        }
        for name, value in (data.get("states") or {}).items()
    }
    defaults = data.get("task_defaults") or {}
    return {
        "task_type": data.get("task_type"),
        "supported_workloads": set(data.get("supported_workloads") or []),
        "initial_state": data.get("initial_state"),
        "required_fields": sorted(data.get("required_fields") or []),
        "default_execution": (defaults.get("spec") or {}).get("execution") or {},
        "default_policies": (defaults.get("spec") or {}).get("policies") or {},
        "states": states,
        "transitions": {
            key: sorted(value or []) for key, value in (data.get("transitions") or {}).items()
        },
        "roles": roles,
        "gates": gates,
        "approval_boundaries": approvals,
        "expected_evidence": evidence,
    }


def workflow_comparison(source: Path, candidate: Path) -> tuple[bool, dict[str, Any]]:
    left = workflow_signature(source)
    right = workflow_signature(candidate)
    workload_ok = left["supported_workloads"].issubset(right["supported_workloads"])
    keys = (
        "task_type",
        "initial_state",
        "required_fields",
        "default_execution",
        "default_policies",
        "states",
        "transitions",
        "roles",
        "gates",
        "approval_boundaries",
        "expected_evidence",
    )
    mismatches = [key for key in keys if left[key] != right[key]]
    return workload_ok and not mismatches, {
        "source_type": left["task_type"],
        "candidate_type": right["task_type"],
        "source_workloads": sorted(left["supported_workloads"]),
        "candidate_workloads": sorted(right["supported_workloads"]),
        "source_counts": {
            "states": len(left["states"]),
            "transitions": len(left["transitions"]),
            "roles": len(left["roles"]),
            "gates": len(left["gates"]),
            "approval_boundaries": len(left["approval_boundaries"]),
            "expected_evidence": len(left["expected_evidence"]),
        },
        "candidate_counts": {
            "states": len(right["states"]),
            "transitions": len(right["transitions"]),
            "roles": len(right["roles"]),
            "gates": len(right["gates"]),
            "approval_boundaries": len(right["approval_boundaries"]),
            "expected_evidence": len(right["expected_evidence"]),
        },
        "mismatched_fields": mismatches,
        "workload_coverage": workload_ok,
    }


def headings(path: Path) -> set[str]:
    output = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("#"):
            normalized = neutral_string(line.lstrip("#").strip().lower())
            normalized = re.sub(r"[^a-z0-9 ]+", " ", normalized)
            normalized = " ".join(normalized.split())
            normalized = {
                "parallel work": "dispatch and parallel work",
                "recommended plugins and skills": "plugins and skills",
                "vm workflow": "local and environment workflow",
                "task 1 create hub documentation structure": (
                    "task 1 create the hub documentation structure"
                ),
                "task 3 add workflow and repo bridge docs": (
                    "task 3 add routing and repository bridge guidance"
                ),
                "task 7 later repo bridge rollout": (
                    "task 7 roll out repository bridges"
                ),
                "task 8 add workload specific guides": (
                    "task 8 add workload specific guidance"
                ),
                "compliance rmf ato workbench implementation plan": (
                    "compliance rmf and ato workbench implementation plan"
                ),
                "task 1 create shared compliance methodology docs": (
                    "task 1 create shared compliance method"
                ),
                "task 2 create program workspace template": (
                    "task 2 create the program workspace template"
                ),
                "task 3 create copyable templates": (
                    "task 3 create reusable compliance templates"
                ),
                "task 4 update hub navigation": (
                    "task 4 update hub navigation and validate"
                ),
                "repo bridge": "repository bridge",
                "compliance rmf ato workbench design": (
                    "compliance rmf and ato workbench design"
                ),
                "default codex posture": "default operating posture",
                "emass template workflow": "authorization workbook workflow",
                "shared compliance docs": "shared compliance guides",
                "machine readable artifact sidecars": (
                    "structured compliance working records"
                ),
                "minimum sidecar fields": "minimum fields",
                "workbook sidecars": "workbook records",
                "consistency": "consistency and delivery",
                "dorganization status": "document status",
                "review notes": "internal working record",
                "dorganization implementation language": "implementation statement",
                "dorganization assessment note": "assessment note",
                "recommended reviewer action": "program action",
                "scenario one patch an data platform image from a repo never cloned": (
                    "scenario one patch a container image from a repository never cloned"
                ),
                (
                    "scenario two research application platform data platform and analytics "
                    "service on il6 eks under edge platform"
                ): "scenario two research a multi service deployment in a restricted environment",
                (
                    "scenario two research application platform data platform and analytics "
                    "service on il6 eks under edge platform edge"
                ): "scenario two research a multi service deployment in a restricted environment",
                (
                    "scenario three secure application platform console feature before github review"
                ): "scenario three secure a multi repository application feature before github review",
                (
                    "scenario three secure multi repository application feature before github review"
                ): "scenario three secure a multi repository application feature before github review",
            }.get(normalized, normalized)
            if normalized:
                output.add(normalized)
    return output


def documentation_mapping(source: Path, candidate: Path) -> tuple[bool, dict[str, Any]]:
    source_files = sorted((source / "docs").rglob("*.md"))
    candidate_files = sorted((candidate / "docs").rglob("*.md"))
    mappings: list[dict[str, Any]] = []
    unresolved: list[str] = []
    for source_path in source_files:
        source_headings = headings(source_path)
        best: tuple[float, Path | None, set[str]] = (0.0, None, set())
        for candidate_path in candidate_files:
            candidate_headings = headings(candidate_path)
            union = source_headings | candidate_headings
            score = len(source_headings & candidate_headings) / len(union) if union else 0.0
            if score > best[0]:
                best = (score, candidate_path, candidate_headings)
        source_rel = str(source_path.relative_to(source))
        candidate_rel = str(best[1].relative_to(candidate)) if best[1] else None
        missing = sorted(source_headings - best[2])
        passed = bool(best[1]) and best[0] >= 0.60 and len(missing) <= 1
        mappings.append(
            {
                "source": source_rel,
                "candidate": candidate_rel,
                "heading_similarity": round(best[0], 3),
                "missing_headings": missing,
                "passed": passed,
            }
        )
        if not passed:
            unresolved.append(source_rel)
    return not unresolved, {
        "mapped_documents": len(mappings),
        "unresolved_documents": unresolved,
        "mappings": mappings,
    }


def command_prefixes(root: Path) -> set[str]:
    executable = hub_executable(root)
    if executable is None:
        return set()
    result = run([str(executable), "help"], cwd=root)
    if result.returncode != 0:
        return set()
    output = set()
    prefix = f"bin/{executable.name} "
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped.startswith(prefix):
            continue
        words = stripped.split()
        if len(words) >= 3 and words[1] in {"task", "repo", "route", "bridge"}:
            output.add(" ".join(words[1:3]))
        else:
            output.add(words[1])
    return output


def doctor_finding_codes(root: Path) -> set[str]:
    codes: set[str] = set()
    families = {
        "automation",
        "bridge",
        "compliance",
        "handoff",
        "provider",
        "registry",
        "repo",
        "task",
        "workflow",
    }
    library = hub_library(root)
    if library is None:
        return set()
    for name in ("doctor.rb", "inspections.rb"):
        text = (library / name).read_text(encoding="utf-8")
        codes.update(
            neutral_string(value)
            for value in re.findall(r'"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"', text)
            if value.split(".", 1)[0] in families
        )
    return codes


def first_existing(*paths: Path) -> Path | None:
    return next((path for path in paths if path.exists()), None)


def hub_executable(root: Path) -> Path | None:
    return first_existing(
        root / "bin" / "flightdeck",
        root / "bin" / SOURCE_CONTROL_TOKEN,
    )


def hub_library(root: Path) -> Path | None:
    return first_existing(
        root / "lib" / "flightdeck",
        root / "lib" / SOURCE_CONTROL_TOKEN,
    )


def registry_schema(root: Path) -> Path:
    path = first_existing(
        root / "hub" / "schemas" / "flightdeck.schema.json",
        root / "hub" / "schemas" / f"{SOURCE_CONTROL_TOKEN}.schema.json",
    )
    if path is None:
        raise FileNotFoundError(f"registry schema not found under {root}")
    return path


def hub_test(root: Path) -> Path:
    path = first_existing(
        root / "tests" / "flightdeck_test.rb",
        root / "tests" / f"{SOURCE_CONTROL_TOKEN}_test.rb",
    )
    if path is None:
        raise FileNotFoundError(f"Hub test suite not found under {root}")
    return path


def source_workflow_map(source: Path) -> dict[str, Path]:
    output = {}
    for path in sorted((source / "hub" / "workflows").glob("*.yaml")):
        task_type = neutral_string(str(load_yaml(path).get("task_type", path.stem)))
        output[task_type] = path
    return output


def candidate_workflow_map(candidate: Path) -> dict[str, Path]:
    return {
        str(load_yaml(path).get("task_type", path.stem)): path
        for path in sorted((candidate / "hub" / "workflows").glob("*.yaml"))
    }


def parse_test_summary(text: str) -> dict[str, int]:
    match = re.search(
        r"(\d+) runs?,\s+(\d+) assertions?,\s+(\d+) failures?,\s+(\d+) errors?,\s+(\d+) skips?",
        text,
    )
    if not match:
        return {}
    keys = ("runs", "assertions", "failures", "errors", "skips")
    return dict(zip(keys, map(int, match.groups())))


def run_json(arguments: list[str], cwd: Path) -> tuple[bool, Any]:
    result = run(arguments, cwd=cwd)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        value = {"stdout": result.stdout, "stderr": result.stderr}
    return result.returncode == 0, value


def static_contains(paths: list[Path], required: dict[str, tuple[str, ...]]) -> tuple[bool, dict[str, Any]]:
    text = " ".join("\n".join(
        path.read_text(encoding="utf-8", errors="replace") for path in paths if path.is_file()
    ).split()).casefold()
    missing = {
        name: [value for value in values if value.casefold() not in text]
        for name, values in required.items()
    }
    missing = {name: values for name, values in missing.items() if values}
    return not missing, {"missing": missing}


def literal_mapping(path: Path, *names: str) -> dict[str, Any]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    wanted = {name.casefold() for name in names}
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Assign, ast.AnnAssign)):
            continue
        targets = node.targets if isinstance(node, ast.Assign) else [node.target]
        if not any(
            isinstance(target, ast.Name) and target.id.casefold() in wanted
            for target in targets
        ):
            continue
        value = ast.literal_eval(node.value)
        if isinstance(value, dict):
            return value
    return {}


def file_inventory(root: Path) -> list[str]:
    return [
        str(path.relative_to(root))
        for path in sorted(root.rglob("*"))
        if path.is_file()
        and not any(
            part in {".git", ".flightdeck-local", "__pycache__"} for part in path.parts
        )
    ]


def generated_template_alignment(
    candidate: Path, generated_hub: Path
) -> tuple[bool, dict[str, Any]]:
    mutable_paths = {Path("hub/repositories.yaml")}
    missing: list[str] = []
    mismatched: list[str] = []
    checked = 0
    for source in sorted(path for path in candidate.rglob("*") if path.is_file()):
        relative = source.relative_to(candidate)
        if relative in mutable_paths:
            continue
        checked += 1
        expected = source.read_bytes()
        if relative == Path("flightdeck.yaml"):
            escaped_root = json.dumps(
                str(generated_hub.resolve()), ensure_ascii=False
            )[1:-1].encode("utf-8")
            expected = expected.replace(b"__FLIGHTDECK_ROOT__", escaped_root)
        generated = generated_hub / relative
        if not generated.is_file():
            missing.append(str(relative))
        elif generated.read_bytes() != expected:
            mismatched.append(str(relative))
    return not missing and not mismatched, {
        "checked_managed_files": checked,
        "allowed_mutable_paths": sorted(str(path) for path in mutable_paths),
        "missing": missing,
        "mismatched": mismatched,
    }


def surface(
    name: str,
    *,
    status: str,
    mandatory: bool,
    scope: str,
    mapping: str,
    probe_name: str,
    passed: bool,
    evidence: Any,
) -> dict[str, Any]:
    if mandatory and status != "unresolved" and not passed:
        status = "unresolved"
    return {
        "surface": name,
        "status": status,
        "mandatory": mandatory,
        "scope": scope,
        "neutral_mapping": mapping,
        "probe": {"name": probe_name, "passed": passed, "evidence": evidence},
    }


def compare(args: argparse.Namespace) -> dict[str, Any]:
    source = args.source.resolve()
    candidate = args.candidate.resolve()
    plugin = args.plugin.resolve()
    setup_scripts = plugin / "skills" / "flightdeck-setup" / "scripts"
    records: list[dict[str, Any]] = []

    schema_details = {}
    schema_pass = True
    schema_pairs = {
        "task.schema.json": (
            source / "hub" / "schemas" / "task.schema.json",
            candidate / "hub" / "schemas" / "task.schema.json",
        ),
        "thread-links.schema.json": (
            source / "hub" / "schemas" / "thread-links.schema.json",
            candidate / "hub" / "schemas" / "thread-links.schema.json",
        ),
        "flightdeck.schema.json": (
            registry_schema(source),
            registry_schema(candidate),
        ),
    }
    for name, (source_schema, candidate_schema) in schema_pairs.items():
        passed, evidence = compare_schema(
            source_schema,
            candidate_schema,
        )
        schema_pass = schema_pass and passed
        schema_details[name] = evidence
    extra_schemas = {
        "bridges.schema.json",
        "bridge-setup-receipt.schema.json",
        "local-repositories.schema.json",
        "project-verifications.schema.json",
        "repository-declarations.schema.json",
        "compliance-artifact.schema.json",
    }
    extra_present = extra_schemas.issubset(
        {path.name for path in (candidate / "hub" / "schemas").glob("*.json")}
    )
    schema_pass = schema_pass and extra_present
    schema_details["candidate_dynamic_schemas"] = {
        "required": sorted(extra_schemas),
        "present": extra_present,
    }
    records.append(
        surface(
            "schema_semantics",
            status="matched",
            mandatory=True,
            scope="local",
            mapping="Source registry, task, and task-link contracts map to neutral equivalents; provider, local repository, bridge, and compliance sidecar contracts are additive.",
            probe_name="recursive required, enum, constant, strict-object, and definition comparison",
            passed=schema_pass,
            evidence=schema_details,
        )
    )

    source_workflows = source_workflow_map(source)
    candidate_workflows = candidate_workflow_map(candidate)
    workflow_details = {}
    workflow_pass = True
    for task_type, source_path in source_workflows.items():
        candidate_path = candidate_workflows.get(task_type)
        if not candidate_path:
            workflow_pass = False
            workflow_details[task_type] = {"missing_candidate": True}
            continue
        passed, evidence = workflow_comparison(source_path, candidate_path)
        workflow_pass = workflow_pass and passed
        workflow_details[task_type] = evidence
    chart_added = "charts" in candidate_workflows
    workflow_pass = workflow_pass and chart_added
    workflow_details["added_chart_workflow"] = chart_added
    records.append(
        surface(
            "workflow_semantics",
            status="matched",
            mandatory=True,
            scope="local",
            mapping="Each source adapter maps by neutral task type; the product-engineering adapter maps to development and remote-specific roles map to configured remote validation. Charts is additive.",
            probe_name="states, transitions, defaults, roles, gates, approvals, evidence, and workload coverage",
            passed=workflow_pass,
            evidence=workflow_details,
        )
    )

    source_commands = command_prefixes(source)
    candidate_commands = command_prefixes(candidate)
    commands_pass = bool(source_commands) and source_commands.issubset(candidate_commands)
    commands_pass = commands_pass and {"repo onboard", "bridge plan", "bridge install"}.issubset(
        candidate_commands
    )
    records.append(
        surface(
            "cli_behavior",
            status="matched",
            mandatory=True,
            scope="local",
            mapping="The source command verbs remain available; explicit onboarding and bridge mutation commands are additive while diagnostic and plan commands remain read-only.",
            probe_name="executed help surfaces and required command-prefix subset",
            passed=commands_pass,
            evidence={
                "source_commands": sorted(source_commands),
                "candidate_commands": sorted(candidate_commands),
                "missing": sorted(source_commands - candidate_commands),
            },
        )
    )

    with tempfile.TemporaryDirectory(
        prefix="flightdeck-source-test-snapshot-"
    ) as snapshot_directory:
        source_snapshot = Path(snapshot_directory)
        source_snapshot_count, source_snapshot_mode = copy_source_test_snapshot(
            source,
            candidate,
            source_snapshot,
        )
        source_tests = run(
            [
                "ruby",
                "-Ilib",
                str(hub_test(source_snapshot).relative_to(source_snapshot)),
            ],
            cwd=source_snapshot,
        )
    candidate_tests = run(
        ["ruby", "-Ilib", str(hub_test(candidate).relative_to(candidate))],
        cwd=candidate,
    )
    test_pass = source_tests.returncode == 0 and candidate_tests.returncode == 0
    records.append(
        surface(
            "task_lifecycle_and_transition_behavior",
            status="matched",
            mandatory=True,
            scope="local",
            mapping="Typed task creation, history validation, non-overwrite behavior, gate enforcement, and atomic transitions retain the source lifecycle vocabulary.",
            probe_name="source and candidate Ruby unit suites",
            passed=test_pass,
            evidence={
                "source": parse_test_summary(source_tests.stdout),
                "source_snapshot": {
                    "mode": source_snapshot_mode,
                    "files": source_snapshot_count,
                },
                "candidate": parse_test_summary(candidate_tests.stdout),
                "source_exit": source_tests.returncode,
                "candidate_exit": candidate_tests.returncode,
            },
        )
    )

    with tempfile.TemporaryDirectory(prefix="flightdeck-parity-") as acceptance_directory:
        acceptance_path = Path(acceptance_directory) / "acceptance.json"
        acceptance = run(
            ["python3", str(setup_scripts / "acceptance_harness.py"), "--json", str(acceptance_path)],
            cwd=plugin.parent.parent,
        )
        acceptance_data = (
            json.loads(acceptance_path.read_text(encoding="utf-8"))
            if acceptance_path.is_file()
            else {"locally_verified": False, "failure": acceptance.stderr}
        )
    acceptance_pass = acceptance.returncode == 0 and acceptance_data.get("locally_verified") is True
    probe_names = {
        item.get("name")
        for item in acceptance_data.get("probes", [])
        if item.get("status") == "passed"
    }
    doctor_required = {
        "fresh_doctor",
        "post_onboarding_doctor_no_errors",
        "doctor_no_fetch_caveat",
    }
    source_doctor_codes = doctor_finding_codes(source)
    candidate_doctor_codes = doctor_finding_codes(candidate)
    missing_doctor_codes = source_doctor_codes - candidate_doctor_codes
    records.append(
        surface(
            "doctor_findings_and_determinism",
            status="matched",
            mandatory=True,
            scope="local",
            mapping="Repository, task, compliance, bridge, automation, stable-finding, and no-fetch diagnostics map to neutral scopes with additive bridge safety checks.",
            probe_name="fresh and post-onboarding Doctor acceptance probes",
            passed=(
                acceptance_pass
                and doctor_required.issubset(probe_names)
                and not missing_doctor_codes
            ),
            evidence={
                "required_probes": sorted(doctor_required),
                "passed_probes": sorted(probe_names & doctor_required),
                "source_finding_codes": sorted(source_doctor_codes),
                "candidate_finding_codes": sorted(candidate_doctor_codes),
                "missing_finding_codes": sorted(missing_doctor_codes),
            },
        )
    )

    bridge_required = {
        "materialized_bridge_portable",
        "repo_native_preserves_authority_without_absolute_paths",
        "worktree_bridge_handoff_uses_verified_original_checkout",
        "clone_origin_branch_sha_clean",
        "bulk_bridge_plan_read_only",
        "bulk_bridge_idempotent_per_repo_receipt",
        "bulk_bridge_conflict_refusal_with_continue_policy",
    }
    records.append(
        surface(
            "bridge_modes_and_integrity",
            status="matched",
            mandatory=True,
            scope="local",
            mapping="The source local reference bridge maps to reference mode; application, chart, patching, and environment profiles map neutrally, with materialized and portable repo-native modes added.",
            probe_name="synthetic reference, materialized, and repo-native bridge installation",
            passed=acceptance_pass and bridge_required.issubset(probe_names),
            evidence={
                "required_probes": sorted(bridge_required),
                "passed_probes": sorted(probe_names & bridge_required),
            },
        )
    )

    bulk_required = {
        "bulk_bridge_plan_read_only",
        "bulk_bridge_idempotent_per_repo_receipt",
        "bulk_bridge_conflict_refusal_with_continue_policy",
        "bulk_project_registration_pending_and_verified",
        "logical_project_key_differs_from_runtime_project_id",
        "legacy_project_self_equality_rejected",
    }
    bulk_static_pass, bulk_static = static_contains(
        [
            plugin / "skills" / "flightdeck" / "SKILL.md",
            plugin / "skills" / "flightdeck-repo-bridge" / "SKILL.md",
            plugin / "skills" / "flightdeck-repo-bridge" / "references" / "configure-bridge-repos.md",
            candidate / "AGENTS.md",
            candidate / "docs" / "workflows" / "configure-bridge-repos.md",
            candidate / "hub" / "schemas" / "repository-declarations.schema.json",
        ],
        {
            "advanced_bridge_scope": (
                "advanced bridge",
                "repo-native",
                "drift",
            ),
            "bulk_commands": ("bridge plan --all", "bridge install --all"),
            "safe_default": ("default new declarations to `reference`",),
            "repo_native_authorization": ("explicit per-repository authorization",),
            "project_verification": ("exact normalized path match",),
            "project_identity": (
                "logical project key",
                "opaque runtime project id",
                "display name",
            ),
            "setup_boundary": ("does not create implementation tasks",),
        },
    )
    records.append(
        surface(
            "bulk_repository_bridge_configuration",
            status="added",
            mandatory=True,
            scope="local",
            mapping="The declarative repository set adds one agent-executable bulk setup surface while retaining the source bridge authority, drift, onboarding, exact-project, and no-monitoring contracts.",
            probe_name="bulk bridge harness plus trigger and runbook semantic anchors",
            passed=(
                acceptance_pass
                and bulk_required.issubset(probe_names)
                and bulk_static_pass
            ),
            evidence={
                "required_probes": sorted(bulk_required),
                "passed_probes": sorted(probe_names & bulk_required),
                "static_contract": bulk_static,
            },
        )
    )

    onboarding_required = {
        "repository_plan_read_only",
        "clone_origin_branch_sha_clean",
        "registration_remains_unclaimed",
        "owning_repository_dispatch_receipt",
        "worktree_bridge_handoff_uses_verified_original_checkout",
        "route_contract",
        "bulk_project_registration_pending_and_verified",
        "logical_project_key_differs_from_runtime_project_id",
        "legacy_project_self_equality_rejected",
    }
    records.append(
        surface(
            "setup_onboarding_and_dispatch_contract",
            status="matched",
            mandatory=True,
            scope="local",
            mapping="Source routing maps to capability-detected exact-path registration, verified clone/onboarding, resume-or-create receipts, and mandatory return without monitoring.",
            probe_name="fresh generation and synthetic owning-repository acceptance harness",
            passed=acceptance_pass and onboarding_required.issubset(probe_names),
            evidence={
                "required_probes": sorted(onboarding_required),
                "passed_probes": sorted(probe_names & onboarding_required),
            },
        )
    )

    links = run(["python3", str(setup_scripts / "validate_links.py")], cwd=plugin.parent.parent)
    preflight_ok, preflight = run_json(
        ["python3", str(setup_scripts / "preflight.py"), "--json"], cwd=plugin.parent.parent
    )
    setup_pass = links.returncode == 0 and preflight_ok and acceptance_pass
    records.append(
        surface(
            "setup_agent_runbook",
            status="added",
            mandatory=True,
            scope="local",
            mapping="The distributable setup flow is additive and fail-closed: empty-target generation, local prerequisites, artifact capability checks, validation, exact-path registration verification, one retry, and one manual action.",
            probe_name="setup link validator, local preflight, and fresh-generation acceptance",
            passed=setup_pass,
            evidence={
                "link_validator_exit": links.returncode,
                "local_preflight_ready": preflight.get("local_ready") if isinstance(preflight, dict) else False,
                "acceptance_verified": acceptance_pass,
            },
        )
    )

    skill_names = {
        path.name for path in (plugin / "skills").iterdir() if (path / "SKILL.md").is_file()
    }
    skills_pass = EXPECTED_SKILLS.issubset(skill_names)
    active_evidence: dict[str, Any] = {"candidate_skills": sorted(skill_names)}
    if args.source_hub_skill:
        hub_skill = args.source_hub_skill.resolve()
        active_evidence["source_hub_skill_files"] = sorted(
            str(path.relative_to(hub_skill)) for path in hub_skill.rglob("*.md")
        )
        hub_anchors_pass, hub_anchors = static_contains(
            [
                plugin / "skills" / "flightdeck" / "SKILL.md",
                plugin / "skills" / "flightdeck" / "references" / "dispatch.md",
            ],
            {
                "dispatch_first": ("dispatch before inspecting target",),
                "registration": (
                    "refresh the live project list",
                    "exact normalized",
                    "display-name",
                ),
                "dynamic_onboarding": (
                    "resolve provider",
                    "default branch",
                    "verify remotes, branch, sha",
                ),
                "task_resolution": ("search for a matching persistent task",),
                "worktree_bridge_handoff": (
                    "complete verified `bridge_handoff`",
                    "original checkout",
                    "never copy ignored bridge files into the worktree",
                ),
                "receipt": (
                    "logical project key",
                    "opaque runtime project id",
                    "task id, mode",
                    "authorization boundary",
                ),
                "no_monitoring": ("do not read, wait for, poll, or monitor",),
                "skill_composition": (
                    "smallest lead flightdeck skill",
                    "independent of the owning workload",
                    "new evidence crosses domains",
                    "before domain-specific mutation",
                    "do not preload speculative skills",
                ),
            },
        )
        active_evidence["coordinator_contract"] = hub_anchors
        skills_pass = (
            skills_pass
            and (hub_skill / "SKILL.md").is_file()
            and hub_anchors_pass
        )
    records.append(
        surface(
            "active_hub_skill_workflows",
            status="matched",
            mandatory=True,
            scope="local",
            mapping="The active coordinator and its routing, patching, workflow, and automation references map to focused neutral skills plus a shared coordinator.",
            probe_name="required skill trigger and reference inventory",
            passed=skills_pass,
            evidence=active_evidence,
        )
    )

    planning_pass, planning_evidence = static_contains(
        [
            plugin / "skills" / "flightdeck-plan" / "SKILL.md",
            plugin / "skills" / "flightdeck-plan" / "agents" / "openai.yaml",
            plugin / "skills" / "flightdeck-plan" / "references" / "planning-method.md",
            candidate / "AGENTS.md",
            candidate / "docs" / "workflows" / "planning.md",
        ],
        {
            "natural_trigger": (
                "natural planning intent",
                "allow_implicit_invocation: true",
            ),
            "planning_boundary": (
                "read-only by default",
                "does not edit files, create or resume tasks",
            ),
            "adaptive_depth": (
                "infer depth",
                "smallest useful executable plan",
            ),
            "coordinator_boundary": (
                "registry and routing evidence",
                "do not inspect owner code",
            ),
            "execution_gate": ("user separately asks to proceed",),
        },
    )
    records.append(
        surface(
            "adaptive_planning_method",
            status="added",
            mandatory=True,
            scope="local",
            mapping="Natural planning intent maps to a read-only, right-sized method that separates Hub ownership planning from owning-repository analysis and execution.",
            probe_name="planning skill and generated Hub semantic anchors",
            passed=planning_pass,
            evidence=planning_evidence,
        )
    )

    review_pass, review_evidence = static_contains(
        [
            plugin / "skills" / "flightdeck-review" / "SKILL.md",
            plugin / "skills" / "flightdeck-review" / "agents" / "openai.yaml",
            plugin / "skills" / "flightdeck-review" / "references" / "review-method.md",
            candidate / "AGENTS.md",
            candidate / "docs" / "review" / "change-review.md",
        ],
        {
            "natural_trigger": (
                "natural review intent",
                "allow_implicit_invocation: true",
            ),
            "review_boundary": (
                "read-only by default",
                "do not fix findings",
            ),
            "owner_dispatch": (
                "before inspecting owner code",
                "return the receipt without monitoring",
            ),
            "findings_first": (
                "lead with actionable findings",
                "path and tight line range",
            ),
            "honest_no_findings": (
                "if no actionable findings",
                "checks skipped",
                "residual risk",
            ),
        },
    )
    records.append(
        surface(
            "findings_first_review_method",
            status="added",
            mandatory=True,
            scope="local",
            mapping="Natural review intent maps to exact-target, findings-first review in each owning project with evidence, validation gaps, and fixes kept separate.",
            probe_name="review skill and generated Hub semantic anchors",
            passed=review_pass,
            evidence=review_evidence,
        )
    )

    ci_pass, ci_evidence = static_contains(
        [
            plugin / "skills" / "flightdeck-ci" / "SKILL.md",
            plugin / "skills" / "flightdeck-ci" / "agents" / "openai.yaml",
            plugin / "skills" / "flightdeck-ci" / "references" / "delivery-method.md",
            candidate / "AGENTS.md",
            candidate / "docs" / "workflows" / "ci-cd.md",
        ],
        {
            "natural_trigger": (
                "natural ci/cd intent",
                "allow_implicit_invocation: true",
            ),
            "exact_revision": (
                "exact source revision",
                "latest run matches the current checkout",
            ),
            "causal_diagnosis": (
                "first causal failure",
                "downstream symptoms",
            ),
            "action_separation": (
                "inspection, source edits, workflow execution, publication, and deployment as distinct actions",
                "build, publish, promote, deploy, and verify",
            ),
            "owner_and_authorization_boundary": (
                "before inspecting pipeline source",
                "do not authorize rerunning or cancelling workflows",
                "return the receipt without monitoring",
            ),
        },
    )
    records.append(
        surface(
            "ci_cd_delivery_method",
            status="added",
            mandatory=True,
            scope="local",
            mapping="Natural CI/CD intent maps to exact-revision pipeline diagnosis and owning-repository source work while workflow execution, publication, promotion, and deployment remain separate gates.",
            probe_name="CI/CD skill and generated Hub semantic anchors",
            passed=ci_pass,
            evidence=ci_evidence,
        )
    )

    platform_pass, platform_evidence = static_contains(
        [
            plugin / "skills" / "flightdeck-platform" / "SKILL.md",
            plugin / "skills" / "flightdeck-platform" / "agents" / "openai.yaml",
            plugin / "skills" / "flightdeck-platform" / "references" / "platform-method.md",
            candidate / "AGENTS.md",
            candidate / "docs" / "workflows" / "platform.md",
            candidate / "environments" / "README.md",
        ],
        {
            "natural_trigger": (
                "natural platform intent",
                "allow_implicit_invocation: true",
            ),
            "source_runtime_split": (
                "source, live state, and runtime validation without conflating them",
                "source ownership and live environment ownership distinct",
            ),
            "exact_context": (
                "exact account, project, subscription, region, cluster, namespace, and revision",
            ),
            "state_distinction": (
                "declared configuration, generated plan, applied state, and observed runtime state distinct",
                "successful plan or render is not evidence that a change was applied",
            ),
            "specialization_and_mutation_gate": (
                "$flightdeck-charts",
                "explicit authorization for each environment write",
                "return the receipt without monitoring",
            ),
            "dynamic_database_handoff": (
                "migration-version",
                "$flightdeck-db",
                "before any database action",
                "do not preload",
            ),
        },
    )
    records.append(
        surface(
            "platform_environment_method",
            status="added",
            mandatory=True,
            scope="local",
            mapping="Natural platform intent maps to distinct source, generated-plan, applied-state, and observed-runtime surfaces with exact environment context and explicit mutation gates.",
            probe_name="platform skill and generated Hub semantic anchors",
            passed=platform_pass,
            evidence=platform_evidence,
        )
    )

    database_pass, database_evidence = static_contains(
        [
            plugin / "skills" / "flightdeck-db" / "SKILL.md",
            plugin / "skills" / "flightdeck-db" / "agents" / "openai.yaml",
            plugin
            / "skills"
            / "flightdeck-db"
            / "references"
            / "database-method.md",
            plugin
            / "skills"
            / "flightdeck-db"
            / "references"
            / "operations-safety.md",
            candidate / "AGENTS.md",
            candidate / "docs" / "workflows" / "database.md",
        ],
        {
            "natural_trigger": (
                "natural database intent",
                "allow_implicit_invocation: true",
                "runtime-discovered migration-version",
                "during another workflow",
            ),
            "adaptive_depth": (
                "conceptual questions",
                "ask only for context",
            ),
            "owner_boundary": (
                "before inspecting its code, schema, data, or runtime",
                "return the receipt without monitoring",
            ),
            "state_distinction": (
                "intended schema and configuration in source",
                "applied migration history and runtime configuration",
                "successful migration command, backup job, or database startup",
            ),
            "safe_change_method": (
                "expand-and-contract",
                "read-only request does not authorize",
                "never run `explain analyze` on a write statement",
            ),
        },
    )
    records.append(
        surface(
            "database_engineering_method",
            status="added",
            mandatory=True,
            scope="local",
            mapping="Natural database intent maps to adaptive design and operational guidance with owner dispatch, evidence-state separation, compatibility-safe migrations, and explicit live-action gates.",
            probe_name="database skill and generated Hub semantic anchors",
            passed=database_pass,
            evidence=database_evidence,
        )
    )

    upgrade_test = run(
        [
            "python3",
            "-m",
            "unittest",
            "discover",
            "-s",
            str(plugin / "skills" / "flightdeck-upgrade" / "tests"),
            "-p",
            "test_*.py",
            "-v",
        ],
        cwd=plugin.parent.parent,
    )
    upgrade_pass, upgrade_evidence = static_contains(
        [
            plugin / "releases.json",
            plugin / "skills" / "flightdeck-upgrade" / "SKILL.md",
            plugin / "skills" / "flightdeck-upgrade" / "agents" / "openai.yaml",
            plugin
            / "skills"
            / "flightdeck-upgrade"
            / "references"
            / "upgrade-contract.md",
            plugin
            / "skills"
            / "flightdeck-upgrade"
            / "scripts"
            / "patch_notes.py",
            plugin
            / "skills"
            / "flightdeck-upgrade"
            / "scripts"
            / "upgrade_planner.py",
            candidate / "AGENTS.md",
            candidate / "docs" / "workflows" / "plugin-lifecycle.md",
        ],
        {
            "natural_trigger": (
                "natural flightdeck upgrade",
                "allow_implicit_invocation: true",
            ),
            "exact_versions_and_patch_notes": (
                "installed_version",
                "target_version",
                "target_release_ledger",
                "flightdeck-releases/v1",
                "complete_range",
            ),
            "product_native_update": (
                "codex plugin marketplace upgrade",
                "codex plugin add",
                "do not run `codex plugin remove` first",
                "does not edit a plugin cache directly",
            ),
            "preservation_boundary": (
                "protected user state",
                "existing hubs stay on their generated template version",
                "does not run setup or bootstrap",
            ),
            "authorization_and_runtime_boundary": (
                "explicit approval",
                "fresh codex task",
                "do not claim installed-runtime success",
            ),
        },
    )
    upgrade_evidence["tests_exit"] = upgrade_test.returncode
    upgrade_pass = upgrade_pass and upgrade_test.returncode == 0
    records.append(
        surface(
            "plugin_upgrade_method",
            status="added",
            mandatory=True,
            scope="local",
            mapping="Natural Flightdeck lifecycle intent maps to exact-version patch notes and a supported preservation-aware reinstall while generated Hubs and repositories remain protected user state.",
            probe_name="upgrade semantic anchors and deterministic planner/patch-note tests",
            passed=upgrade_pass,
            evidence=upgrade_evidence,
        )
    )

    automation_paths = sorted((candidate / "hub" / "automations").glob("*.yaml"))
    automation_values = [load_yaml(path) for path in automation_paths]
    automation_pass = bool(automation_values) and all(
        item.get("enabled") is False
        and (item.get("activation") or {}).get("policy") == "explicit_user_enablement"
        and (item.get("output_contract") or {}).get("delta_states")
        == ["new", "resolved", "persistent", "blocked"]
        for item in automation_values
    )
    records.append(
        surface(
            "automation_method",
            status="matched",
            mandatory=True,
            scope="local",
            mapping="Active recurring-work guidance maps to disabled YAML specifications plus a distinct real-Codex-automation procedure, stable finding keys, deltas, and read-only authority.",
            probe_name="automation specification semantic validation",
            passed=automation_pass,
            evidence={"templates": len(automation_values), "all_safe": automation_pass},
        )
    )

    artifact_paths = [
        plugin / "skills" / "flightdeck-artifacts" / "SKILL.md",
        plugin / "skills" / "flightdeck-artifacts" / "references" / "artifact-gates.md",
        plugin
        / "skills"
        / "flightdeck-artifacts"
        / "scripts"
        / "validate_deliverable.py",
        plugin / "skills" / "flightdeck-setup" / "references" / "setup-runbook.md",
        candidate / "docs" / "workflows" / "artifacts.md",
        candidate / "docs" / "compliance" / "README.md",
        candidate / "hub" / "schemas" / "compliance-artifact.schema.json",
    ]
    artifact_pass, artifact_evidence = static_contains(
        artifact_paths,
        {
            "external_capabilities": ("documents", "pdf", "Spreadsheets", "load_workspace_dependencies"),
            "docx_gate": ("render every page", "inspect every page"),
            "pdf_gate": ("Render every page", "inspect layout"),
            "spreadsheet_gate": ("scan formula errors", "render every sheet"),
            "no_copy": ("does not bundle artifact implementations",),
            "deliverable_hygiene": (
                "professional human-authored",
                "unresolved template",
                "validate_deliverable.py",
                "explicit file-type allowlist",
                "unsubmitted",
            ),
        },
    )
    artifact_test = run(
        [
            "python3",
            "-m",
            "unittest",
            "discover",
            "-s",
            str(plugin / "skills" / "flightdeck-artifacts" / "tests"),
            "-p",
            "test_*.py",
            "-v",
        ],
        cwd=plugin.parent.parent,
    )
    artifact_evidence["tests_exit"] = artifact_test.returncode
    artifact_pass = artifact_pass and artifact_test.returncode == 0
    records.append(
        surface(
            "artifact_capability_integration",
            status="added",
            mandatory=True,
            scope="local",
            mapping="DOCX, PDF, and spreadsheet authoring remain external installed capabilities; the plugin supplies routing, visual quality gates, and deterministic presentation-hygiene validation.",
            probe_name="artifact capability, render-inspect, and clean-deliverable gates",
            passed=artifact_pass,
            evidence=artifact_evidence,
        )
    )

    stig_test = run(
        ["python3", "-m", "unittest", "discover", "-s", str(plugin / "skills" / "flightdeck-stig" / "tests"), "-p", "test_*.py", "-v"],
        cwd=plugin.parent.parent,
    )
    stig_files = {
        path.name
        for path in (plugin / "skills" / "flightdeck-stig" / "references").glob("*.md")
    }
    stig_scripts = {
        path.name for path in (plugin / "skills" / "flightdeck-stig" / "scripts").glob("*.py")
    }
    stig_pass = stig_test.returncode == 0 and {
        "evaluator.md",
        "evidence-contract.md",
        "ckl-workflow.md",
        "helm-remediation.md",
        "summary-extractor.md",
    }.issubset(stig_files) and {
        "ckl_parser.py",
        "ckl_generator.py",
        "evaluation_validator.py",
        "summary_extractor.py",
    }.issubset(stig_scripts)
    stig_evidence: dict[str, Any] = {
        "references": sorted(stig_files),
        "scripts": sorted(stig_scripts),
        "tests_exit": stig_test.returncode,
    }
    stig_method_pass, stig_method_evidence = static_contains(
        [
            plugin / "skills" / "flightdeck-stig" / "SKILL.md",
            plugin / "skills" / "flightdeck-stig" / "agents" / "openai.yaml",
            plugin / "skills" / "flightdeck-stig" / "references" / "evidence-contract.md",
            plugin / "skills" / "flightdeck-stig" / "scripts" / "evaluation_validator.py",
            candidate / "AGENTS.md",
            candidate / "docs" / "compliance" / "stig-evaluation.md",
        ],
        {
            "natural_trigger": (
                "natural stig intent",
                "allow_implicit_invocation: true",
                "users do not need to name a skill",
            ),
            "adaptive_depth": (
                "fixed intake form",
                "ask only for information that blocks an honest next step",
                "draft",
                "export",
            ),
            "evidence_and_applicability": (
                "direct",
                "inherited",
                "declared",
                "decide applicability before",
            ),
            "status_integrity": (
                "Not a Finding",
                "Open",
                "Not Applicable",
                "Not Reviewed",
                "generated CKL does not prove",
            ),
            "ownership_and_gates": (
                "$flightdeck-development",
                "$flightdeck-charts",
                "$flightdeck-ci",
                "$flightdeck-platform",
                "$flightdeck-compliance",
                "does not authorize",
            ),
        },
    )
    stig_evidence["adaptive_method"] = stig_method_evidence
    stig_pass = stig_pass and stig_method_pass
    if args.source_stig_skill:
        source_stig = args.source_stig_skill.resolve()
        stig_evidence["source_reference_count"] = len(list((source_stig / "references").glob("*.md")))
        source_attributes = literal_mapping(
            source_stig / "scripts" / "ckl_parser.py", "attribute_map"
        )
        candidate_attributes = literal_mapping(
            plugin / "skills" / "flightdeck-stig" / "scripts" / "ckl_parser.py",
            "ATTRIBUTE_MAP",
        )
        missing_attributes = {
            key: value
            for key, value in source_attributes.items()
            if candidate_attributes.get(key) != value
        }
        stig_anchor_pass, stig_anchors = static_contains(
            [
                plugin / "skills" / "flightdeck-stig" / "SKILL.md",
                *sorted(
                    (plugin / "skills" / "flightdeck-stig" / "references").glob("*.md")
                ),
                *sorted(
                    (plugin / "skills" / "flightdeck-stig" / "scripts").glob("*.py")
                ),
            ],
            {
                "statuses": (
                    "Not a Finding",
                    "Open",
                    "Not Applicable",
                    "Not Reviewed",
                ),
                "evidence_default": ("read-only evidence", "notes are not evidence"),
                "helm": ("helm template", "remediation plan"),
                "batch": ("batch evaluation", "progress"),
                "summary": (
                    "status summary",
                    "finding details",
                    "evidence limitation",
                ),
                "ckl_compatibility": (
                    "--dry-run",
                    "--no-timestamp",
                    "--verbose",
                    "duplicate finding ID",
                ),
            },
        )
        stig_evidence["missing_source_parser_attributes"] = missing_attributes
        stig_evidence["coverage_anchors"] = stig_anchors
        stig_pass = (
            stig_pass
            and (source_stig / "SKILL.md").is_file()
            and not missing_attributes
            and stig_anchor_pass
        )
    records.append(
        surface(
            "stig_workflow",
            status="matched",
            mandatory=True,
            scope="local",
            mapping="Natural STIG intent maps to adaptive rule, evidence-gap, applicability, inherited-control, draft/export, remediation-routing, Helm, and deterministic CKL workflows.",
            probe_name="adaptive STIG method anchors and deterministic evidence/CKL tests",
            passed=stig_pass,
            evidence=stig_evidence,
        )
    )

    docs_pass, docs_evidence = documentation_mapping(source, candidate)
    records.append(
        surface(
            "reusable_method_documentation",
            status="matched",
            mandatory=True,
            scope="local",
            mapping="Every reusable source Markdown guide under docs maps by normalized heading semantics rather than filename equality.",
            probe_name="per-document normalized heading mapping",
            passed=docs_pass,
            evidence=docs_evidence,
        )
    )

    process_inventory_output = args.json.resolve().parent / "process-inventory.json"
    require_ignored_output(process_inventory_output)
    process_inventory_output.parent.mkdir(parents=True, exist_ok=True)
    process_inventory_output.unlink(missing_ok=True)
    process_inventory_result = run(
        [
            "python3",
            str(setup_scripts / "process_inventory.py"),
            "--source",
            str(source),
            "--candidate",
            str(candidate),
            "--plugin",
            str(plugin),
            "--json",
            str(process_inventory_output),
        ],
        cwd=plugin.parent.parent,
    )
    try:
        process_inventory_report = json.loads(
            process_inventory_output.read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as error:
        process_inventory_report = {
            "ok": False,
            "failures": [f"strict process inventory report is unreadable: {error}"],
        }
    if not isinstance(process_inventory_report, dict):
        process_inventory_report = {
            "ok": False,
            "failures": ["strict process inventory report must be a JSON object"],
        }
    process_inventory_pass = (
        process_inventory_result.returncode == 0
        and process_inventory_report.get("ok") is True
    )
    process_inventory_failures = process_inventory_report.get(
        "failures",
        process_inventory_report.get("unresolved", []),
    )
    if not isinstance(process_inventory_failures, list):
        process_inventory_failures = [str(process_inventory_failures)]
    if process_inventory_result.returncode != 0 and process_inventory_result.stderr.strip():
        process_inventory_failures.append(process_inventory_result.stderr.strip())
    elif process_inventory_result.returncode != 0 and process_inventory_result.stdout.strip():
        process_inventory_failures.append(process_inventory_result.stdout.strip())
    records.append(
        surface(
            "strict_process_inventory",
            status="matched",
            mandatory=True,
            scope="local",
            mapping="Every strict source process-inventory item must have a neutral candidate or plugin implementation and a passing deterministic inventory probe.",
            probe_name="strict source, candidate, and plugin process inventory",
            passed=process_inventory_pass,
            evidence={
                "output": str(process_inventory_output),
                "exit": process_inventory_result.returncode,
                "counts": process_inventory_report.get("counts", {}),
                "failures": process_inventory_failures,
                "stderr": process_inventory_result.stderr.strip(),
            },
        )
    )

    scanner = setup_scripts / "scan_debranding.py"
    scanner_private_args = (
        [
            "--private-neutralization-map",
            str(args.private_neutralization_map),
        ]
        if args.private_neutralization_map
        else []
    )
    scan_repository = run(
        [
            "python3",
            str(scanner),
            str(plugin.parent.parent),
            *scanner_private_args,
        ],
        cwd=plugin.parent.parent,
    )
    scan_plugin = run(
        ["python3", str(scanner), str(plugin), *scanner_private_args],
        cwd=plugin.parent.parent,
    )
    scan_candidate = run(
        ["python3", str(scanner), str(candidate), *scanner_private_args],
        cwd=plugin.parent.parent,
    )
    debrand_pass = (
        scan_repository.returncode == 0
        and scan_plugin.returncode == 0
        and scan_candidate.returncode == 0
    )
    records.append(
        surface(
            "debranding_and_synthetic_only_distribution",
            status="matched",
            mandatory=True,
            scope="local",
            mapping="Organization, product, person, and machine-path tokens are excluded; operational topology, evidence, tasks, and findings are classified as intentional exclusions.",
            probe_name="independent recursive token-aware scan including hidden files",
            passed=debrand_pass,
            evidence={
                "repository_exit": scan_repository.returncode,
                "plugin_exit": scan_plugin.returncode,
                "candidate_exit": scan_candidate.returncode,
                "repository_summary": scan_repository.stdout.strip().splitlines()[-1:] or [],
                "plugin_summary": scan_plugin.stdout.strip().splitlines()[-1:] or [],
                "candidate_summary": scan_candidate.stdout.strip().splitlines()[-1:] or [],
            },
        )
    )

    runtime_pass = False
    runtime_evidence: dict[str, Any] = {
        "status": "not_run",
        "required_procedure": "flightdeck-setup/references/installed-acceptance.md",
        "validation_failures": ["runtime acceptance evidence was not provided"],
    }
    if args.runtime_acceptance:
        validation_failures: list[str] = []
        try:
            loaded_runtime_evidence = json.loads(
                args.runtime_acceptance.read_text(encoding="utf-8")
            )
        except (OSError, json.JSONDecodeError) as error:
            loaded_runtime_evidence = {}
            validation_failures.append(f"runtime acceptance evidence is unreadable: {error}")
        if not isinstance(loaded_runtime_evidence, dict):
            loaded_runtime_evidence = {}
            validation_failures.append("runtime acceptance evidence must be a JSON object")
        runtime_evidence = dict(loaded_runtime_evidence)
        runtime_evidence["evidence_path"] = str(args.runtime_acceptance.resolve())

        manifest_path = plugin / ".codex-plugin" / "plugin.json"
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            manifest = {}
            validation_failures.append(f"current plugin manifest is unreadable: {error}")
        if not isinstance(manifest, dict):
            manifest = {}
            validation_failures.append("current plugin manifest must be a JSON object")
        current_plugin_version = manifest.get("version")
        if not isinstance(current_plugin_version, str) or not current_plugin_version:
            validation_failures.append(
                "current plugin manifest must declare a non-empty version"
            )

        expected_metadata = {
            "schema_version": "flightdeck.runtime-acceptance/v1",
            "plugin_name": "flightdeck",
            "plugin_version": current_plugin_version,
            "candidate_root": str(candidate),
        }
        for field, expected in expected_metadata.items():
            actual = runtime_evidence.get(field)
            if actual != expected:
                validation_failures.append(
                    f"{field} must equal {expected!r}; received {actual!r}"
                )

        generated_hub_value = runtime_evidence.get("generated_hub_path")
        generated_hub = (
            Path(generated_hub_value).expanduser()
            if isinstance(generated_hub_value, str) and generated_hub_value
            else None
        )
        if generated_hub is None:
            validation_failures.append(
                "generated_hub_path must be a non-empty filesystem path"
            )
        else:
            if not generated_hub.is_dir():
                validation_failures.append(
                    f"generated_hub_path does not exist as a directory: {generated_hub}"
                )
            elif not (generated_hub / "flightdeck.yaml").is_file():
                validation_failures.append(
                    "generated_hub_path must contain flightdeck.yaml"
                )
            elif (generated_hub / f"{SOURCE_CONTROL_TOKEN}.yaml").exists():
                validation_failures.append(
                    f"generated_hub_path must not contain {SOURCE_CONTROL_TOKEN}.yaml"
                )
            else:
                aligned, alignment_evidence = generated_template_alignment(
                    candidate, generated_hub
                )
                runtime_evidence["generated_template_alignment"] = alignment_evidence
                if not aligned:
                    validation_failures.append(
                        "generated_hub_path does not match the current candidate "
                        "template managed surface"
                    )

        results = runtime_evidence.get("runtime_acceptance") or []
        if not isinstance(results, list):
            results = []
            validation_failures.append("runtime_acceptance must be a JSON array")
        malformed_results = [
            index for index, item in enumerate(results) if not isinstance(item, dict)
        ]
        if malformed_results:
            validation_failures.append(
                "runtime_acceptance entries must be objects; invalid indexes: "
                + ", ".join(str(index) for index in malformed_results)
            )
        submitted_result_names = [
            item.get("name") for item in results if isinstance(item, dict)
        ]
        invalid_name_indexes = [
            index
            for index, item in enumerate(results)
            if isinstance(item, dict) and not isinstance(item.get("name"), str)
        ]
        if invalid_name_indexes:
            validation_failures.append(
                "runtime_acceptance names must be strings; invalid indexes: "
                + ", ".join(str(index) for index in invalid_name_indexes)
            )
        result_names = [
            name for name in submitted_result_names if isinstance(name, str)
        ]
        duplicate_names = sorted(
            {
                name
                for name in result_names
                if result_names.count(name) > 1
            }
        )
        if duplicate_names:
            validation_failures.append(
                "runtime_acceptance contains duplicate assertion names: "
                + ", ".join(duplicate_names)
            )
        by_name = {
            item["name"]: item
            for item in results
            if isinstance(item, dict) and isinstance(item.get("name"), str)
        }
        required_runtime = {
            "installed_setup_and_exact_path_project_registration",
            "installed_bulk_bridge_configuration",
            "installed_task_search_create_resume_and_no_monitoring",
        }
        if len(results) != len(required_runtime) or set(result_names) != required_runtime:
            validation_failures.append(
                "runtime_acceptance must contain exactly the three required results"
            )
        setup_result = by_name.get(
            "installed_setup_and_exact_path_project_registration", {}
        )
        bridge_result = by_name.get("installed_bulk_bridge_configuration", {})
        dispatch_result = by_name.get(
            "installed_task_search_create_resume_and_no_monitoring", {}
        )
        runtime_assertions_pass = (
            required_runtime.issubset(by_name)
            and all(by_name[name].get("status") == "passed" for name in required_runtime)
            and setup_result.get("exact_path_match") is True
            and bool(setup_result.get("runtime_project_id"))
            and bridge_result.get("logical_project_key")
            != bridge_result.get("runtime_project_id")
            and bool(bridge_result.get("runtime_project_id"))
            and bridge_result.get("no_implementation_task_created") is True
            and dispatch_result.get("create_task_id")
            and dispatch_result.get("resume_task_id")
            and dispatch_result.get("create_task_id")
            == dispatch_result.get("resume_task_id")
            and dispatch_result.get("runtime_project_id_used") is True
            and dispatch_result.get("monitoring_after_receipt") is False
        )
        if not required_runtime.issubset(by_name):
            validation_failures.append(
                "runtime_acceptance is missing required assertions: "
                + ", ".join(sorted(required_runtime - by_name.keys()))
            )
        for name in sorted(required_runtime & by_name.keys()):
            if by_name[name].get("status") != "passed":
                validation_failures.append(f"{name} status must be 'passed'")
        if required_runtime.issubset(by_name) and not runtime_assertions_pass:
            validation_failures.append(
                "one or more installed-runtime assertion fields did not pass"
            )
        runtime_evidence["validation_failures"] = validation_failures
        runtime_pass = not validation_failures and runtime_assertions_pass
    records.append(
        surface(
            "installed_runtime_project_and_task_acceptance",
            status="matched" if runtime_pass else "unresolved",
            mandatory=True,
            scope="runtime",
            mapping="Native registration or supported open-folder fallback must be verified by an exact path in the refreshed live project list; create/resume response is the receipt and monitoring stops.",
            probe_name="installed-plugin fresh-task acceptance",
            passed=runtime_pass,
            evidence=runtime_evidence,
        )
    )

    upgrade_runtime_pass = False
    upgrade_runtime_evidence: dict[str, Any] = {
        "status": "not_run",
        "required_procedure": "flightdeck-setup/references/installed-acceptance.md#plugin-upgrade-acceptance",
        "validation_failures": [
            "installed plugin upgrade acceptance evidence was not provided"
        ],
    }
    if args.upgrade_acceptance:
        upgrade_failures: list[str] = []
        try:
            loaded_upgrade_evidence = json.loads(
                args.upgrade_acceptance.read_text(encoding="utf-8")
            )
        except (OSError, json.JSONDecodeError) as error:
            loaded_upgrade_evidence = {}
            upgrade_failures.append(
                f"upgrade acceptance evidence is unreadable: {error}"
            )
        if not isinstance(loaded_upgrade_evidence, dict):
            loaded_upgrade_evidence = {}
            upgrade_failures.append(
                "upgrade acceptance evidence must be a JSON object"
            )
        upgrade_runtime_evidence = dict(loaded_upgrade_evidence)
        upgrade_runtime_evidence["evidence_path"] = str(
            args.upgrade_acceptance.resolve()
        )

        try:
            current_manifest = json.loads(
                (plugin / ".codex-plugin" / "plugin.json").read_text(
                    encoding="utf-8"
                )
            )
        except (OSError, json.JSONDecodeError) as error:
            current_manifest = {}
            upgrade_failures.append(f"current plugin manifest is unreadable: {error}")
        current_version = (
            current_manifest.get("version")
            if isinstance(current_manifest, dict)
            else None
        )
        if not isinstance(current_version, str) or not current_version:
            upgrade_failures.append(
                "current plugin manifest must declare a non-empty version"
            )
        plugin_id = upgrade_runtime_evidence.get("plugin_id")
        if (
            not isinstance(plugin_id, str)
            or not plugin_id.startswith("flightdeck@")
            or plugin_id == "flightdeck@"
        ):
            upgrade_failures.append(
                "plugin_id must identify flightdeck at one configured marketplace"
            )
        prior_version = upgrade_runtime_evidence.get("prior_version")
        target_version = upgrade_runtime_evidence.get("target_version")
        installed_version = upgrade_runtime_evidence.get("installed_version")
        expected_metadata = {
            "schema_version": "flightdeck.upgrade-acceptance/v1",
            "target_version": current_version,
            "installed_version": current_version,
            "approval_confirmed": True,
            "fresh_task_loaded_target": True,
        }
        for field, expected in expected_metadata.items():
            actual = upgrade_runtime_evidence.get(field)
            if actual != expected:
                upgrade_failures.append(
                    f"{field} must equal {expected!r}; received {actual!r}"
                )
        if not isinstance(prior_version, str) or not prior_version:
            upgrade_failures.append("prior_version must be a non-empty exact version")
        elif prior_version == target_version:
            upgrade_failures.append(
                "prior_version must differ from target_version for upgrade acceptance"
            )

        source_type = upgrade_runtime_evidence.get("marketplace_source_type")
        if source_type not in {"local", "git", "github"}:
            upgrade_failures.append(
                "marketplace_source_type must be local, git, or github"
            )

        commands = upgrade_runtime_evidence.get("commands")
        if not isinstance(commands, list):
            commands = []
            upgrade_failures.append("commands must be a JSON array")
        command_arguments: list[list[str]] = []
        for index, command in enumerate(commands):
            if not isinstance(command, dict):
                upgrade_failures.append(f"commands[{index}] must be an object")
                continue
            arguments = command.get("arguments")
            if (
                not isinstance(arguments, list)
                or not arguments
                or not all(isinstance(item, str) for item in arguments)
            ):
                upgrade_failures.append(
                    f"commands[{index}].arguments must be a non-empty string array"
                )
                continue
            command_arguments.append(arguments)
            if command.get("exit_code") != 0:
                upgrade_failures.append(f"commands[{index}].exit_code must equal 0")
            if "remove" in arguments:
                upgrade_failures.append(
                    f"commands[{index}] must not remove the plugin before reinstall"
                )
            if "setup" in arguments or "bootstrap" in arguments:
                upgrade_failures.append(
                    f"commands[{index}] must not run setup or bootstrap"
                )

        if isinstance(plugin_id, str):
            expected_install = [
                "codex",
                "plugin",
                "add",
                plugin_id,
                "--json",
            ]
            if expected_install not in command_arguments:
                upgrade_failures.append(
                    "commands must include the supported exact plugin add command"
                )
            marketplace_name = plugin_id.split("@", 1)[1] if "@" in plugin_id else ""
            expected_refresh = [
                "codex",
                "plugin",
                "marketplace",
                "upgrade",
                marketplace_name,
                "--json",
            ]
            if source_type in {"git", "github"} and expected_refresh not in command_arguments:
                upgrade_failures.append(
                    "Git marketplace acceptance must include the exact refresh command"
                )
            if source_type == "local" and any(
                arguments[:4]
                == ["codex", "plugin", "marketplace", "upgrade"]
                for arguments in command_arguments
            ):
                upgrade_failures.append(
                    "local marketplace acceptance must not include a refresh command"
                )

        preservation_checks = upgrade_runtime_evidence.get("preservation_checks")
        if not isinstance(preservation_checks, list):
            preservation_checks = []
            upgrade_failures.append("preservation_checks must be a JSON array")
        preservation_by_name = {
            item.get("name"): item
            for item in preservation_checks
            if isinstance(item, dict) and isinstance(item.get("name"), str)
        }
        required_preservation = {
            "hub_doctor",
            "hub_git_status",
            "attached_repository_git_status",
            "ignored_state",
        }
        missing_preservation = required_preservation - preservation_by_name.keys()
        if missing_preservation:
            upgrade_failures.append(
                "preservation_checks is missing required results: "
                + ", ".join(sorted(missing_preservation))
            )
        for name in sorted(required_preservation & preservation_by_name.keys()):
            if preservation_by_name[name].get("status") != "passed":
                upgrade_failures.append(
                    f"preservation check {name} status must be 'passed'"
                )

        upgrade_runtime_evidence["validation_failures"] = upgrade_failures
        upgrade_runtime_pass = not upgrade_failures
    records.append(
        surface(
            "installed_plugin_upgrade_acceptance",
            status="matched" if upgrade_runtime_pass else "unresolved",
            mandatory=True,
            scope="runtime",
            mapping="An installed upgrade must prove the approved exact target, supported same-plugin reinstall, unchanged synthetic Hub and repository state, and target skill loading in a fresh task.",
            probe_name="installed plugin upgrade and preservation acceptance",
            passed=upgrade_runtime_pass,
            evidence=upgrade_runtime_evidence,
        )
    )

    setup_connection_required = {
        "setup_repository_discovery_read_only",
        "setup_attached_reference_bridge_portable",
        "setup_connect_idempotent_and_preserves_tracked_files",
    }
    setup_connection_static_pass, setup_connection_static = static_contains(
        [
            plugin / "skills" / "flightdeck-setup" / "SKILL.md",
            plugin / "skills" / "flightdeck-setup" / "references" / "setup-runbook.md",
            candidate / "AGENTS.md",
            candidate / "README.md",
            candidate / "lib" / "flightdeck" / "cli.rb",
            candidate / "hub" / "schemas" / "repository-declarations.schema.json",
        ],
        {
            "natural_language_setup": ("set up flightdeck", "connect repositories"),
            "deterministic_commands": ("setup plan", "setup connect"),
            "attached_portability": ("placement: attached", "ignored local state"),
            "safe_bridge_default": ("reference", "tracked repository files"),
        },
    )
    records.append(
        surface(
            "one_prompt_repository_connection",
            status="added",
            mandatory=True,
            scope="local",
            mapping="Initial setup now discovers repositories only under an authorized root, attaches them without moving checkout state, records portable declarations plus ignored exact paths, and installs safe local reference bridges.",
            probe_name="setup discovery, attached portability, and idempotent bridge harness",
            passed=(
                acceptance_pass
                and setup_connection_required.issubset(probe_names)
                and setup_connection_static_pass
            ),
            evidence={
                "required_probes": sorted(setup_connection_required),
                "passed_probes": sorted(probe_names & setup_connection_required),
                "static_contract": setup_connection_static,
            },
        )
    )

    records.append(
        surface(
            "organization_operational_content",
            status="intentionally_excluded",
            mandatory=False,
            scope="distribution",
            mapping="Live topology, repositories, program facts, credentials, tasks, evidence, generated findings, and controlled artifacts have no distributable mapping.",
            probe_name="distribution boundary classification",
            passed=True,
            evidence={"classification": "excluded_data_not_functional_gap"},
        )
    )

    local_mandatory = [
        item for item in records if item["mandatory"] and item["scope"] == "local"
    ]
    all_mandatory = [item for item in records if item["mandatory"]]
    local_passed = all(item["probe"]["passed"] and item["status"] != "unresolved" for item in local_mandatory)
    overall_passed = all(item["probe"]["passed"] and item["status"] != "unresolved" for item in all_mandatory)
    counts = {
        status: sum(1 for item in records if item["status"] == status)
        for status in ("matched", "generalized", "added", "intentionally_excluded", "unresolved")
    }
    return {
        "schema_version": "flightdeck.parity/v4",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source_root": str(source),
        "candidate_root": str(candidate),
        "plugin_root": str(plugin),
        "claim": {
            "locally_testable_mandatory_surfaces_pass": local_passed,
            "overall_1_to_1_functional_parity": overall_passed,
            "statement": (
                "All mandatory neutral mappings and probes passed."
                if overall_passed
                else "No overall 1:1 claim: one or more mandatory probes are unresolved or failed."
            ),
        },
        "summary": counts,
        "mandatory_summary": {
            "local_total": len(local_mandatory),
            "local_passed": sum(
                1 for item in local_mandatory if item["probe"]["passed"] and item["status"] != "unresolved"
            ),
            "overall_total": len(all_mandatory),
            "overall_passed": sum(
                1 for item in all_mandatory if item["probe"]["passed"] and item["status"] != "unresolved"
            ),
        },
        "distribution_inventory": {
            "repository_files": file_inventory(plugin.parent.parent),
            "plugin_files": file_inventory(plugin),
        },
        "surfaces": records,
    }


def write_summary(path: Path, report: dict[str, Any]) -> None:
    claim = report["claim"]
    mandatory = report["mandatory_summary"]
    lines = [
        "# Flightdeck semantic parity summary",
        "",
        f"Generated: {report['generated_at']}",
        "",
        claim["statement"],
        "",
        f"- Local mandatory probes: {mandatory['local_passed']}/{mandatory['local_total']}",
        f"- Overall mandatory probes: {mandatory['overall_passed']}/{mandatory['overall_total']}",
        f"- Overall 1:1 functional parity: {str(claim['overall_1_to_1_functional_parity']).lower()}",
        "",
        "## Surfaces",
        "",
    ]
    for item in report["surfaces"]:
        result = "pass" if item["probe"]["passed"] else "not passed"
        lines.append(
            f"- {item['surface']}: {item['status']} ({result}) — {item['neutral_mapping']}"
        )
    atomic_text(path, "\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--source-hub-skill", type=Path)
    parser.add_argument("--source-stig-skill", type=Path)
    parser.add_argument(
        "--private-neutralization-map",
        type=Path,
        help=(
            "Ignored external JSON mapping private source terms to neutral "
            "equivalents; never distribute this file"
        ),
    )
    parser.add_argument("--runtime-acceptance", type=Path)
    parser.add_argument("--upgrade-acceptance", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()

    for output in (args.json, args.summary):
        require_ignored_output(output)
    configure_private_neutralization(args.private_neutralization_map)
    report = compare(args)
    atomic_text(args.json, json.dumps(report, indent=2, sort_keys=True) + "\n")
    write_summary(args.summary, report)
    print(json.dumps({"summary": report["summary"], "claim": report["claim"]}, sort_keys=True))
    return 0 if report["claim"]["overall_1_to_1_functional_parity"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
