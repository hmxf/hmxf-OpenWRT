#!/usr/bin/env python3
"""Validate boot-critical structures in hmxf-OpenWRT disk images.

This intentionally uses only the Python standard library.  It validates the
formats produced by the locked x86_64, Raspberry Pi 4, and Raspberry Pi 5
targets without mounting an untrusted image or requiring root privileges.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
import struct
import sys
from typing import Iterable
import uuid
import zlib


SECTOR_SIZE = 512
MIB = 1024 * 1024
PROBE_BYTES = 80 * MIB
TRAILER_PROBE_BYTES = 64 * 1024
SQUASHFS_SUPERBLOCK_SIZE = 96
FWTOOL_TRAILER_SIZE = 16
FWTOOL_METADATA_MAX_SIZE = 30 * 1024
GPT_LINUX_FILESYSTEM = bytes.fromhex("af3dc60f838472478e793d69d8477de4")
GPT_GRUB_RESERVED = b"Hah!IdontNeedEFI"


class VerificationError(Exception):
    """An image does not match the required bootable layout."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def unpack_from(fmt: str, data: bytes, offset: int, description: str):
    try:
        return struct.unpack_from(fmt, data, offset)
    except struct.error as exc:
        raise VerificationError(f"truncated {description}") from exc


@dataclass(frozen=True)
class RawImage:
    prefix: bytes
    suffix: bytes
    size: int


def read_gzip_image(path: Path, media_limit: int) -> RawImage:
    """Fully validate exactly one gzip member while retaining its boot area."""
    prefix = bytearray()
    suffix = bytearray()
    raw_size = 0

    def retain(chunk: bytes) -> None:
        nonlocal raw_size
        if len(prefix) < PROBE_BYTES:
            wanted = PROBE_BYTES - len(prefix)
            prefix.extend(chunk[:wanted])
        suffix.extend(chunk)
        if len(suffix) > TRAILER_PROBE_BYTES:
            del suffix[:-TRAILER_PROBE_BYTES]
        raw_size += len(chunk)
        require(
            raw_size < media_limit,
            f"{path}: uncompressed image is not smaller than "
            f"the {media_limit}-byte media limit",
        )

    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        with path.open("rb") as stream:
            pending = b""
            while True:
                if not pending:
                    pending = stream.read(MIB)
                if not pending:
                    break
                chunk = decompressor.decompress(pending, 8 * MIB)
                pending = decompressor.unconsumed_tail
                retain(chunk)
                if decompressor.eof:
                    require(
                        not decompressor.unused_data and not pending and not stream.read(1),
                        f"{path}: trailing data or multiple gzip members are not allowed",
                    )
                    break
    except (OSError, zlib.error) as exc:
        raise VerificationError(f"{path}: invalid gzip stream: {exc}") from exc

    require(decompressor.eof, f"{path}: truncated gzip stream")
    require(raw_size % SECTOR_SIZE == 0, f"{path}: raw image is not sector-aligned")
    require(raw_size >= SECTOR_SIZE, f"{path}: raw image is empty")
    return RawImage(bytes(prefix), bytes(suffix), raw_size)


def raw_slice(raw: RawImage, offset: int, length: int, path: Path, description: str) -> bytes:
    """Read a small absolute range retained in either image probe."""
    require(offset >= 0 and length >= 0, f"{path}: invalid {description} bounds")
    if offset + length <= len(raw.prefix):
        return raw.prefix[offset : offset + length]
    suffix_start = raw.size - len(raw.suffix)
    if offset >= suffix_start and offset + length <= raw.size:
        relative = offset - suffix_start
        return raw.suffix[relative : relative + length]
    raise VerificationError(f"{path}: {description} is outside the validated probes")


@dataclass(frozen=True)
class Partition:
    first_lba: int
    last_lba: int
    type_id: bytes
    unique_id: bytes
    attributes: int = 0

    @property
    def sectors(self) -> int:
        return self.last_lba - self.first_lba + 1


def verify_gpt(raw: RawImage, rootfs_mib: int, path: Path) -> tuple[Partition, Partition]:
    data = raw.prefix
    require(len(data) >= 3 * SECTOR_SIZE, f"{path}: truncated GPT image")
    require(data[510:512] == b"\x55\xaa", f"{path}: protective MBR signature is absent")

    protective = data[446:462]
    protective_start, protective_count = unpack_from(
        "<II", protective, 8, "protective MBR entry"
    )
    require(protective[4] == 0xEE, f"{path}: GPT protective MBR entry has the wrong type")
    require(
        protective_start == 1 and protective_count > 0,
        f"{path}: GPT protective MBR entry has invalid bounds",
    )
    require(
        data[462:510] == bytes(48),
        f"{path}: protective MBR contains unexpected extra partitions",
    )

    header_offset = SECTOR_SIZE
    header_sector = data[header_offset : header_offset + SECTOR_SIZE]
    require(header_sector[:8] == b"EFI PART", f"{path}: primary GPT header is absent")
    revision, header_size, stored_header_crc = unpack_from(
        "<III", header_sector, 8, "GPT header"
    )
    require(revision == 0x00010000, f"{path}: unsupported GPT revision 0x{revision:08x}")
    require(header_size == 92, f"{path}: GPT header size is not the locked 92 bytes")
    require(
        header_sector[20:24] == bytes(4),
        f"{path}: GPT reserved header field is not zero",
    )
    crc_header = bytearray(header_sector[:header_size])
    struct.pack_into("<I", crc_header, 16, 0)
    actual_header_crc = zlib.crc32(crc_header) & 0xFFFFFFFF
    require(
        actual_header_crc == stored_header_crc,
        f"{path}: GPT header CRC mismatch "
        f"(stored 0x{stored_header_crc:08x}, actual 0x{actual_header_crc:08x})",
    )

    current_lba, alternate_lba, first_usable, last_usable = unpack_from(
        "<QQQQ", header_sector, 24, "GPT bounds"
    )
    entries_lba = unpack_from("<Q", header_sector, 72, "GPT entry location")[0]
    entry_count, entry_size, stored_array_crc = unpack_from(
        "<III", header_sector, 80, "GPT entry table description"
    )
    raw_sectors = raw.size // SECTOR_SIZE
    require(current_lba == 1, f"{path}: primary GPT is not at LBA 1")
    require(
        entries_lba == 2
        and entry_count == 128
        and entry_size == 128
        and first_usable == 34,
        f"{path}: GPT partition-entry geometry is not the locked 128-entry layout",
    )
    require(
        first_usable <= last_usable < alternate_lba < raw_sectors,
        f"{path}: GPT usable/alternate LBA bounds are invalid",
    )
    array_offset = entries_lba * SECTOR_SIZE
    array_size = entry_count * entry_size
    require(
        array_offset + array_size == first_usable * SECTOR_SIZE
        and array_offset + array_size <= len(data),
        f"{path}: GPT partition-entry array does not exactly fill the reserved area",
    )
    entries = data[array_offset : array_offset + array_size]
    actual_array_crc = zlib.crc32(entries) & 0xFFFFFFFF
    require(
        actual_array_crc == stored_array_crc,
        f"{path}: GPT partition-entry CRC mismatch "
        f"(stored 0x{stored_array_crc:08x}, actual 0x{actual_array_crc:08x})",
    )

    partitions: list[Partition] = []
    used_indexes: list[int] = []
    unique_ids: set[bytes] = set()
    for index in range(entry_count):
        entry = entries[index * entry_size : (index + 1) * entry_size]
        if entry[:16] == bytes(16):
            continue
        first_lba, last_lba = unpack_from("<QQ", entry, 32, "GPT partition entry")
        require(
            first_usable <= first_lba <= last_lba <= last_usable,
            f"{path}: GPT partition {index + 1} has invalid bounds",
        )
        unique_id = entry[16:32]
        require(unique_id != bytes(16), f"{path}: GPT partition {index + 1} has no GUID")
        require(unique_id not in unique_ids, f"{path}: duplicate GPT partition GUID")
        unique_ids.add(unique_id)
        attributes = unpack_from("<Q", entry, 48, "GPT partition attributes")[0]
        used_indexes.append(index)
        partitions.append(
            Partition(first_lba, last_lba, entry[:16], unique_id, attributes)
        )

    require(
        used_indexes == [0, 1, 127],
        f"{path}: GPT entries are not in the locked boot/root/reserved slots",
    )

    partitions.sort(key=lambda partition: partition.first_lba)
    for previous, current in zip(partitions, partitions[1:]):
        require(
            previous.last_lba < current.first_lba,
            f"{path}: GPT partitions overlap",
        )

    # OpenWrt reserves LBAs 34..511 using its deliberately non-standard
    # "Hah!IdontNeedEFI" type GUID.  GRUB may use that gap for embedded data;
    # it is not one of the two user-visible partitions.
    reserved = [partition for partition in partitions if partition.last_lba < 512]
    visible = [partition for partition in partitions if partition.first_lba >= 512]
    require(len(reserved) == 1, f"{path}: GPT bootloader-reserved partition is absent")
    require(
        reserved[0].first_lba == 34
        and reserved[0].last_lba == 511
        and reserved[0].type_id == GPT_GRUB_RESERVED
        and reserved[0].attributes == 0,
        f"{path}: GPT bootloader-reserved partition is invalid",
    )
    require(
        len(visible) == 2 and len(partitions) == len(reserved) + 2,
        f"{path}: GPT must contain boot and root partitions",
    )
    boot, root = visible
    require(
        boot.first_lba == 512
        and boot.sectors == 32 * MIB // SECTOR_SIZE
        and boot.type_id == GPT_LINUX_FILESYSTEM
        and boot.attributes == 4,
        f"{path}: EFI boot partition is not the locked 32 MiB layout",
    )
    expected_root_sectors = rootfs_mib * MIB // SECTOR_SIZE
    require(
        root.first_lba == boot.last_lba + 1
        and root.sectors == expected_root_sectors
        and root.type_id == GPT_LINUX_FILESYSTEM
        and root.attributes == 0,
        f"{path}: SquashFS partition is not the requested {rootfs_mib} MiB layout",
    )
    require(last_usable == root.last_lba, f"{path}: GPT last usable LBA does not match rootfs")
    require(
        protective_count == alternate_lba,
        f"{path}: protective MBR does not exactly cover the declared GPT disk",
    )

    # The locked OpenWrt/ImmortalWrt disk-image recipe emits only the primary
    # GPT because the final physical disk size is unknown at build time.  It
    # reserves the conventional 32-entry-sector + one-header-sector location
    # after rootfs and pads the rest of the image with zeroes.  Validate that
    # exact upstream layout instead of pretending a secondary GPT is present.
    require(
        alternate_lba == root.last_lba + 33,
        f"{path}: GPT alternate-header reservation has unexpected geometry",
    )
    trailing_offset = (root.last_lba + 1) * SECTOR_SIZE
    trailing = raw_slice(
        raw, trailing_offset, raw.size - trailing_offset, path, "post-root GPT reservation"
    )
    require(
        all(value == 0 for value in trailing),
        f"{path}: x86 post-root GPT reservation is not zero-filled",
    )
    return boot, root


def verify_mbr(raw: RawImage, rootfs_mib: int, media_limit: int, path: Path) -> tuple[Partition, Partition]:
    data = raw.prefix
    require(len(data) >= SECTOR_SIZE, f"{path}: truncated MBR image")
    require(data[510:512] == b"\x55\xaa", f"{path}: MBR signature is absent")

    active: list[tuple[int, int, int, int]] = []
    for index in range(4):
        entry = data[446 + index * 16 : 462 + index * 16]
        status, part_type = entry[0], entry[4]
        first, count = unpack_from("<II", entry, 8, "MBR partition entry")
        require(status in (0, 0x80), f"{path}: MBR partition {index + 1} has invalid status")
        if part_type:
            require(count > 0, f"{path}: MBR partition {index + 1} is empty")
            active.append((status, part_type, first, count))
        else:
            require(
                entry == bytes(16),
                f"{path}: unused MBR partition {index + 1} is not empty",
            )

    require(len(active) == 2, f"{path}: MBR must contain exactly boot and root partitions")
    boot_entry, root_entry = active
    require(
        boot_entry == (0x80, 0x0C, 8192, 131072),
        f"{path}: Raspberry Pi boot partition is not the locked 64 MiB layout",
    )
    expected_root_sectors = rootfs_mib * MIB // SECTOR_SIZE
    require(
        root_entry == (0, 0x83, 147456, expected_root_sectors),
        f"{path}: Raspberry Pi root partition is not the requested {rootfs_mib} MiB layout",
    )

    boot = Partition(
        boot_entry[2], boot_entry[2] + boot_entry[3] - 1, bytes([boot_entry[1]]), b""
    )
    root = Partition(
        root_entry[2], root_entry[2] + root_entry[3] - 1, bytes([root_entry[1]]), b""
    )
    declared_end = (root.last_lba + 1) * SECTOR_SIZE
    require(
        declared_end < media_limit,
        f"{path}: declared Raspberry Pi partitions do not fit the media limit",
    )
    require(
        raw.size <= declared_end,
        f"{path}: factory image extends beyond its declared root partition",
    )
    return boot, root


@dataclass(frozen=True)
class FatEntry:
    name: str
    attributes: int
    first_cluster: int
    size: int

    @property
    def is_directory(self) -> bool:
        return bool(self.attributes & 0x10)


class Fat16Volume:
    """Small read-only FAT16 parser used for boot-file validation."""

    def __init__(
        self,
        image: bytes,
        partition: Partition,
        image_name: Path,
        expected_label: bytes,
    ):
        self.image = image
        self.partition = partition
        self.image_name = image_name
        self.base = partition.first_lba * SECTOR_SIZE
        volume_size = partition.sectors * SECTOR_SIZE
        require(
            self.base + volume_size <= len(image),
            f"{image_name}: FAT16 partition is outside the validated image prefix",
        )
        boot = image[self.base : self.base + SECTOR_SIZE]
        require(boot[510:512] == b"\x55\xaa", f"{image_name}: FAT16 boot signature is absent")

        self.bytes_per_sector = unpack_from("<H", boot, 11, "FAT16 BPB")[0]
        self.sectors_per_cluster = boot[13]
        self.reserved_sectors = unpack_from("<H", boot, 14, "FAT16 BPB")[0]
        self.fat_count = boot[16]
        self.root_entries = unpack_from("<H", boot, 17, "FAT16 BPB")[0]
        total16 = unpack_from("<H", boot, 19, "FAT16 BPB")[0]
        self.fat_sectors = unpack_from("<H", boot, 22, "FAT16 BPB")[0]
        hidden_sectors = unpack_from("<I", boot, 28, "FAT16 BPB")[0]
        total32 = unpack_from("<I", boot, 32, "FAT16 BPB")[0]
        total_sectors = total16 or total32

        require(
            boot[:3] == b"\xeb\x3c\x90",
            f"{image_name}: FAT16 boot jump is not the locked mkfs.fat layout",
        )
        require(self.bytes_per_sector == SECTOR_SIZE, f"{image_name}: FAT sector size is not 512")
        require(
            self.sectors_per_cluster == 4,
            f"{image_name}: FAT cluster size is not the locked four sectors",
        )
        require(self.reserved_sectors == 4, f"{image_name}: FAT reserved area is not four sectors")
        require(self.fat_count == 2, f"{image_name}: FAT must contain two allocation tables")
        require(self.root_entries == 512, f"{image_name}: FAT16 root directory is not 512 entries")
        require(
            self.fat_sectors == partition.sectors // 1024,
            f"{image_name}: FAT allocation-table geometry is unexpected",
        )
        require(
            total16 == 0
            and total32 == partition.sectors
            and total_sectors == partition.sectors
            and hidden_sectors == 0,
            f"{image_name}: FAT/partition size fields do not match the locked layout",
        )
        require(boot[38] == 0x29, f"{image_name}: FAT extended boot signature is absent")
        require(boot[43:54] == expected_label, f"{image_name}: FAT volume label is unexpected")
        require(boot[54:62] == b"FAT16   ", f"{image_name}: boot partition is not FAT16")

        self.root_sectors = (
            self.root_entries * 32 + self.bytes_per_sector - 1
        ) // self.bytes_per_sector
        first_data_sector = (
            self.reserved_sectors + self.fat_count * self.fat_sectors + self.root_sectors
        )
        require(first_data_sector < total_sectors, f"{image_name}: FAT data area is absent")
        data_sectors = total_sectors - first_data_sector
        self.cluster_count = data_sectors // self.sectors_per_cluster
        require(
            4085 <= self.cluster_count < 65525,
            f"{image_name}: BPB does not describe a FAT16 volume",
        )
        self.max_cluster = self.cluster_count + 1
        self.cluster_bytes = self.sectors_per_cluster * self.bytes_per_sector

        fat_offset = self.base + self.reserved_sectors * self.bytes_per_sector
        fat_size = self.fat_sectors * self.bytes_per_sector
        self.fat = image[fat_offset : fat_offset + fat_size]
        require(
            len(self.fat) // 2 > self.max_cluster,
            f"{image_name}: FAT is too small for the declared data area",
        )
        for copy_index in range(1, self.fat_count):
            copy_offset = fat_offset + copy_index * fat_size
            require(
                image[copy_offset : copy_offset + fat_size] == self.fat,
                f"{image_name}: FAT allocation-table copies differ",
            )
        first_fat_entry, second_fat_entry = unpack_from("<HH", self.fat, 0, "FAT entries")
        require(
            (first_fat_entry & 0xFF00) == 0xFF00
            and (first_fat_entry & 0xFF) == boot[21]
            and second_fat_entry >= 0xFFF8,
            f"{image_name}: FAT reserved entries are invalid",
        )

        self.root_offset = fat_offset + self.fat_count * fat_size
        self.root_size = self.root_entries * 32
        self.data_offset = self.root_offset + self.root_sectors * self.bytes_per_sector

    @staticmethod
    def _lfn_checksum(short_name: bytes) -> int:
        checksum = 0
        for value in short_name:
            checksum = ((checksum & 1) << 7) + (checksum >> 1) + value
            checksum &= 0xFF
        return checksum

    def _lfn_fragment(self, entry: bytes, is_last: bool) -> bytes:
        raw = entry[1:11] + entry[14:26] + entry[28:32]
        units = [value for (value,) in struct.iter_unpack("<H", raw)]
        if 0 in units:
            terminator = units.index(0)
            require(
                is_last and all(value == 0xFFFF for value in units[terminator + 1 :]),
                f"{self.image_name}: malformed FAT long-name terminator",
            )
            units = units[:terminator]
        else:
            require(
                all(value != 0xFFFF for value in units),
                f"{self.image_name}: malformed FAT long-name padding",
            )
        return b"".join(struct.pack("<H", value) for value in units)

    @staticmethod
    def _short_name(entry: bytes) -> str:
        short = bytearray(entry[:11])
        if short[0] == 0x05:
            short[0] = 0xE5
        base = bytes(short[:8]).decode("cp437").rstrip(" ")
        extension = bytes(short[8:11]).decode("cp437").rstrip(" ")
        return f"{base}.{extension}" if extension else base

    def _parse_directory(self, data: bytes) -> list[FatEntry]:
        result: list[FatEntry] = []
        lfn_parts: dict[int, bytes] = {}
        lfn_checksum: int | None = None
        lfn_maximum = 0
        lfn_expected = 0
        for offset in range(0, len(data) - 31, 32):
            entry = data[offset : offset + 32]
            if entry[0] == 0:
                require(not lfn_parts, f"{self.image_name}: dangling FAT long-name entries")
                break
            if entry[0] == 0xE5:
                require(not lfn_parts, f"{self.image_name}: interrupted FAT long name")
                continue
            attributes = entry[11]
            if attributes & 0x0F == 0x0F:
                require(attributes == 0x0F, f"{self.image_name}: invalid FAT long-name attributes")
                order_byte = entry[0]
                order = order_byte & 0x1F
                is_last = bool(order_byte & 0x40)
                require(
                    not order_byte & 0x80
                    and not order_byte & 0x20
                    and 1 <= order <= 20
                    and entry[12] == 0
                    and entry[26:28] == bytes(2),
                    f"{self.image_name}: malformed FAT long-name entry",
                )
                if is_last:
                    require(not lfn_parts, f"{self.image_name}: overlapping FAT long names")
                    lfn_maximum = order
                    lfn_expected = order
                    lfn_checksum = entry[13]
                else:
                    require(lfn_parts, f"{self.image_name}: FAT long name has no final fragment")
                require(
                    order == lfn_expected
                    and entry[13] == lfn_checksum
                    and order not in lfn_parts,
                    f"{self.image_name}: FAT long-name sequence is out of order",
                )
                lfn_parts[order] = self._lfn_fragment(entry, is_last)
                lfn_expected -= 1
                continue

            short_name = self._short_name(entry)
            expected_orders = set(range(1, lfn_maximum + 1))
            if lfn_maximum:
                require(
                    lfn_expected == 0
                    and set(lfn_parts) == expected_orders
                    and lfn_checksum == self._lfn_checksum(entry[:11]),
                    f"{self.image_name}: FAT long name does not match its short entry",
                )
                encoded_name = b"".join(
                    lfn_parts[index] for index in range(1, lfn_maximum + 1)
                )
                try:
                    name = encoded_name.decode("utf-16le")
                except UnicodeDecodeError as exc:
                    raise VerificationError(
                        f"{self.image_name}: FAT long name is not valid UTF-16"
                    ) from exc
                require(
                    name
                    and all(ord(character) >= 0x20 for character in name)
                    and not set(name) & set('"*/:<>?\\|'),
                    f"{self.image_name}: FAT long name contains an invalid character",
                )
            else:
                name = short_name
            lfn_parts.clear()
            lfn_checksum = None
            lfn_maximum = 0
            lfn_expected = 0

            require(not attributes & 0xC0, f"{self.image_name}: FAT entry has reserved attributes")
            if attributes & 0x08:
                continue
            high_cluster = unpack_from("<H", entry, 20, "FAT directory entry")[0]
            low_cluster = unpack_from("<H", entry, 26, "FAT directory entry")[0]
            size = unpack_from("<I", entry, 28, "FAT directory entry")[0]
            result.append(FatEntry(name, attributes, high_cluster << 16 | low_cluster, size))
        require(not lfn_parts, f"{self.image_name}: dangling FAT long-name entries")
        return result

    def _cluster_chain(self, first_cluster: int) -> list[int]:
        require(
            2 <= first_cluster <= self.max_cluster,
            f"{self.image_name}: FAT cluster {first_cluster} is outside the data area",
        )
        chain: list[int] = []
        seen: set[int] = set()
        cluster = first_cluster
        while True:
            require(cluster not in seen, f"{self.image_name}: loop in FAT cluster chain")
            require(
                2 <= cluster <= self.max_cluster,
                f"{self.image_name}: FAT cluster chain leaves the data area",
            )
            seen.add(cluster)
            chain.append(cluster)
            next_cluster = unpack_from("<H", self.fat, cluster * 2, "FAT cluster entry")[0]
            if next_cluster >= 0xFFF8:
                break
            require(
                2 <= next_cluster <= self.max_cluster and next_cluster != 0xFFF7,
                f"{self.image_name}: invalid FAT cluster-chain value 0x{next_cluster:04x}",
            )
            cluster = next_cluster
            require(
                len(chain) <= self.cluster_count,
                f"{self.image_name}: FAT cluster chain is unbounded",
            )
        return chain

    def _cluster_data(self, cluster: int) -> bytes:
        offset = self.data_offset + (cluster - 2) * self.cluster_bytes
        data = self.image[offset : offset + self.cluster_bytes]
        require(
            len(data) == self.cluster_bytes,
            f"{self.image_name}: FAT cluster is outside the validated boot partition",
        )
        return data

    def _directory_entries(self, directory: FatEntry | None) -> list[FatEntry]:
        if directory is None:
            entries = self._parse_directory(
                self.image[self.root_offset : self.root_offset + self.root_size]
            )
        else:
            require(directory.is_directory, f"{self.image_name}: {directory.name} is not a directory")
            data = b"".join(
                self._cluster_data(cluster)
                for cluster in self._cluster_chain(directory.first_cluster)
            )
            entries = self._parse_directory(data)
        names = [entry.name.casefold() for entry in entries]
        require(
            len(names) == len(set(names)),
            f"{self.image_name}: FAT directory contains ambiguous names",
        )
        return entries

    def audit_tree(self) -> None:
        """Validate every reachable allocation and reject aliases or orphans."""
        owners: dict[int, str] = {}

        def claim(chain: list[int], owner: str) -> None:
            for cluster in chain:
                require(
                    cluster not in owners,
                    f"{self.image_name}: FAT cluster {cluster} is shared by "
                    f"{owners.get(cluster)!r} and {owner!r}",
                )
                owners[cluster] = owner

        def walk(directory: FatEntry | None, parent: str) -> None:
            for entry in self._directory_entries(directory):
                if entry.name in (".", ".."):
                    continue
                child = f"{parent}/{entry.name}" if parent else entry.name
                if entry.is_directory:
                    require(entry.size == 0, f"{self.image_name}: FAT directory has a file size: {child}")
                    chain = self._cluster_chain(entry.first_cluster)
                    claim(chain, child + "/")
                    walk(entry, child)
                elif entry.size == 0:
                    require(
                        entry.first_cluster == 0,
                        f"{self.image_name}: empty FAT file owns a cluster: {child}",
                    )
                else:
                    chain = self._cluster_chain(entry.first_cluster)
                    expected = (entry.size + self.cluster_bytes - 1) // self.cluster_bytes
                    require(
                        len(chain) == expected,
                        f"{self.image_name}: FAT chain length disagrees with file size: {child}",
                    )
                    claim(chain, child)

        walk(None, "")
        for cluster in range(2, self.max_cluster + 1):
            value = unpack_from("<H", self.fat, cluster * 2, "FAT cluster entry")[0]
            require(
                value == 0 or cluster in owners,
                f"{self.image_name}: allocated FAT cluster {cluster} is unreachable",
            )

    def resolve(self, path: str) -> FatEntry:
        components = [component for component in path.replace("\\", "/").split("/") if component]
        require(components, f"{self.image_name}: empty FAT path")
        directory: FatEntry | None = None
        for index, component in enumerate(components):
            matches = [
                entry
                for entry in self._directory_entries(directory)
                if entry.name.casefold() == component.casefold()
            ]
            require(matches, f"{self.image_name}: required FAT path is absent: {path}")
            require(len(matches) == 1, f"{self.image_name}: ambiguous FAT path: {path}")
            entry = matches[0]
            if index != len(components) - 1:
                require(entry.is_directory, f"{self.image_name}: FAT path component is not a directory: {path}")
                directory = entry
        return entry

    def verify_file(self, path: str) -> FatEntry:
        entry = self.resolve(path)
        require(not entry.is_directory, f"{self.image_name}: required FAT file is a directory: {path}")
        require(entry.size > 0, f"{self.image_name}: required FAT file is empty: {path}")
        chain = self._cluster_chain(entry.first_cluster)
        expected_clusters = (entry.size + self.cluster_bytes - 1) // self.cluster_bytes
        require(
            len(chain) == expected_clusters,
            f"{self.image_name}: FAT chain length disagrees with file size: {path}",
        )
        return entry

    def read_file(self, path: str) -> bytes:
        entry = self.verify_file(path)
        return b"".join(
            self._cluster_data(cluster)
            for cluster in self._cluster_chain(entry.first_cluster)
        )[: entry.size]

    def verify_directory(self, path: str) -> list[FatEntry]:
        entry = self.resolve(path)
        require(entry.is_directory, f"{self.image_name}: required FAT directory is a file: {path}")
        return self._directory_entries(entry)


def verify_squashfs(raw: RawImage, root: Partition, path: Path) -> None:
    offset = root.first_lba * SECTOR_SIZE
    require(
        offset + SQUASHFS_SUPERBLOCK_SIZE <= len(raw.prefix),
        f"{path}: SquashFS superblock is outside the validated image prefix",
    )
    superblock = raw.prefix[offset : offset + SQUASHFS_SUPERBLOCK_SIZE]
    require(superblock[:4] == b"hsqs", f"{path}: root partition does not start with SquashFS")
    inodes, block_size = unpack_from("<II", superblock, 4, "SquashFS superblock")[0], unpack_from(
        "<I", superblock, 12, "SquashFS superblock"
    )[0]
    compression, block_log = unpack_from("<HH", superblock, 20, "SquashFS compression")
    major, minor = unpack_from("<HH", superblock, 28, "SquashFS version")
    bytes_used = unpack_from("<Q", superblock, 40, "SquashFS size")[0]
    require(inodes > 0, f"{path}: SquashFS contains no inodes")
    require(
        block_size == 256 * 1024 and block_log == 18,
        f"{path}: SquashFS does not use the locked 256 KiB block size",
    )
    require(compression == 4, f"{path}: SquashFS compression is not XZ")
    require((major, minor) == (4, 0), f"{path}: unsupported SquashFS version {major}.{minor}")
    partition_bytes = root.sectors * SECTOR_SIZE
    require(
        SQUASHFS_SUPERBLOCK_SIZE <= bytes_used <= partition_bytes,
        f"{path}: SquashFS size exceeds its root partition",
    )
    require(
        offset + bytes_used <= raw.size,
        f"{path}: image is truncated inside the SquashFS filesystem",
    )


def verify_pe_image(data: bytes, path: Path, description: str) -> None:
    require(len(data) >= 0x40 and data[:2] == b"MZ", f"{path}: {description} has no DOS/PE header")
    pe_offset = unpack_from("<I", data, 0x3C, f"{description} PE offset")[0]
    require(
        pe_offset % 4 == 0
        and pe_offset + 6 <= len(data)
        and data[pe_offset : pe_offset + 4] == b"PE\0\0"
        and unpack_from("<H", data, pe_offset + 4, f"{description} PE machine")[0] == 0x8664,
        f"{path}: {description} is not an x86-64 PE image",
    )


def decode_boot_text(data: bytes, path: Path, name: str) -> str:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise VerificationError(f"{path}: {name} is not UTF-8 text") from exc
    require("\0" not in text and "\r" not in text, f"{path}: {name} contains invalid text bytes")
    require(text.endswith("\n"), f"{path}: {name} has no final newline")
    return text


def verify_fdt(data: bytes, path: Path, name: str) -> None:
    require(len(data) >= 40, f"{path}: {name} is too small for a flattened device tree")
    (
        magic,
        total_size,
        structure_offset,
        strings_offset,
        reserve_offset,
        version,
        last_compatible,
        _boot_cpu,
        strings_size,
        structure_size,
    ) = unpack_from(">10I", data, 0, f"{name} device-tree header")
    require(magic == 0xD00DFEED, f"{path}: {name} has no flattened-device-tree magic")
    require(total_size == len(data), f"{path}: {name} device-tree size is inconsistent")
    require(
        version == 17
        and last_compatible <= version
        and reserve_offset % 8 == 0
        and 40 <= reserve_offset < total_size
        and structure_offset % 4 == 0
        and structure_offset + structure_size <= total_size
        and strings_offset + strings_size <= total_size,
        f"{path}: {name} device-tree header has invalid bounds",
    )
    require(
        data[structure_offset : structure_offset + 4] == b"\0\0\0\1",
        f"{path}: {name} device-tree structure block is absent",
    )


def verify_x86(path: Path, rootfs_mib: int, media_limit: int) -> None:
    raw = read_gzip_image(path, media_limit)
    boot, root = verify_gpt(raw, rootfs_mib, path)
    fat = Fat16Volume(raw.prefix, boot, path, b"kernel     ")
    fat.audit_tree()
    for required_path in (
        "EFI/BOOT/BOOTX64.EFI",
        "boot/grub/grub.cfg",
        "boot/vmlinuz",
    ):
        fat.verify_file(required_path)
    verify_pe_image(fat.read_file("EFI/BOOT/BOOTX64.EFI"), path, "BOOTX64.EFI")
    kernel = fat.read_file("boot/vmlinuz")
    verify_pe_image(kernel, path, "vmlinuz")
    require(kernel[0x202:0x206] == b"HdrS", f"{path}: vmlinuz has no Linux setup header")
    grub = decode_boot_text(fat.read_file("boot/grub/grub.cfg"), path, "grub.cfg")
    root_guid = str(uuid.UUID(bytes_le=root.unique_id))
    require(
        f"root=PARTUUID={root_guid}" in grub
        and "search -l kernel -s root" in grub
        and "linux /boot/vmlinuz" in grub,
        f"{path}: GRUB configuration does not identify the verified kernel/root partition",
    )
    verify_squashfs(raw, root, path)


PI_BOOT_FILES = {
    "rpi4": (
        "config.txt",
        "distroconfig.txt",
        "cmdline.txt",
        "partuuid.txt",
        "kernel8.img",
        "bcm2711-rpi-4-b.dtb",
        "bcm2711-rpi-400.dtb",
        "bcm2711-rpi-cm4.dtb",
        "start4.elf",
        "fixup4.dat",
    ),
    "rpi5": (
        "config.txt",
        "distroconfig.txt",
        "cmdline.txt",
        "partuuid.txt",
        "kernel_2712.img",
        "bcm2712-rpi-5-b.dtb",
        "bcm2712d0-rpi-5-b.dtb",
        "bcm2712-rpi-cm5-cm5io.dtb",
    ),
}

PI_METADATA = {
    "rpi4": (
        "bcm27xx/bcm2711",
        "rpi-4",
        {
            "raspberrypi,400",
            "raspberrypi,4-compute-module",
            "raspberrypi,4-model-b",
        },
    ),
    "rpi5": (
        "bcm27xx/bcm2712",
        "rpi-5",
        {
            "raspberrypi,500",
            "raspberrypi,5-compute-module",
            "raspberrypi,5-model-b",
        },
    ),
}


def crc32_fwtool_prefix(path: Path, length: int) -> int:
    crc = 0
    remaining = length
    try:
        with path.open("rb") as stream:
            while remaining:
                chunk = stream.read(min(8 * MIB, remaining))
                require(chunk, f"{path}: truncated while calculating fwtool CRC")
                crc = zlib.crc32(chunk, crc)
                remaining -= len(chunk)
    except OSError as exc:
        raise VerificationError(f"{path}: cannot calculate fwtool CRC: {exc}") from exc
    # fwtool stores the internal reflected CRC-32 state, before the usual
    # final XOR used by zlib.crc32().
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF


def compare_factory_prefix(factory: Path, sysupgrade: Path, length: int) -> None:
    remaining = length
    try:
        with factory.open("rb") as factory_stream, sysupgrade.open("rb") as sysupgrade_stream:
            while remaining:
                amount = min(8 * MIB, remaining)
                factory_chunk = factory_stream.read(amount)
                sysupgrade_chunk = sysupgrade_stream.read(amount)
                require(
                    factory_chunk == sysupgrade_chunk and len(factory_chunk) == amount,
                    f"{sysupgrade}: gzip payload is not byte-equivalent to {factory}",
                )
                remaining -= amount
    except OSError as exc:
        raise VerificationError(f"cannot compare Pi factory/sysupgrade images: {exc}") from exc


def verify_fwtool(
    factory: Path,
    sysupgrade: Path,
    target: str,
    expected_version: str,
    expected_revision: str,
) -> None:
    try:
        factory_size = factory.stat().st_size
        sysupgrade_size = sysupgrade.stat().st_size
        require(
            sysupgrade_size >= factory_size + FWTOOL_TRAILER_SIZE + 8,
            f"{sysupgrade}: fwtool metadata is absent",
        )
        with sysupgrade.open("rb") as stream:
            stream.seek(-FWTOOL_TRAILER_SIZE, 2)
            trailer = stream.read(FWTOOL_TRAILER_SIZE)
    except OSError as exc:
        raise VerificationError(f"{sysupgrade}: cannot read fwtool trailer: {exc}") from exc

    magic, stored_crc, chunk_type, reserved, chunk_size = unpack_from(
        ">4sIB3sI", trailer, 0, "fwtool trailer"
    )
    require(magic == b"FWx0", f"{sysupgrade}: fwtool trailer magic is absent")
    require(chunk_type == 1, f"{sysupgrade}: final fwtool chunk is not image metadata")
    require(reserved == bytes(3), f"{sysupgrade}: fwtool trailer reserved bytes are not zero")
    require(
        chunk_size == sysupgrade_size - factory_size,
        f"{sysupgrade}: fwtool chunk does not begin at the end of the factory gzip payload",
    )
    require(
        chunk_size >= FWTOOL_TRAILER_SIZE + 8,
        f"{sysupgrade}: fwtool metadata chunk is too small",
    )
    require(
        chunk_size - FWTOOL_TRAILER_SIZE <= FWTOOL_METADATA_MAX_SIZE,
        f"{sysupgrade}: fwtool metadata exceeds the 30 KiB format limit",
    )

    compare_factory_prefix(factory, sysupgrade, factory_size)
    actual_crc = crc32_fwtool_prefix(sysupgrade, sysupgrade_size - FWTOOL_TRAILER_SIZE)
    require(
        actual_crc == stored_crc,
        f"{sysupgrade}: fwtool CRC mismatch "
        f"(stored 0x{stored_crc:08x}, actual 0x{actual_crc:08x})",
    )

    metadata_size = chunk_size - FWTOOL_TRAILER_SIZE
    try:
        with sysupgrade.open("rb") as stream:
            stream.seek(factory_size)
            metadata_chunk = stream.read(metadata_size)
    except OSError as exc:
        raise VerificationError(f"{sysupgrade}: cannot read fwtool metadata: {exc}") from exc
    require(len(metadata_chunk) == metadata_size, f"{sysupgrade}: truncated fwtool metadata")
    header_version, header_flags = unpack_from(">II", metadata_chunk, 0, "fwtool header")
    require(
        header_version == 0 and header_flags == 0,
        f"{sysupgrade}: unsupported fwtool metadata header",
    )
    def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key {key!r}")
            result[key] = value
        return result

    def reject_json_constant(value: str) -> object:
        raise ValueError(f"non-finite JSON number {value!r}")

    try:
        metadata = json.loads(
            metadata_chunk[8:].decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise VerificationError(f"{sysupgrade}: invalid fwtool metadata JSON: {exc}") from exc
    require(isinstance(metadata, dict), f"{sysupgrade}: fwtool metadata is not a JSON object")

    expected_target, expected_board, expected_devices = PI_METADATA[target]
    version = metadata.get("version")
    require(isinstance(version, dict), f"{sysupgrade}: fwtool version identity is absent")
    require(
        version.get("target") == expected_target
        and version.get("board") == expected_board
        and version.get("dist") == "ImmortalWrt"
        and version.get("version") == expected_version
        and version.get("revision") == expected_revision,
        f"{sysupgrade}: fwtool version identity does not match the {target} profile",
    )
    supported = metadata.get("supported_devices")
    require(
        isinstance(supported, list)
        and all(isinstance(item, str) and item for item in supported)
        and len(supported) == len(set(supported)),
        f"{sysupgrade}: fwtool supported_devices is absent, duplicated, or invalid",
    )
    require(
        expected_devices.issubset(set(supported)),
        f"{sysupgrade}: fwtool supported_devices does not cover the {target} profile",
    )
    require(
        metadata.get("metadata_version") == "1.1"
        and metadata.get("compat_version") == "1.0",
        f"{sysupgrade}: unsupported fwtool metadata compatibility version",
    )


def select_pi_images(paths: Iterable[Path]) -> tuple[Path, Path]:
    path_list = list(paths)
    factory = [path for path in path_list if "-factory.img.gz" in path.name]
    sysupgrade = [path for path in path_list if "-sysupgrade.img.gz" in path.name]
    require(
        len(path_list) == 2 and len(factory) == 1 and len(sysupgrade) == 1,
        "Raspberry Pi validation requires exactly one factory.img.gz and one sysupgrade.img.gz",
    )
    return factory[0], sysupgrade[0]


def verify_pi(
    target: str,
    paths: Iterable[Path],
    rootfs_mib: int,
    media_limit: int,
    expected_version: str,
    expected_revision: str,
) -> tuple[Path, Path]:
    factory, sysupgrade = select_pi_images(paths)
    raw = read_gzip_image(factory, media_limit)
    boot, root = verify_mbr(raw, rootfs_mib, media_limit, factory)
    fat = Fat16Volume(raw.prefix, boot, factory, b"boot       ")
    fat.audit_tree()
    for required_path in PI_BOOT_FILES[target]:
        fat.verify_file(required_path)
    overlay_entries = fat.verify_directory("overlays")
    require(
        any(
            not entry.is_directory
            and entry.size > 0
            and entry.name.casefold().endswith(".dtbo")
            for entry in overlay_entries
        ),
        f"{factory}: overlays directory contains no device-tree overlay",
    )

    config = decode_boot_text(fat.read_file("config.txt"), factory, "config.txt")
    distro = decode_boot_text(
        fat.read_file("distroconfig.txt"), factory, "distroconfig.txt"
    )
    cmdline = decode_boot_text(fat.read_file("cmdline.txt"), factory, "cmdline.txt")
    partuuid = decode_boot_text(
        fat.read_file("partuuid.txt"), factory, "partuuid.txt"
    ).removesuffix("\n")
    disk_id = unpack_from("<I", raw.prefix, 440, "MBR disk identifier")[0]
    expected_partuuid = f"{disk_id:08x}"
    require(disk_id != 0 and raw.prefix[444:446] == bytes(2), f"{factory}: invalid MBR disk identifier")
    require(
        partuuid == expected_partuuid
        and re.fullmatch(r"[0-9a-f]{8}", partuuid) is not None
        and cmdline.count(f"root=PARTUUID={partuuid}-02") == 1
        and "rootfstype=squashfs,ext4" in cmdline,
        f"{factory}: Pi boot text does not identify the verified root partition",
    )
    require(
        "\ninclude distroconfig.txt\n" in config
        and "\ndtoverlay=disable-bt\n" in distro
        and "\narm_boost=1\n" in distro,
        f"{factory}: Pi firmware configuration is incomplete",
    )

    kernel_name = "kernel8.img" if target == "rpi4" else "kernel_2712.img"
    kernel = fat.read_file(kernel_name)
    require(
        len(kernel) >= 64 and kernel[0x38:0x3C] == b"ARMd",
        f"{factory}: {kernel_name} has no arm64 Image header",
    )
    root_entries = fat._directory_entries(None)
    dtb_names = [entry.name for entry in root_entries if entry.name.casefold().endswith(".dtb")]
    require(dtb_names, f"{factory}: boot partition contains no device trees")
    for name in dtb_names:
        verify_fdt(fat.read_file(name), factory, name)
    dtbo_names = [
        entry.name for entry in overlay_entries if entry.name.casefold().endswith(".dtbo")
    ]
    for name in dtbo_names:
        verify_fdt(fat.read_file(f"overlays/{name}"), factory, f"overlays/{name}")
    if target == "rpi4":
        require(
            fat.read_file("start4.elf")[:4] == b"\x7fELF",
            f"{factory}: start4.elf is not an ELF firmware image",
        )
    verify_squashfs(raw, root, factory)
    verify_fwtool(
        factory, sysupgrade, target, expected_version, expected_revision
    )
    return factory, sysupgrade


def positive_int(value: str) -> int:
    try:
        number = int(value, 10)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"not an integer: {value!r}") from exc
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="verify boot-critical structure of hmxf-OpenWRT .img.gz artifacts"
    )
    parser.add_argument("target", choices=("x86_64", "rpi4", "rpi5"))
    parser.add_argument(
        "--expected-version",
        required=True,
        help="exact ImmortalWrt version expected in image metadata",
    )
    parser.add_argument(
        "--expected-revision",
        required=True,
        help="exact ImmortalWrt rNNNN-hash revision expected in image metadata",
    )
    parser.add_argument("rootfs_mib", type=positive_int, help="declared rootfs partition size in MiB")
    parser.add_argument("media_limit", type=positive_int, help="exclusive raw media-size limit in bytes")
    parser.add_argument(
        "images",
        nargs="+",
        type=Path,
        help="x86 image, or Raspberry Pi factory and sysupgrade images",
    )
    arguments = parser.parse_args(argv)
    if not (
        arguments.expected_version == "SNAPSHOT"
        or re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", arguments.expected_version)
    ):
        parser.error("--expected-version must be SNAPSHOT or X.Y.Z")
    if re.fullmatch(r"r[0-9]+-[0-9a-f]{7,40}", arguments.expected_revision) is None:
        parser.error("--expected-revision must be rNNNN-lowercase-hex")
    for image in arguments.images:
        if not image.is_file() or image.is_symlink():
            parser.error(f"image is not a regular file: {image}")
    return arguments


def main(argv: list[str] | None = None) -> int:
    arguments = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if arguments.target == "x86_64":
            require(len(arguments.images) == 1, "x86_64 validation requires exactly one image")
            verify_x86(
                arguments.images[0], arguments.rootfs_mib, arguments.media_limit
            )
            print(f"Verified x86_64 GPT/FAT16/SquashFS image: {arguments.images[0]}")
        else:
            factory, sysupgrade = verify_pi(
                arguments.target,
                arguments.images,
                arguments.rootfs_mib,
                arguments.media_limit,
                arguments.expected_version,
                arguments.expected_revision,
            )
            print(
                f"Verified {arguments.target} MBR/FAT16/SquashFS images: "
                f"{factory} and {sysupgrade}"
            )
    except VerificationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
