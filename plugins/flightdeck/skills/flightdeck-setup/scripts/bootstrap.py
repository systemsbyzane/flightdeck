#!/usr/bin/env python3
"""Preview or apply a deterministic first-time Flightdeck bootstrap."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


SCRIPTS = Path(__file__).resolve().parent
SKILL_ROOT = SCRIPTS.parent
TEMPLATE = SKILL_ROOT / "assets" / "flightdeck-template"
PREFLIGHT = SCRIPTS / "preflight.py"
SETUP = SCRIPTS / "setup_flightdeck.py"
STRUCTURED = SCRIPTS / "validate_structured.py"
SCANNER = SCRIPTS / "scan_debranding.py"
LINKS = SCRIPTS / "validate_links.py"
REPOSITORY_ROOT = SKILL_ROOT.parents[3]
COMMAND_TIMEOUT = 300
CONFIGURABLE_MANAGED_FILES = {
    Path("flightdeck.yaml"),
    Path("hub/repositories.yaml"),
}
RUBY_SUMMARY = re.compile(
    r"(?P<runs>\d+) runs, (?P<assertions>\d+) assertions, "
    r"(?P<failures>\d+) failures, (?P<errors>\d+) errors, "
    r"(?P<skips>\d+) skips"
)
DEBRANDING_SUMMARY = re.compile(r"(?P<findings>\d+) finding\(s\)")


class BootstrapFailure(RuntimeError):
    """A deterministic bootstrap refusal or validation failure."""

    def __init__(self, stage: str, message: str, *, exit_code: int = 1) -> None:
        super().__init__(message)
        self.stage = stage
        self.exit_code = exit_code


def run(
    arguments: list[str],
    *,
    cwd: Path,
    stage: str,
    timeout: int = COMMAND_TIMEOUT,
    allowed_exit_codes: tuple[int, ...] = (0,),
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            arguments,
            cwd=cwd,
            text=True,
            capture_output=True,
            check=False,
            timeout=timeout,
            env={**os.environ, "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BootstrapFailure(stage, f"command could not complete: {error}") from error
    if result.returncode not in allowed_exit_codes:
        details = (result.stderr or result.stdout).strip()
        suffix = f": {details}" if details else ""
        raise BootstrapFailure(
            stage,
            f"command exited {result.returncode}{suffix}",
        )
    return result


def json_result(
    arguments: list[str],
    *,
    cwd: Path,
    stage: str,
    allowed_exit_codes: tuple[int, ...] = (0,),
) -> dict[str, Any]:
    result = run(
        arguments,
        cwd=cwd,
        stage=stage,
        allowed_exit_codes=allowed_exit_codes,
    )
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise BootstrapFailure(stage, f"command returned invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise BootstrapFailure(stage, "command returned a non-object JSON value")
    return value


def normalize_target(requested: Path) -> Path:
    expanded = requested.expanduser()
    if expanded.is_symlink():
        raise BootstrapFailure(
            "target",
            f"target must not be a symlink: {expanded.absolute()}",
            exit_code=2,
        )
    try:
        target = expanded.resolve(strict=False)
    except (OSError, RuntimeError) as error:
        raise BootstrapFailure(
            "target", f"target path cannot be normalized: {error}", exit_code=2
        ) from error
    if target == Path(target.anchor) or target == Path.home().resolve():
        raise BootstrapFailure(
            "target", f"unsafe target path: {target}", exit_code=2
        )
    if target.exists() and not target.is_dir():
        raise BootstrapFailure(
            "target", f"target must be absent or a directory: {target}", exit_code=2
        )
    try:
        source_relative = target.relative_to(REPOSITORY_ROOT.resolve())
    except ValueError:
        pass
    else:
        if not source_relative.parts or source_relative.parts[0] != ".flightdeck-local":
            raise BootstrapFailure(
                "target",
                f"target must be outside the Flightdeck plugin source: {target}",
                exit_code=2,
            )
    return target


def normalize_repositories_root(requested: Path) -> Path:
    expanded = requested.expanduser()
    if not expanded.is_absolute():
        raise BootstrapFailure(
            "repositories-root",
            f"repositories root must be absolute: {expanded}",
            exit_code=2,
        )
    if expanded.is_symlink():
        raise BootstrapFailure(
            "repositories-root",
            f"repositories root must not be a symlink: {expanded.absolute()}",
            exit_code=2,
        )
    try:
        root = expanded.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise BootstrapFailure(
            "repositories-root",
            f"repositories root cannot be normalized: {error}",
            exit_code=2,
        ) from error
    if not root.is_dir():
        raise BootstrapFailure(
            "repositories-root",
            f"repositories root must be a directory: {root}",
            exit_code=2,
        )
    if root == Path(root.anchor) or root == Path.home().resolve():
        raise BootstrapFailure(
            "repositories-root",
            f"repositories root is too broad: {root}",
            exit_code=2,
        )
    return root


def preflight() -> dict[str, Any]:
    report = json_result(
        [sys.executable, str(PREFLIGHT), "--json"],
        cwd=SCRIPTS,
        stage="preflight",
    )
    commands = report.get("commands")
    if not report.get("local_ready") or not isinstance(commands, dict):
        missing = [
            command
            for command in ("python3", "ruby", "git")
            if not isinstance(commands, dict)
            or not isinstance(commands.get(command), dict)
            or not commands[command].get("path")
        ]
        raise BootstrapFailure(
            "preflight",
            "missing required local command(s): " + ", ".join(missing),
        )
    return report


def parse_registry(path: Path, ruby: str) -> dict[str, Any]:
    script = (
        "value=YAML.safe_load(File.read(ARGV.fetch(0)),"
        " permitted_classes:[Date,Time], permitted_symbols:[], aliases:false);"
        "puts JSON.generate(value)"
    )
    return json_result(
        [ruby, "-rjson", "-ryaml", "-rdate", "-e", script, str(path)],
        cwd=path.parent,
        stage="target-recognition",
    )


def expected_managed_files() -> list[Path]:
    return sorted(path for path in TEMPLATE.rglob("*") if path.is_file())


def expected_managed_bytes(source: Path, target: Path) -> bytes:
    content = source.read_bytes()
    if source.relative_to(TEMPLATE) == Path("flightdeck.yaml"):
        escaped_root = json.dumps(str(target), ensure_ascii=False)[1:-1].encode("utf-8")
        content = content.replace(b"__FLIGHTDECK_ROOT__", escaped_root)
    return content


def recognize_generated_target(target: Path, ruby: str) -> None:
    required = [
        target / "flightdeck.yaml",
        target / "hub" / "state" / "repositories.yaml",
        target / "hub" / "state" / "projects.yaml",
    ]
    missing = [str(path.relative_to(target)) for path in required if not path.is_file()]
    if missing:
        raise BootstrapFailure(
            "target-recognition",
            "non-empty target is not a complete generated Flightdeck; "
            f"missing: {', '.join(missing)}",
            exit_code=2,
        )

    mismatches: list[str] = []
    for source in expected_managed_files():
        relative = source.relative_to(TEMPLATE)
        if relative in CONFIGURABLE_MANAGED_FILES:
            continue
        candidate = target / relative
        if (
            not candidate.is_file()
            or candidate.read_bytes() != expected_managed_bytes(source, target)
        ):
            mismatches.append(str(relative))
    if mismatches:
        raise BootstrapFailure(
            "target-recognition",
            "non-empty target has unrecognized generated managed content: "
            + ", ".join(mismatches),
            exit_code=2,
        )

    registry = parse_registry(target / "flightdeck.yaml", ruby)
    workspace = registry.get("workspace")
    projects = registry.get("codex_projects")
    configured_root = workspace.get("root") if isinstance(workspace, dict) else None
    coordination = projects.get("flightdeck") if isinstance(projects, dict) else None
    coordination_path = (
        coordination.get("path") if isinstance(coordination, dict) else None
    )
    if (
        registry.get("api_version") != "flightdeck.dev/v1alpha1"
        or registry.get("kind") != "FlightdeckRegistry"
        or configured_root != str(target)
        or coordination_path != str(target)
    ):
        raise BootstrapFailure(
            "target-recognition",
            "non-empty target is not a generated Flightdeck for the exact normalized "
            f"path {target}",
            exit_code=2,
        )


def target_state(target: Path, ruby: str) -> str:
    if not target.exists():
        return "absent"
    if not any(target.iterdir()):
        return "empty"
    recognize_generated_target(target, ruby)
    return "generated"


def validate(target: Path, python3: str, ruby: str) -> dict[str, Any]:
    ruby_result = run(
        [ruby, "-Ilib", "tests/flightdeck_test.rb"],
        cwd=target,
        stage="ruby-tests",
    )
    match = RUBY_SUMMARY.search(ruby_result.stdout)
    if not match:
        raise BootstrapFailure("ruby-tests", "Minitest summary counts were not found")
    ruby_counts = {key: int(value) for key, value in match.groupdict().items()}

    structured = json_result(
        [python3, str(STRUCTURED), str(target), "--json"],
        cwd=SCRIPTS,
        stage="structured-validation",
    )
    counts = structured.get("counts")
    if structured.get("ok") is not True or not isinstance(counts, dict):
        raise BootstrapFailure(
            "structured-validation", "structured validation did not report success"
        )
    structured_counts = {
        name: counts.get(name) for name in ("json", "yaml", "schemas")
    }
    failures = structured.get("failures")
    if (
        any(not isinstance(value, int) for value in structured_counts.values())
        or not isinstance(failures, list)
    ):
        raise BootstrapFailure(
            "structured-validation", "structured validation counts are invalid"
        )

    doctor = json_result(
        [str(target / "bin" / "flightdeck"), "doctor", "--json"],
        cwd=target,
        stage="doctor",
    )
    summary = doctor.get("summary")
    if not isinstance(summary, dict):
        raise BootstrapFailure("doctor", "Doctor summary counts were not found")
    doctor_count_names = (
        "errors",
        "warnings",
        "findings",
        "repositories",
        "tasks",
        "compliance_pairs",
        "bridges",
        "repository_declarations",
    )
    doctor_counts = {name: summary.get(name) for name in doctor_count_names}
    if any(not isinstance(value, int) for value in doctor_counts.values()):
        raise BootstrapFailure("doctor", "Doctor summary counts are invalid")
    if doctor_counts["errors"]:
        raise BootstrapFailure(
            "doctor", f"Doctor reported {doctor_counts['errors']} error(s)"
        )

    debranding = run(
        [python3, str(SCANNER), str(target), "--allow-generated-root"],
        cwd=SCRIPTS,
        stage="debranding",
    )
    finding_match = DEBRANDING_SUMMARY.search(debranding.stdout)
    if not finding_match:
        raise BootstrapFailure("debranding", "de-branding finding count was not found")
    findings = int(finding_match.group("findings"))
    links = run(
        [python3, str(LINKS)],
        cwd=SCRIPTS,
        stage="setup-links",
    )
    link_match = re.search(
        r"Validated setup links \([^)]+\): (?P<required>\d+) required path\(s\), "
        r"(?P<failures>\d+) failure\(s\)",
        links.stdout,
    )
    if not link_match:
        raise BootstrapFailure("setup-links", "setup-link counts were not found")

    return {
        "ruby_tests": ruby_counts,
        "structured": {
            **structured_counts,
            "failures": len(failures),
        },
        "doctor": {
            **doctor_counts,
            "no_fetch": doctor.get("no_fetch") is True,
        },
        "debranding": {"findings": findings},
        "setup_links": {
            key: int(value) for key, value in link_match.groupdict().items()
        },
    }


def base_report(target: Path, mode: str, preflight_report: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": "flightdeck.bootstrap/v1",
        "target": str(target),
        "mode": mode,
        "status": "pending",
        "generated": False,
        "no_op": False,
        "credential_free": True,
        "preflight": {
            command: preflight_report["commands"][command]
            for command in ("python3", "ruby", "git")
        },
        "runtime_status": "agent_verification_required",
        "runtime_requirements": preflight_report.get("agent_runtime_requirements", []),
        "validation": None,
        "repository_setup": None,
        "external_actions": {
            "plugin_installed": False,
            "git_staged": False,
            "git_committed": False,
            "git_pushed": False,
            "secrets_configured": False,
            "projects_registered": False,
            "published": False,
            "portable_repository_declarations_written": False,
            "local_repository_state_written": False,
            "safe_reference_bridges_installed": False,
            "tracked_repository_files_changed": False,
        },
    }


def repository_setup_plan(
    hub: Path,
    ruby: str,
    repositories_root: Path,
) -> dict[str, Any]:
    return json_result(
        [
            ruby,
            str(hub / "bin" / "flightdeck"),
            "setup",
            "plan",
            "--repositories-root",
            str(repositories_root),
            "--failure-policy",
            "continue",
            "--json",
        ],
        cwd=hub,
        stage="repository-discovery",
    )


def repository_setup_connect(
    hub: Path,
    ruby: str,
    repositories_root: Path,
) -> dict[str, Any]:
    return json_result(
        [
            ruby,
            str(hub / "bin" / "flightdeck"),
            "setup",
            "connect",
            "--repositories-root",
            str(repositories_root),
            "--failure-policy",
            "continue",
            "--json",
        ],
        cwd=hub,
        stage="repository-connection",
        allowed_exit_codes=(0, 1),
    )


def record_repository_connection(
    report: dict[str, Any],
    connection: dict[str, Any],
) -> None:
    report["repository_setup"]["connection"] = connection
    bridge_summary = connection.get("bridge_receipt", {}).get("summary", {})
    changed = connection.get("changed") is True
    report["external_actions"]["portable_repository_declarations_written"] = changed
    report["external_actions"]["local_repository_state_written"] = changed
    report["external_actions"]["safe_reference_bridges_installed"] = (
        bridge_summary.get("installed", 0) > 0
    )


def bootstrap(
    target: Path,
    *,
    apply: bool,
    repositories_root: Path | None = None,
) -> dict[str, Any]:
    preflight_report = preflight()
    report = base_report(target, "apply" if apply else "preview", preflight_report)
    python3 = str(preflight_report["commands"]["python3"]["path"])
    ruby = str(preflight_report["commands"]["ruby"]["path"])
    state = target_state(target, ruby)
    if repositories_root is not None:
        plan_hub = target if state == "generated" else TEMPLATE
        report["repository_setup"] = {
            "repositories_root": str(repositories_root),
            "plan": repository_setup_plan(plan_hub, ruby, repositories_root),
            "connection": None,
        }

    if state == "generated":
        if apply and repositories_root is not None:
            connection = repository_setup_connect(target, ruby, repositories_root)
            record_repository_connection(report, connection)
            report["validation"] = validate(target, python3, ruby)
            report["status"] = (
                "validated_and_connected"
                if connection.get("ok") is True
                else "validated_and_connected_with_blockers"
            )
            report["no_op"] = connection.get("changed") is not True
            return report
        report["validation"] = validate(target, python3, ruby)
        report["status"] = "validated_noop"
        report["no_op"] = True
        return report

    if not apply:
        report["status"] = "preview"
        report["would_generate"] = True
        report["target_state"] = state
        return report

    setup = json_result(
        [python3, str(SETUP), str(target), "--json"],
        cwd=SCRIPTS,
        stage="generation",
    )
    if setup.get("generated") is not True or setup.get("target") != str(target):
        raise BootstrapFailure(
            "generation", "setup_flightdeck.py did not confirm the exact target"
        )
    report["generated"] = True
    recognize_generated_target(target, ruby)
    if repositories_root is not None:
        connection = repository_setup_connect(target, ruby, repositories_root)
        record_repository_connection(report, connection)
    report["validation"] = validate(target, python3, ruby)
    if repositories_root is None:
        report["status"] = "generated_and_validated"
    elif report["repository_setup"]["connection"].get("ok") is True:
        report["status"] = "generated_connected_and_validated"
    else:
        report["status"] = "generated_connected_with_blockers_and_validated"
    return report


def human_output(report: dict[str, Any]) -> str:
    lines = [
        f"Target: {report['target']}",
        "Preflight: "
        + ", ".join(
            f"{command}={report['preflight'][command]['version']}"
            for command in ("python3", "ruby", "git")
        ),
    ]
    if report["status"] == "preview":
        lines.extend(
            [
                "Preview: a new Flightdeck would be generated at this exact path.",
                "No changes made. Re-run with --apply to generate and validate it.",
            ]
        )
        repository_setup = report.get("repository_setup")
        if repository_setup:
            summary = repository_setup["plan"]["summary"]
            lines.append(
                "Repository preview: "
                f"{summary['discovered']} discovered, {summary['ready']} ready, "
                f"{summary['noop']} already connected, {summary['blocked']} blocked."
            )
        return "\n".join(lines)

    validation = report["validation"]
    tests = validation["ruby_tests"]
    structured = validation["structured"]
    doctor = validation["doctor"]
    debranding = validation["debranding"]
    links = validation["setup_links"]
    action = (
        "Existing Flightdeck validated."
        if report["status"].startswith("validated")
        else "Flightdeck generated and validated."
    )
    lines.extend(
        [
            action,
            "Ruby tests: "
            f"{tests['runs']} runs, {tests['assertions']} assertions, "
            f"{tests['failures']} failures, {tests['errors']} errors, "
            f"{tests['skips']} skips",
            "Structured validation: "
            f"{structured['json']} JSON, {structured['yaml']} YAML, "
            f"{structured['schemas']} schemas, {structured['failures']} failures",
            "Doctor: "
            f"{doctor['errors']} errors, {doctor['warnings']} warnings, "
            f"{doctor['findings']} findings, {doctor['repositories']} repositories, "
            f"{doctor['tasks']} tasks, {doctor['compliance_pairs']} compliance pairs, "
            f"{doctor['bridges']} bridges, "
            f"{doctor['repository_declarations']} repository declarations "
            "(read-only, no fetch)",
            f"De-branding: {debranding['findings']} findings",
            f"Setup links: {links['required']} required paths, "
            f"{links['failures']} failures",
            "No plugin installation, staging, commit, push, secret configuration, "
            "project registration, or publication occurred.",
        ]
    )
    repository_setup = report.get("repository_setup")
    if repository_setup and repository_setup.get("connection"):
        connection = repository_setup["connection"]
        summary = connection["summary"]
        lines.extend(
            [
                "Repository setup: "
                f"{summary['discovered']} discovered, {summary['connected']} connected, "
                f"{summary['blocked']} blocked, "
                f"{summary['project_pending']} Codex project(s) pending exact-path verification.",
                "Attached repositories stayed in place; no tracked repository files changed.",
            ]
        )
    elif repository_setup:
        summary = repository_setup["plan"]["summary"]
        lines.append(
            "Repository preview: "
            f"{summary['discovered']} discovered, {summary['ready']} ready, "
            f"{summary['noop']} already connected, {summary['blocked']} blocked; "
            "no repository connection changes were made."
        )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target_path", nargs="?", type=Path)
    parser.add_argument("--target", dest="target_option", type=Path)
    parser.add_argument(
        "--repositories-root",
        type=Path,
        help="Discover and connect Git repositories under this authorized root",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Generate a new target; otherwise only preview",
    )
    parser.add_argument("--json", action="store_true", help="Emit a JSON report")
    args = parser.parse_args()
    if args.target_path is not None and args.target_option is not None:
        parser.error("provide the target either positionally or with --target, not both")
    requested_target = args.target_option or args.target_path
    if requested_target is None:
        parser.error("a target is required")

    target: Path | None = None
    repositories_root: Path | None = None
    try:
        target = normalize_target(requested_target)
        if args.repositories_root is not None:
            repositories_root = normalize_repositories_root(args.repositories_root)
        report = bootstrap(
            target,
            apply=args.apply,
            repositories_root=repositories_root,
        )
    except BootstrapFailure as error:
        failure = {
            "schema_version": "flightdeck.bootstrap/v1",
            "target": (
                str(target)
                if target is not None
                else str(requested_target.expanduser())
            ),
            "mode": "apply" if args.apply else "preview",
            "repositories_root": (
                str(repositories_root)
                if repositories_root is not None
                else (
                    str(args.repositories_root.expanduser())
                    if args.repositories_root is not None
                    else None
                )
            ),
            "status": "failed",
            "error": {"stage": error.stage, "message": str(error)},
        }
        if args.json:
            print(json.dumps(failure, indent=2, sort_keys=True))
        else:
            print(f"Bootstrap failed during {error.stage}: {error}", file=sys.stderr)
        return error.exit_code

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(human_output(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
