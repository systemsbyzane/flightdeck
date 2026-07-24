#!/usr/bin/env python3
"""Validate mandatory setup/runbook links and generated Hub document targets."""

from __future__ import annotations

import re
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "assets" / "flightdeck-template"
PLUGIN = ROOT.parent.parent
REPOSITORY_CANDIDATE = ROOT.parents[3]
SOURCE_REPOSITORY = (
    REPOSITORY_CANDIDATE
    if (REPOSITORY_CANDIDATE / ".agents" / "plugins" / "marketplace.json").is_file()
    else None
)
BRIDGE_SKILL = ROOT.parent / "flightdeck-repo-bridge"
REQUIRED = (
    ROOT / "references" / "setup-runbook.md",
    ROOT / "references" / "setup-contract.md",
    ROOT / "references" / "installed-acceptance.md",
    ROOT / "scripts" / "preflight.py",
    ROOT / "scripts" / "bootstrap.py",
    ROOT / "scripts" / "setup_flightdeck.py",
    ROOT / "scripts" / "acceptance_harness.py",
    ROOT / "scripts" / "scan_debranding.py",
    ROOT / "scripts" / "validate_structured.py",
    TEMPLATE / "AGENTS.md",
    TEMPLATE / "docs" / "README.md",
    TEMPLATE / "docs" / "codex-ui-workflow.md",
    TEMPLATE / "docs" / "workflows" / "thread-routing.md",
    TEMPLATE / "docs" / "workflows" / "repo-onboarding.md",
    TEMPLATE / "docs" / "workflows" / "configure-bridge-repos.md",
    TEMPLATE / "hub" / "repositories.yaml",
    TEMPLATE / "hub" / "schemas" / "repository-declarations.schema.json",
    TEMPLATE / "hub" / "schemas" / "project-verifications.schema.json",
    BRIDGE_SKILL / "references" / "configure-bridge-repos.md",
    PLUGIN / "process-parity.json",
)


def display(path: Path) -> str:
    for base in (ROOT, PLUGIN, SOURCE_REPOSITORY):
        if base is None:
            continue
        try:
            return str(path.relative_to(base))
        except ValueError:
            continue
    return str(path)


def local_markdown_link_failures(root: Path) -> list[str]:
    failures: list[str] = []
    pattern = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")
    for path in sorted(root.rglob("*.md")):
        if any(part in {".git", ".flightdeck-local", "__pycache__"} for part in path.parts):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for raw_target in pattern.findall(text):
            target = raw_target.strip().strip("<>")
            if not target or target.startswith(("#", "http://", "https://", "mailto:", "codex://")):
                continue
            target = unquote(target.split("#", 1)[0])
            resolved = (path.parent / target).resolve()
            if not resolved.exists():
                failures.append(
                    f"{display(path)} has missing local Markdown link: {raw_target}"
                )
    return failures


def main() -> int:
    required = list(REQUIRED)
    if SOURCE_REPOSITORY is not None:
        required.append(SOURCE_REPOSITORY / "README.md")
    failures = [f"missing: {display(path)}" for path in required if not path.is_file()]
    validation_root = SOURCE_REPOSITORY or PLUGIN
    failures.extend(local_markdown_link_failures(validation_root))
    skill = (ROOT / "SKILL.md").read_text(encoding="utf-8")
    if "references/setup-runbook.md" not in skill or "mandatory" not in skill.lower():
        failures.append("SKILL.md must mandate references/setup-runbook.md")

    triggers = (
        "configure bridge repos",
        "configure repository bridges",
        "set up all repos",
    )
    trigger_paths = (
        TEMPLATE / "AGENTS.md",
        TEMPLATE / "docs" / "workflows" / "configure-bridge-repos.md",
        PLUGIN / "skills" / "flightdeck" / "SKILL.md",
        BRIDGE_SKILL / "SKILL.md",
        BRIDGE_SKILL / "references" / "configure-bridge-repos.md",
    )
    for path in trigger_paths:
        text = path.read_text(encoding="utf-8").casefold()
        for trigger in triggers:
            if trigger not in text:
                failures.append(f"{display(path)} missing trigger: {trigger}")

    if SOURCE_REPOSITORY is not None:
        readme = (SOURCE_REPOSITORY / "README.md").read_text(encoding="utf-8")
        required_readme_links = (
            "plugins/flightdeck/skills/flightdeck-setup/references/setup-runbook.md",
            "plugins/flightdeck/skills/flightdeck-repo-bridge/references/configure-bridge-repos.md",
        )
        for relative in required_readme_links:
            if relative not in readme:
                failures.append(f"README.md missing runbook link: {relative}")

    bridge_skill = (BRIDGE_SKILL / "SKILL.md").read_text(encoding="utf-8")
    if "references/configure-bridge-repos.md" not in bridge_skill or "mandatory" not in bridge_skill.lower():
        failures.append("flightdeck-repo-bridge/SKILL.md must mandate configure-bridge-repos.md")

    for path in (TEMPLATE / "hub" / "bridges" / "templates").glob("*/AGENTS.override.md"):
        text = path.read_text(encoding="utf-8")
        for relative in re.findall(r"\{\{HUB_ROOT\}\}/(docs/[A-Za-z0-9_./-]+\.md)", text):
            if not (TEMPLATE / relative).is_file():
                failures.append(f"{path.relative_to(ROOT)} references missing {relative}")

    for failure in failures:
        print(f"ERROR {failure}")
    mode = "source-tree" if SOURCE_REPOSITORY is not None else "installed-package"
    print(
        f"Validated setup links ({mode}): {len(required)} required path(s), "
        f"{len(failures)} failure(s)"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
