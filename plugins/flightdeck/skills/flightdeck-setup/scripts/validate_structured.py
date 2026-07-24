#!/usr/bin/env python3
"""Parse JSON/YAML and check deterministic structural invariants in JSON Schemas."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any


SKIP_PARTS = {".git", ".flightdeck-local", "__pycache__"}
SCHEMA_TYPES = {"array", "boolean", "integer", "null", "number", "object", "string"}
DEFAULT_LOCAL_ROOTS = (
    ".flightdeck-local",
    "handoffs",
    "hub/cache",
    "hub/reports",
    "hub/state",
    "hub/tasks",
    "hub/tmp",
)


def yaml_value(path: Path) -> Any:
    script = (
        "value=YAML.safe_load(File.read(ARGV.fetch(0)),"
        " permitted_classes:[Date,Time], permitted_symbols:[], aliases:false);"
        "puts JSON.generate(value)"
    )
    result = subprocess.run(
        ["ruby", "-rjson", "-ryaml", "-rdate", "-e", script, str(path)],
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )
    if result.returncode != 0:
        raise ValueError(result.stderr.strip())
    return json.loads(result.stdout)


def safe_relative_path(value: Any) -> Path | None:
    if not isinstance(value, str) or not value:
        return None
    path = Path(value)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        return None
    return path


def generated_boundaries(
    root: Path,
) -> tuple[tuple[tuple[Path, tuple[Path, ...]], ...], tuple[Path, ...]]:
    config_path = root / "flightdeck.yaml"
    if not config_path.is_file():
        return (), ()
    try:
        config = yaml_value(config_path)
    except (OSError, ValueError, json.JSONDecodeError):
        return (), ()
    if not isinstance(config, dict) or config.get("kind") != "FlightdeckRegistry":
        return (), ()

    workload_boundaries: list[tuple[Path, tuple[Path, ...]]] = []
    workloads = config.get("workloads")
    if isinstance(workloads, dict):
        for workload in workloads.values():
            if not isinstance(workload, dict):
                continue
            workload_root = safe_relative_path(workload.get("path"))
            if workload_root is None:
                continue
            allowed: list[Path] = []
            dynamic_programs = workload.get("dynamic_programs")
            if isinstance(dynamic_programs, dict):
                template = safe_relative_path(dynamic_programs.get("template_path"))
                if template is not None and template.is_relative_to(workload_root):
                    allowed.append(template)
            workload_boundaries.append((workload_root, tuple(allowed)))

    local_roots = {Path(value) for value in DEFAULT_LOCAL_ROOTS}
    workspace = config.get("workspace")
    if isinstance(workspace, dict):
        for key in ("task_records_root", "report_root"):
            path = safe_relative_path(workspace.get(key))
            if path is not None:
                local_roots.add(path)
        for key in (
            "local_registry",
            "bridge_registry",
            "project_registry",
            "bridge_setup_receipt",
        ):
            path = safe_relative_path(workspace.get(key))
            if path is not None:
                local_roots.add(path if path.parent == Path(".") else path.parent)
    return tuple(workload_boundaries), tuple(sorted(local_roots, key=str))


def is_generated_control_plane_file(
    relative: Path,
    boundaries: tuple[tuple[tuple[Path, tuple[Path, ...]], ...], tuple[Path, ...]],
) -> bool:
    workloads, local_roots = boundaries
    for local_root in local_roots:
        if relative == local_root or relative.is_relative_to(local_root):
            return False
    for workload_root, allowed in workloads:
        if relative == workload_root or relative.is_relative_to(workload_root):
            if relative == workload_root / "README.md":
                return True
            return any(
                relative == allowed_root or relative.is_relative_to(allowed_root)
                for allowed_root in allowed
            )
    return True


def resolve_pointer(document: Any, reference: str) -> bool:
    if reference == "#":
        return True
    if not reference.startswith("#/"):
        return True
    value = document
    for raw in reference[2:].split("/"):
        key = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(value, dict) and key in value:
            value = value[key]
        else:
            return False
    return True


def check_schema(value: Any, document: dict[str, Any], path: str, failures: list[str]) -> None:
    if isinstance(value, list):
        for index, item in enumerate(value):
            check_schema(item, document, f"{path}[{index}]", failures)
        return
    if not isinstance(value, dict):
        return

    schema_type = value.get("type")
    types = schema_type if isinstance(schema_type, list) else [schema_type]
    if schema_type is not None and (
        not types
        or any(not isinstance(item, str) or item not in SCHEMA_TYPES for item in types)
    ):
        failures.append(f"{path}.type is invalid")
    required = value.get("required")
    if required is not None and (
        not isinstance(required, list)
        or len(required) != len(set(required))
        or any(not isinstance(item, str) or not item for item in required)
    ):
        failures.append(f"{path}.required must contain unique non-empty strings")
    properties = value.get("properties")
    if properties is not None and not isinstance(properties, dict):
        failures.append(f"{path}.properties must be an object")
    enum = value.get("enum")
    if enum is not None and (not isinstance(enum, list) or not enum):
        failures.append(f"{path}.enum must be a non-empty array")
    additional = value.get("additionalProperties")
    if additional is not None and not isinstance(additional, (bool, dict)):
        failures.append(f"{path}.additionalProperties must be boolean or a schema")
    reference = value.get("$ref")
    if isinstance(reference, str) and not resolve_pointer(document, reference):
        failures.append(f"{path} has unresolved internal reference {reference}")

    for key in ("properties", "patternProperties", "$defs", "definitions", "dependentSchemas"):
        children = value.get(key)
        if isinstance(children, dict):
            for child_name, child in children.items():
                check_schema(child, document, f"{path}.{key}.{child_name}", failures)
    for key in (
        "additionalProperties",
        "contains",
        "else",
        "if",
        "items",
        "not",
        "propertyNames",
        "then",
        "unevaluatedItems",
        "unevaluatedProperties",
    ):
        child = value.get(key)
        if isinstance(child, (dict, list)):
            check_schema(child, document, f"{path}.{key}", failures)
    for key in ("allOf", "anyOf", "oneOf", "prefixItems"):
        children = value.get(key)
        if isinstance(children, list):
            check_schema(children, document, f"{path}.{key}", failures)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    failures: list[str] = []
    counts = {"json": 0, "yaml": 0, "schemas": 0}
    boundaries = generated_boundaries(root)

    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if (
            not path.is_file()
            or any(part in SKIP_PARTS for part in relative.parts)
            or not is_generated_control_plane_file(relative, boundaries)
        ):
            continue
        try:
            if path.suffix.lower() == ".json":
                value = json.loads(path.read_text(encoding="utf-8"))
                counts["json"] += 1
                if path.name.endswith(".schema.json"):
                    counts["schemas"] += 1
                    if not isinstance(value, dict):
                        failures.append(f"{relative} schema root is not an object")
                    else:
                        check_schema(value, value, "$", failures)
            elif path.suffix.lower() in {".yaml", ".yml"}:
                yaml_value(path)
                counts["yaml"] += 1
        except (OSError, ValueError, json.JSONDecodeError) as error:
            failures.append(f"{relative}: {error}")

    report = {
        "schema_version": "flightdeck.structured-validation/v1",
        "root": str(root),
        "counts": counts,
        "failures": failures,
        "ok": not failures,
    }
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(
            f"Parsed {counts['json']} JSON and {counts['yaml']} YAML files; "
            f"checked {counts['schemas']} schema files; {len(failures)} failure(s)"
        )
        for failure in failures:
            print(f"ERROR {failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
