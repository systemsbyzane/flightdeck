#!/usr/bin/env python3
"""Generate a portable Flightdeck from the bundled template."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def atomic_text(path: Path, content: str) -> None:
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path)
    parser.add_argument("--no-git", action="store_true", help="Do not initialize a Git repository")
    parser.add_argument("--json", action="store_true", help="Emit a machine-readable result")
    args = parser.parse_args()

    template = Path(__file__).resolve().parent.parent / "assets" / "flightdeck-template"
    requested = args.target.expanduser()
    if requested.is_symlink():
        parser.error(f"target must not be a symlink: {requested}")
    target = requested.resolve()
    if not template.is_dir():
        parser.error(f"bundled template is missing: {template}")
    if target == Path(target.anchor) or target == Path.home().resolve():
        parser.error(f"unsafe target path: {target}")
    if target.exists() and any(target.iterdir()):
        parser.error(f"target must be absent or empty: {target}")

    target.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".flightdeck-setup-", dir=target.parent))
    try:
        shutil.copytree(template, staging, dirs_exist_ok=True)
        registry = staging / "flightdeck.yaml"
        escaped_root = json.dumps(str(target), ensure_ascii=False)[1:-1]
        atomic_text(
            registry,
            registry.read_text(encoding="utf-8").replace("__FLIGHTDECK_ROOT__", escaped_root),
        )
        local_registry = staging / "hub" / "state" / "repositories.yaml"
        local_registry.parent.mkdir(parents=True, exist_ok=True)
        atomic_text(
            local_registry,
            "api_version: flightdeck.dev/v1alpha1\n"
            "kind: LocalRepositoryRegistry\n"
            "repositories: {}\n",
        )
        project_registry = staging / "hub" / "state" / "projects.yaml"
        atomic_text(
            project_registry,
            "api_version: flightdeck.dev/v1alpha1\n"
            "kind: CodexProjectVerifications\n"
            "projects: {}\n",
        )
        (staging / "bin" / "flightdeck").chmod(0o755)
        for script in (staging / "scripts").glob("*.sh"):
            script.chmod(0o755)

        if not args.no_git:
            subprocess.run(
                ["git", "init", "--quiet", str(staging)],
                check=True,
                timeout=30,
            )
        if target.exists():
            target.rmdir()
        os.replace(staging, target)
    finally:
        if staging.exists():
            shutil.rmtree(staging)

    result = {
        "schema_version": "flightdeck.setup/v1",
        "target": str(target),
        "generated": True,
        "git_initialized": not args.no_git,
        "merge_performed": False,
        "next": f"{target / 'bin' / 'flightdeck'} doctor --json",
    }
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(f"Generated Flightdeck: {target}")
        print(f"Next: {result['next']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
