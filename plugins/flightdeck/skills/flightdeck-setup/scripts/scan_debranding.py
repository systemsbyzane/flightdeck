#!/usr/bin/env python3
"""Fail when distributable text contains private or machine-specific tokens."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from validate_structured import generated_boundaries, is_generated_control_plane_file


TEXT_SUFFIXES = {
    ".md", ".txt", ".json", ".yaml", ".yml", ".rb", ".py", ".sh",
    ".toml", ".xml", ".ckl", ".gitignore", ""
}

SKIP_PARTS = {".git", ".flightdeck-local", "__pycache__"}
PRIVATE_MAP_SCHEMA = "flightdeck.private-neutralization/v1"


class PrivateMapError(ValueError):
    """An external private-neutralization map is malformed."""


@dataclass(frozen=True)
class PrivateNeutralization:
    source_control_token: str | None = None
    replacements: tuple[tuple[str, str], ...] = ()
    deny_tokens: tuple[str, ...] = ()

    @property
    def tokens(self) -> tuple[str, ...]:
        ordered: dict[str, None] = {}
        if self.source_control_token:
            ordered[self.source_control_token] = None
        for source, _replacement in self.replacements:
            ordered[source] = None
        for token in self.deny_tokens:
            ordered[token] = None
        return tuple(ordered)


def require_nonempty_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PrivateMapError(f"{field} must be a non-empty string")
    return value


def load_private_neutralization(path: Path | None) -> PrivateNeutralization:
    if path is None:
        return PrivateNeutralization()
    resolved = path.expanduser().resolve()
    try:
        value = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PrivateMapError(
            f"private neutralization map is unreadable: {resolved}: {error}"
        ) from error
    if not isinstance(value, dict):
        raise PrivateMapError("private neutralization map must be a JSON object")
    if value.get("schema_version") != PRIVATE_MAP_SCHEMA:
        raise PrivateMapError(
            f"schema_version must equal {PRIVATE_MAP_SCHEMA!r}"
        )

    source_control_value = value.get("source_control_token")
    source_control_token = (
        require_nonempty_string(
            source_control_value,
            "source_control_token",
        )
        if source_control_value is not None
        else None
    )

    replacements_value = value.get("replacements", {})
    if not isinstance(replacements_value, dict):
        raise PrivateMapError("replacements must be a JSON object")
    replacements = tuple(
        (
            require_nonempty_string(source, "replacement source"),
            require_nonempty_string(replacement, f"replacement for {source!r}"),
        )
        for source, replacement in replacements_value.items()
    )

    deny_value = value.get("deny_tokens", [])
    if not isinstance(deny_value, list):
        raise PrivateMapError("deny_tokens must be a JSON array")
    deny_tokens = tuple(
        require_nonempty_string(item, f"deny_tokens[{index}]")
        for index, item in enumerate(deny_value)
    )

    private = PrivateNeutralization(
        source_control_token=source_control_token,
        replacements=replacements,
        deny_tokens=deny_tokens,
    )
    if not private.tokens:
        raise PrivateMapError(
            "private neutralization map must declare at least one private token"
        )
    return private


def pattern_for(token: str) -> re.Pattern[str]:
    escaped = re.escape(token)
    if token.isalpha() and len(token) <= 5:
        return re.compile(rf"(?<![A-Za-z0-9]){escaped}(?![A-Za-z0-9])", re.IGNORECASE)
    return re.compile(escaped, re.IGNORECASE)


def token_profile(token: str) -> str:
    return hashlib.sha256(token.casefold().encode("utf-8")).hexdigest()[:16]


def encoded_patterns(token: str) -> tuple[tuple[str, re.Pattern[str]], ...]:
    hexadecimal = token.encode("utf-8").hex()
    base64_value = base64.b64encode(token.encode("utf-8")).decode("ascii")
    return (
        (
            "hex",
            re.compile(
                rf"(?<![0-9a-f]){re.escape(hexadecimal)}(?![0-9a-f])",
                re.IGNORECASE,
            ),
        ),
        (
            "base64",
            re.compile(
                rf"(?<![A-Za-z0-9+/=]){re.escape(base64_value)}"
                r"(?![A-Za-z0-9+/=])"
            ),
        ),
    )


def current_home_patterns() -> tuple[re.Pattern[str], ...]:
    home = str(Path.home().resolve())
    if not home or home == Path(home).anchor:
        return ()
    return (
        re.compile(re.escape(home), re.IGNORECASE),
        re.compile(re.escape(Path(home).as_uri()), re.IGNORECASE),
    )


def scan(
    root: Path,
    allow: set[str],
    private: PrivateNeutralization = PrivateNeutralization(),
    allowed_exact_paths: tuple[str, ...] = (),
    generated_control_plane_only: bool = False,
) -> list[tuple[str, int, str, str]]:
    token_patterns = [
        (
            token,
            token_profile(token),
            pattern_for(token),
            encoded_patterns(token),
            re.sub(r"[^A-Za-z0-9]+", "", token).casefold(),
        )
        for token in private.tokens
        if token.casefold() not in allow
    ]
    home_patterns = current_home_patterns()
    findings: list[tuple[str, int, str, str]] = []
    boundaries = generated_boundaries(root) if generated_control_plane_only else ((), ())
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if (
            not path.is_file()
            or any(part in SKIP_PARTS for part in relative.parts)
            or not is_generated_control_plane_file(relative, boundaries)
        ):
            continue
        if path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        for number, line in enumerate(lines, 1):
            inspected = line
            for allowed_path in allowed_exact_paths:
                inspected = inspected.replace(allowed_path, "<generated-root>")
            for pattern in home_patterns:
                if pattern.search(inspected):
                    findings.append(
                        (str(relative), number, "current-home-path", "plaintext")
                    )
                    break
            compact = re.sub(r"[^A-Za-z0-9]+", "", inspected).casefold()
            for _token, profile, direct, encoded, compact_token in token_patterns:
                if direct.search(inspected):
                    findings.append((str(relative), number, profile, "plaintext"))
                    continue
                encoded_match = next(
                    (name for name, pattern in encoded if pattern.search(inspected)),
                    None,
                )
                if encoded_match:
                    findings.append((str(relative), number, profile, encoded_match))
                    continue
                if len(compact_token) >= 6 and compact_token in compact:
                    findings.append(
                        (str(relative), number, profile, "reconstructed")
                    )
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--allow", action="append", default=[], help="Exact token allowlist entry")
    parser.add_argument(
        "--private-neutralization-map",
        type=Path,
        help=(
            "Ignored external JSON containing private source replacements and deny "
            "tokens; never place this file in distributable content"
        ),
    )
    parser.add_argument(
        "--allow-generated-root",
        action="store_true",
        help="Allow only the exact scanned root path when validating a generated Hub",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    allowed_exact_paths = (str(root),) if args.allow_generated_root else ()
    try:
        private = load_private_neutralization(args.private_neutralization_map)
        findings = scan(
            root,
            {item.casefold() for item in args.allow},
            private=private,
            allowed_exact_paths=allowed_exact_paths,
            generated_control_plane_only=args.allow_generated_root,
        )
    except PrivateMapError as error:
        parser.error(str(error))
    for path, line, profile, variant in findings:
        print(
            f"{path}:{line}: prohibited private token profile {profile} "
            f"({variant})"
        )
    print(f"Scanned {root}: {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
