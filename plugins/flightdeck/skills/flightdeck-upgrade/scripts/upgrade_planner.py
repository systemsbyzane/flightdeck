#!/usr/bin/env python3
"""Create a read-only Flightdeck plugin upgrade plan from Codex JSON state."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


class PlanError(ValueError):
    """Raised when exact upgrade identities cannot be resolved."""


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PlanError(f"cannot read {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise PlanError(f"{label} must be a JSON object")
    return value


def find_marketplace(document: dict[str, Any], name: str) -> dict[str, Any]:
    matches = [
        item
        for item in document.get("marketplaces", [])
        if isinstance(item, dict) and item.get("name") == name
    ]
    if len(matches) != 1:
        raise PlanError(f"expected exactly one configured marketplace named {name!r}")
    return matches[0]


def find_installed(
    document: dict[str, Any], plugin: str, marketplace: str
) -> dict[str, Any]:
    plugin_id = f"{plugin}@{marketplace}"
    matches = [
        item
        for item in document.get("installed", [])
        if isinstance(item, dict)
        and (
            item.get("pluginId") == plugin_id
            or (
                item.get("name") == plugin
                and item.get("marketplaceName") == marketplace
            )
        )
    ]
    if len(matches) != 1:
        raise PlanError(f"expected exactly one installed plugin named {plugin_id!r}")
    if matches[0].get("installed") is not True:
        raise PlanError(f"plugin {plugin_id!r} is not marked installed")
    return matches[0]


def resolve_target_manifest(
    marketplace: dict[str, Any], plugin: str
) -> tuple[Path, dict[str, Any], Path]:
    root_value = marketplace.get("root")
    if not isinstance(root_value, str) or not root_value:
        raise PlanError("marketplace root is unavailable")
    root = Path(root_value).expanduser().resolve()
    catalog_path = root / ".agents" / "plugins" / "marketplace.json"
    catalog = load_json(catalog_path, "marketplace catalog")
    matches = [
        item
        for item in catalog.get("plugins", [])
        if isinstance(item, dict) and item.get("name") == plugin
    ]
    if len(matches) != 1:
        raise PlanError(f"expected exactly one marketplace entry for plugin {plugin!r}")
    source = matches[0].get("source")
    if not isinstance(source, dict) or source.get("source") != "local":
        raise PlanError("marketplace plugin source is not a resolvable local snapshot")
    relative = source.get("path")
    if not isinstance(relative, str) or not relative:
        raise PlanError("marketplace plugin source has no path")
    plugin_root = (root / relative).resolve()
    try:
        plugin_root.relative_to(root)
    except ValueError as exc:
        raise PlanError("marketplace plugin path escapes its configured root") from exc
    manifest_path = plugin_root / ".codex-plugin" / "plugin.json"
    manifest = load_json(manifest_path, "target plugin manifest")
    if manifest.get("name") != plugin:
        raise PlanError("target manifest plugin name does not match the requested plugin")
    if not isinstance(manifest.get("version"), str) or not manifest["version"]:
        raise PlanError("target manifest has no version")
    releases_path = plugin_root / "releases.json"
    releases = load_json(releases_path, "target release ledger")
    if releases.get("schema_version") != "flightdeck-releases/v1":
        raise PlanError("target release ledger has an unsupported schema")
    entries = releases.get("releases")
    if not isinstance(entries, list) or not entries:
        raise PlanError("target release ledger has no releases")
    latest = entries[-1]
    if not isinstance(latest, dict) or latest.get("version") != manifest["version"]:
        raise PlanError(
            "target release ledger latest version does not match the target manifest"
        )
    return manifest_path, manifest, releases_path


def build_plan(
    plugin_state: dict[str, Any],
    marketplace_state: dict[str, Any],
    plugin: str,
    marketplace_name: str,
) -> dict[str, Any]:
    marketplace = find_marketplace(marketplace_state, marketplace_name)
    installed = find_installed(plugin_state, plugin, marketplace_name)
    manifest_path, target_manifest, releases_path = resolve_target_manifest(
        marketplace, plugin
    )
    current = installed.get("version")
    if not isinstance(current, str) or not current:
        raise PlanError("installed plugin has no exact version")
    target = target_manifest["version"]

    source = marketplace.get("marketplaceSource")
    source_type = source.get("sourceType") if isinstance(source, dict) else None
    if source_type == "local":
        refresh = "not_required"
        refresh_command = None
    elif source_type in {"git", "github"}:
        refresh = "required_before_final_plan"
        refresh_command = [
            "codex",
            "plugin",
            "marketplace",
            "upgrade",
            marketplace_name,
            "--json",
        ]
    else:
        refresh = "unknown"
        refresh_command = None

    if current == target:
        status = "current"
    else:
        status = "update_available"

    return {
        "schema_version": "flightdeck-upgrade-plan/v1",
        "status": status,
        "plugin_id": f"{plugin}@{marketplace_name}",
        "installed_version": current,
        "target_version": target,
        "target_manifest": str(manifest_path),
        "target_release_ledger": str(releases_path),
        "installed_enabled": installed.get("enabled") is True,
        "marketplace_source_type": source_type or "unknown",
        "marketplace_refresh": refresh,
        "commands": {
            "marketplace_refresh": refresh_command,
            "install": [
                "codex",
                "plugin",
                "add",
                f"{plugin}@{marketplace_name}",
                "--json",
            ],
            "verify": [
                "codex",
                "plugin",
                "list",
                "--marketplace",
                marketplace_name,
                "--available",
                "--json",
            ],
        },
        "approval_required": [
            action
            for action, command in (
                ("marketplace_refresh", refresh_command),
                ("plugin_reinstall", True),
            )
            if command
        ],
        "protected_state": [
            "generated_hubs",
            "hub_ignored_local_state",
            "attached_repositories",
            "tasks_and_runtime_ids",
            "evidence_and_credentials",
        ],
        "invariants": [
            "do_not_remove_plugin_first",
            "do_not_edit_plugin_cache",
            "do_not_run_setup_or_bootstrap",
            "do_not_migrate_generated_hubs",
            "start_fresh_task_after_upgrade",
        ],
        "warnings": (
            [
                "Marketplace source type is unknown; resolve whether a supported "
                "refresh is needed before applying."
            ]
            if source_type is None
            else []
        ),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-list", required=True, type=Path)
    parser.add_argument("--marketplaces", required=True, type=Path)
    parser.add_argument("--plugin", default="flightdeck")
    parser.add_argument("--marketplace", required=True)
    parser.add_argument("--json", action="store_true", dest="as_json")
    return parser.parse_args()


def render_text(plan: dict[str, Any]) -> str:
    lines = [
        f"Plugin: {plan['plugin_id']}",
        f"Status: {plan['status']}",
        f"Installed: {plan['installed_version']}",
        f"Target: {plan['target_version']}",
        f"Marketplace source: {plan['marketplace_source_type']}",
        f"Marketplace refresh: {plan['marketplace_refresh']}",
        "Protected: " + ", ".join(plan["protected_state"]),
        "Approval required: " + ", ".join(plan["approval_required"]),
    ]
    if plan["warnings"]:
        lines.extend(f"Warning: {warning}" for warning in plan["warnings"])
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    try:
        plan = build_plan(
            load_json(args.plugin_list, "plugin list"),
            load_json(args.marketplaces, "marketplace list"),
            args.plugin,
            args.marketplace,
        )
    except PlanError as exc:
        print(f"upgrade plan error: {exc}", file=sys.stderr)
        return 2
    if args.as_json:
        json.dump(plan, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        sys.stdout.write(render_text(plan))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
