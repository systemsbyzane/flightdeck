#!/usr/bin/env python3
"""Report local and agent-runtime prerequisites for Flightdeck setup."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess


COMMANDS = ("python3", "ruby", "git")
RUNTIME_REQUIREMENTS = (
    "live_project_list",
    "native_project_registration_or_supported_open_folder",
    "task_search_and_create",
    "workspace_dependency_loader",
    "documents_capability",
    "pdf_capability",
    "spreadsheets_capability",
)


def version(command: str) -> str | None:
    path = shutil.which(command)
    if not path:
        return None
    result = subprocess.run(
        [path, "--version"], text=True, capture_output=True, check=False, timeout=10
    )
    return (result.stdout or result.stderr).splitlines()[0].strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    commands = {
        command: {"path": shutil.which(command), "version": version(command)}
        for command in COMMANDS
    }
    report = {
        "schema_version": "flightdeck.setup-preflight/v1",
        "local_ready": all(item["path"] for item in commands.values()),
        "commands": commands,
        "agent_runtime_requirements": [
            {"capability": item, "status": "agent_verification_required"}
            for item in RUNTIME_REQUIREMENTS
        ],
    }
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        for command, item in commands.items():
            print(f"{command}: {item['version'] or 'missing'}")
        print("Agent runtime and artifact capabilities require live verification.")
    return 0 if report["local_ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
