#!/usr/bin/env python3
"""Validate final deliverables for presentation leaks and unresolved templates."""

from __future__ import annotations

import argparse
import io
import json
import re
import shutil
import subprocess
import tempfile
import zipfile
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath
from typing import Iterable
from xml.etree import ElementTree


TEXT_SUFFIXES = {
    ".ckl",
    ".cklb",
    ".csv",
    ".html",
    ".htm",
    ".json",
    ".md",
    ".rtf",
    ".tsv",
    ".txt",
    ".xml",
    ".yaml",
    ".yml",
}
OOXML_SUFFIXES = {".docm", ".docx", ".pptm", ".pptx", ".xlsm", ".xlsx"}
IMAGE_SUFFIXES = {".gif", ".jpeg", ".jpg", ".png", ".tif", ".tiff"}
ARCHIVE_SUFFIXES = {".zip"}
PDF_SUFFIXES = {".pdf"}
MAX_FILE_SIZE = 512 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 10_000
MAX_ARCHIVE_ENTRY_SIZE = 256 * 1024 * 1024
MAX_ARCHIVE_TOTAL_SIZE = 1024 * 1024 * 1024
MAX_COMPRESSION_RATIO = 200

CONTENT_PATTERNS = (
    (
        "ai_provenance",
        re.compile(
            r"\b(?:generated|created|produced|authored|written|prepared)\s+by\s+"
            r"(?:an?\s+)?(?:ai|artificial intelligence|codex|chatgpt|openai|"
            r"(?:large\s+)?language model|llm)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "ai_provenance",
        re.compile(
            r"\b(?:ai|artificial intelligence|codex|chatgpt|openai|"
            r"(?:large\s+)?language model|llm)[-_ ]+"
            r"(?:generated|created|produced|authored|written|prepared)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "ai_provenance",
        re.compile(
            r"\bgenerated_by\b[\"']?\s*[:=]\s*[\"']?"
            r"(?:ai|artificial intelligence|codex|chatgpt|openai|"
            r"(?:large\s+)?language model|llm)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "review_workflow_label",
        re.compile(
            r"\b(?:draft|ready)[-_ ]+for[-_ ]+(?:human[-_ ]+)?review\b",
            re.IGNORECASE,
        ),
    ),
    (
        "review_workflow_label",
        re.compile(
            r"\bhuman[-_ ]+review[-_ ]+(?:required|recommended|pending)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "review_workflow_label",
        re.compile(
            r"\bdraft\s+(?:implementation language|assessment note|"
            r"policy language|material)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "model_provenance",
        re.compile(r"\b(?:machine|model)[- ]generated\b", re.IGNORECASE),
    ),
    (
        "internal_output_path",
        re.compile(r"\bgenerated-documents\b", re.IGNORECASE),
    ),
    (
        "internal_process_metadata",
        re.compile(
            r"\b(?:fields_generated|reviewer_actions|source_human_artifact|"
            r"tooling_notes)\b[\"']?\s*[:=]",
            re.IGNORECASE,
        ),
    ),
)

PLACEHOLDER_PATTERNS = (
    ("template_expression", re.compile(r"\{\{[^{}\r\n]{1,200}\}\}")),
    ("template_expression", re.compile(r"\{%[^{}\r\n]{1,200}%\}")),
    ("template_expression", re.compile(r"\$\{[^{}\r\n]{1,200}\}")),
    ("template_expression", re.compile(r"<<[^<>\r\n]{1,200}>>")),
    (
        "template_expression",
        re.compile(r"<[A-Z][A-Z0-9_ -]{2,80}>"),
    ),
    (
        "template_variable",
        re.compile(r"(?<![\w$])\$[A-Z][A-Z0-9_]{2,80}\b"),
    ),
    (
        "template_variable",
        re.compile(r"%[A-Z][A-Z0-9_]{2,80}%"),
    ),
    (
        "template_variable",
        re.compile(r"__[A-Z][A-Z0-9_]{2,80}__"),
    ),
    (
        "unfinished_marker",
        re.compile(
            r"(?<![\w-])(?:TBD|TBC|TODO|FIXME|CHANGEME|PLACEHOLDER)(?![\w-])",
            re.IGNORECASE,
        ),
    ),
)

SQUARE_PLACEHOLDER = re.compile(r"\[([A-Za-z][A-Za-z0-9 _/.,:-]{0,79})\]")
SQUARE_PLACEHOLDER_TERMS = {
    "action",
    "assumption",
    "boundary",
    "cause",
    "claim",
    "component",
    "control",
    "date",
    "environment",
    "evidence",
    "fact",
    "file",
    "gap",
    "id",
    "impact",
    "inference",
    "insert",
    "item",
    "location",
    "milestone",
    "name",
    "note",
    "organization",
    "output",
    "owner",
    "part",
    "path",
    "plan",
    "program",
    "question",
    "replace",
    "review",
    "risk",
    "role",
    "scope",
    "source",
    "statement",
    "status",
    "summary",
    "system",
    "tier",
    "title",
    "type",
    "unknown",
    "value",
    "weakness",
}
SQUARE_PLACEHOLDER_EXCLUSIONS = {"n/a", "na", "redacted"}

FILENAME_PATTERN = re.compile(
    r"(?:^|[_. -])(?:draft|generated|codex|human[_. -]?review)(?:$|[_. -])",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class Finding:
    code: str
    source: str
    line: int | None
    excerpt: str


class DeliverableValidator:
    def __init__(
        self,
        *,
        allowed_extensions: set[str],
        require_flat_archive: bool,
    ) -> None:
        self.allowed_extensions = allowed_extensions
        self.require_flat_archive = require_flat_archive
        self.findings: list[Finding] = []
        self.files_scanned = 0
        self.sources_scanned = 0

    def validate(self, paths: Iterable[Path]) -> dict[str, object]:
        resolved_paths = [path.resolve() for path in paths]
        for path in resolved_paths:
            if not path.exists():
                self.add("missing_path", str(path), None, "path does not exist")
                continue
            if path.is_dir():
                for child in sorted(item for item in path.rglob("*") if item.is_file()):
                    self.scan_file(child, root=path)
            else:
                self.scan_file(path, root=path.parent, top_level=True)

        return {
            "ok": not self.findings,
            "paths": [str(path) for path in resolved_paths],
            "allowed_extensions": sorted(self.allowed_extensions),
            "require_flat_archive": self.require_flat_archive,
            "files_scanned": self.files_scanned,
            "sources_scanned": self.sources_scanned,
            "findings": [asdict(finding) for finding in self.findings],
        }

    def scan_file(self, path: Path, *, root: Path, top_level: bool = False) -> None:
        relative = path.relative_to(root).as_posix()
        source = str(path) if top_level else relative
        self.files_scanned += 1
        self.scan_name(source, PurePosixPath(relative).name)
        suffix = path.suffix.casefold()

        if self.allowed_extensions and not (top_level and suffix in ARCHIVE_SUFFIXES):
            self.check_extension(source, suffix)

        if path.stat().st_size > MAX_FILE_SIZE:
            self.add(
                "file_too_large",
                source,
                None,
                f"file exceeds {MAX_FILE_SIZE} bytes",
            )
            return
        data = path.read_bytes()
        self.scan_payload(source, suffix, data, archive_depth=0)

    def scan_payload(
        self,
        source: str,
        suffix: str,
        data: bytes,
        *,
        archive_depth: int,
    ) -> None:
        if suffix in TEXT_SUFFIXES:
            self.scan_text(source, data.decode("utf-8", errors="replace"))
            return
        if suffix in OOXML_SUFFIXES:
            self.scan_zip(source, data, ooxml=True, archive_depth=archive_depth)
            return
        if suffix in ARCHIVE_SUFFIXES:
            self.scan_zip(source, data, ooxml=False, archive_depth=archive_depth)
            return
        if suffix in PDF_SUFFIXES:
            self.scan_pdf(source, data)
            return
        if suffix in IMAGE_SUFFIXES:
            return
        if not data:
            return
        self.add(
            "inspection_unavailable",
            source,
            None,
            f"unsupported final-deliverable format: {suffix or '[no extension]'}",
        )

    def scan_zip(
        self,
        source: str,
        data: bytes,
        *,
        ooxml: bool,
        archive_depth: int,
    ) -> None:
        if archive_depth > 4:
            self.add("archive_depth", source, None, "nested archive depth exceeds 4")
            return
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                entries = archive.infolist()
                if len(entries) > MAX_ARCHIVE_ENTRIES:
                    self.add(
                        "unsafe_archive",
                        source,
                        None,
                        f"archive exceeds {MAX_ARCHIVE_ENTRIES} entries",
                    )
                    return
                total_size = 0
                for info in entries:
                    if info.is_dir():
                        continue
                    entry = PurePosixPath(info.filename)
                    entry_source = f"{source}!{entry.as_posix()}"
                    if entry.is_absolute() or ".." in entry.parts:
                        self.add(
                            "unsafe_archive_path",
                            entry_source,
                            None,
                            "archive entry uses an absolute or parent-relative path",
                        )
                        continue
                    total_size += info.file_size
                    if (
                        info.file_size > MAX_ARCHIVE_ENTRY_SIZE
                        or total_size > MAX_ARCHIVE_TOTAL_SIZE
                    ):
                        self.add(
                            "unsafe_archive",
                            entry_source,
                            None,
                            "archive uncompressed size exceeds the safety limit",
                        )
                        return
                    if (
                        info.compress_size > 0
                        and info.file_size > 1024 * 1024
                        and info.file_size / info.compress_size
                        > MAX_COMPRESSION_RATIO
                    ):
                        self.add(
                            "unsafe_archive",
                            entry_source,
                            None,
                            "archive entry compression ratio exceeds the safety limit",
                        )
                        continue
                    self.scan_name(entry_source, entry.name)
                    if not ooxml:
                        if self.require_flat_archive and len(entry.parts) > 1:
                            self.add(
                                "nested_archive_entry",
                                entry_source,
                                None,
                                "archive entry is not at the archive root",
                            )
                        if self.allowed_extensions:
                            self.check_extension(entry_source, entry.suffix.casefold())
                    payload = archive.read(info)
                    suffix = entry.suffix.casefold()
                    if ooxml:
                        if suffix in {".xml", ".rels"}:
                            self.scan_xml(entry_source, payload)
                        continue
                    self.scan_payload(
                        entry_source,
                        suffix,
                        payload,
                        archive_depth=archive_depth + 1,
                    )
        except (OSError, RuntimeError, NotImplementedError, zipfile.BadZipFile) as error:
            self.add("invalid_archive", source, None, str(error))

    def scan_xml(self, source: str, data: bytes) -> None:
        try:
            root = ElementTree.fromstring(data)
        except ElementTree.ParseError:
            self.scan_text(source, data.decode("utf-8", errors="replace"))
            return
        fragments: list[str] = []
        for element in root.iter():
            if element.text:
                fragments.append(element.text)
            fragments.extend(element.attrib.values())
        self.scan_text(source, "\n".join(fragments))

    def scan_pdf(self, source: str, data: bytes) -> None:
        text_command = shutil.which("pdftotext")
        info_command = shutil.which("pdfinfo")
        if text_command is None or info_command is None:
            self.add(
                "inspection_unavailable",
                source,
                None,
                "pdftotext and pdfinfo are required to inspect PDF text and metadata",
            )
            return
        with tempfile.NamedTemporaryFile(suffix=".pdf") as temporary:
            temporary.write(data)
            temporary.flush()
            result = subprocess.run(
                [text_command, "-layout", temporary.name, "-"],
                check=False,
                capture_output=True,
                text=True,
            )
            metadata = subprocess.run(
                [info_command, temporary.name],
                check=False,
                capture_output=True,
                text=True,
            )
        if result.returncode != 0:
            self.add(
                "pdf_extraction_failed",
                source,
                None,
                result.stderr.strip() or f"pdftotext exited {result.returncode}",
            )
            return
        self.scan_text(source, result.stdout)
        if metadata.returncode != 0:
            self.add(
                "pdf_metadata_failed",
                source,
                None,
                metadata.stderr.strip()
                or f"pdfinfo exited {metadata.returncode}",
            )
            return
        self.scan_text(f"{source} [metadata]", metadata.stdout)

    def scan_name(self, source: str, name: str) -> None:
        stem = PurePosixPath(name).stem
        match = FILENAME_PATTERN.search(stem)
        if match:
            self.add("presentation_filename", source, None, match.group(0).strip("_. -"))
        self.scan_text(f"{source} [filename]", name)

    def check_extension(self, source: str, suffix: str) -> None:
        if suffix not in self.allowed_extensions:
            self.add(
                "unexpected_file_type",
                source,
                None,
                f"{suffix or '[no extension]'} is not in the delivery allowlist",
            )

    def scan_text(self, source: str, text: str) -> None:
        self.sources_scanned += 1
        for code, pattern in (*CONTENT_PATTERNS, *PLACEHOLDER_PATTERNS):
            for match in pattern.finditer(text):
                self.add_match(code, source, text, match)
        for match in SQUARE_PLACEHOLDER.finditer(text):
            if match.end() < len(text) and text[match.end()] == "(":
                continue
            content = match.group(1).strip()
            if content.casefold() in SQUARE_PLACEHOLDER_EXCLUSIONS:
                continue
            words = set(re.findall(r"[A-Za-z]+", content.casefold()))
            if words & SQUARE_PLACEHOLDER_TERMS:
                self.add_match("unresolved_placeholder", source, text, match)

    def add_match(
        self,
        code: str,
        source: str,
        text: str,
        match: re.Match[str],
    ) -> None:
        line = text.count("\n", 0, match.start()) + 1
        start = max(0, match.start() - 50)
        end = min(len(text), match.end() + 50)
        excerpt = " ".join(text[start:end].split())
        self.add(code, source, line, excerpt)

    def add(self, code: str, source: str, line: int | None, excerpt: str) -> None:
        finding = Finding(code=code, source=source, line=line, excerpt=excerpt)
        if finding not in self.findings:
            self.findings.append(finding)


def normalize_extension(value: str) -> str:
    normalized = value.casefold()
    return normalized if normalized.startswith(".") else f".{normalized}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Fail when final deliverables expose AI/process provenance, "
            "review-workflow labels, unresolved placeholders, or disallowed files."
        )
    )
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument(
        "--allow-extension",
        action="append",
        default=[],
        help="allowed final file extension; repeat for an allowlist",
    )
    parser.add_argument(
        "--require-flat-archive",
        action="store_true",
        help="require archive entries to be at the archive root",
    )
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    validator = DeliverableValidator(
        allowed_extensions={normalize_extension(item) for item in args.allow_extension},
        require_flat_archive=args.require_flat_archive,
    )
    report = validator.validate(args.paths)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    elif report["ok"]:
        print(
            "Deliverable validation passed: "
            f"{report['files_scanned']} file(s), {report['sources_scanned']} content source(s)."
        )
    else:
        for finding in report["findings"]:
            location = finding["source"]
            if finding["line"] is not None:
                location = f"{location}:{finding['line']}"
            print(f"{finding['code']}: {location}: {finding['excerpt']}")
        print(f"Deliverable validation failed: {len(report['findings'])} finding(s).")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
