#!/usr/bin/env python3
"""Safely extract the deterministic nightly build-context archive."""

from __future__ import annotations

import argparse
import os
from pathlib import Path, PurePosixPath
import stat
import tarfile


MAX_MEMBERS = 10_000
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_TOTAL_BYTES = 256 * 1024 * 1024


def safe_path(name: str) -> PurePosixPath:
    if not name or name.startswith("/") or "\\" in name or "\x00" in name:
        raise ValueError(f"unsafe context archive path: {name!r}")
    path = PurePosixPath(name)
    if any(part in ("", ".", "..") for part in path.parts):
        raise ValueError(f"unsafe context archive path: {name!r}")
    if path != PurePosixPath("NIGHTLY_BUILD.env") and path.parts[0] != "context":
        raise ValueError(f"unexpected context archive path: {name!r}")
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive")
    parser.add_argument("destination")
    parser.add_argument("source_date_epoch", type=int)
    args = parser.parse_args()
    if args.source_date_epoch < 0:
        raise ValueError("source date epoch must be nonnegative")
    archive_path = Path(args.archive)
    destination = Path(args.destination)
    if not stat.S_ISREG(archive_path.lstat().st_mode):
        raise ValueError("context archive is not a regular file")
    if not stat.S_ISDIR(destination.lstat().st_mode) or any(destination.iterdir()):
        raise ValueError("context extraction destination is not an empty real directory")
    if destination.resolve(strict=True) != Path(os.path.abspath(destination)):
        raise ValueError("context extraction destination traverses a symbolic link")

    seen: set[PurePosixPath] = set()
    previous_name = ""
    total = 0
    with tarfile.open(archive_path, mode="r:") as archive:
        for index, member in enumerate(archive, 1):
            if index > MAX_MEMBERS:
                raise ValueError("context archive has too many members")
            path = safe_path(member.name)
            canonical_name = path.as_posix()
            if previous_name and canonical_name <= previous_name:
                raise ValueError("context archive members are not in canonical order")
            previous_name = canonical_name
            if path in seen:
                raise ValueError(f"duplicate context archive member: {member.name}")
            seen.add(path)
            if member.uid != 0 or member.gid != 0 or member.mtime != args.source_date_epoch:
                raise ValueError(f"noncanonical context archive metadata: {member.name}")
            output = destination.joinpath(*path.parts)
            if member.isdir():
                if member.mode & 0o777 != 0o755:
                    raise ValueError(f"noncanonical directory mode: {member.name}")
                output.mkdir(mode=0o755, parents=True, exist_ok=True)
                continue
            if not member.isreg() or member.mode & 0o777 != 0o644:
                raise ValueError(f"unsafe context archive member type/mode: {member.name}")
            if member.size <= 0 or member.size > MAX_FILE_BYTES:
                raise ValueError(f"unsafe context archive member size: {member.name}")
            total += member.size
            if total > MAX_TOTAL_BYTES:
                raise ValueError("context archive expands beyond its size limit")
            output.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise ValueError(f"cannot read context archive member: {member.name}")
            with source, output.open("xb") as target:
                remaining = member.size
                while remaining:
                    chunk = source.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ValueError(f"truncated context archive member: {member.name}")
                    target.write(chunk)
                    remaining -= len(chunk)
            output.chmod(0o644)
    if PurePosixPath("NIGHTLY_BUILD.env") not in seen:
        raise ValueError("context archive is missing NIGHTLY_BUILD.env")
    if not (destination / "context" / "CONTEXT.sha256").is_file():
        raise ValueError("context archive is missing context/CONTEXT.sha256")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, tarfile.TarError, ValueError) as error:
        raise SystemExit(f"error: {error}")
