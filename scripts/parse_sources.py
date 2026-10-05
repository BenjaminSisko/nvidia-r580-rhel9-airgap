#!/usr/bin/env python3
"""Parse NVIDIA's RHEL 9 status/repository pages without third-party modules.

The build script deliberately keeps this parser small and vendored so a stock
RHEL 9 staging host can reproduce the coverage decision.  It never infers that
the proprietary ``kmod-nvidia`` is an open kernel-module build.  Open DKMS
packages are reported separately so they can be carried as an explicit,
operator-selected emergency fallback without being mistaken for precompiled
coverage.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import gzip
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from typing import Iterable


R580 = re.compile(r"^580\.\d+\.\d+$")
RPM_DRIVER = re.compile(r"(?:^|-)580\.\d+\.\d+(?:-|\.)")


class TableParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.rows: list[list[str]] = []
        self._row: list[str] | None = None
        self._cell: list[str] | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "tr":
            self._row = []
        elif tag in {"td", "th"} and self._row is not None:
            self._cell = []

    def handle_data(self, data: str) -> None:
        if self._cell is not None:
            self._cell.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag in {"td", "th"} and self._cell is not None and self._row is not None:
            self._row.append(" ".join("".join(self._cell).split()))
            self._cell = None
        elif tag == "tr" and self._row is not None:
            if self._row:
                self.rows.append(self._row)
            self._row = None


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "a":
            return
        href = dict(attrs).get("href")
        if href:
            self.links.append(href.rsplit("/", 1)[-1])


def read_bytes(path: Path) -> bytes:
    data = path.read_bytes()
    if path.suffix == ".gz" or data[:2] == b"\x1f\x8b":
        return gzip.decompress(data)
    return data


def html_rows(path: Path) -> list[list[str]]:
    parser = TableParser()
    parser.feed(read_bytes(path).decode("utf-8", errors="replace"))
    return parser.rows


def repo_links(path: Path) -> list[str]:
    parser = LinkParser()
    parser.feed(read_bytes(path).decode("utf-8", errors="replace"))
    return sorted({item for item in parser.links if item.endswith(".rpm")})


def status_records(path: Path) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    kernels: list[dict[str, str]] = []
    kmods: list[dict[str, str]] = []
    for row in html_rows(path):
        if len(row) < 5:
            continue
        date_s, component, driver, kernel_base, suffix = row[:5]
        try:
            dt.date.fromisoformat(date_s)
        except ValueError:
            continue
        full_kernel = f"{kernel_base}.{suffix}" if suffix else kernel_base
        record = {
            "date": date_s,
            "component": component,
            "driver": driver,
            "kernel": full_kernel,
        }
        if component == "kernel-core":
            kernels.append(record)
        elif component == "kmod-nvidia" and R580.match(driver):
            kmods.append(record)
    return kernels, kmods


def in_window(records: Iterable[dict[str, str]], cutoff: dt.date, as_of: dt.date) -> list[dict[str, str]]:
    result = []
    for record in records:
        date = dt.date.fromisoformat(record["date"])
        if cutoff <= date <= as_of:
            result.append(record)
    return result


def open_precompiled_candidates(files: Iterable[str], kernel: str) -> list[str]:
    """Return only unambiguously named, non-DKMS open precompiled packages.

    A generic ``kmod-nvidia`` is intentionally not accepted: NVIDIA's current
    RHEL 9 metadata labels those packages ``Nvidia`` and declares conflicts
    with the open packages.  The build script performs a second RPM-header
    verification before accepting any future candidate returned here.
    """

    kernel_base, _, suffix = kernel.partition(".el9_")
    needles = {kernel, kernel_base, kernel.replace(f".{suffix}", f"-{suffix}") if suffix else kernel}
    candidates = []
    for filename in files:
        lower = filename.lower()
        if "kmod-nvidia-open" not in lower or "dkms" in lower:
            continue
        if not RPM_DRIVER.search(filename):
            continue
        if any(needle and needle in filename for needle in needles):
            candidates.append(filename)
    return sorted(candidates)


def driver_from_filename(filename: str) -> str:
    match = re.search(r"580\.\d+\.\d+", filename)
    return match.group(0) if match else ""


def open_dkms_candidates(files: Iterable[str]) -> dict[str, list[str]]:
    """Group exact R580 open-DKMS RPM filenames by driver version."""

    candidates: dict[str, list[str]] = {}
    pattern = re.compile(
        r"^kmod-nvidia-open-dkms-(580\.\d+\.\d+)-.+\.noarch\.rpm$"
    )
    for filename in files:
        match = pattern.match(filename)
        if match:
            candidates.setdefault(match.group(1), []).append(filename)
    return {version: sorted(names) for version, names in candidates.items()}


def write_coverage(args: argparse.Namespace) -> int:
    as_of = dt.date.fromisoformat(args.as_of)
    cutoff = as_of - dt.timedelta(days=args.days)
    kernels, status_kmods = status_records(Path(args.status_html))
    kernels = in_window(kernels, cutoff, as_of)
    status_kmods = in_window(status_kmods, cutoff, as_of)
    files = repo_links(Path(args.repo_index))
    dkms_by_version = open_dkms_candidates(files)
    latest_dkms = max(dkms_by_version, key=version_key) if dkms_by_version else ""

    proprietary_by_kernel: dict[str, set[str]] = {}
    for record in status_kmods:
        proprietary_by_kernel.setdefault(record["kernel"], set()).add(record["driver"])

    # A kernel can appear more than once on the status page.  Preserve its
    # earliest observed release date while emitting one deterministic row.
    released: dict[str, str] = {}
    for record in kernels:
        released[record["kernel"]] = min(record["date"], released.get(record["kernel"], record["date"]))

    writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    writer.writerow(
        [
            "release_date",
            "kernel",
            "status",
            "open_driver_version",
            "open_kmod_rpm",
            "status_page_proprietary_r580",
            "dkms_fallback",
            "dkms_driver_version",
            "reason",
        ]
    )
    covered = 0
    for kernel, release_date in sorted(released.items(), key=lambda item: (item[1], item[0])):
        candidates = open_precompiled_candidates(files, kernel)
        if len(candidates) == 1:
            status = "COVERED"
            driver = driver_from_filename(candidates[0])
            rpm = candidates[0]
            reason = "candidate requires RPM-header/signature verification"
            covered += 1
        elif len(candidates) > 1:
            status = "GAP"
            driver = ""
            rpm = ""
            reason = "ambiguous open precompiled candidates: " + ",".join(candidates)
        else:
            status = "GAP"
            driver = ""
            rpm = ""
            reason = "no non-DKMS kmod-nvidia-open RPM in NVIDIA RHEL 9 repository index"
        writer.writerow(
            [
                release_date,
                kernel,
                status,
                driver,
                rpm,
                ",".join(sorted(proprietary_by_kernel.get(kernel, set()), key=version_key)),
                "AVAILABLE_EXPLICIT_FLAG" if latest_dkms else "UNAVAILABLE",
                latest_dkms,
                reason,
            ]
        )
    if args.require_covered and covered == 0:
        return 42
    return 0


def coverage_driver_versions(path: Path) -> list[str]:
    """Return R580 versions referenced by the selected coverage window."""

    versions: set[str] = set()
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            open_version = row.get("open_driver_version", "")
            if R580.match(open_version):
                versions.add(open_version)
            for version in row.get("status_page_proprietary_r580", "").split(","):
                if R580.match(version):
                    versions.add(version)
    return sorted(versions, key=version_key)


def write_dkms_fallbacks(args: argparse.Namespace) -> int:
    """Map every R580 version in COVERAGE.txt to its open-DKMS RPM."""

    files = repo_links(Path(args.repo_index))
    candidates = open_dkms_candidates(files)
    versions = coverage_driver_versions(Path(args.coverage))
    writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    writer.writerow(["driver_version", "status", "open_dkms_rpm", "reason"])
    missing = 0
    for version in versions:
        matches = candidates.get(version, [])
        if len(matches) == 1:
            status = "AVAILABLE"
            rpm = matches[0]
            reason = "exact-version open DKMS source package"
        elif len(matches) > 1:
            status = "MISSING"
            rpm = ""
            reason = "ambiguous packages: " + ",".join(matches)
            missing += 1
        else:
            status = "MISSING"
            rpm = ""
            reason = "no exact-version kmod-nvidia-open-dkms RPM in repository index"
            missing += 1
        writer.writerow([version, status, rpm, reason])
    if not versions:
        missing += 1
    if args.require_all and missing:
        return 42
    return 0


def version_key(value: str) -> tuple[int | str, ...]:
    return tuple(int(part) if part.isdigit() else part for part in re.split(r"([0-9]+)", value))


def list_rpms(args: argparse.Namespace) -> int:
    for filename in repo_links(Path(args.repo_index)):
        print(filename)
    return 0


def module_streams(args: argparse.Namespace) -> int:
    text = read_bytes(Path(args.modules)).decode("utf-8", errors="replace")
    streams = []
    for line in text.splitlines():
        match = re.match(r"\s*stream:\s*['\"]?([^'\"\s]+)", line)
        if match:
            streams.append(match.group(1))
    for stream in sorted(set(streams), key=version_key):
        print(stream)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    coverage = sub.add_parser("coverage")
    coverage.add_argument("--status-html", required=True)
    coverage.add_argument("--repo-index", required=True)
    coverage.add_argument("--as-of", required=True)
    coverage.add_argument("--days", type=int, default=365)
    coverage.add_argument("--require-covered", action="store_true")
    coverage.set_defaults(func=write_coverage)

    rpms = sub.add_parser("list-rpms")
    rpms.add_argument("--repo-index", required=True)
    rpms.set_defaults(func=list_rpms)

    streams = sub.add_parser("module-streams")
    streams.add_argument("--modules", required=True)
    streams.set_defaults(func=module_streams)

    fallbacks = sub.add_parser("dkms-fallbacks")
    fallbacks.add_argument("--repo-index", required=True)
    fallbacks.add_argument("--coverage", required=True)
    fallbacks.add_argument("--require-all", action="store_true")
    fallbacks.set_defaults(func=write_dkms_fallbacks)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
