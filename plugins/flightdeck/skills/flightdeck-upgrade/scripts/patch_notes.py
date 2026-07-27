#!/usr/bin/env python3
"""Render deterministic Flightdeck patch notes from the release ledger."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


SCHEMA = "flightdeck-releases/v1"
CATEGORY_ORDER = ("added", "changed", "fixed", "security", "removed")


class ReleaseError(ValueError):
    """Raised when the release ledger or requested range is invalid."""


def load_ledger(path: Path) -> list[dict[str, Any]]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ReleaseError(f"cannot read release ledger: {exc}") from exc
    if document.get("schema_version") != SCHEMA:
        raise ReleaseError(f"unsupported release ledger schema: {document.get('schema_version')!r}")
    releases = document.get("releases")
    if not isinstance(releases, list) or not releases:
        raise ReleaseError("release ledger must contain a non-empty releases list")

    seen: set[str] = set()
    for index, release in enumerate(releases):
        if not isinstance(release, dict):
            raise ReleaseError(f"release {index} must be an object")
        version = release.get("version")
        if not isinstance(version, str) or not version:
            raise ReleaseError(f"release {index} has no version")
        if version in seen:
            raise ReleaseError(f"duplicate release version: {version}")
        seen.add(version)
        if not isinstance(release.get("summary"), str) or not release["summary"]:
            raise ReleaseError(f"release {version} has no summary")
        for field in ("changes", "breaking_changes", "migration"):
            if not isinstance(release.get(field), list):
                raise ReleaseError(f"release {version} field {field} must be a list")
        for change in release["changes"]:
            if not isinstance(change, dict):
                raise ReleaseError(f"release {version} contains a non-object change")
            if change.get("category") not in CATEGORY_ORDER:
                raise ReleaseError(
                    f"release {version} has unsupported change category: {change.get('category')!r}"
                )
            if not isinstance(change.get("text"), str) or not change["text"]:
                raise ReleaseError(f"release {version} contains a change without text")
    return releases


def select_range(
    releases: list[dict[str, Any]],
    from_version: str | None,
    to_version: str | None,
) -> dict[str, Any]:
    by_version = {release["version"]: index for index, release in enumerate(releases)}
    target = to_version or releases[-1]["version"]
    if target not in by_version:
        raise ReleaseError(f"target version is not recorded: {target}")
    target_index = by_version[target]

    if from_version is None:
        selected = [releases[target_index]]
        complete = True
        status = "latest"
    elif from_version == target:
        selected = []
        complete = True
        status = "current"
    elif from_version not in by_version:
        selected = [releases[target_index]]
        complete = False
        status = "unknown_from_version"
    else:
        start_index = by_version[from_version]
        if start_index > target_index:
            raise ReleaseError(
                f"installed version {from_version} is newer than target version {target}"
            )
        selected = releases[start_index + 1 : target_index + 1]
        complete = True
        status = "range"

    return {
        "schema_version": "flightdeck-patch-notes/v1",
        "from_version": from_version,
        "to_version": target,
        "status": status,
        "complete_range": complete,
        "releases": selected,
    }


def render_markdown(notes: dict[str, Any]) -> str:
    source = notes["from_version"] or "not specified"
    lines = [
        "# Flightdeck patch notes",
        "",
        f"- From: `{source}`",
        f"- To: `{notes['to_version']}`",
        f"- Complete recorded range: `{'yes' if notes['complete_range'] else 'no'}`",
        "",
    ]

    if notes["status"] == "current":
        lines.append("This installation already matches the requested target version.")
        return "\n".join(lines) + "\n"
    if not notes["complete_range"]:
        lines.extend(
            [
                "> The installed version is not present in the release ledger. "
                "Only the target release is shown; intermediate changes are unknown.",
                "",
            ]
        )

    for release in notes["releases"]:
        lines.extend(
            [
                f"## {release['version']} — {release.get('date', 'date not recorded')}",
                "",
                release["summary"],
                "",
            ]
        )
        for category in CATEGORY_ORDER:
            changes = [
                change["text"]
                for change in release["changes"]
                if change["category"] == category
            ]
            if changes:
                lines.extend([f"### {category.title()}", ""])
                lines.extend(f"- {change}" for change in changes)
                lines.append("")
        if release["breaking_changes"]:
            lines.extend(["### Breaking changes", ""])
            lines.extend(f"- {item}" for item in release["breaking_changes"])
            lines.append("")
        if release["migration"]:
            lines.extend(["### Upgrade notes", ""])
            lines.extend(f"- {item}" for item in release["migration"])
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--releases", required=True, type=Path)
    parser.add_argument("--from-version")
    parser.add_argument("--to-version")
    parser.add_argument("--json", action="store_true", dest="as_json")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        notes = select_range(
            load_ledger(args.releases),
            args.from_version,
            args.to_version,
        )
    except ReleaseError as exc:
        print(f"patch notes error: {exc}", file=sys.stderr)
        return 2
    if args.as_json:
        json.dump(notes, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        sys.stdout.write(render_markdown(notes))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
