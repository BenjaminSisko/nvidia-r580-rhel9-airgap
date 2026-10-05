#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PARSER = ROOT / "scripts" / "parse_sources.py"


STATUS = """<!doctype html><table>
<tr><th>Date</th><th>Component</th><th>Driver version</th><th>Kernel version</th><th>Kernel suffix</th></tr>
<tr><td>2026-09-24</td><td>kernel-core</td><td>-</td><td>5.14.0-687.51.1</td><td>el9_8.x86_64</td></tr>
<tr><td>2026-10-02</td><td>kernel-core</td><td>-</td><td>5.14.0-687.54.1</td><td>el9_8.x86_64</td></tr>
<tr><td>2026-10-01</td><td>kmod-nvidia</td><td>580.178.04</td><td>5.14.0-687.54.1</td><td>el9_8.x86_64</td></tr>
</table>"""


class ParserTests(unittest.TestCase):
    def run_coverage(self, index: str, require: bool = False) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "status.html").write_text(STATUS, encoding="utf-8")
            (root / "index.html").write_text(index, encoding="utf-8")
            command = [
                "python3",
                str(PARSER),
                "coverage",
                "--status-html",
                str(root / "status.html"),
                "--repo-index",
                str(root / "index.html"),
                "--as-of",
                "2026-10-05",
                "--days",
                "365",
            ]
            if require:
                command.append("--require-covered")
            return subprocess.run(command, text=True, capture_output=True, check=False)

    def test_target_kernel_is_gap_with_only_open_dkms(self) -> None:
        index = """<a href='kmod-nvidia-580.178.04-5.14.0-687.54.1-580.178.04-3.el9_8.x86_64.rpm'>p</a>
<a href='kmod-nvidia-open-dkms-580.178.04-1.el9.noarch.rpm'>d</a>"""
        result = self.run_coverage(index, require=True)
        self.assertEqual(result.returncode, 42)
        target = next(line for line in result.stdout.splitlines() if "687.51.1" in line)
        self.assertIn("\tGAP\t", target)
        self.assertIn("AVAILABLE_EXPLICIT_FLAG\t580.178.04", target)

    def test_proprietary_precompiled_package_is_never_open_coverage(self) -> None:
        index = """<a href='kmod-nvidia-580.178.04-5.14.0-687.54.1-580.178.04-3.el9_8.x86_64.rpm'>p</a>
<a href='kmod-nvidia-open-dkms-580.178.04-1.el9.noarch.rpm'>d</a>"""
        result = self.run_coverage(index)
        newer = next(line for line in result.stdout.splitlines() if "687.54.1" in line)
        self.assertIn("\tGAP\t", newer)
        self.assertIn("\t580.178.04\t", newer)

    def test_hypothetical_kernel_specific_open_rpm_is_covered(self) -> None:
        index = """<a href='kmod-nvidia-open-580.178.04-5.14.0-687.51.1-580.178.04-3.el9_8.x86_64.rpm'>o</a>"""
        result = self.run_coverage(index)
        target = next(line for line in result.stdout.splitlines() if "687.51.1" in line)
        self.assertIn("\tCOVERED\t580.178.04\t", target)

    def test_module_stream_listing_preserves_580_open(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            modules = Path(directory) / "modules.yaml"
            modules.write_text("data:\n  stream: 580-open\n---\ndata:\n  stream: 580\n", encoding="utf-8")
            result = subprocess.run(
                ["python3", str(PARSER), "module-streams", "--modules", str(modules)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.splitlines(), ["580", "580-open"])

    def test_exact_open_dkms_version_is_available(self) -> None:
        index = "<a href='kmod-nvidia-open-dkms-580.178.04-1.el9.noarch.rpm'>d</a>"
        coverage = """release_date\tkernel\tstatus\topen_driver_version\topen_kmod_rpm\tstatus_page_proprietary_r580\tdkms_fallback\tdkms_driver_version\treason
2026-10-02\t5.14.0-687.51.1.el9_8.x86_64\tGAP\t\t\t580.178.04\tAVAILABLE_EXPLICIT_FLAG\t580.178.04\tgap
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "index.html").write_text(index, encoding="utf-8")
            (root / "coverage.tsv").write_text(coverage, encoding="utf-8")
            result = subprocess.run(
                [
                    "python3",
                    str(PARSER),
                    "dkms-fallbacks",
                    "--repo-index",
                    str(root / "index.html"),
                    "--coverage",
                    str(root / "coverage.tsv"),
                    "--require-all",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("580.178.04\tAVAILABLE", result.stdout)


if __name__ == "__main__":
    unittest.main()
