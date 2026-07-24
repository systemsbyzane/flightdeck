#!/usr/bin/env python3
"""Focused tests for the deterministic Flightdeck bootstrap helper."""

from __future__ import annotations

import base64
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
BOOTSTRAP = ROOT / "scripts" / "bootstrap.py"
SCANNER = ROOT / "scripts" / "scan_debranding.py"
STRUCTURED = ROOT / "scripts" / "validate_structured.py"


class BootstrapTest(unittest.TestCase):
    def run_bootstrap(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(BOOTSTRAP), *arguments],
            cwd=ROOT,
            check=False,
            text=True,
            capture_output=True,
            timeout=180,
        )

    def json_report(self, result: subprocess.CompletedProcess[str]) -> dict:
        self.assertTrue(result.stdout, result.stderr)
        return json.loads(result.stdout)

    def run_scanner(
        self,
        root: Path,
        private_map: Path | None = None,
        *,
        allow_generated_root: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        arguments = ["python3", str(SCANNER), str(root)]
        if private_map:
            arguments.extend(
                ["--private-neutralization-map", str(private_map)]
            )
        if allow_generated_root:
            arguments.append("--allow-generated-root")
        return subprocess.run(
            arguments,
            cwd=ROOT,
            check=False,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def run_structured(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(STRUCTURED), str(root), "--json"],
            cwd=ROOT,
            check=False,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def test_debranding_uses_external_private_map_and_detects_obfuscation(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="flightdeck-private-map-"
        ) as directory:
            root = Path(directory)
            scanned = root / "scanned"
            scanned.mkdir()
            private_token = "private-fixture-token"
            private_map = root / "private-neutralization.json"
            private_map.write_text(
                json.dumps(
                    {
                        "schema_version": "flightdeck.private-neutralization/v1",
                        "source_control_token": "legacy-fixture-hub",
                        "replacements": {
                            private_token: "neutral-fixture-token",
                        },
                        "deny_tokens": ["private-fixture-owner"],
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            (scanned / "plaintext.txt").write_text(
                private_token + "\n",
                encoding="utf-8",
            )
            (scanned / "hex.txt").write_text(
                private_token.encode("utf-8").hex() + "\n",
                encoding="utf-8",
            )
            (scanned / "base64.txt").write_text(
                base64.b64encode(private_token.encode("utf-8")).decode("ascii")
                + "\n",
                encoding="utf-8",
            )
            (scanned / "reconstructed.py").write_text(
                'value = "".join(("private", "fixture", "token"))\n',
                encoding="utf-8",
            )

            without_map = self.run_scanner(scanned)
            self.assertEqual(0, without_map.returncode, without_map.stderr)
            with_map = self.run_scanner(scanned, private_map)
            self.assertEqual(1, with_map.returncode, with_map.stderr)
            self.assertEqual(
                4,
                with_map.stdout.count("prohibited private token profile"),
            )
            for variant in ("plaintext", "hex", "base64", "reconstructed"):
                self.assertIn(f"({variant})", with_map.stdout)

    def test_debranding_rejects_malformed_private_map(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="flightdeck-private-map-invalid-"
        ) as directory:
            root = Path(directory)
            private_map = root / "private-neutralization.json"
            private_map.write_text(
                '{"schema_version":"unexpected","deny_tokens":["synthetic"]}\n',
                encoding="utf-8",
            )
            result = self.run_scanner(root, private_map)
            self.assertEqual(2, result.returncode)
            self.assertIn("schema_version must equal", result.stderr)

    def test_generated_validation_excludes_workload_and_local_state_payloads(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="flightdeck-generated-boundary-"
        ) as directory:
            root = Path(directory) / "generated"
            (root / "development" / "synthetic-repository").mkdir(parents=True)
            (root / "hub" / "state").mkdir(parents=True)
            (root / "flightdeck.yaml").write_text(
                "api_version: flightdeck.dev/v1alpha1\n"
                "kind: FlightdeckRegistry\n"
                "workspace:\n"
                f'  root: "{root}"\n'
                "  local_registry: hub/state/repositories.yaml\n"
                "workloads:\n"
                "  development:\n"
                "    path: development\n",
                encoding="utf-8",
            )
            (root / "managed.json").write_text(
                '{"synthetic": true}\n',
                encoding="utf-8",
            )
            (root / "development" / "synthetic-repository" / "broken.yaml").write_text(
                "broken: [\n",
                encoding="utf-8",
            )
            (root / "development" / "synthetic-repository" / "machine.txt").write_text(
                str(Path.home()) + "\n",
                encoding="utf-8",
            )
            (root / "hub" / "state" / "local.yaml").write_text(
                "broken: [\n",
                encoding="utf-8",
            )

            structured = self.run_structured(root)
            self.assertEqual(0, structured.returncode, structured.stderr)
            report = self.json_report(structured)
            self.assertTrue(report["ok"])
            self.assertEqual(0, len(report["failures"]))
            scanner = self.run_scanner(root, allow_generated_root=True)
            self.assertEqual(0, scanner.returncode, scanner.stdout + scanner.stderr)

            (root / "managed-broken.yaml").write_text("broken: [\n", encoding="utf-8")
            managed_structured = self.run_structured(root)
            self.assertEqual(1, managed_structured.returncode)
            self.assertIn(
                "managed-broken.yaml",
                "\n".join(self.json_report(managed_structured)["failures"]),
            )
            (root / "managed-home.txt").write_text(
                str(Path.home()) + "\n",
                encoding="utf-8",
            )
            managed_scan = self.run_scanner(root, allow_generated_root=True)
            self.assertEqual(1, managed_scan.returncode)
            self.assertIn("managed-home.txt", managed_scan.stdout)

    def test_preview_is_default_and_does_not_create_target(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-bootstrap-preview-") as directory:
            root = Path(directory)
            requested = root / "nested" / ".." / "generated"
            expected = (root / "generated").resolve()
            result = self.run_bootstrap(str(requested), "--json")
            self.assertEqual(0, result.returncode, result.stderr)
            report = self.json_report(result)
            self.assertEqual(str(expected), report["target"])
            self.assertEqual("preview", report["status"])
            self.assertTrue(report["would_generate"])
            self.assertFalse(report["generated"])
            self.assertFalse(expected.exists())
            self.assertEqual(
                {"git", "python3", "ruby"},
                set(report["preflight"]),
            )
            self.assertEqual(
                "agent_verification_required", report["runtime_status"]
            )

            option_target = root / "option-target"
            option_result = self.run_bootstrap(
                "--target", str(option_target), "--json"
            )
            self.assertEqual(0, option_result.returncode, option_result.stderr)
            self.assertEqual(
                str(option_target.resolve()),
                self.json_report(option_result)["target"],
            )

    def test_refuses_symlink_and_partial_nonempty_targets(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-bootstrap-refusal-") as directory:
            root = Path(directory)
            real = root / "real"
            real.mkdir()
            link = root / "linked"
            link.symlink_to(real, target_is_directory=True)
            symlink_result = self.run_bootstrap(str(link), "--json")
            self.assertEqual(2, symlink_result.returncode)
            self.assertEqual(
                "target", self.json_report(symlink_result)["error"]["stage"]
            )

            partial = root / "partial"
            partial.mkdir()
            (partial / "flightdeck.yaml").write_text(
                "api_version: flightdeck.dev/v1alpha1\n"
                "kind: FlightdeckRegistry\n",
                encoding="utf-8",
            )
            partial_result = self.run_bootstrap(str(partial), "--json")
            self.assertEqual(2, partial_result.returncode)
            partial_report = self.json_report(partial_result)
            self.assertEqual("target-recognition", partial_report["error"]["stage"])
            self.assertIn("not a complete generated Flightdeck", partial_report["error"]["message"])

    def test_refuses_filesystem_root_and_home(self) -> None:
        for unsafe in (Path("/"), Path.home()):
            with self.subTest(target=unsafe):
                result = self.run_bootstrap(str(unsafe), "--json")
                self.assertEqual(2, result.returncode)
                report = self.json_report(result)
                self.assertEqual("target", report["error"]["stage"])
                self.assertIn("unsafe target path", report["error"]["message"])

    def test_apply_validates_and_rerun_is_an_idempotent_noop(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flightdeck-bootstrap-apply-") as directory:
            target = Path(directory) / "generated"
            first = self.run_bootstrap(str(target), "--apply", "--json")
            self.assertEqual(0, first.returncode, first.stderr)
            report = self.json_report(first)
            self.assertEqual("generated_and_validated", report["status"])
            self.assertTrue(report["generated"])
            self.assertEqual(0, report["validation"]["ruby_tests"]["failures"])
            self.assertGreater(report["validation"]["ruby_tests"]["runs"], 0)
            self.assertGreater(report["validation"]["structured"]["schemas"], 0)
            self.assertEqual(0, report["validation"]["structured"]["failures"])
            self.assertEqual(0, report["validation"]["doctor"]["errors"])
            self.assertEqual(0, report["validation"]["debranding"]["findings"])
            self.assertEqual(0, report["validation"]["setup_links"]["failures"])
            self.assertTrue((target / ".git").is_dir())
            remotes = subprocess.run(
                ["git", "remote"],
                cwd=target,
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(0, remotes.returncode, remotes.stderr)
            self.assertEqual("", remotes.stdout.strip())

            before = (target / "flightdeck.yaml").read_bytes()
            second = self.run_bootstrap(str(target), "--apply", "--json")
            self.assertEqual(0, second.returncode, second.stderr)
            rerun = self.json_report(second)
            self.assertEqual("validated_noop", rerun["status"])
            self.assertTrue(rerun["no_op"])
            self.assertFalse(rerun["generated"])
            self.assertEqual(before, (target / "flightdeck.yaml").read_bytes())

            config = target / "flightdeck.yaml"
            config.write_text(
                config.read_text(encoding="utf-8").replace(
                    "Portable workspace topology, ownership, routing, and safety policy.",
                    "Configured synthetic workspace topology.",
                ),
                encoding="utf-8",
            )
            declarations = target / "hub" / "repositories.yaml"
            declarations.write_text(
                declarations.read_text(encoding="utf-8")
                + "# Locally configured declarations remain user-managed.\n",
                encoding="utf-8",
            )
            configured_result = self.run_bootstrap(str(target), "--apply", "--json")
            self.assertEqual(0, configured_result.returncode, configured_result.stderr)
            configured_report = self.json_report(configured_result)
            self.assertEqual("validated_noop", configured_report["status"])
            self.assertTrue(configured_report["no_op"])
            self.assertIn(
                "Configured synthetic workspace topology.",
                config.read_text(encoding="utf-8"),
            )
            self.assertIn(
                "Locally configured declarations remain user-managed.",
                declarations.read_text(encoding="utf-8"),
            )

            readme = target / "README.md"
            readme.write_text(
                readme.read_text(encoding="utf-8") + "\nLocal drift.\n",
                encoding="utf-8",
            )
            documentation_drift = self.run_bootstrap(str(target), "--json")
            self.assertEqual(2, documentation_drift.returncode)
            documentation_report = self.json_report(documentation_drift)
            self.assertEqual(
                "target-recognition", documentation_report["error"]["stage"]
            )
            self.assertIn(
                "unrecognized generated managed content",
                documentation_report["error"]["message"],
            )
            self.assertIn("README.md", documentation_report["error"]["message"])

            readme.write_bytes(
                (ROOT / "assets" / "flightdeck-template" / "README.md").read_bytes()
            )
            (target / "bin" / "flightdeck").write_text(
                "#!/usr/bin/env ruby\nexit 0\n", encoding="utf-8"
            )
            tampered = self.run_bootstrap(str(target), "--json")
            self.assertEqual(2, tampered.returncode)
            tampered_report = self.json_report(tampered)
            self.assertEqual("target-recognition", tampered_report["error"]["stage"])
            self.assertIn(
                "unrecognized generated managed content",
                tampered_report["error"]["message"],
            )


if __name__ == "__main__":
    unittest.main()
