#!/usr/bin/env python3
"""Inventory distributable process surfaces against a neutral parity manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Iterable


ALLOWED_STATUSES = {"matched", "generalized", "added", "intentionally_excluded"}
SOURCE_STATUSES = {"matched", "generalized"}


class InventoryError(ValueError):
    """Raised when the inventory contract itself is invalid."""


def _glob_regex(pattern: str) -> re.Pattern[str]:
    """Compile a portable path glob where ``*`` never crosses ``/``."""

    expression = ""
    index = 0
    while index < len(pattern):
        character = pattern[index]
        if character == "*":
            if index + 1 < len(pattern) and pattern[index + 1] == "*":
                index += 2
                if index < len(pattern) and pattern[index] == "/":
                    expression += "(?:.*/)?"
                    index += 1
                else:
                    expression += ".*"
                continue
            expression += "[^/]*"
        elif character == "?":
            expression += "[^/]"
        else:
            expression += re.escape(character)
        index += 1
    return re.compile(f"^{expression}$")


def matches(path: str, patterns: Iterable[str]) -> bool:
    return any(_glob_regex(pattern).fullmatch(path) for pattern in patterns)


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".process-inventory-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def require_local_report(path: Path) -> None:
    if ".flightdeck-local" not in path.resolve().parts:
        raise InventoryError("JSON report must be written under .flightdeck-local")


def candidate_files(root: Path) -> list[str]:
    if not root.is_dir():
        raise InventoryError("candidate root is not a directory")
    paths = []
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if (
            not (path.is_file() or path.is_symlink())
            or path.name == ".DS_Store"
            or any(
                part in {".git", ".flightdeck-local", "__pycache__"}
                for part in relative.parts
            )
        ):
            continue
        paths.append(relative.as_posix())
    return sorted(paths)


def source_files(root: Path) -> list[str]:
    if not root.is_dir():
        raise InventoryError("source root is not a directory")
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-co", "--exclude-standard", "-z"],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        raise InventoryError("source inventory requires a readable Git worktree")
    decoded = result.stdout.decode("utf-8").split("\0")
    paths = sorted(path for path in decoded if path)
    if any(path.startswith("/") or ".." in Path(path).parts for path in paths):
        raise InventoryError("source inventory contains a path outside its root")
    return paths


def canonical_source_paths(paths: list[str]) -> dict[str, str]:
    """Derive neutral aliases for source-specific control-plane filenames."""

    aliases = {path: path for path in paths}

    registries = [
        path
        for path in paths
        if "/" not in path and Path(path).suffix.lower() in {".yaml", ".yml"}
    ]
    if len(registries) == 1:
        aliases[registries[0]] = "@registry"

    entrypoints = [path for path in paths if path.startswith("bin/") and "/" not in path[4:]]
    if len(entrypoints) == 1:
        aliases[entrypoints[0]] = "@entrypoint"

    library_roots = {
        parts[1]
        for path in paths
        if len(parts := Path(path).parts) >= 3 and parts[0] == "lib"
    }
    if len(library_roots) == 1:
        library_root = next(iter(library_roots))
        for path in paths:
            prefix = f"lib/{library_root}/"
            if path.startswith(prefix):
                aliases[path] = f"lib/@control-plane/{path[len(prefix):]}"

    return aliases


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise InventoryError("parity manifest is missing or invalid JSON") from error
    if not isinstance(manifest, dict) or manifest.get("schema_version") != "process-parity/v1":
        raise InventoryError("unsupported parity manifest schema")
    capabilities = manifest.get("capabilities")
    exclusions = manifest.get("exclusions")
    plugin_exclusions = manifest.get("plugin_exclusions", [])
    if (
        not isinstance(capabilities, list)
        or not isinstance(exclusions, list)
        or not isinstance(plugin_exclusions, list)
    ):
        raise InventoryError("manifest capabilities and exclusions must be arrays")

    records = capabilities + exclusions + plugin_exclusions
    identifiers: set[str] = set()
    for record in records:
        if not isinstance(record, dict):
            raise InventoryError("manifest records must be objects")
        identifier = record.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise InventoryError("every mapping requires a neutral ID")
        if identifier in identifiers:
            raise InventoryError("duplicate mapping ID")
        identifiers.add(identifier)
        status = record.get("status")
        if status not in ALLOWED_STATUSES:
            raise InventoryError("invalid mapping status")
        source_patterns = record.get("source_paths", [])
        candidate_paths = record.get("candidate_paths", [])
        plugin_paths = record.get("plugin_paths", [])
        if not isinstance(source_patterns, list) or not all(
            isinstance(item, str) and item for item in source_patterns
        ):
            raise InventoryError("source_paths must contain non-empty strings")
        if not isinstance(candidate_paths, list) or not all(
            isinstance(item, str) and item for item in candidate_paths
        ):
            raise InventoryError("candidate_paths must contain non-empty strings")
        if not isinstance(plugin_paths, list) or not all(
            isinstance(item, str) and item for item in plugin_paths
        ):
            raise InventoryError("plugin_paths must contain non-empty strings")
        expected_source_count = record.get("source_count", 0)
        if not isinstance(expected_source_count, int) or expected_source_count < 0:
            raise InventoryError("source_count must be a non-negative integer")
        if status in SOURCE_STATUSES and not (source_patterns or plugin_paths):
            raise InventoryError("source mappings require source_paths")
        expected_plugin_count = record.get("plugin_count", 0)
        if not isinstance(expected_plugin_count, int) or expected_plugin_count < 0:
            raise InventoryError("plugin_count must be a non-negative integer")
        if status == "intentionally_excluded":
            is_source_exclusion = record in exclusions
            is_plugin_exclusion = record in plugin_exclusions
            if is_source_exclusion == is_plugin_exclusion:
                raise InventoryError("each exclusion must have exactly one scope")
            if is_source_exclusion and (not source_patterns or candidate_paths or plugin_paths):
                raise InventoryError("source exclusions require only precise source_paths")
            if is_plugin_exclusion and (not plugin_paths or candidate_paths or source_patterns):
                raise InventoryError("plugin exclusions require only precise plugin_paths")
            if not isinstance(record.get("reason"), str) or not record["reason"].strip():
                raise InventoryError("exclusions require a neutral reason")
        elif record in exclusions or record in plugin_exclusions:
            raise InventoryError("exclusion records must use excluded status")
        if status != "intentionally_excluded" and not (candidate_paths or plugin_paths):
            raise InventoryError("non-excluded mappings require candidate_paths or plugin_paths")
    return manifest


def _record_matches(path: str, records: list[dict[str, Any]], key: str) -> list[dict[str, Any]]:
    return [record for record in records if matches(path, record.get(key, []))]


def build_report(
    *,
    source: Path | None,
    candidate: Path,
    plugin: Path,
) -> dict[str, Any]:
    manifest_path = plugin / "process-parity.json"
    manifest = load_manifest(manifest_path)
    capabilities = manifest["capabilities"]
    exclusions = manifest["exclusions"]
    plugin_exclusions = manifest.get("plugin_exclusions", [])
    source_records = capabilities + exclusions
    plugin_records = capabilities + plugin_exclusions

    candidate_inventory = candidate_files(candidate)
    candidate_classification: list[dict[str, str]] = []
    unclassified_candidate: list[str] = []
    ambiguous_candidate: list[str] = []
    for path in candidate_inventory:
        found = _record_matches(path, capabilities, "candidate_paths")
        if len(found) == 1:
            candidate_classification.append(
                {"path": path, "mapping_id": found[0]["id"], "status": found[0]["status"]}
            )
        elif not found:
            unclassified_candidate.append(path)
        else:
            ambiguous_candidate.append(path)

    missing_candidate_paths: list[dict[str, str]] = []
    for record in capabilities:
        for pattern in record["candidate_paths"]:
            if not matches_any(candidate_inventory, pattern):
                missing_candidate_paths.append(
                    {"mapping_id": record["id"], "candidate_path": pattern}
                )

    plugin_inventory = candidate_files(plugin)
    plugin_classification: list[dict[str, str]] = []
    unclassified_plugin: list[str] = []
    ambiguous_plugin: list[str] = []
    asset_prefix = "skills/flightdeck-setup/assets/flightdeck-template/"
    for path in plugin_inventory:
        if path.startswith(asset_prefix):
            candidate_path = path[len(asset_prefix) :]
            found = _record_matches(candidate_path, capabilities, "candidate_paths")
        else:
            excluded = _record_matches(path, plugin_exclusions, "plugin_paths")
            mapped = _record_matches(path, capabilities, "plugin_paths")
            found = excluded or mapped
            if excluded and mapped:
                found = excluded + mapped
        if len(found) == 1:
            plugin_classification.append(
                {"path": path, "mapping_id": found[0]["id"], "status": found[0]["status"]}
            )
        elif not found:
            unclassified_plugin.append(path)
        else:
            ambiguous_plugin.append(path)

    plugin_count_errors: list[dict[str, Any]] = []
    for record in plugin_records:
        patterns = record.get("plugin_paths", [])
        actual = sum(1 for path in plugin_inventory if matches(path, patterns))
        expected = record.get("plugin_count", 0)
        if actual != expected:
            plugin_count_errors.append(
                {"mapping_id": record["id"], "expected": expected, "actual": actual}
            )

    source_inventory: list[str] = []
    source_classification: list[dict[str, str]] = []
    unresolved_source: list[str] = []
    ambiguous_source: list[str] = []
    source_count_errors: list[dict[str, Any]] = []
    if source is not None:
        source_inventory = source_files(source)
        aliases = canonical_source_paths(source_inventory)
        for path in source_inventory:
            alias = aliases[path]
            excluded = _record_matches(alias, exclusions, "source_paths")
            mapped = _record_matches(alias, capabilities, "source_paths")
            found = excluded or mapped
            if len(found) == 1 and not (excluded and mapped):
                source_classification.append(
                    {
                        "path": path,
                        "surface": alias,
                        "mapping_id": found[0]["id"],
                        "status": found[0]["status"],
                    }
                )
            elif not found:
                unresolved_source.append(path)
            else:
                ambiguous_source.append(path)

        for record in source_records:
            actual = sum(
                1
                for alias in aliases.values()
                if matches(alias, record.get("source_paths", []))
            )
            expected = record.get("source_count", 0)
            if actual != expected:
                source_count_errors.append(
                    {"mapping_id": record["id"], "expected": expected, "actual": actual}
                )

    mapped_count = sum(
        1 for item in source_classification if item["status"] in SOURCE_STATUSES
    )
    excluded_count = sum(
        1
        for item in source_classification
        if item["status"] == "intentionally_excluded"
    )
    unresolved_count = (
        len(unresolved_source)
        + len(ambiguous_source)
        + len(unclassified_candidate)
        + len(ambiguous_candidate)
        + len(missing_candidate_paths)
        + len(source_count_errors)
        + len(unclassified_plugin)
        + len(ambiguous_plugin)
        + len(plugin_count_errors)
    )
    failures: list[str] = []
    for name, values in (
        ("unresolved_source", unresolved_source),
        ("ambiguous_source", ambiguous_source),
        ("source_count_mismatch", source_count_errors),
        ("unclassified_candidate", unclassified_candidate),
        ("ambiguous_candidate", ambiguous_candidate),
        ("missing_candidate_path", missing_candidate_paths),
        ("unclassified_plugin", unclassified_plugin),
        ("ambiguous_plugin", ambiguous_plugin),
        ("plugin_count_mismatch", plugin_count_errors),
    ):
        if values:
            failures.append(name)
    ok = not failures
    return {
        "schema_version": "process-inventory/v1",
        "ok": ok,
        "failures": failures,
        "counts": {
            "source": len(source_inventory),
            "candidate": len(candidate_inventory),
            "plugin": len(plugin_inventory),
            "mapped": mapped_count,
            "excluded": excluded_count,
            "unresolved": unresolved_count,
        },
        "digests": {
            "source_paths_sha256": path_list_digest(source_inventory),
            "candidate_paths_sha256": path_list_digest(candidate_inventory),
            "plugin_paths_sha256": path_list_digest(plugin_inventory),
        },
        "passed": ok,
        "source": {
            "files": source_inventory,
            "classification": source_classification,
            "unresolved": unresolved_source,
            "ambiguous": ambiguous_source,
            "count_errors": source_count_errors,
        },
        "candidate": {
            "files": candidate_inventory,
            "classification": candidate_classification,
            "unclassified": unclassified_candidate,
            "ambiguous": ambiguous_candidate,
            "missing_paths": missing_candidate_paths,
        },
        "plugin": {
            "files": plugin_inventory,
            "classification": plugin_classification,
            "unclassified": unclassified_plugin,
            "ambiguous": ambiguous_plugin,
            "count_errors": plugin_count_errors,
        },
    }


def matches_any(paths: Iterable[str], pattern: str) -> bool:
    compiled = _glob_regex(pattern)
    return any(compiled.fullmatch(path) for path in paths)


def path_list_digest(paths: Iterable[str]) -> str:
    value = "".join(f"{path}\n" for path in paths).encode("utf-8")
    return hashlib.sha256(value).hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--json", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        require_local_report(args.json)
        report = build_report(
            source=args.source.resolve() if args.source else None,
            candidate=args.candidate.resolve(),
            plugin=args.plugin.resolve(),
        )
        atomic_json(args.json.resolve(), report)
    except InventoryError as error:
        print(f"process inventory error: {error}")
        return 2
    print(json.dumps(report["counts"], sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
