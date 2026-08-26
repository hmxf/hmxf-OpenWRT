#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

BUILD_CHANNEL=${BUILD_CHANNEL:-stable}
load_build_config
load_release_lock
load_target_lock "${1:-}"
load_preset "${2:-}"
if [[ "$PACKAGE_REPOSITORY_MODE" == snapshot ]]; then
    load_package_snapshot_lock
fi
output_dir=${3:-"$PROJECT_ROOT/out/$IMMORTALWRT_VERSION/$TARGET_NAME/$PRESET_NAME"}
[[ -d "$output_dir" ]] || die "missing artifact directory: $output_dir"
require_command cmp
require_command dd
require_command gzip
require_command mktemp
require_command python3
require_command sha256sum
require_command unsquashfs

shopt -s nullglob
case "$TARGET_NAME" in
    x86_64)
        images=("$output_dir"/*-squashfs-combined-efi.img.gz)
        ;;
    rpi4)
        factory_images=("$output_dir"/*-rpi-4*-squashfs-factory.img.gz)
        sysupgrade_images=("$output_dir"/*-rpi-4*-squashfs-sysupgrade.img.gz)
        [[ ${#factory_images[@]} -eq 1 && ${#sysupgrade_images[@]} -eq 1 ]] || \
            die "expected exactly one Raspberry Pi 4 factory and one sysupgrade image"
        images=("${factory_images[@]}" "${sysupgrade_images[@]}")
        ;;
    rpi5)
        factory_images=("$output_dir"/*-rpi-5*-squashfs-factory.img.gz)
        sysupgrade_images=("$output_dir"/*-rpi-5*-squashfs-sysupgrade.img.gz)
        [[ ${#factory_images[@]} -eq 1 && ${#sysupgrade_images[@]} -eq 1 ]] || \
            die "expected exactly one Raspberry Pi 5 factory and one sysupgrade image"
        images=("${factory_images[@]}" "${sysupgrade_images[@]}")
        ;;
esac

expected=1
[[ "$TARGET_NAME" == x86_64 ]] || expected=2
[[ ${#images[@]} -eq $expected ]] || die "wrong number of SquashFS images in $output_dir"
for image in "${images[@]}"; do
    [[ -f "$image" && ! -L "$image" ]] || die "image is not a regular file: $image"
done

build_info="$output_dir/BUILD_INFO.txt"
[[ -f "$build_info" && ! -L "$build_info" && -s "$build_info" ]] || \
    die "missing or unsafe BUILD_INFO.txt"
build_mode=$(sed -n 's/^build_mode=//p' "$build_info")
release_channel=$(sed -n 's/^release_channel=//p' "$build_info")
canonical_build=$(sed -n 's/^canonical_build=//p' "$build_info")
candidate_build=$(sed -n 's/^candidate_build=//p' "$build_info")
development_build=$(sed -n 's/^development_build=//p' "$build_info")
extra_packages_line=$(sed -n 's/^extra_packages=//p' "$build_info")
[[ "$build_mode" == imagebuilder || "$build_mode" == source ]] || die "unknown BUILD_INFO build mode"
[[ "$release_channel" == "$BUILD_CHANNEL" ]] || \
    die 'BUILD_INFO release channel mismatch'
[[ "$canonical_build" == 0 || "$canonical_build" == 1 ]] || die "invalid BUILD_INFO canonical flag"
[[ "$candidate_build" == 0 || "$candidate_build" == 1 ]] || die "invalid BUILD_INFO candidate flag"
[[ "$development_build" == 0 || "$development_build" == 1 ]] || \
    die "invalid BUILD_INFO development flag"
(( canonical_build + candidate_build + development_build == 1 )) || \
    die 'an artifact must have exactly one canonical/candidate/development identity'
if [[ "$BUILD_CHANNEL" == nightly ]]; then
    [[ "$build_mode" == imagebuilder && "$canonical_build" == 0 && \
       "$candidate_build" == 1 && "$development_build" == 0 ]] || \
        die 'nightly ImageBuilder output must retain candidate identity'
    [[ ${NIGHTLY_FINGERPRINT:-} =~ ^[0-9a-f]{64}$ ]] || \
        die 'nightly verification requires NIGHTLY_FINGERPRINT'
    grep -Fqx "nightly_fingerprint=$NIGHTLY_FINGERPRINT" "$build_info" || \
        die 'BUILD_INFO nightly fingerprint mismatch'
    [[ ${NIGHTLY_CONTEXT_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || \
        die 'nightly verification requires NIGHTLY_CONTEXT_SHA256'
    grep -Fqx "nightly_context_sha256=$NIGHTLY_CONTEXT_SHA256" "$build_info" || \
        die 'BUILD_INFO nightly context identity mismatch'
elif grep -q '^nightly_fingerprint=' "$build_info"; then
    die 'stable BUILD_INFO must not contain a nightly fingerprint'
fi
if [[ "$build_mode" == source && "$canonical_build" != 0 ]]; then
    die "a source build cannot claim canonical ImageBuilder identity"
fi
if [[ "$build_mode" == source && \
      ( "$candidate_build" != 0 || "$development_build" != 1 ) ]]; then
    die 'a source build must have development identity'
fi
if [[ "$build_mode" == imagebuilder && \
      "$ARTIFACT_LOCK_POLICY" == enforce && -z "$extra_packages_line" ]]; then
    load_package_manifest_lock
    load_artifact_locks
elif (( candidate_build == 1 )); then
    [[ "$ARTIFACT_LOCK_POLICY" == record ]] || \
        die 'candidate verification requires record lock policy'
fi
grep -Fqx "release=$IMMORTALWRT_VERSION" "$build_info" || die "BUILD_INFO release mismatch"
grep -Fqx "source_commit=$IMMORTALWRT_COMMIT" "$build_info" || die "BUILD_INFO source mismatch"
grep -Fqx "version_code=$IMMORTALWRT_VERSION_CODE" "$build_info" || die "BUILD_INFO version code mismatch"
grep -Fqx "source_date_epoch=$IMMORTALWRT_SOURCE_DATE_EPOCH" "$build_info" || \
    die "BUILD_INFO source date epoch mismatch"
grep -Fqx "target=$TARGET/$SUBTARGET" "$build_info" || die "BUILD_INFO target mismatch"
grep -Fqx "profile=$PROFILE" "$build_info" || die "BUILD_INFO profile mismatch"
grep -Fqx "preset=$PRESET_NAME" "$build_info" || die "BUILD_INFO preset mismatch"
grep -Fqx "package_arch=$PACKAGE_ARCH" "$build_info" || die "BUILD_INFO package arch mismatch"
grep -Fqx "kernel_version=$IMMORTALWRT_KERNEL_VERSION" "$build_info" || \
    die "BUILD_INFO kernel version mismatch"
grep -Fqx "kernel_release=$IMMORTALWRT_KERNEL_RELEASE" "$build_info" || \
    die "BUILD_INFO kernel release mismatch"
if [[ "$build_mode" == imagebuilder ]]; then
    expected_kernel_vermagic=$KERNEL_VERMAGIC
    grep -Fqx "kernel_vermagic=$expected_kernel_vermagic" "$build_info" || \
        die "BUILD_INFO ImageBuilder kernel vermagic mismatch"
else
    expected_kernel_vermagic=$(sed -n 's/^kernel_vermagic=//p' "$build_info")
    [[ "$expected_kernel_vermagic" =~ ^[0-9a-f]{32}$ ]] || \
        die 'source BUILD_INFO has invalid kernel vermagic'
    grep -Fqx "official_imagebuilder_kernel_vermagic=$KERNEL_VERMAGIC" "$build_info" || \
        die 'source BUILD_INFO does not record the official ABI boundary'
fi
grep -Fqx "rootfs_partsize_mb=$ROOTFS_PARTSIZE" "$build_info" || die "BUILD_INFO rootfs mismatch"
grep -Fqx "nominal_media_bytes=$NOMINAL_MEDIA_BYTES" "$build_info" || die "BUILD_INFO media limit mismatch"

if [[ "$build_mode" == imagebuilder ]]; then
    grep -Fqx "imagebuilder_file=$IMAGEBUILDER_FILE" "$build_info" || \
        die "BUILD_INFO ImageBuilder filename mismatch"
    grep -Fqx "imagebuilder_sha256=$IMAGEBUILDER_SHA256" "$build_info" || \
        die "BUILD_INFO ImageBuilder digest mismatch"
    grep -Fqx "imagebuilder_bytes=$IMAGEBUILDER_BYTES" "$build_info" || \
        die "BUILD_INFO ImageBuilder byte-size mismatch"
    if [[ "$PACKAGE_REPOSITORY_MODE" == snapshot ]]; then
        if [[ "$BUILD_CHANNEL" == nightly ]]; then
            [[ ${NIGHTLY_PACKAGE_SNAPSHOTS_SHA256:-} =~ ^[0-9a-f]{64}$ && \
               ${NIGHTLY_PACKAGE_SNAPSHOT_LOCK_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || \
                die 'nightly verification requires a package-snapshot lock identity'
            grep -Fqx \
                "nightly_package_snapshots_sha256=$NIGHTLY_PACKAGE_SNAPSHOTS_SHA256" \
                "$build_info" || \
                die 'BUILD_INFO nightly package-snapshot identity mismatch'
            grep -Fqx \
                "nightly_package_snapshot_lock_sha256=$NIGHTLY_PACKAGE_SNAPSHOT_LOCK_SHA256" \
                "$build_info" || \
                die 'BUILD_INFO nightly package-snapshot lock mismatch'
            [[ $(sha256sum "$PACKAGE_SNAPSHOT_LOCK" | awk '{ print $1 }') == \
               "$NIGHTLY_PACKAGE_SNAPSHOT_LOCK_SHA256" && \
               $("$INPUT_SCRIPTS_DIR/nightly-build-identity.sh" content \
                   "$PACKAGE_SNAPSHOT_LOCK") == \
               "$NIGHTLY_PACKAGE_SNAPSHOTS_SHA256" ]] || \
                die 'nightly package-snapshot lock digest changed'
        fi
        for snapshot_identity in \
            "package_snapshot_file=$PACKAGE_SNAPSHOT_FILE" \
            "package_snapshot_sha256=$PACKAGE_SNAPSHOT_SHA256" \
            "package_snapshot_bytes=$PACKAGE_SNAPSHOT_BYTES" \
            "package_snapshot_tree_sha256=$PACKAGE_SNAPSHOT_TREE_SHA256"; do
            grep -Fqx "$snapshot_identity" "$build_info" || \
                die "BUILD_INFO package snapshot identity mismatch: $snapshot_identity"
        done
    fi
    if [[ "$ARTIFACT_LOCK_POLICY" == enforce ]]; then
        grep -Fqx "package_count=$EXPECTED_PACKAGE_COUNT" "$build_info" || \
            die "BUILD_INFO package count mismatch"
        grep -Fqx "package_manifest_sha256=$EXPECTED_MANIFEST_SHA256" "$build_info" || \
            die "BUILD_INFO package manifest digest mismatch"
    fi
    for image in "${images[@]}"; do
        [[ $(basename -- "$image") == *"-$PRESET_NAME-"* ]] || \
            die "ImageBuilder filename does not identify preset $PRESET_NAME: $image"
    done
    grep -Fqx "artifact_lock_policy=$ARTIFACT_LOCK_POLICY" "$build_info" || \
        die 'BUILD_INFO artifact lock policy mismatch'
    grep -Fqx "package_repository_mode=$PACKAGE_REPOSITORY_MODE" "$build_info" || \
        die 'BUILD_INFO package repository mode mismatch'
    grep -Fqx "package_cache_index=$PACKAGE_CACHE_INDEX" "$build_info" || \
        die 'BUILD_INFO package cache-index policy mismatch'
    recorded_smoke_policy=$(sed -n 's/^x86_smoke_test=//p' "$build_info")
    if [[ -n "$recorded_smoke_policy" ]]; then
        [[ "$recorded_smoke_policy" == "$RUN_X86_SMOKE_TEST" ]] || \
            die 'BUILD_INFO x86 smoke policy mismatch'
    elif [[ "$canonical_build" == 1 ]]; then
        die 'canonical BUILD_INFO does not record the x86 smoke policy'
    fi
    if [[ "$canonical_build" == 1 && "$TARGET_NAME" == x86_64 && \
          "$RUN_X86_SMOKE_TEST" != 1 ]]; then
        die 'canonical x86 artifact requires the QEMU/OVMF smoke gate'
    fi
    if [[ "$canonical_build" == 1 ]]; then
        expected_config_sha=$(sha256sum "$PROJECT_ROOT/configs/build.env" | awk '{ print $1 }')
        grep -Fqx 'build_config=configs/build.env' "$build_info" || \
            die 'canonical artifact did not use configs/build.env'
        grep -Fqx "build_config_sha256=$expected_config_sha" "$build_info" || \
            die 'canonical artifact build policy digest mismatch'
        grep -Eq '^project_commit=[0-9a-f]{40}$' "$build_info" || \
            die 'canonical artifact has no clean committed project revision'
        for expected_policy in \
            check_latest_on_build=0 \
            package_repository_mode=snapshot \
            package_cache_index=0 \
            source_fetch_mode=locked \
            source_fetch_policy=if-missing \
            source_feed_cache_mode=auto \
            source_feed_retries=3 \
            source_kmod_scope=preset \
            source_failure_diagnostics=0 \
            x86_smoke_test=1 \
            require_clean_project=1 \
            require_shellcheck=1 \
            keep_build=0 \
            imagebuilder_retries=3 \
            network_proxy_mode=direct; do
            grep -Fqx "$expected_policy" "$build_info" || \
                die "canonical BUILD_INFO policy mismatch: $expected_policy"
        done
    fi
fi

# profiles.json is emitted by the same image pipeline that appends fwtool
# metadata.  Match target/profile plus every selected file's name, size and
# digest, so damaged metadata or a stale image cannot pass verification.
profiles_json="$output_dir/profiles.json"
[[ -f "$profiles_json" && ! -L "$profiles_json" && -s "$profiles_json" ]] || \
    die "missing or unsafe profiles.json"
python3 - "$profiles_json" "$IMMORTALWRT_VERSION" "$IMMORTALWRT_VERSION_CODE" \
    "$IMMORTALWRT_SOURCE_DATE_EPOCH" "$TARGET/$SUBTARGET" "$PACKAGE_ARCH" \
    "$IMMORTALWRT_KERNEL_VERSION" "$IMMORTALWRT_KERNEL_RELEASE" "$expected_kernel_vermagic" \
    "$PROFILE" "${images[@]}" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

metadata_path = Path(sys.argv[1])
(
    expected_version,
    expected_version_code,
    expected_epoch,
    expected_target,
    expected_arch,
    expected_kernel,
    expected_kernel_release,
    expected_vermagic,
    expected_profile,
) = sys.argv[2:11]
image_paths = [Path(value) for value in sys.argv[11:]]

try:
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid profiles.json: {exc}")

if metadata.get("version_number") != expected_version:
    raise SystemExit(f"profiles.json version mismatch: {metadata.get('version_number')!r}")
if metadata.get("version_code") != expected_version_code:
    raise SystemExit(f"profiles.json version code mismatch: {metadata.get('version_code')!r}")
if metadata.get("source_date_epoch") != int(expected_epoch):
    raise SystemExit(f"profiles.json source epoch mismatch: {metadata.get('source_date_epoch')!r}")
if metadata.get("target") != expected_target:
    raise SystemExit(f"profiles.json target mismatch: {metadata.get('target')!r}")
if metadata.get("arch_packages") != expected_arch:
    raise SystemExit(f"profiles.json package arch mismatch: {metadata.get('arch_packages')!r}")

kernel = metadata.get("linux_kernel")
if not isinstance(kernel, dict):
    raise SystemExit("profiles.json kernel metadata is missing")
if kernel.get("version") != expected_kernel:
    raise SystemExit(f"profiles.json kernel version mismatch: {kernel.get('version')!r}")
if kernel.get("release") != expected_kernel_release:
    raise SystemExit(f"profiles.json kernel release mismatch: {kernel.get('release')!r}")
if kernel.get("vermagic") != expected_vermagic:
    raise SystemExit(f"profiles.json kernel vermagic mismatch: {kernel.get('vermagic')!r}")

profiles = metadata.get("profiles")
if not isinstance(profiles, dict) or expected_profile not in profiles:
    raise SystemExit(f"profiles.json does not contain profile {expected_profile!r}")
entries = profiles[expected_profile].get("images")
if not isinstance(entries, list):
    raise SystemExit("profiles.json image list is missing")

by_name = {}
for entry in entries:
    if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
        raise SystemExit("profiles.json contains an invalid image entry")
    if entry["name"] in by_name:
        raise SystemExit(f"duplicate profiles.json image: {entry['name']}")
    by_name[entry["name"]] = entry

for image_path in image_paths:
    entry = by_name.get(image_path.name)
    if entry is None:
        raise SystemExit(f"image is absent from profiles.json: {image_path.name}")
    actual_size = image_path.stat().st_size
    if entry.get("size") != actual_size:
        raise SystemExit(
            f"image size mismatch for {image_path.name}: "
            f"metadata={entry.get('size')!r}, actual={actual_size}"
        )
    digest = hashlib.sha256()
    with image_path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    actual_digest = digest.hexdigest()
    if entry.get("sha256") != actual_digest:
        raise SystemExit(
            f"image SHA-256 mismatch for {image_path.name}: "
            f"metadata={entry.get('sha256')!r}, actual={actual_digest}"
        )
PY

for image in "${images[@]}"; do
    set +e
    gzip_result=$(LC_ALL=C gzip -t "$image" 2>&1)
    gzip_status=$?
    set -e
    if [[ $gzip_status -eq 0 ]]; then
        continue
    fi

    # bcm27xx sysupgrade images deliberately append fwtool metadata after the
    # gzip member. GNU gzip validates the member but returns 2 for that tail.
    trailer_magic=$(tail -c 16 "$image" | head -c 4)
    if [[ "$TARGET_NAME" != x86_64 && "$image" == *-sysupgrade.img.gz && \
          $gzip_status -eq 2 && "$trailer_magic" == 'FWx0' ]]; then
        continue
    fi
    die "gzip integrity check failed for $image: $gzip_result"
done

python3 "$VERIFY_SCRIPTS_DIR/verify-image-structure.py" \
    --expected-version "$IMMORTALWRT_VERSION" \
    --expected-revision "$IMMORTALWRT_VERSION_CODE" \
    "$TARGET_NAME" "$ROOTFS_PARTSIZE" "$NOMINAL_MEDIA_BYTES" "${images[@]}"

# Check partition declarations, not compressed size.  Pi factory images are
# intentionally truncated after the SquashFS data even though their MBR
# declares the complete root partition.
geometry_image=${images[0]}
[[ "$TARGET_NAME" == x86_64 ]] || geometry_image=${factory_images[0]}
python3 - "$TARGET_NAME" "$ROOTFS_PARTSIZE" "$NOMINAL_MEDIA_BYTES" "$geometry_image" <<'PY'
import gzip
from pathlib import Path
import struct
import sys

target, rootfs_mib, media_limit, image_name = sys.argv[1:]
rootfs_bytes = int(rootfs_mib) * 1024 * 1024
media_limit = int(media_limit)
image = Path(image_name)

with gzip.open(image, "rb") as stream:
    header = stream.read(65536)

if target == "x86_64":
    sector = 512
    if header[sector:sector + 8] != b"EFI PART":
        raise SystemExit("x86 image has no primary GPT header")
    entries_lba = struct.unpack_from("<Q", header, sector + 72)[0]
    entries_count = struct.unpack_from("<I", header, sector + 80)[0]
    entry_size = struct.unpack_from("<I", header, sector + 84)[0]
    if entries_count < 2 or entry_size < 128:
        raise SystemExit("x86 GPT partition table is invalid")
    partitions = []
    for index in range(entries_count):
        offset = entries_lba * sector + index * entry_size
        if offset + entry_size > len(header):
            break
        if header[offset:offset + 16] == bytes(16):
            continue
        first, last = struct.unpack_from("<QQ", header, offset + 32)
        if first >= 512 and last >= first:
            partitions.append((first, last))
    partitions.sort()
    if len(partitions) < 2:
        raise SystemExit("x86 GPT does not contain boot and root partitions")
    boot, root = partitions[:2]
    if boot != (512, 66047):
        raise SystemExit(f"x86 boot partition is not the locked 32 MiB layout: {boot}")
    if root[0] != boot[1] + 1 or (root[1] - root[0] + 1) * sector != rootfs_bytes:
        raise SystemExit(f"x86 root partition is not {rootfs_mib} MiB: {root}")
    declared_end = (root[1] + 1) * sector
    with image.open("rb") as stream:
        stream.seek(-4, 2)
        raw_size = struct.unpack("<I", stream.read(4))[0]
    if raw_size < declared_end or raw_size >= media_limit:
        raise SystemExit(
            f"x86 raw image size is outside the safe media boundary: {raw_size}"
        )
else:
    if header[510:512] != b"\x55\xaa":
        raise SystemExit("Raspberry Pi factory image has no MBR signature")
    partitions = []
    for index in range(4):
        offset = 446 + index * 16
        part_type = header[offset + 4]
        first, count = struct.unpack_from("<II", header, offset + 8)
        if part_type:
            partitions.append((part_type, first, count))
    if len(partitions) != 2:
        raise SystemExit(f"Raspberry Pi MBR has {len(partitions)} partitions, expected 2")
    boot, root = partitions
    if boot[1:] != (8192, 131072):
        raise SystemExit(f"Raspberry Pi boot partition is not the locked 64 MiB layout: {boot}")
    if root[1] != 147456 or root[2] * 512 != rootfs_bytes:
        raise SystemExit(f"Raspberry Pi root partition is not {rootfs_mib} MiB: {root}")
    declared_end = (root[1] + root[2]) * 512
    if declared_end >= media_limit:
        raise SystemExit(
            f"Raspberry Pi partition layout exceeds nominal 4 GB media: {declared_end}"
        )

print(f"Verified partition end {declared_end} < {media_limit} bytes")
PY

# Inspect the root filesystem itself rather than trusting only the partition
# declaration.  A sparse temporary raw file keeps the 3072 MiB zero-filled
# area from consuming physical disk space.
temporary_dir=$(mktemp -d)
cleanup_temporary_image() {
    rm -rf -- "$temporary_dir"
}
trap cleanup_temporary_image EXIT
raw_image="$temporary_dir/firmware.img"
gzip -dc -- "$geometry_image" | dd of="$raw_image" bs=4M conv=sparse status=none
if [[ "$TARGET_NAME" == x86_64 ]]; then
    rootfs_offset=$((66048 * 512))
else
    rootfs_offset=$((147456 * 512))
fi
unsquashfs -stat -offset "$rootfs_offset" "$raw_image" >/dev/null
unsquashfs -cat -offset "$rootfs_offset" "$raw_image" \
    etc/config/attendedsysupgrade > "$temporary_dir/attendedsysupgrade"
cmp -s "$PROJECT_ROOT/files/etc/config/attendedsysupgrade" \
    "$temporary_dir/attendedsysupgrade" || die "embedded ASU configuration is not canonical"
unsquashfs -cat -offset "$rootfs_offset" "$raw_image" \
    etc/config/uhttpd > "$temporary_dir/uhttpd"
cmp -s "$PROJECT_ROOT/files/etc/config/uhttpd" "$temporary_dir/uhttpd" || \
    die "embedded HTTPS uhttpd configuration is not canonical"
grep -Eq '^[[:space:]]+list listen_https[[:space:]]+0[.]0[.]0[.]0:443$' \
    "$temporary_dir/uhttpd" || die "embedded uhttpd does not listen on HTTPS"
grep -Eq '^[[:space:]]+option redirect_https[[:space:]]+1$' \
    "$temporary_dir/uhttpd" || die "embedded uhttpd does not redirect HTTP to HTTPS"
# HTTPS depends on uhttpd and libustream's TLS provider. `openssl-util` used to
# arrive transitively, but it is not a requested package and newer signed
# release indexes correctly omit its optional command-line binary.
for root_file in lib/libustream-ssl.so usr/sbin/uhttpd www/cgi-bin/luci; do
    unsquashfs -cat -offset "$rootfs_offset" "$raw_image" "$root_file" >/dev/null || \
        die "root filesystem is missing $root_file"
done

[[ -f "$output_dir/SHA256SUMS" && ! -L "$output_dir/SHA256SUMS" && \
   -s "$output_dir/SHA256SUMS" ]] || die "missing or unsafe SHA256SUMS"
(
    cd "$output_dir"
    awk '
        NF != 2 || $1 !~ /^[0-9a-f]{64}$/ { exit 1 }
        {
            name = $2
            sub(/^\*/, "", name)
            if (name !~ /^[A-Za-z0-9][A-Za-z0-9+._-]*$/ || seen[name]++) exit 1
        }
    ' SHA256SUMS || die 'SHA256SUMS contains an unsafe or duplicate entry'
    locked_names=$(awk '{ sub(/^\*/, "", $2); print $2 }' SHA256SUMS | sort)
    actual_names=$(find . -mindepth 1 -maxdepth 1 ! -name SHA256SUMS -printf '%P\n' | sort)
    [[ "$locked_names" == "$actual_names" ]] || \
        die 'artifact file set differs from SHA256SUMS'
    while IFS= read -r locked_name; do
        [[ -f "$locked_name" && ! -L "$locked_name" ]] || \
            die "artifact checksum entry is not a regular file: $locked_name"
    done <<< "$locked_names"
    sha256sum -c SHA256SUMS
)

if [[ "$build_mode" == imagebuilder && \
      "$ARTIFACT_LOCK_POLICY" == enforce && -z "$extra_packages_line" ]]; then
    for index in "${!EXPECTED_ARTIFACT_FILES[@]}"; do
        expected_file=${EXPECTED_ARTIFACT_FILES[$index]}
        expected_sha=${EXPECTED_ARTIFACT_SHA256S[$index]}
        matched=
        for image in "${images[@]}"; do
            if [[ $(basename -- "$image") == "$expected_file" ]]; then
                matched=$image
                break
            fi
        done
        [[ -n "$matched" ]] || die "locked image is missing: $expected_file"
        actual_sha=$(sha256sum "$matched" | awk '{ print $1 }')
        [[ "$actual_sha" == "$expected_sha" ]] || \
            die "locked image digest drifted: $expected_file"
    done
fi

manifests=("$output_dir"/*.manifest)
[[ ${#manifests[@]} -eq 1 ]] || die "expected exactly one package manifest"
manifest=${manifests[0]}
[[ -f "$manifest" && ! -L "$manifest" ]] || die 'package manifest is not a regular file'
if [[ "$build_mode" == imagebuilder && \
      "$ARTIFACT_LOCK_POLICY" == enforce && -z "$extra_packages_line" ]]; then
    actual_package_count=$(wc -l < "$manifest")
    actual_manifest_sha256=$(sha256sum "$manifest" | awk '{ print $1 }')
    [[ "$actual_package_count" == "$EXPECTED_PACKAGE_COUNT" ]] || \
        die "resolved package count drifted: expected $EXPECTED_PACKAGE_COUNT, got $actual_package_count"
    [[ "$actual_manifest_sha256" == "$EXPECTED_MANIFEST_SHA256" ]] || \
        die "resolved package versions drifted from the reviewed manifest lock"
    cmp -s "$manifest" "$EXPECTED_MANIFEST_FILE" || \
        die 'resolved package manifest differs from the reviewed manifest file'
elif [[ "$build_mode" == imagebuilder && "$candidate_build" == 1 ]]; then
    grep -Fqx "package_count=$(wc -l < "$manifest")" "$build_info" || \
        die 'candidate BUILD_INFO package count mismatch'
    candidate_manifest_sha=$(sha256sum "$manifest" | awk '{ print $1 }')
    grep -Fqx "package_manifest_sha256=$candidate_manifest_sha" "$build_info" || \
        die 'candidate BUILD_INFO package manifest digest mismatch'
fi
manifest_has_package() {
    awk -v package="$1" '$1 == package && $2 == "-" { found = 1 } END { exit !found }' \
        "$manifest"
}

while IFS= read -r package_file; do
    while IFS= read -r required_package; do
        manifest_has_package "$required_package" || \
            die "$PRESET_NAME package is missing from manifest: $required_package"
    done < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$package_file")
done < <(preset_package_files)

if [[ "$build_mode" == imagebuilder ]]; then
    if [[ "$canonical_build" == 1 && -n "$extra_packages_line" ]]; then
        die "canonical ImageBuilder artifact contains EXTRA_PACKAGES"
    elif [[ "$canonical_build" == 0 && "$candidate_build" == 0 && \
            "$development_build" == 0 && \
            -z "$extra_packages_line" ]]; then
        die "non-canonical ImageBuilder artifact does not identify EXTRA_PACKAGES"
    fi
fi
extra_package_array=()
if [[ -n "$extra_packages_line" ]]; then
    read -r -a extra_package_array <<< "$extra_packages_line"
fi
for required_package in "${extra_package_array[@]}"; do
    manifest_has_package "$required_package" || \
        die "extra package is missing from manifest: $required_package"
done

while IFS= read -r runtime_package; do
    if manifest_has_package "$runtime_package"; then
        die "runtime application was unexpectedly embedded: $runtime_package"
    fi
done < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
    "$PROJECT_ROOT/packages/runtime-apps.txt")

printf 'Verified %s/%s artifacts (%s)\n' "$TARGET_NAME" "$PRESET_NAME" "$IMMORTALWRT_VERSION"
