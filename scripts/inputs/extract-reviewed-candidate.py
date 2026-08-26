#!/usr/bin/env python3
"""Safely extract one digest-locked GitHub Actions candidate artifact."""

from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import zipfile


MAX_ENTRIES = 100_000
MAX_TOTAL_BYTES = 20 * 1024 * 1024 * 1024
MAX_FILE_BYTES = 5 * 1024 * 1024 * 1024
CHUNK_BYTES = 1024 * 1024


def fail(message: str) -> "None":
    raise SystemExit(f"error: {message}")


def safe_parts(info: zipfile.ZipInfo) -> tuple[tuple[str, ...], bool]:
    name = info.filename
    if not name or "\\" in name or "\x00" in name:
        fail(f"unsafe ZIP member name: {name!r}")
    if any(ord(character) < 32 or ord(character) == 127 for character in name):
        fail(f"control character in ZIP member name: {name!r}")
    is_directory = info.is_dir()
    normalized = name[:-1] if is_directory and name.endswith("/") else name
    if not normalized or normalized.startswith("/") or normalized.endswith("/"):
        fail(f"unsafe ZIP member path: {name!r}")
    raw_parts = normalized.split("/")
    if any(part in {"", ".", ".."} for part in raw_parts):
        fail(f"non-canonical ZIP member path: {name!r}")
    path = PurePosixPath(normalized)
    if path.is_absolute() or path.parts != tuple(raw_parts):
        fail(f"unsafe ZIP member path: {name!r}")
    if raw_parts[0].endswith(":"):
        fail(f"drive-like ZIP member path: {name!r}")
    return tuple(raw_parts), is_directory


def member_kind(info: zipfile.ZipInfo, is_directory: bool) -> str:
    if info.flag_bits & 0x1:
        fail(f"encrypted ZIP member is forbidden: {info.filename!r}")
    unix_mode = (info.external_attr >> 16) & 0xFFFF
    file_type = stat.S_IFMT(unix_mode)
    if file_type and file_type not in {stat.S_IFREG, stat.S_IFDIR}:
        fail(f"link or special ZIP member is forbidden: {info.filename!r}")
    if is_directory and file_type == stat.S_IFREG:
        fail(f"directory ZIP member has regular-file mode: {info.filename!r}")
    if not is_directory and file_type == stat.S_IFDIR:
        fail(f"file ZIP member has directory mode: {info.filename!r}")
    return "directory" if is_directory else "file"


def validate_members(
    archive: zipfile.ZipFile,
) -> list[tuple[zipfile.ZipInfo, tuple[str, ...], str]]:
    infos = archive.infolist()
    if not infos or len(infos) > MAX_ENTRIES:
        fail(f"ZIP entry count is outside 1..{MAX_ENTRIES}: {len(infos)}")
    entries: list[tuple[zipfile.ZipInfo, tuple[str, ...], str]] = []
    kinds: dict[tuple[str, ...], str] = {}
    total_bytes = 0
    for info in infos:
        parts, is_directory = safe_parts(info)
        kind = member_kind(info, is_directory)
        if parts in kinds:
            fail(f"duplicate ZIP member path: {info.filename!r}")
        if info.file_size < 0 or info.compress_size < 0:
            fail(f"negative ZIP member size: {info.filename!r}")
        if kind == "directory" and info.file_size != 0:
            fail(f"directory ZIP member has content: {info.filename!r}")
        if kind == "file" and info.file_size > MAX_FILE_BYTES:
            fail(f"ZIP member exceeds the per-file limit: {info.filename!r}")
        total_bytes += info.file_size
        if total_bytes > MAX_TOTAL_BYTES:
            fail("ZIP exceeds the total uncompressed-size limit")
        kinds[parts] = kind
        entries.append((info, parts, kind))

    for parts, kind in kinds.items():
        for depth in range(1, len(parts)):
            if kinds.get(parts[:depth]) == "file":
                fail(f"ZIP file/directory prefix collision: {'/'.join(parts)!r}")
        if kind == "file" and any(
            other[: len(parts)] == parts and len(other) > len(parts)
            for other in kinds
        ):
            fail(f"ZIP file/directory prefix collision: {'/'.join(parts)!r}")
    return entries


def extract(archive_path: Path, destination: Path) -> None:
    try:
        archive_stat = archive_path.lstat()
    except FileNotFoundError:
        fail(f"artifact ZIP does not exist: {archive_path}")
    if not stat.S_ISREG(archive_stat.st_mode):
        fail(f"artifact ZIP is not a regular file: {archive_path}")
    if destination.exists() or destination.is_symlink():
        fail(f"extraction destination already exists: {destination}")
    probe = destination.parent
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    while True:
        if probe.is_symlink():
            fail(f"symbolic-link extraction ancestor: {probe}")
        if probe == probe.parent:
            break
        probe = probe.parent
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.parent.is_symlink() or not destination.parent.is_dir():
        fail(f"unsafe extraction parent: {destination.parent}")

    try:
        with zipfile.ZipFile(archive_path, "r") as archive:
            entries = validate_members(archive)
            destination.mkdir(mode=0o755)
            for _info, parts, kind in entries:
                if kind == "directory":
                    (destination.joinpath(*parts)).mkdir(
                        mode=0o755, parents=True, exist_ok=True
                    )
            for info, parts, kind in entries:
                if kind == "directory":
                    continue
                target = destination.joinpath(*parts)
                target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                descriptor = os.open(target, flags, 0o644)
                copied = 0
                try:
                    with os.fdopen(descriptor, "wb") as output, archive.open(
                        info, "r"
                    ) as source:
                        while True:
                            chunk = source.read(CHUNK_BYTES)
                            if not chunk:
                                break
                            copied += len(chunk)
                            if copied > info.file_size:
                                fail(f"ZIP member expanded past its declared size: {info.filename!r}")
                            output.write(chunk)
                except BaseException:
                    target.unlink(missing_ok=True)
                    raise
                if copied != info.file_size:
                    fail(f"ZIP member size mismatch: {info.filename!r}")
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        if destination.exists() and not destination.is_symlink():
            shutil.rmtree(destination)
        fail(f"cannot safely extract reviewed artifact: {error}")
    except BaseException:
        if destination.exists() and not destination.is_symlink():
            shutil.rmtree(destination)
        raise


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: extract-reviewed-candidate.py ARTIFACT.zip DESTINATION")
    archive = Path(os.path.abspath(sys.argv[1]))
    destination = Path(os.path.abspath(sys.argv[2]))
    extract(archive, destination)


if __name__ == "__main__":
    main()
