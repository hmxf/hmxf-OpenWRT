#!/usr/bin/env python3
"""Map manifest packages to authenticated cache files for frozen snapshots."""

from __future__ import annotations

import csv
import hashlib
import json
import os
import re
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn


INDEX_SCHEMA = "# package-cache-index-v1"
INDEX_COLUMNS = [
    "# release",
    "target",
    "filename",
    "package",
    "version",
    "architecture",
    "size",
    "sha256",
    "metadata_status",
]
BUILTIN_PACKAGES = frozenset({"base-files", "kernel", "libc"})
RELEASE_RE = re.compile(r"(?:[0-9]+\.[0-9]+\.[0-9]+|SNAPSHOT)")
TARGET_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
ATOM_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9+._~:-]*")
ARCH_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9+._~-]*")
APK_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9+._~:-]*\.apk")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
REPOSITORY_RE = re.compile(r"repo-([1-9][0-9]*)")


class ContractError(ValueError):
    """Raised when an input violates the package snapshot contract."""


@dataclass(frozen=True)
class CacheEntry:
    release: str
    target: str
    filename: str
    package: str
    version: str
    architecture: str
    size: int
    sha256: str
    metadata_status: str


@dataclass(frozen=True)
class RepositoryPackage:
    repository: str
    repository_order: int
    name: str
    version: str
    architecture: str
    package_hash: str

    @property
    def cache_filename(self) -> str:
        return f"{self.name}-{self.version}.{self.package_hash[:8]}.apk"

    @property
    def canonical_filename(self) -> str:
        return f"{self.name}-{self.version}.apk"


def die(message: str, status: int = 1) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(status)


def usage() -> NoReturn:
    die(
        "usage: map-package-snapshot.py INDEX RELEASE TARGET MANIFEST... "
        "-- REPO_NAME REPO_JSON [REPO_NAME REPO_JSON ...]",
        2,
    )


def regular_file(path_text: str, description: str, maximum_size: int) -> Path:
    path = Path(path_text)
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ContractError(f"cannot stat {description} {path}: {error}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise ContractError(f"{description} is not a regular file: {path}")
    if metadata.st_size <= 0 or metadata.st_size > maximum_size:
        raise ContractError(
            f"{description} has an unsafe size ({metadata.st_size} bytes): {path}"
        )
    return path


def read_text(path: Path, description: str, maximum_size: int) -> str:
    regular_file(str(path), description, maximum_size)
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ContractError(f"cannot read {description} {path}: {error}") from error


def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"JSON contains a duplicate key: {key}")
        result[key] = value
    return result


def reject_constant(value: str) -> NoReturn:
    raise ContractError(f"JSON contains an invalid numeric constant: {value}")


def load_json(path: Path) -> object:
    payload = read_text(path, "repository JSON", 256 * 1024 * 1024)
    try:
        return json.loads(
            payload,
            object_pairs_hook=reject_duplicates,
            parse_constant=reject_constant,
        )
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ContractError(f"invalid repository JSON {path}: {error}") from error


def load_index(index_path: Path) -> tuple[dict[tuple[str, str, str], CacheEntry], Path]:
    payload = read_text(index_path, "package cache index", 64 * 1024 * 1024)
    if not payload.endswith("\n"):
        raise ContractError(f"package cache index lacks a final newline: {index_path}")
    lines = payload.splitlines()
    if len(lines) < 2 or lines[0] != INDEX_SCHEMA:
        raise ContractError(f"package cache index has the wrong schema: {index_path}")
    if lines[1].split("\t") != INDEX_COLUMNS:
        raise ContractError(f"package cache index has the wrong columns: {index_path}")

    entries: dict[tuple[str, str, str], CacheEntry] = {}
    previous = ""
    for line_number, line in enumerate(lines[2:], 3):
        fields = next(csv.reader([line], delimiter="\t", strict=True))
        if len(fields) != 9 or "\r" in line:
            raise ContractError(f"malformed package cache index row {line_number}")
        release, target, filename, package, version, architecture, size, digest, status = fields
        if not RELEASE_RE.fullmatch(release) or not TARGET_RE.fullmatch(target):
            raise ContractError(f"unsafe release or target in index row {line_number}")
        if not APK_RE.fullmatch(filename):
            raise ContractError(f"unsafe APK filename in index row {line_number}")
        if status == "apk-adbdump":
            if (
                not ATOM_RE.fullmatch(package)
                or not ATOM_RE.fullmatch(version)
                or not ARCH_RE.fullmatch(architecture)
            ):
                raise ContractError(
                    f"index row {line_number} has unsafe authenticated APK metadata"
                )
            expected_filename = re.fullmatch(
                rf"{re.escape(package)}-{re.escape(version)}[.][0-9a-f]{{8}}[.]apk",
                filename,
            )
            if expected_filename is None:
                raise ContractError(
                    f"APK filename disagrees with metadata in index row {line_number}"
                )
        elif status == "unavailable":
            if (package, version, architecture) != ("-", "-", "-"):
                raise ContractError(
                    f"unavailable metadata fields disagree in index row {line_number}"
                )
        else:
            raise ContractError(f"unsafe metadata status in index row {line_number}")
        if not size.isascii() or not size.isdecimal() or int(size) <= 0:
            raise ContractError(f"invalid APK size in index row {line_number}")
        if not SHA256_RE.fullmatch(digest):
            raise ContractError(f"invalid APK SHA-256 in index row {line_number}")
        if previous and line <= previous:
            raise ContractError("package cache index is not strictly sorted")
        previous = line
        key = (release, target, filename)
        if key in entries:
            raise ContractError(f"duplicate package cache index key: {'/'.join(key)}")
        entries[key] = CacheEntry(
            release,
            target,
            filename,
            package,
            version,
            architecture,
            int(size),
            digest,
            status,
        )
    return entries, index_path.parent


def load_manifests(paths: list[Path]) -> set[tuple[str, str]]:
    required: dict[str, str] = {}
    seen_paths: set[Path] = set()
    for path in paths:
        canonical_path = path.absolute()
        if canonical_path in seen_paths:
            raise ContractError(f"duplicate manifest path: {path}")
        seen_paths.add(canonical_path)
        payload = read_text(path, "package manifest", 16 * 1024 * 1024)
        if not payload.endswith("\n"):
            raise ContractError(f"package manifest lacks a final newline: {path}")
        previous: tuple[str, str] | None = None
        seen: set[tuple[str, str]] = set()
        for line_number, line in enumerate(payload.splitlines(), 1):
            parts = line.split(" - ")
            if len(parts) != 2:
                raise ContractError(f"malformed manifest row {path}:{line_number}")
            name, version = parts
            if not ATOM_RE.fullmatch(name) or not ATOM_RE.fullmatch(version):
                raise ContractError(f"unsafe manifest row {path}:{line_number}")
            identity = (name, version)
            if identity in seen or previous is not None and identity <= previous:
                raise ContractError(f"manifest is duplicate or unsorted: {path}:{line_number}")
            seen.add(identity)
            previous = identity
            old_version = required.get(name)
            if old_version is not None and old_version != version:
                raise ContractError(
                    f"manifests resolve conflicting versions for {name}: "
                    f"{old_version} and {version}"
                )
            required[name] = version
    if not required:
        raise ContractError("package manifests resolve no packages")
    return {(name, version) for name, version in required.items()}


def load_repositories(
    pairs: list[tuple[str, Path]],
) -> dict[tuple[str, str], list[RepositoryPackage]]:
    by_identity: dict[tuple[str, str], list[RepositoryPackage]] = {}
    for order, (repository, json_path) in enumerate(pairs, 1):
        match = REPOSITORY_RE.fullmatch(repository)
        if match is None or int(match.group(1)) != order:
            raise ContractError(
                f"repositories must be unique and contiguous in repo-1..repo-N order: {repository}"
            )
        document = load_json(json_path)
        if not isinstance(document, dict) or set(document) != {"packages"}:
            raise ContractError(f"repository JSON has the wrong top-level shape: {json_path}")
        packages = document["packages"]
        if not isinstance(packages, list) or not packages:
            raise ContractError(f"repository JSON has no packages: {json_path}")
        seen: set[tuple[str, str, str]] = set()
        for position, item in enumerate(packages, 1):
            if not isinstance(item, dict):
                raise ContractError(f"repository package {json_path}:{position} is not an object")
            name = item.get("name")
            version = item.get("version")
            architecture = item.get("arch")
            package_hash = item.get("hashes")
            if (
                not isinstance(name, str)
                or not ATOM_RE.fullmatch(name)
                or not isinstance(version, str)
                or not ATOM_RE.fullmatch(version)
                or not isinstance(architecture, str)
                or not ARCH_RE.fullmatch(architecture)
                or not isinstance(package_hash, str)
                or not SHA256_RE.fullmatch(package_hash)
            ):
                raise ContractError(
                    f"repository package has unsafe identity metadata: {json_path}:{position}"
                )
            repository_identity = (name, version, architecture)
            if repository_identity in seen:
                raise ContractError(
                    f"duplicate package identity in repository {repository}: "
                    f"{name} {version} {architecture}"
                )
            seen.add(repository_identity)
            entry = RepositoryPackage(
                repository,
                order,
                name,
                version,
                architecture,
                package_hash,
            )
            by_identity.setdefault((name, version), []).append(entry)
    return by_identity


def verify_cache_file(cache_root: Path, entry: CacheEntry) -> None:
    release_dir = cache_root / entry.release
    target_dir = release_dir / entry.target
    for directory, description in (
        (cache_root, "cache root"),
        (release_dir, "cache release directory"),
        (target_dir, "cache target directory"),
    ):
        try:
            metadata = directory.lstat()
        except OSError as error:
            raise ContractError(f"cannot stat {description} {directory}: {error}") from error
        if not stat.S_ISDIR(metadata.st_mode):
            raise ContractError(f"{description} is not a real directory: {directory}")
    apk_path = target_dir / entry.filename
    regular_file(str(apk_path), "cached APK", 4 * 1024 * 1024 * 1024)
    metadata = apk_path.stat()
    if metadata.st_size != entry.size:
        raise ContractError(f"cached APK size differs from index: {apk_path}")
    digest = hashlib.sha256()
    try:
        with apk_path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise ContractError(f"cannot hash cached APK {apk_path}: {error}") from error
    if digest.hexdigest() != entry.sha256:
        raise ContractError(f"cached APK SHA-256 differs from index: {apk_path}")


def map_packages(
    cache_entries: dict[tuple[str, str, str], CacheEntry],
    cache_root: Path,
    release: str,
    target: str,
    required: set[tuple[str, str]],
    repositories: dict[tuple[str, str], list[RepositoryPackage]],
) -> list[tuple[int, str, str, str]]:
    scoped_entries = {
        filename: entry
        for (entry_release, entry_target, filename), entry in cache_entries.items()
        if entry_release == release and entry_target == target
    }
    unauthenticated = sorted(
        filename
        for filename, entry in scoped_entries.items()
        if entry.metadata_status != "apk-adbdump"
    )
    if unauthenticated:
        raise ContractError(
            "selected cache scope contains entries without authenticated metadata: "
            + ", ".join(unauthenticated)
        )
    mappings: list[tuple[int, str, str, str]] = []
    for name, version in sorted(required):
        candidates = repositories.get((name, version), [])
        matches: list[tuple[RepositoryPackage, CacheEntry]] = []
        for package in candidates:
            cache_entry = scoped_entries.get(package.cache_filename)
            if cache_entry is None:
                continue
            if (
                cache_entry.package != name
                or cache_entry.version != version
                or cache_entry.architecture != package.architecture
            ):
                raise ContractError(
                    f"cache metadata disagrees with repository metadata: "
                    f"{release}/{target}/{package.cache_filename}"
                )
            matches.append((package, cache_entry))
        distinct_files = {entry.filename for _, entry in matches}
        if len(distinct_files) > 1:
            raise ContractError(
                f"multiple repository hashes match cached variants for {name} {version}"
            )
        if not matches:
            if name in BUILTIN_PACKAGES:
                continue
            if not candidates:
                raise ContractError(
                    f"manifest package is absent from all repository indexes: {name} {version}"
                )
            expected = ", ".join(
                f"{package.repository}/{package.cache_filename}" for package in candidates
            )
            raise ContractError(
                f"resolved package has no exact cached hash: {name} {version} ({expected})"
            )
        package, cache_entry = min(matches, key=lambda item: item[0].repository_order)
        verify_cache_file(cache_root, cache_entry)
        mappings.append(
            (
                package.repository_order,
                package.repository,
                package.canonical_filename,
                cache_entry.filename,
            )
        )
    mappings.sort(key=lambda item: (item[0], item[2], item[3]))
    return mappings


def main(arguments: list[str]) -> int:
    if "--" not in arguments:
        usage()
    separator = arguments.index("--")
    left = arguments[:separator]
    right = arguments[separator + 1 :]
    if len(left) < 4 or len(right) < 2 or len(right) % 2:
        usage()
    index_text, release, target, *manifest_texts = left
    if not RELEASE_RE.fullmatch(release) or not TARGET_RE.fullmatch(target):
        raise ContractError("release or target argument has an unsafe format")
    repository_pairs = [
        (right[position], Path(right[position + 1]))
        for position in range(0, len(right), 2)
    ]
    if len({name for name, _ in repository_pairs}) != len(repository_pairs):
        raise ContractError("duplicate repository name")

    cache_entries, cache_root = load_index(Path(index_text))
    required = load_manifests([Path(path) for path in manifest_texts])
    repositories = load_repositories(repository_pairs)
    mappings = map_packages(
        cache_entries,
        cache_root,
        release,
        target,
        required,
        repositories,
    )
    for _, repository, canonical_name, cache_filename in mappings:
        print(f"{repository}\t{canonical_name}\t{cache_filename}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ContractError as error:
        die(str(error))
