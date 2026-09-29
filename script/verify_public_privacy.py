#!/usr/bin/env python3
"""Scan a public SceneHarbor export without printing private values.

The private values used to catch a local username, a signing fingerprint, or
an actual service key are supplied in a JSON file outside the public tree via
``--private-patterns``.  The scanner itself contains no machine-specific
values.  It also checks generic token shapes, private filenames, user-home
paths, Mach-O bytes, and plist API-key fields.

With no positional paths, the scanner uses the repository's Git-visible file
list and ignores common build products.  Positional files or directories are
explicit inputs; those are scanned without source-mode build exclusions, which
allows a packed ``.app`` or an exported root to be checked in full.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import plistlib
import re
import subprocess
import sys
import tarfile
import zipfile
from collections import defaultdict
from pathlib import Path, PurePosixPath
from typing import DefaultDict, Dict, Iterator, List, Optional, Sequence, Set, Tuple


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MAX_FILE_BYTES = 512 * 1024 * 1024
DEFAULT_MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
DEFAULT_MAX_ARCHIVE_MEMBERS = 10_000
MAX_ARCHIVE_DEPTH = 3

SOURCE_BUILD_PARTS = frozenset({
    ".build",
    ".swiftpm",
    "build",
    "deriveddata",
    "dist",
    "outputs",
    "result",
    "results",
    "__pycache__",
})

SOURCE_EXTENSIONS = frozenset({
    ".c", ".cc", ".cpp", ".cs", ".go", ".h", ".hpp", ".java", ".js", ".jsx",
    ".m", ".mm", ".py", ".rb", ".rs", ".sh", ".swift", ".ts", ".tsx", ".yaml",
    ".yml",
})

ARCHIVE_SUFFIXES = (
    ".tar.gz",
    ".tar.bz2",
    ".tar.xz",
    ".tar",
    ".tgz",
    ".zip",
)

PRIVATE_FILENAME_PATTERN = re.compile(
    r"^(?:session|token|cookies|actualdata)(?:[._-].*)?$",
    re.IGNORECASE,
)

# Build the prefix in pieces so this scanner does not match its own literal
# pattern when it is included in the Git-visible source file list.
USER_HOME_PATTERN = re.compile(rb"/" + rb"Users/" + rb"([^/\\\x00\s\"'<>:;=,\)\]\[{}]+)")

# A UUID by itself is not sensitive: protocol fixtures and generated content
# commonly use UUID-shaped constants.  Flag only a literal UUID that appears
# near an explicit display/device identifier assignment, where it can pin the
# public source to one developer's monitor or machine.  Keep this contextual
# so ordinary UUID keys (for example wallpaper fixtures) remain allowed.
UUID_LITERAL_PATTERN = re.compile(
    rb"(?<![0-9A-Fa-f])"
    rb"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    rb"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    rb"(?![0-9A-Fa-f])"
)
DEVICE_UUID_CONTEXT_PATTERN = re.compile(
    rb"\b(?:target|default|configured|selected|current|external|primary|preferred|"
    rb"monitor|display|screen|device|hardware|platform)"
    rb"[A-Za-z0-9_-]{0,32}(?:uuid|udid|identifier)\b",
    re.IGNORECASE,
)
DEVICE_UUID_ASSIGNMENT_PATTERN = re.compile(rb"(?:=|:)\s*[\"'`]?")

GENERIC_TOKEN_PATTERNS: Dict[str, Tuple[re.Pattern[bytes], ...]] = {
    "github-token": (
        re.compile(rb"gh[pousr]_[A-Za-z0-9_]{20,}"),
        re.compile(rb"github_pat_[A-Za-z0-9_]{20,}"),
    ),
    "openai-token": (
        re.compile(rb"(?<![A-Za-z0-9])sk-(?:proj-|admin-|svcacct-)?[A-Za-z0-9_-]{20,}"),
    ),
    "aws-access-key": (
        re.compile(rb"\b(?:AKIA|ASIA|AIDA|AROA)[A-Z0-9]{16}\b"),
    ),
    "aws-secret-token": (
        re.compile(
            rb"\baws_(?:secret_access_key|session_token)\b\s*[:=]\s*[\"']?[A-Za-z0-9/+=_-]{20,}",
            re.IGNORECASE,
        ),
    ),
    "private-key": (
        re.compile(rb"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----"),
    ),
}


def _digest(category: str, value: bytes) -> str:
    """Return a comparison token without retaining the matched secret."""

    return hashlib.sha256(category.encode("utf-8") + b"\0" + value).hexdigest()


def _filename_label(value: object) -> str:
    """Return only a basename suitable for privacy-safe reporting."""

    raw = str(value).replace("\\", "/")
    label = PurePosixPath(raw).name
    return label or "<unnamed>"


def _decode_escaped_text(text: str) -> str:
    """Decode common JSON/Swift/C textual escapes without evaluating code."""

    text = text.replace("\\/", "/")

    def replace_codepoint(match: re.Match[str]) -> str:
        try:
            return chr(int(match.group(1), 16))
        except (ValueError, OverflowError):
            return match.group(0)

    text = re.sub(r"\\u([0-9a-fA-F]{4})", replace_codepoint, text)
    text = re.sub(r"\\U([0-9a-fA-F]{8})", replace_codepoint, text)
    text = re.sub(r"\\x([0-9a-fA-F]{2})", replace_codepoint, text)
    return text


def _text_variants(data: bytes) -> Iterator[bytes]:
    """Yield raw, escaped-decoded, and likely UTF-16 textual byte views."""

    seen: Set[bytes] = set()

    def emit(value: bytes) -> Iterator[bytes]:
        if value and value not in seen:
            seen.add(value)
            yield value

    yield from emit(data)
    try:
        utf8 = data.decode("utf-8", errors="ignore")
    except Exception:
        utf8 = ""
    if utf8:
        yield from emit(utf8.encode("utf-8", errors="ignore"))
        decoded = _decode_escaped_text(utf8)
        yield from emit(decoded.encode("utf-8", errors="ignore"))
        # A JSON string can use a doubled backslash before a unicode escape.
        doubled = _decode_escaped_text(decoded.replace("\\\\", "\\"))
        yield from emit(doubled.encode("utf-8", errors="ignore"))

    if data.count(b"\0") > 0:
        for encoding in ("utf-16-le", "utf-16-be"):
            try:
                decoded = data.decode(encoding, errors="ignore")
            except Exception:
                continue
            if decoded:
                yield from emit(decoded.encode("utf-8", errors="ignore"))
                yield from emit(_decode_escaped_text(decoded).encode("utf-8", errors="ignore"))


def _normalise_pattern_key(key: str) -> str:
    return re.sub(r"[^a-z0-9]", "", key.casefold())


def _category_for_key(key: str) -> Optional[str]:
    normalized = _normalise_pattern_key(key)
    if not normalized:
        return None
    if "username" in normalized or normalized in {"user", "localuser", "localusername"}:
        return "local-username"
    if "fingerprint" in normalized or "codesign" in normalized or normalized in {"sha1", "signingidentity"}:
        return "codesign-fingerprint"
    if "steam" in normalized and ("key" in normalized or "token" in normalized or "secret" in normalized):
        return "steam-api-key"
    if "apikey" in normalized or normalized.endswith("token") or "secret" in normalized:
        return "private-pattern"
    return None


def _collect_private_patterns(node: object, hint: Optional[str] = None) -> List[Tuple[str, str]]:
    """Accept a small JSON object, a list of values, or category/value entries."""

    collected: List[Tuple[str, str]] = []
    if isinstance(node, dict):
        explicit = node.get("category") or node.get("type")
        explicit_category = _category_for_key(str(explicit)) if explicit is not None else None
        if "value" in node and isinstance(node["value"], (str, int, float)):
            value = str(node["value"])
            if value.strip():
                collected.append((explicit_category or hint or "private-pattern", value))
        for key, value in node.items():
            if key in {"category", "type", "value"}:
                continue
            category = _category_for_key(str(key))
            if category is None and _normalise_pattern_key(str(key)) in {"patterns", "values", "secrets", "private"}:
                category = "private-pattern"
            if category is not None:
                collected.extend(_collect_private_patterns(value, category))
    elif isinstance(node, list):
        for value in node:
            collected.extend(_collect_private_patterns(value, hint))
    elif isinstance(node, (str, int, float)):
        value = str(node)
        if value.strip():
            collected.append((hint or "private-pattern", value))
    return collected


def _pattern_variants(category: str, value: str) -> Iterator[Tuple[str, bytes, bool]]:
    """Yield safe matching forms; values never appear in diagnostics."""

    decoded = _decode_escaped_text(value)
    values = [value, decoded]
    if category == "codesign-fingerprint":
        compact = re.sub(r"[^0-9a-fA-F]", "", decoded)
        values.extend([compact, compact.lower(), compact.upper()])
    seen: Set[Tuple[str, bool]] = set()
    for item in values:
        if not item or len(item) < 4:
            continue
        case_insensitive = category in {"local-username", "codesign-fingerprint"}
        key = (item, case_insensitive)
        if key in seen:
            continue
        seen.add(key)
        yield category, item.encode("utf-8"), case_insensitive


def _is_placeholder(value: str) -> bool:
    normalized = value.strip().casefold()
    if not normalized:
        return True
    if normalized.startswith("${") or normalized.startswith("<"):
        return True
    return normalized in {
        "example",
        "example-key",
        "insert-key-here",
        "replace-me",
        "your-key",
        "your_api_key",
        "your-api-key",
        "changeme",
        "todo",
        "none",
        "null",
    }


def _device_uuid_digests(data: bytes) -> Set[str]:
    """Find UUID literals pinned to a display/device identifier assignment.

    UUID-shaped protocol values and fixture IDs are intentionally ignored.  A
    hit needs both an identifier name (for example ``targetUUID`` or
    ``configuredDisplayUUID``) and assignment punctuation in the nearby text.
    The digest keeps the literal out of reports and prevents duplicate hits
    across the decoded text variants.
    """

    found: Set[str] = set()
    for match in UUID_LITERAL_PATTERN.finditer(data):
        window_start = max(0, match.start() - 192)
        window_end = min(len(data), match.end() + 192)
        window = data[window_start:window_end]
        if not DEVICE_UUID_CONTEXT_PATTERN.search(window):
            continue
        if not DEVICE_UUID_ASSIGNMENT_PATTERN.search(window):
            continue
        found.add(_digest("device-identifier", match.group(0).lower()))
    return found


def _plist_api_key_digests(value: object) -> Set[str]:
    """Find non-placeholder API-key-like plist fields without exposing values."""

    found: Set[str] = set()

    def walk(node: object) -> None:
        if isinstance(node, dict):
            for key, child in node.items():
                key_text = str(key)
                normalized = _normalise_pattern_key(key_text)
                key_like = (
                    normalized.endswith("apikey")
                    or normalized.endswith("token")
                    or normalized in {"steamkey", "actualsteamkey", "secretkey", "secretaccesskey"}
                )
                if key_like and isinstance(child, (str, bytes)):
                    child_text = child.decode("utf-8", errors="ignore") if isinstance(child, bytes) else child
                    if not _is_placeholder(child_text):
                        found.add(_digest("plist-api-key-field", key_text.encode("utf-8") + b"\0" + child_text.encode("utf-8")))
                walk(child)
        elif isinstance(node, list):
            for child in node:
                walk(child)

    walk(value)
    return found


def _looks_like_plist(filename: str, data: bytes) -> bool:
    lower = filename.casefold()
    return lower.endswith(".plist") or data.startswith(b"bplist") or b"<plist" in data[:512]


def _is_archive_name(filename: str) -> bool:
    lower = filename.casefold()
    return lower.endswith(ARCHIVE_SUFFIXES)


def _private_filename_hit(filename: str) -> bool:
    basename = _filename_label(filename).casefold()
    if basename == ".env" or (basename.startswith(".env.") and basename not in {".env.example", ".env.sample", ".env.template"}):
        return True
    if basename.endswith(".p12"):
        return True
    if basename in {"hosts.yml", "hosts.yaml"}:
        return True
    if not PRIVATE_FILENAME_PATTERN.match(basename):
        return False
    suffix = Path(basename).suffix.casefold()
    return suffix not in SOURCE_EXTENSIONS


def _is_source_build_artifact(path: Path, root: Path) -> bool:
    try:
        relative = path.resolve().relative_to(root.resolve())
    except ValueError:
        relative = path
    parts = {part.casefold() for part in relative.parts}
    if parts.intersection(SOURCE_BUILD_PARTS):
        return True
    if any(part.casefold().endswith(".app") for part in relative.parts):
        return True
    return False


def _git_visible_files(root: Path) -> Tuple[List[Path], bool]:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            check=True,
            capture_output=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return [], False
    values = [value for value in result.stdout.split(b"\0") if value]
    files = [root / value.decode("utf-8", errors="surrogateescape") for value in values]
    return [
        path
        for path in files
        if (path.is_file() or path.is_symlink()) and not _is_source_build_artifact(path, root)
    ], True


class Scanner:
    def __init__(
        self,
        private_patterns: Sequence[Tuple[str, str]],
        *,
        scan_archives: bool,
        max_file_bytes: int,
        max_archive_bytes: int,
        max_archive_members: int,
    ) -> None:
        self.scan_archives = scan_archives
        self.max_file_bytes = max_file_bytes
        self.max_archive_bytes = max_archive_bytes
        self.max_archive_members = max_archive_members
        self.findings: DefaultDict[Tuple[str, str], int] = defaultdict(int)
        self.scanned_files = 0
        self.reviewed_fixtures: Dict[str, Set[str]] = {}
        self.reviewed_files = 0
        self._private_matchers: List[Tuple[str, bytes, bool]] = []
        for category, value in private_patterns:
            self._private_matchers.extend(_pattern_variants(category, value))

    def add_finding(self, filename: str, category: str, count: int = 1) -> None:
        self.findings[(_filename_label(filename), category)] += count

    def add_filename_finding(self, filename: str) -> None:
        if _private_filename_hit(filename):
            self.add_finding(filename, "banned-private-filename")

    def _scan_variants(self, filename: str, data: bytes, reviewed: Set[str]) -> None:
        matched: DefaultDict[str, Set[str]] = defaultdict(set)
        for variant in _text_variants(data):
            for category, patterns in GENERIC_TOKEN_PATTERNS.items():
                if category in reviewed:
                    continue
                for pattern in patterns:
                    for match in pattern.finditer(variant):
                        matched[category].add(_digest(category, match.group(0)))
            # Do not allow upstream fixture reviews to suppress this
            # category: a literal hardware/display UUID is release-specific
            # even when it appears in a reviewed third-party file.
            device_hits = _device_uuid_digests(variant)
            if device_hits:
                matched["device-identifier"].update(device_hits)
            for category, needle, case_insensitive in self._private_matchers:
                # Patterns and variants are bytes so binary Mach-O data can be
                # checked without lossy decoding.  ``bytes`` has ``lower``
                # rather than ``casefold``; the private values are restricted
                # to UTF-8/ASCII forms where this is sufficient.
                haystack = variant.lower() if case_insensitive else variant
                target = needle.lower() if case_insensitive else needle
                if target in haystack:
                    matched[category].add(_digest(category, target))
            for match in USER_HOME_PATTERN.finditer(variant):
                component = match.group(1).decode("utf-8", errors="ignore").casefold()
                if "user-home-path" not in reviewed and component.rstrip("|") not in {"developer", "shared", "*"}:
                    matched["user-home-path"].add(_digest("user-home-path", match.group(0)))
        for category, values in matched.items():
            self.add_finding(filename, category, len(values))

    def scan_blob(self, filename: str, data: bytes) -> None:
        self.scanned_files += 1
        reviewed = self.reviewed_fixtures.get(hashlib.sha256(data).hexdigest(), set())
        if reviewed:
            self.reviewed_files += 1
        if "banned-private-filename" not in reviewed:
            self.add_filename_finding(filename)
        self._scan_variants(filename, data, reviewed)
        if _looks_like_plist(filename, data):
            try:
                plist = plistlib.loads(data)
            except Exception:
                plist = None
            if plist is not None:
                values = _plist_api_key_digests(plist)
                if values:
                    self.add_finding(filename, "plist-api-key-field", len(values))

    def scan_file(self, path: Path) -> None:
        label = _filename_label(path.name)
        if path.is_symlink():
            try:
                self.scan_blob(label, os.readlink(path).encode("utf-8", errors="surrogateescape"))
            except OSError:
                self.add_finding(label, "unreadable", 1)
            return
        try:
            size = path.stat().st_size
        except OSError:
            self.add_finding(label, "unreadable", 1)
            return
        if size > self.max_file_bytes:
            self.add_finding(label, "file-size-limit", 1)
            return
        try:
            data = path.read_bytes()
        except OSError:
            self.add_finding(label, "unreadable", 1)
            return
        self.scan_blob(label, data)
        if self.scan_archives and _is_archive_name(label):
            self.scan_archive_bytes(label, data, depth=0)

    def scan_path(self, path: Path) -> None:
        if path.is_dir() and not path.is_symlink():
            for current, directories, filenames in os.walk(path, followlinks=False):
                current_path = Path(current)
                directories[:] = [
                    name for name in sorted(directories)
                    if not (current_path / name).is_symlink()
                ]
                for name in sorted(filenames):
                    self.scan_file(current_path / name)
            return
        if path.is_file() or path.is_symlink():
            self.scan_file(path)
        else:
            self.add_finding(path.name, "missing-path", 1)

    def scan_archive_bytes(self, filename: str, data: bytes, depth: int) -> None:
        if depth >= MAX_ARCHIVE_DEPTH:
            self.add_finding(filename, "archive-depth-limit", 1)
            return
        if len(data) > self.max_archive_bytes:
            self.add_finding(filename, "archive-size-limit", 1)
            return

        lower = filename.casefold()
        try:
            if lower.endswith(".zip"):
                self._scan_zip(filename, data, depth)
            elif lower.endswith((".tar.gz", ".tgz", ".tar.bz2", ".tar.xz", ".tar")):
                self._scan_tar(filename, data, depth)
        except (OSError, EOFError, tarfile.TarError, zipfile.BadZipFile, ValueError):
            self.add_finding(filename, "archive-read-error", 1)

    def _scan_member(self, member_name: str, data: bytes, depth: int, cumulative: int) -> int:
        label = _filename_label(member_name)
        self.scan_blob(label, data)
        if self.scan_archives and _is_archive_name(member_name):
            self.scan_archive_bytes(member_name, data, depth + 1)
        return cumulative + len(data)

    def _scan_zip(self, filename: str, data: bytes, depth: int) -> None:
        cumulative = 0
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            infos = archive.infolist()
            if len(infos) > self.max_archive_members:
                self.add_finding(filename, "archive-member-limit", 1)
                infos = infos[: self.max_archive_members]
            for info in infos:
                if info.is_dir():
                    continue
                if info.file_size > self.max_archive_bytes or cumulative + info.file_size > self.max_archive_bytes:
                    self.add_filename_finding(info.filename)
                    self.add_finding(_filename_label(info.filename), "archive-size-limit", 1)
                    continue
                member = archive.read(info)
                cumulative = self._scan_member(info.filename, member, depth, cumulative)

    def _scan_tar(self, filename: str, data: bytes, depth: int) -> None:
        cumulative = 0
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
            members = archive.getmembers()
            if len(members) > self.max_archive_members:
                self.add_finding(filename, "archive-member-limit", 1)
                members = members[: self.max_archive_members]
            for info in members:
                if not info.isfile():
                    continue
                if info.size > self.max_archive_bytes or cumulative + info.size > self.max_archive_bytes:
                    self.add_filename_finding(info.name)
                    self.add_finding(_filename_label(info.name), "archive-size-limit", 1)
                    continue
                extracted = archive.extractfile(info)
                if extracted is None:
                    self.add_finding(_filename_label(info.name), "archive-read-error", 1)
                    continue
                member = extracted.read(self.max_archive_bytes - cumulative + 1)
                if len(member) > self.max_archive_bytes - cumulative:
                    self.add_finding(_filename_label(info.name), "archive-size-limit", 1)
                    continue
                cumulative = self._scan_member(info.name, member, depth, cumulative)


def _parse_positive(value: str) -> int:
    try:
        result = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if result <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return result


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify a public SceneHarbor source export or explicit app/root without printing secret values."
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="Explicit files/directories to scan; omit to scan the Git-visible source file list.",
    )
    parser.add_argument(
        "--private-patterns",
        type=Path,
        help="Private JSON file outside the public tree containing values to match; values are never printed.",
    )
    parser.add_argument(
        "--archives",
        action="store_true",
        help="Recursively inspect zip/tar archives with bounded size and depth.",
    )
    parser.add_argument("--upstream-fixtures", type=Path, help="Reviewed upstream fixture file hashes; never exempts personal-value matches.")
    parser.add_argument("--max-file-bytes", type=_parse_positive, default=DEFAULT_MAX_FILE_BYTES)
    parser.add_argument("--max-archive-bytes", type=_parse_positive, default=DEFAULT_MAX_ARCHIVE_BYTES)
    parser.add_argument("--max-archive-members", type=_parse_positive, default=DEFAULT_MAX_ARCHIVE_MEMBERS)
    return parser


def _load_private_patterns(path: Optional[Path]) -> Tuple[List[Tuple[str, str]], Optional[str]]:
    if path is None:
        return [], "private-patterns-missing"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return [], "private-patterns-unreadable"
    pairs = _collect_private_patterns(data)
    deduplicated: List[Tuple[str, str]] = []
    seen: Set[Tuple[str, str]] = set()
    for category, value in pairs:
        key = (category, value)
        if key not in seen:
            seen.add(key)
            deduplicated.append(key)
    return deduplicated, None if deduplicated else "private-patterns-empty"


def _print_report(scanner: Scanner, mode: str, configuration_error: Optional[str], git_available: bool) -> int:
    print(f"INFO filename={mode} category=scanned-files count={scanner.scanned_files}")
    if not git_available and mode == "source-git-filelist":
        print("ERROR filename=source category=git-metadata count=1")
    if configuration_error:
        print(f"ERROR filename=private-patterns.json category={configuration_error} count=1")

    if scanner.reviewed_files:
        print(f"INFO filename=upstream-fixtures category=reviewed-public-fixture count={scanner.reviewed_files}")

    for (filename, category), count in sorted(scanner.findings.items()):
        print(f"HIT filename={filename} category={category} count={count}")

    if not scanner.findings and not configuration_error and (git_available or mode != "source-git-filelist"):
        print(f"PASS filename={mode} category=privacy-hit count=0")

    has_failure = bool(scanner.findings) or configuration_error is not None
    if not git_available and mode == "source-git-filelist":
        has_failure = True
    return 1 if has_failure else 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    private_patterns, configuration_error = _load_private_patterns(args.private_patterns)
    scanner = Scanner(
        private_patterns,
        scan_archives=args.archives,
        max_file_bytes=args.max_file_bytes,
        max_archive_bytes=args.max_archive_bytes,
        max_archive_members=args.max_archive_members,
    )

    if args.upstream_fixtures:
        allowed = set(GENERIC_TOKEN_PATTERNS) | {"user-home-path", "banned-private-filename"}
        try:
            fixture_entries = json.loads(args.upstream_fixtures.read_text())["entries"]
            for entry in fixture_entries:
                digest = entry["sha256"]
                categories = set(entry["categories"])
                if not re.fullmatch(r"[a-f0-9]{64}", digest) or not categories <= allowed:
                    raise ValueError("Invalid fixture review")
                scanner.reviewed_fixtures.setdefault(digest, set()).update(categories)
        except (OSError, ValueError, KeyError, TypeError):
            print("ERROR filename=upstream-fixtures category=invalid-review count=1")
            return 1

    if args.paths:
        git_available = True
        mode = "explicit-inputs"
        paths = [Path(value) for value in args.paths]
        for path in paths:
            scanner.scan_path(path)
    else:
        mode = "source-git-filelist"
        paths, git_available = _git_visible_files(ROOT)
        if paths:
            for path in paths:
                scanner.scan_file(path)
        elif not git_available:
            # A source export without .git is not Git-visible, but a recursive
            # fallback still gives useful privacy diagnostics before release.
            scanner.scan_path(ROOT)

    return _print_report(scanner, mode, configuration_error, git_available)


if __name__ == "__main__":
    sys.exit(main())
