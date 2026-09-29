#!/usr/bin/env python3
"""Verify that a bundled Mach-O closure has no dangling local edges.

System frameworks are allowed. Every @rpath/@loader_path/@executable_path
edge must resolve inside the bundle, and every symlink must resolve. This is
intentionally independent of codesign and catches a missing transitive edge
such as brotli's libbrotlicommon provider.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from typing import Optional


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True, errors="replace", stderr=subprocess.STDOUT)


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as source:
            return source.read(4) in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")
    except OSError:
        return False


def dependencies(path: Path) -> list[str]:
    output = run("/usr/bin/otool", "-L", str(path))
    identities = {v.strip() for v in run("/usr/bin/otool", "-D", str(path)).splitlines()[1:]}
    result: list[str] = []
    for line in output.splitlines()[1:]:
        value = line.strip().split(" (compatibility version", 1)[0]
        if not value or value in identities:
            continue
        result.append(value.split(" (compatibility version", 1)[0])
    return result


def nearest_frameworks(path: Path) -> Optional[Path]:
    for ancestor in (path.parent, *path.parents):
        candidate = ancestor / "Frameworks"
        if candidate.is_dir():
            return candidate
    return None


def local_edge(path: Path, dependency: str) -> Optional[Path]:
    if dependency.startswith("@rpath/"):
        frameworks = nearest_frameworks(path)
        return frameworks / dependency.removeprefix("@rpath/") if frameworks else None
    if dependency.startswith("@loader_path/"):
        return path.parent / dependency.removeprefix("@loader_path/")
    if dependency.startswith("@executable_path/"):
        return path.parent / dependency.removeprefix("@executable_path/")
    return None


def verify(bundle: Path) -> list[str]:
    failures: list[str] = []
    if not bundle.exists():
        return [f"bundle missing: {bundle}"]

    for path in bundle.rglob("*"):
        if path.is_symlink():
            try:
                path.resolve(strict=True)
            except FileNotFoundError:
                failures.append(f"dangling symlink: {path}")

    for path in bundle.rglob("*"):
        if not path.is_file() or path.is_symlink() or not is_macho(path):
            continue
        try:
            deps = dependencies(path)
        except subprocess.CalledProcessError as error:
            failures.append(f"otool failed for {path}: {error.output.strip()}")
            continue
        for dependency in deps:
            if dependency.startswith("/usr/lib/") or dependency.startswith("/System/"):
                continue
            if dependency.startswith("/"):
                failures.append(f"absolute non-system dependency: {path} -> {dependency}")
                continue
            candidate = local_edge(path, dependency)
            if candidate is None:
                failures.append(f"unhandled dependency form: {path} -> {dependency}")
                continue
            try:
                candidate.resolve(strict=True)
            except FileNotFoundError:
                failures.append(f"missing local dependency: {path} -> {dependency} (looked for {candidate})")
    return failures


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} BUNDLE", file=sys.stderr)
        return 2
    failures = verify(Path(sys.argv[1]))
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print(f"PASS: portable Mach-O closure verified for {sys.argv[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
