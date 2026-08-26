#!/usr/bin/env python3
"""Safely extract and verify one externally locked package snapshot tree."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tarfile
from typing import BinaryIO, NoReturn


SHA256_RE = re.compile(r"[0-9a-f]{64}")
RELEASE_RE = re.compile(r"(?:[0-9]+\.[0-9]+\.[0-9]+|SNAPSHOT)")
TARGET_RE = re.compile(r"(?:x86_64|rpi4|rpi5)")
REPOSITORY_RE = re.compile(r"repo-([1-9][0-9]*)")
APK_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9+._~:-]*\.apk")
MAX_MEMBERS = 100_000
MAX_FILE_BYTES = 4 * 1024 * 1024 * 1024
MAX_TOTAL_BYTES = 16 * 1024 * 1024 * 1024
COPY_CHUNK_BYTES = 1024 * 1024


class SnapshotError(ValueError):
    """An input violates the locked package-snapshot contract."""


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(COPY_CHUNK_BYTES), b""):
                digest.update(chunk)
    except OSError as error:
        raise SnapshotError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def require_regular_file(path: Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise SnapshotError(f"cannot stat {label} {path}: {error}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise SnapshotError(f"{label} is not a regular file: {path}")
    return metadata


def require_canonical_directory(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise SnapshotError(f"cannot inspect {label} {path}: {error}") from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise SnapshotError(f"{label} is not a real directory: {path}")
    if resolved != Path(os.path.abspath(path)):
        raise SnapshotError(f"{label} traverses a symbolic link: {path}")


def safe_relative_path(name: str, prefix: PurePosixPath) -> PurePosixPath:
    if not name or "\\" in name or "\x00" in name or name.startswith("/"):
        raise SnapshotError(f"unsafe archive member path: {name!r}")
    path = PurePosixPath(name)
    if any(part in ("", ".", "..") for part in path.parts):
        raise SnapshotError(f"unsafe archive member path: {name!r}")
    if path != prefix and prefix not in path.parents:
        raise SnapshotError(
            f"archive member is outside {prefix.as_posix()}: {name!r}"
        )
    return path


def copy_member(source: BinaryIO, destination: Path, expected_size: int) -> None:
    written = 0
    try:
        with destination.open("xb") as output:
            while written < expected_size:
                chunk = source.read(min(COPY_CHUNK_BYTES, expected_size - written))
                if not chunk:
                    raise SnapshotError(
                        f"archive member ended early: {destination} "
                        f"({written}/{expected_size} bytes)"
                    )
                output.write(chunk)
                written += len(chunk)
            if source.read(1):
                raise SnapshotError(f"archive member exceeds declared size: {destination}")
    except OSError as error:
        raise SnapshotError(f"cannot extract archive member {destination}: {error}") from error
    os.chmod(destination, 0o644)


def extract_bundle(bundle: Path, destination_root: Path, release: str, target: str) -> Path:
    require_regular_file(bundle, "snapshot bundle")
    require_canonical_directory(destination_root, "extraction root")
    try:
        if any(destination_root.iterdir()):
            raise SnapshotError(f"extraction root is not empty: {destination_root}")
    except OSError as error:
        raise SnapshotError(f"cannot inspect extraction root {destination_root}: {error}") from error

    prefix = PurePosixPath(release, target)
    seen: set[PurePosixPath] = set()
    member_count = 0
    total_bytes = 0
    process = subprocess.Popen(
        ["zstd", "--quiet", "--decompress", "--stdout", "--", str(bundle)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdout is not None
    caught_error: BaseException | None = None
    try:
        with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
            for member in archive:
                member_count += 1
                if member_count > MAX_MEMBERS:
                    raise SnapshotError("snapshot bundle has too many members")
                member_path = safe_relative_path(member.name, prefix)
                if member_path in seen:
                    raise SnapshotError(
                        f"snapshot bundle has a duplicate member: {member.name}"
                    )
                seen.add(member_path)
                destination = destination_root.joinpath(*member_path.parts)
                if member.isdir():
                    try:
                        destination.mkdir(mode=0o755, parents=True, exist_ok=False)
                    except FileExistsError:
                        if not destination.is_dir() or destination.is_symlink():
                            raise SnapshotError(
                                f"archive directory collides with another member: {member.name}"
                            )
                    except OSError as error:
                        raise SnapshotError(
                            f"cannot create archive directory {destination}: {error}"
                        ) from error
                    continue
                if not member.isreg():
                    raise SnapshotError(
                        f"snapshot bundle contains a non-regular member: {member.name}"
                    )
                if member.size <= 0 or member.size > MAX_FILE_BYTES:
                    raise SnapshotError(
                        f"snapshot bundle member has an unsafe size: {member.name}"
                    )
                total_bytes += member.size
                if total_bytes > MAX_TOTAL_BYTES:
                    raise SnapshotError("snapshot bundle expands beyond the size limit")
                try:
                    destination.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                except OSError as error:
                    raise SnapshotError(
                        f"cannot create archive parent {destination.parent}: {error}"
                    ) from error
                source = archive.extractfile(member)
                if source is None:
                    raise SnapshotError(f"cannot read archive member: {member.name}")
                with source:
                    copy_member(source, destination, member.size)
    except BaseException as error:
        caught_error = error
    finally:
        process.stdout.close()
        if caught_error is not None and process.poll() is None:
            try:
                process.terminate()
            except ProcessLookupError:
                pass
    stderr = process.stderr.read().decode("utf-8", errors="replace") if process.stderr else ""
    status = process.wait()
    if caught_error is not None:
        if isinstance(caught_error, SnapshotError):
            raise caught_error
        if isinstance(caught_error, (tarfile.TarError, EOFError, OSError)):
            raise SnapshotError(
                f"cannot decode snapshot bundle {bundle}: {caught_error}"
            ) from caught_error
        raise caught_error
    if status:
        raise SnapshotError(
            f"cannot decompress snapshot bundle {bundle} "
            f"(zstd exit {status}): {stderr.strip()}"
        )
    if not seen:
        raise SnapshotError("snapshot bundle is empty")
    expected_root = destination_root / release / target
    return expected_root


def parse_checksum_manifest(path: Path) -> dict[str, str]:
    require_regular_file(path, "snapshot checksum manifest")
    try:
        payload = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise SnapshotError(f"cannot read snapshot checksum manifest {path}: {error}") from error
    if not payload or not payload.endswith("\n"):
        raise SnapshotError("snapshot checksum manifest is empty or lacks a final newline")
    result: dict[str, str] = {}
    previous = ""
    for line_number, line in enumerate(payload.splitlines(), 1):
        match = re.fullmatch(r"([0-9a-f]{64}) [ *](.+)", line)
        if match is None:
            raise SnapshotError(f"malformed checksum row {line_number}")
        digest, name = match.groups()
        if (
            name != "repositories.list"
            and re.fullmatch(
                r"repo-[1-9][0-9]*/(?:packages[.]adb|"
                r"[A-Za-z0-9][A-Za-z0-9+._~:-]*[.]apk)",
                name,
            )
            is None
        ):
            raise SnapshotError(f"unsafe checksum path at row {line_number}: {name}")
        if name in result or previous and name <= previous:
            raise SnapshotError("snapshot checksum paths are duplicate or unsorted")
        previous = name
        result[name] = digest
    return result


def verify_snapshot(snapshot: Path, release: str, target: str, manifest_sha256: str) -> None:
    require_canonical_directory(snapshot, "snapshot tree")
    if snapshot.name != target or snapshot.parent.name != release:
        raise SnapshotError(
            f"snapshot tree does not end in the locked release/target: {snapshot}"
        )
    manifest = snapshot / "SHA256SUMS"
    require_regular_file(manifest, "snapshot checksum manifest")
    if sha256_file(manifest) != manifest_sha256:
        raise SnapshotError("snapshot checksum manifest differs from its external lock")
    checksums = parse_checksum_manifest(manifest)

    actual_files: set[str] = set()
    repository_dirs: list[str] = []
    for root, directories, files in os.walk(snapshot, topdown=True, followlinks=False):
        root_path = Path(root)
        for directory in directories:
            path = root_path / directory
            if not stat.S_ISDIR(path.lstat().st_mode):
                raise SnapshotError(f"snapshot contains a non-directory node: {path}")
            relative = path.relative_to(snapshot).as_posix()
            if root_path == snapshot:
                if REPOSITORY_RE.fullmatch(directory) is None:
                    raise SnapshotError(f"snapshot has an unknown directory: {relative}")
                repository_dirs.append(directory)
            else:
                raise SnapshotError(f"snapshot contains a nested directory: {relative}")
        for filename in files:
            path = root_path / filename
            require_regular_file(path, "snapshot file")
            relative = path.relative_to(snapshot).as_posix()
            if relative != "SHA256SUMS":
                actual_files.add(relative)

    if actual_files != set(checksums):
        missing = sorted(set(checksums) - actual_files)
        extra = sorted(actual_files - set(checksums))
        raise SnapshotError(
            f"snapshot file set differs from checksum manifest "
            f"(missing={missing}, extra={extra})"
        )
    for name, expected_digest in checksums.items():
        if sha256_file(snapshot / name) != expected_digest:
            raise SnapshotError(f"snapshot file digest mismatch: {name}")

    repositories_file = snapshot / "repositories.list"
    try:
        repository_payload = repositories_file.read_text(encoding="ascii")
    except (OSError, UnicodeError) as error:
        raise SnapshotError(f"cannot read repositories.list: {error}") from error
    if not repository_payload or not repository_payload.endswith("\n"):
        raise SnapshotError("repositories.list is empty or lacks a final newline")
    repositories = repository_payload.splitlines()
    expected_repositories = [f"repo-{index}" for index in range(1, len(repositories) + 1)]
    if repositories != expected_repositories:
        raise SnapshotError("repositories.list is not contiguous repo-1..repo-N")
    if sorted(repository_dirs, key=lambda name: int(name.removeprefix("repo-"))) != repositories:
        raise SnapshotError("snapshot repository directories differ from repositories.list")
    for repository in repositories:
        package_index = snapshot / repository / "packages.adb"
        require_regular_file(package_index, "repository package index")
        if package_index.stat().st_size <= 0:
            raise SnapshotError(f"repository package index is empty: {repository}")
        for path in (snapshot / repository).iterdir():
            require_regular_file(path, "repository file")
            if path.name != "packages.adb" and APK_RE.fullmatch(path.name) is None:
                raise SnapshotError(f"unsafe repository filename: {repository}/{path.name}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="mode", required=True)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("snapshot")
    extract_parser = subparsers.add_parser("extract")
    extract_parser.add_argument("bundle")
    extract_parser.add_argument("destination_root")
    for command_parser in (verify_parser, extract_parser):
        command_parser.add_argument("release")
        command_parser.add_argument("target")
        command_parser.add_argument("manifest_sha256")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if RELEASE_RE.fullmatch(arguments.release) is None:
        raise SnapshotError(f"unsafe release: {arguments.release}")
    if TARGET_RE.fullmatch(arguments.target) is None:
        raise SnapshotError(f"unsafe target: {arguments.target}")
    if SHA256_RE.fullmatch(arguments.manifest_sha256) is None:
        raise SnapshotError("unsafe external checksum-manifest SHA-256")
    if arguments.mode == "verify":
        snapshot = Path(arguments.snapshot)
    else:
        snapshot = extract_bundle(
            Path(arguments.bundle),
            Path(arguments.destination_root),
            arguments.release,
            arguments.target,
        )
    verify_snapshot(
        snapshot,
        arguments.release,
        arguments.target,
        arguments.manifest_sha256,
    )
    print(f"Verified package snapshot: {snapshot}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SnapshotError as error:
        fail(str(error))
