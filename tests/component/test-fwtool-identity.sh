#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
temporary_dir=$(mktemp -d)
cleanup() {
    rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

PYTHONDONTWRITEBYTECODE=1 python3 - \
    "$PROJECT_ROOT/scripts/verify/verify-image-structure.py" \
    "$temporary_dir" <<'PY'
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import struct
import sys
import zlib


verifier_path = Path(sys.argv[1])
temporary_dir = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("image_verifier", verifier_path)
if spec is None or spec.loader is None:
    raise SystemExit("cannot import image structure verifier")
verifier = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = verifier
spec.loader.exec_module(verifier)


def write_pair(version: str, revision: str) -> tuple[Path, Path]:
    factory = temporary_dir / "firmware-rpi-4-squashfs-factory.img.gz"
    sysupgrade = temporary_dir / "firmware-rpi-4-squashfs-sysupgrade.img.gz"
    factory_payload = b"validated-factory-gzip-payload"
    factory.write_bytes(factory_payload)
    metadata = {
        "version": {
            "target": "bcm27xx/bcm2711",
            "board": "rpi-4",
            "dist": "ImmortalWrt",
            "version": version,
            "revision": revision,
        },
        "supported_devices": [
            "raspberrypi,400",
            "raspberrypi,4-compute-module",
            "raspberrypi,4-model-b",
        ],
        "metadata_version": "1.1",
        "compat_version": "1.0",
    }
    metadata_chunk = struct.pack(">II", 0, 0) + json.dumps(
        metadata, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    crc_prefix = factory_payload + metadata_chunk
    stored_crc = (zlib.crc32(crc_prefix) ^ 0xFFFFFFFF) & 0xFFFFFFFF
    chunk_size = len(metadata_chunk) + verifier.FWTOOL_TRAILER_SIZE
    trailer = struct.pack(
        ">4sIB3sI", b"FWx0", stored_crc, 1, bytes(3), chunk_size
    )
    sysupgrade.write_bytes(crc_prefix + trailer)
    return factory, sysupgrade


snapshot_revision = "r40001-bcdefa234567"
factory_path, sysupgrade_path = write_pair("SNAPSHOT", snapshot_revision)
verifier.verify_fwtool(
    factory_path, sysupgrade_path, "rpi4", "SNAPSHOT", snapshot_revision
)

for wrong_version, wrong_revision in (
    ("25.12.1", snapshot_revision),
    ("SNAPSHOT", "r40000-abcdef123456"),
):
    try:
        verifier.verify_fwtool(
            factory_path,
            sysupgrade_path,
            "rpi4",
            wrong_version,
            wrong_revision,
        )
    except verifier.VerificationError:
        pass
    else:
        raise SystemExit("fwtool verifier accepted the wrong build identity")

stable_revision = "r39000-0123456789ab"
factory_path, sysupgrade_path = write_pair("25.12.1", stable_revision)
verifier.verify_fwtool(
    factory_path, sysupgrade_path, "rpi4", "25.12.1", stable_revision
)
PY

printf '%s\n' 'Stable and SNAPSHOT fwtool identity tests passed.'
