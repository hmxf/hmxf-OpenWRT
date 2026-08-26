#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

BUILD_CHANNEL=${BUILD_CHANNEL:-stable}
load_build_config
configure_network_environment
sanitize_build_path
load_release_lock
load_target_lock "${1:-}"
load_preset "${2:-}"
validate_extra_packages
if [[ "$BUILD_CHANNEL" == nightly ]]; then
    require_command sha256sum
    [[ ${NIGHTLY_FINGERPRINT:-} =~ ^[0-9a-f]{64}$ ]] || \
        die 'nightly build requires NIGHTLY_FINGERPRINT'
    [[ "$LOCKED_INPUT_RELEASE_TAG" == "nightly-$NIGHTLY_FINGERPRINT" ]] || \
        die 'nightly context fingerprint/release tag mismatch'
    [[ ${NIGHTLY_CONTEXT_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || \
        die 'nightly build requires NIGHTLY_CONTEXT_SHA256'
    actual_context_sha256=$(sha256sum \
        "$PROJECT_ROOT/build/nightly/$NIGHTLY_FINGERPRINT/context/CONTEXT.sha256" \
        | awk '{ print $1 }')
    [[ "$actual_context_sha256" == "$NIGHTLY_CONTEXT_SHA256" ]] || \
        die 'nightly context checksum-index identity changed'
    if [[ "$PACKAGE_REPOSITORY_MODE" == snapshot ]]; then
        [[ ${NIGHTLY_PACKAGE_SNAPSHOTS_SHA256:-} =~ ^[0-9a-f]{64}$ && \
           ${NIGHTLY_PACKAGE_SNAPSHOT_LOCK_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || \
            die 'nightly snapshot build requires NIGHTLY_PACKAGE_SNAPSHOTS_SHA256'
        actual_package_snapshot_lock_sha256=$(sha256sum "$PACKAGE_SNAPSHOT_LOCK" \
            | awk '{ print $1 }')
        actual_package_snapshots_sha256=$(
            "$INPUT_SCRIPTS_DIR/nightly-build-identity.sh" content \
                "$PACKAGE_SNAPSHOT_LOCK"
        )
        [[ "$actual_package_snapshot_lock_sha256" == \
               "$NIGHTLY_PACKAGE_SNAPSHOT_LOCK_SHA256" && \
           "$actual_package_snapshots_sha256" == \
               "$NIGHTLY_PACKAGE_SNAPSHOTS_SHA256" ]] || \
            die 'nightly package snapshot lock identity changed'
    fi
fi
if [[ "$ARTIFACT_LOCK_POLICY" == enforce ]]; then
    load_package_manifest_lock
fi
require_clean_project_if_configured
if (( CHECK_LATEST_ON_BUILD == 1 )); then
    "$LOCK_SCRIPTS_DIR/check-latest-release.sh"
fi

project_commit=$(project_revision)
canonical_build=0
candidate_build=0
development_build=0
if [[ "$ARTIFACT_LOCK_POLICY" == record ]]; then
    [[ -z ${EXTRA_PACKAGES:-} ]] || die 'record mode does not accept EXTRA_PACKAGES'
    candidate_build=1
elif [[ "$BUILD_CHANNEL" == nightly && \
        "$ARTIFACT_LOCK_POLICY" == enforce && \
        "$PACKAGE_REPOSITORY_MODE" == snapshot && \
        "$PACKAGE_CACHE_INDEX" == 0 && -z ${EXTRA_PACKAGES:-} ]]; then
    candidate_build=1
elif [[ -z ${EXTRA_PACKAGES:-} && "$project_commit" != uncommitted && \
        "$project_commit" != *-dirty && \
        "$LOCKS_DIR" == "$PROJECT_ROOT/locks" && \
        "$CONFIGS_DIR" == "$PROJECT_ROOT/configs" && \
        "$BUILD_CONFIG_FILE" == "$PROJECT_ROOT/configs/build.env" && \
        "$CHECK_LATEST_ON_BUILD" == 0 && \
        "$PACKAGE_REPOSITORY_MODE" == snapshot && \
        "$PACKAGE_CACHE_INDEX" == 0 && \
        "$SOURCE_FETCH_MODE" == locked && \
        "$SOURCE_FETCH_POLICY" == if-missing && \
        "$SOURCE_FEED_CACHE_MODE" == auto && \
        "$SOURCE_FEED_RETRIES" == 3 && \
        "$SOURCE_KMOD_SCOPE" == preset && \
        "$SOURCE_FAILURE_DIAGNOSTICS" == 0 && \
        "$RUN_X86_SMOKE_TEST" == 1 && \
        "$REQUIRE_CLEAN_PROJECT" == 1 && \
        "$REQUIRE_SHELLCHECK" == 1 && \
        "$KEEP_BUILD" == 0 && \
        "$IMAGEBUILDER_RETRIES" == 3 && \
        "$NETWORK_PROXY_MODE" == direct ]]; then
    canonical_build=1
else
    development_build=1
fi

for tool in cmp curl find flock gzip make paste python3 realpath sha256sum sort stat \
            tar uname wc xargs zstd; do
    require_command "$tool"
done
[[ $(uname -m) == x86_64 ]] || die "the locked ImageBuilder requires an x86_64 Linux host"

download_dir=${DOWNLOAD_DIR:-"$PROJECT_ROOT/.cache/imagebuilders"}
build_parent=${BUILD_DIR:-"$PROJECT_ROOT/build"}
output_root=${OUTPUT_ROOT:-"$PROJECT_ROOT/out"}
output_dir=$(realpath -m -- \
    "${OUTPUT_DIR:-"$output_root/$IMMORTALWRT_VERSION/$TARGET_NAME/$PRESET_NAME"}")
case "$output_dir" in
    / | "$PROJECT_ROOT" | "$(dirname -- "$PROJECT_ROOT")")
        die "unsafe output directory: $output_dir"
        ;;
esac
if [[ "$ARTIFACT_LOCK_POLICY" == record ]]; then
    if [[ "$BUILD_CHANNEL" == nightly ]]; then
        case "$output_dir" in
            "$PROJECT_ROOT/build/nightly/$NIGHTLY_FINGERPRINT/"*) ;;
            *) die 'nightly record mode may publish only below its fingerprint directory' ;;
        esac
    else
        case "$output_dir" in
            "$PROJECT_ROOT/build/lock-refresh/"*) ;;
            *) die 'record mode may publish only below build/lock-refresh/' ;;
        esac
    fi
fi
output_parent=$(dirname -- "$output_dir")
archive="$download_dir/$IMAGEBUILDER_FILE"
if [[ "$BUILD_CHANNEL" == nightly ]]; then
    url="$IMMORTALWRT_DOWNLOAD_URL/snapshots/targets/$TARGET/$SUBTARGET/$IMAGEBUILDER_FILE"
else
    url="$IMMORTALWRT_DOWNLOAD_URL/releases/$IMMORTALWRT_VERSION/targets/$TARGET/$SUBTARGET/$IMAGEBUILDER_FILE"
fi

mkdir -p "$download_dir" "$build_parent" "$output_parent"

if [[ "$PACKAGE_REPOSITORY_MODE" == snapshot ]]; then
    restore_inputs="$INPUT_SCRIPTS_DIR/restore-locked-inputs.sh"
    [[ -x "$restore_inputs" ]] || \
        die "locked-input restore helper is unavailable: $restore_inputs"
    BUILD_CONFIG="$BUILD_CONFIG_FILE" \
    DOWNLOAD_DIR="$download_dir" \
    PACKAGE_SNAPSHOT_DIR="${PACKAGE_SNAPSHOT_DIR:-$PROJECT_ROOT/.cache/package-snapshots}" \
        "$restore_inputs" "$TARGET_NAME"
fi

download_lock="$download_dir/.$IMAGEBUILDER_FILE.lock"
require_regular_file_or_absent "$download_lock" 'ImageBuilder cache lock'
exec {download_lock_fd}>"$download_lock"
flock "$download_lock_fd"
if [[ -e "$archive" || -L "$archive" ]]; then
    [[ -f "$archive" && ! -L "$archive" ]] || \
        die "cached ImageBuilder is not a regular file: $archive"
    [[ $(stat -c '%s' "$archive") == "$IMAGEBUILDER_BYTES" ]] || \
        die "cached ImageBuilder has the wrong byte size: $archive"
    printf '%s  %s\n' "$IMAGEBUILDER_SHA256" "$archive" | sha256sum -c -
else
    [[ "$PACKAGE_REPOSITORY_MODE" == live ]] || \
        die "locked-input restore did not provide ImageBuilder: $archive"
    partial="$archive.part"
    if [[ -e "$partial" || -L "$partial" ]]; then
        [[ -f "$partial" && ! -L "$partial" ]] || \
            die "unsafe partial ImageBuilder download: $partial"
        rm -f -- "$partial"
    fi
    if ! curl --disable --proto '=https' --proto-redir '=https' \
            --fail --location --retry 3 --retry-all-errors \
            --output "$partial" "$url"; then
        rm -f -- "$partial"
        die "cannot download the locked ImageBuilder: $url"
    fi
    if ! printf '%s  %s\n' "$IMAGEBUILDER_SHA256" "$partial" | sha256sum -c -; then
        rm -f -- "$partial"
        die "downloaded ImageBuilder has the wrong SHA-256: $url"
    fi
    if [[ $(stat -c '%s' "$partial") != "$IMAGEBUILDER_BYTES" ]]; then
        rm -f -- "$partial"
        die "downloaded ImageBuilder has the wrong byte size: $url"
    fi
    mv -- "$partial" "$archive"
fi
flock -u "$download_lock_fd"

work_dir=
artifact_staging=
previous_output=
cleanup() {
    if [[ -n "$work_dir" && -d "$work_dir" && ${KEEP_BUILD:-0} != 1 ]]; then
        rm -rf -- "$work_dir"
    elif [[ -n "$work_dir" && -d "$work_dir" ]]; then
        printf 'Preserved build directory: %s\n' "$work_dir"
    fi
    [[ -z "$artifact_staging" || ! -d "$artifact_staging" ]] || \
        rm -rf -- "$artifact_staging"
    if [[ -n "$previous_output" && -e "$previous_output" ]]; then
        if [[ ! -e "$output_dir" && ! -L "$output_dir" ]]; then
            mv -- "$previous_output" "$output_dir" || true
        else
            rm -rf -- "$previous_output"
        fi
    fi
}
trap cleanup EXIT
work_dir=$(mktemp -d "$build_parent/$TARGET_NAME-$PRESET_NAME.XXXXXXXX")
artifact_staging=$(mktemp -d "$output_parent/.$PRESET_NAME.XXXXXXXX")

tar --zstd -xf "$archive" -C "$work_dir"
imagebuilder_dir="$work_dir/${IMAGEBUILDER_FILE%.tar.zst}"
[[ -d "$imagebuilder_dir" ]] || die "unexpected ImageBuilder archive layout"

packages=$(read_preset_packages)
packages="$packages ${EXTRA_PACKAGES:-}"

set_imagebuilder_config() {
    local symbol=$1
    local value=$2
    local config="$imagebuilder_dir/.config"

    sed -i -e "/^${symbol}=/d" -e "/^# ${symbol} is not set$/d" "$config"
    if [[ "$value" == n ]]; then
        printf '# %s is not set\n' "$symbol" >> "$config"
    else
        printf '%s=%s\n' "$symbol" "$value" >> "$config"
    fi
}

package_cache_dir=${PACKAGE_CACHE_DIR:-"$PROJECT_ROOT/.cache/packages/$IMMORTALWRT_VERSION/$TARGET_NAME"}
if [[ "$PACKAGE_REPOSITORY_MODE" == live ]]; then
    mkdir -p "$package_cache_dir"
    package_cache_dir=$(realpath -e -- "$package_cache_dir")
    package_cache_index_root=
    if (( PACKAGE_CACHE_INDEX == 1 )); then
        cache_release_dir=$(dirname -- "$package_cache_dir")
        package_cache_index_root=$(dirname -- "$cache_release_dir")
        [[ $(basename -- "$package_cache_dir") == "$TARGET_NAME" && \
           $(basename -- "$cache_release_dir") == "$IMMORTALWRT_VERSION" && \
           "$package_cache_dir" == \
             "$package_cache_index_root/$IMMORTALWRT_VERSION/$TARGET_NAME" ]] || \
            die 'PACKAGE_CACHE_INDEX=1 requires PACKAGE_CACHE_DIR ending in VERSION/TARGET'
        if find "$package_cache_dir" -maxdepth 1 -type f -name '*.apk' -print -quit \
                | grep -q .; then
            APK_METADATA_TOOL="$imagebuilder_dir/staging_dir/host/bin/apk" \
                "$CACHE_SCRIPTS_DIR/index-package-cache.sh" update \
                "$package_cache_index_root" "$IMMORTALWRT_VERSION" "$TARGET_NAME"
        fi
    fi
    package_cache_lock="$package_cache_dir/.imagebuilder.lock"
    unsafe_cache_entry=$(find "$package_cache_dir" -mindepth 1 -maxdepth 1 \
        ! -type d ! -type f -print -quit)
    [[ -z "$unsafe_cache_entry" ]] || \
        die "package cache contains a symbolic link or special file: $unsafe_cache_entry"
    require_regular_file_or_absent "$package_cache_lock" 'package cache lock'
    exec {package_cache_lock_fd}>"$package_cache_lock"
    flock "$package_cache_lock_fd"
    set_imagebuilder_config CONFIG_DOWNLOAD_FOLDER "\"$package_cache_dir\""
else
    load_package_snapshot_lock
    snapshot_root=${PACKAGE_SNAPSHOT_DIR:-"$PROJECT_ROOT/.cache/package-snapshots"}
    snapshot_root=$(realpath -e -- "$snapshot_root")
    snapshot_dir=$(realpath -e -- "$snapshot_root/$IMMORTALWRT_VERSION/$TARGET_NAME")
    case "$snapshot_dir" in
        "$snapshot_root/$IMMORTALWRT_VERSION/$TARGET_NAME") ;;
        *) die "package snapshot resolves outside its locked root: $snapshot_dir" ;;
    esac
    [[ -d "$snapshot_dir" && ! -L "$snapshot_dir" && \
       -f "$snapshot_dir/SHA256SUMS" && ! -L "$snapshot_dir/SHA256SUMS" && \
       -s "$snapshot_dir/SHA256SUMS" ]] || \
        die "missing package snapshot for $TARGET_NAME: $snapshot_dir"
    (
        cd "$snapshot_dir"
        printf '%s  %s\n' "$PACKAGE_SNAPSHOT_TREE_SHA256" SHA256SUMS \
            | sha256sum --strict --quiet -c - || \
            die 'package snapshot tree manifest differs from its external lock'
        awk '
            NF != 2 || $1 !~ /^[0-9a-f]{64}$/ { exit 1 }
            {
                name = $2
                sub(/^\*/, "", name)
                if (name !~ /^(repositories[.]list|repo-[1-9][0-9]*\/[A-Za-z0-9][A-Za-z0-9+._~:-]*)$/ ||
                    seen[name]++) exit 1
            }
        ' SHA256SUMS || die 'package snapshot has unsafe or duplicate checksum entries'
        locked_names=$(awk '{ sub(/^\*/, "", $2); print $2 }' SHA256SUMS | sort)
        actual_names=$(find . -type f ! -name SHA256SUMS -printf '%P\n' | sort)
        [[ "$locked_names" == "$actual_names" ]] || \
            die "package snapshot file set differs from SHA256SUMS: $snapshot_dir"
        special_entry=$(find . -mindepth 1 ! -type d ! -type f -print -quit)
        [[ -z "$special_entry" ]] || \
            die "package snapshot contains a special file: $special_entry"
        while IFS= read -r locked_name; do
            [[ -f "$locked_name" && ! -L "$locked_name" ]] || \
                die "package snapshot entry is not a regular file: $locked_name"
        done <<< "$locked_names"
        sha256sum --strict --quiet -c SHA256SUMS
    )
    [[ -f "$snapshot_dir/repositories.list" && \
       ! -L "$snapshot_dir/repositories.list" && \
       -s "$snapshot_dir/repositories.list" ]] || \
        die "package snapshot has no repositories.list: $snapshot_dir"
    : > "$imagebuilder_dir/repositories"
    repository_number=0
    expected_repository_dirs=
    while IFS= read -r repository_name; do
        repository_number=$((repository_number + 1))
        [[ "$repository_name" == "repo-$repository_number" ]] || \
            die "snapshot repository list is not contiguous at entry $repository_number"
        repository_dir="$snapshot_dir/$repository_name"
        [[ -d "$repository_dir" && ! -L "$repository_dir" && \
           -f "$repository_dir/packages.adb" && \
           ! -L "$repository_dir/packages.adb" && \
           -s "$repository_dir/packages.adb" ]] || \
            die "snapshot repository has no index: $repository_dir"
        expected_repository_dirs=${expected_repository_dirs:+"$expected_repository_dirs"$'\n'}$repository_name
        while IFS= read -r repository_file; do
            [[ "$repository_file" == packages.adb || \
               "$repository_file" =~ ^[A-Za-z0-9][A-Za-z0-9+._~:-]*[.]apk$ ]] || \
                die "unsafe file in snapshot repository: $repository_name/$repository_file"
        done < <(find "$repository_dir" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
        printf 'file://%s/packages.adb\n' "$repository_dir" >> "$imagebuilder_dir/repositories"
    done < "$snapshot_dir/repositories.list"
    (( repository_number > 0 )) || die "package snapshot has an empty repository list"
    actual_repository_dirs=$(find "$snapshot_dir" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' | sort -V)
    [[ "$actual_repository_dirs" == "$expected_repository_dirs" ]] || \
        die "package snapshot directory set differs from repositories.list: $snapshot_dir"
    nested_repository_dir=$(find "$snapshot_dir" -mindepth 2 -type d -print -quit)
    [[ -z "$nested_repository_dir" ]] || \
        die "package snapshot contains a nested directory: $nested_repository_dir"
fi

# Restrict the release buildbot configuration before invoking its nested make
# processes.  The target profile itself is never renamed: minimal/full are
# package presets only, so ASU continues to recognize the device profile.
set_imagebuilder_config CONFIG_TARGET_ROOTFS_PARTSIZE "$ROOTFS_PARTSIZE"
set_imagebuilder_config CONFIG_TARGET_ROOTFS_SQUASHFS y
set_imagebuilder_config CONFIG_TARGET_ROOTFS_EXT4FS n
set_imagebuilder_config CONFIG_TARGET_ROOTFS_TARGZ n
if [[ "$TARGET_NAME" == x86_64 ]]; then
    set_imagebuilder_config CONFIG_TARGET_KERNEL_PARTSIZE 32
    set_imagebuilder_config CONFIG_TARGET_IMAGES_GZIP y
    set_imagebuilder_config CONFIG_GRUB_IMAGES n
    set_imagebuilder_config CONFIG_GRUB_EFI_IMAGES y
    set_imagebuilder_config CONFIG_ISO_IMAGES n
    set_imagebuilder_config CONFIG_QCOW2_IMAGES n
    set_imagebuilder_config CONFIG_VDI_IMAGES n
    set_imagebuilder_config CONFIG_VHDX_IMAGES n
    set_imagebuilder_config CONFIG_VMDK_IMAGES n
else
    set_imagebuilder_config CONFIG_TARGET_KERNEL_PARTSIZE 64
fi

# Package downloads occasionally terminate early on long full builds.  Retry
# in the same work tree so already verified APK downloads are reused; genuine
# dependency or image errors still fail after the bounded third attempt.
max_attempts=$IMAGEBUILDER_RETRIES
for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if make -C "$imagebuilder_dir" image \
        PROFILE="$PROFILE" \
        PACKAGES="$packages" \
        FILES="$PROJECT_ROOT/files" \
        ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE" \
        EXTRA_IMAGE_NAME="$PRESET_NAME"; then
        break
    fi
    if (( attempt == max_attempts )); then
        die "ImageBuilder failed after $max_attempts attempts"
    fi
    printf 'ImageBuilder attempt %d/%d failed; retrying in the same work directory\n' \
        "$attempt" "$max_attempts" >&2
done
if [[ "$PACKAGE_REPOSITORY_MODE" == live ]]; then
    flock -u "$package_cache_lock_fd"
    if (( PACKAGE_CACHE_INDEX == 1 )); then
        APK_METADATA_TOOL="$imagebuilder_dir/staging_dir/host/bin/apk" \
            "$CACHE_SCRIPTS_DIR/index-package-cache.sh" update \
            "$package_cache_index_root" "$IMMORTALWRT_VERSION" "$TARGET_NAME"
    fi
fi

embedded_asu=$(find "$imagebuilder_dir/build_dir" -path '*/root-*/etc/config/attendedsysupgrade' \
    -type f -print -quit)
[[ -n "$embedded_asu" ]] || die "static attendedsysupgrade config was not embedded"
cmp -s "$PROJECT_ROOT/files/etc/config/attendedsysupgrade" "$embedded_asu" || \
    die "embedded attendedsysupgrade config differs from the locked static file"
embedded_root=${embedded_asu%/etc/config/attendedsysupgrade}
embedded_uhttpd="$embedded_root/etc/config/uhttpd"
[[ -s "$embedded_uhttpd" ]] || die "static HTTPS uhttpd config was not embedded"
cmp -s "$PROJECT_ROOT/files/etc/config/uhttpd" "$embedded_uhttpd" || \
    die "embedded uhttpd config differs from the locked static file"

bin_dir="$imagebuilder_dir/bin/targets/$TARGET/$SUBTARGET"
[[ -d "$bin_dir" ]] || die "missing ImageBuilder output directory"

shopt -s nullglob
case "$TARGET_NAME" in
    x86_64)
        images=("$bin_dir"/*-squashfs-combined-efi.img.gz)
        [[ ${#images[@]} -eq 1 ]] || die "expected exactly one x86 UEFI SquashFS image"
        ;;
    rpi4)
        factory_images=("$bin_dir"/*-rpi-4-squashfs-factory.img.gz)
        sysupgrade_images=("$bin_dir"/*-rpi-4-squashfs-sysupgrade.img.gz)
        [[ ${#factory_images[@]} -eq 1 && ${#sysupgrade_images[@]} -eq 1 ]] || \
            die "expected Raspberry Pi 4 factory and sysupgrade images"
        images=("${factory_images[0]}" "${sysupgrade_images[0]}")
        ;;
    rpi5)
        factory_images=("$bin_dir"/*-rpi-5-squashfs-factory.img.gz)
        sysupgrade_images=("$bin_dir"/*-rpi-5-squashfs-sysupgrade.img.gz)
        [[ ${#factory_images[@]} -eq 1 && ${#sysupgrade_images[@]} -eq 1 ]] || \
            die "expected Raspberry Pi 5 factory and sysupgrade images"
        images=("${factory_images[0]}" "${sysupgrade_images[0]}")
        ;;
esac

cp -- "${images[@]}" "$artifact_staging/"
metadata=("$bin_dir"/*.manifest "$bin_dir"/profiles.json "$bin_dir"/config.buildinfo \
          "$bin_dir"/feeds.buildinfo "$bin_dir"/version.buildinfo)
for item in "${metadata[@]}"; do
    [[ -f "$item" ]] && cp -- "$item" "$artifact_staging/"
done

staged_manifests=("$artifact_staging"/*.manifest)
[[ ${#staged_manifests[@]} -eq 1 ]] || die 'ImageBuilder did not emit exactly one manifest'
actual_package_count=$(wc -l < "${staged_manifests[0]}")
actual_manifest_sha256=$(sha256sum "${staged_manifests[0]}" | awk '{ print $1 }')
if [[ "$ARTIFACT_LOCK_POLICY" == record ]]; then
    EXPECTED_PACKAGE_COUNT=$actual_package_count
    EXPECTED_MANIFEST_SHA256=$actual_manifest_sha256
fi

build_config_sha256=$(sha256sum "$BUILD_CONFIG_FILE" | awk '{ print $1 }')
package_list_names=()
while IFS= read -r package_file; do
    package_list_names+=("${package_file#"$PROJECT_ROOT/"}")
done < <(preset_package_files)
package_list_csv=$(IFS=,; printf '%s' "${package_list_names[*]}")
{
    printf 'build_mode=imagebuilder\n'
    printf 'release_channel=%s\n' "$BUILD_CHANNEL"
    printf 'canonical_build=%s\n' "$canonical_build"
    printf 'candidate_build=%s\n' "$candidate_build"
    printf 'development_build=%s\n' "$development_build"
    printf 'release=%s\n' "$IMMORTALWRT_VERSION"
    if [[ "$BUILD_CHANNEL" == nightly ]]; then
        printf 'nightly_fingerprint=%s\n' "$NIGHTLY_FINGERPRINT"
        printf 'nightly_context_sha256=%s\n' "$NIGHTLY_CONTEXT_SHA256"
        if [[ "$PACKAGE_REPOSITORY_MODE" == snapshot ]]; then
            printf 'nightly_package_snapshots_sha256=%s\n' \
                "$NIGHTLY_PACKAGE_SNAPSHOTS_SHA256"
            printf 'nightly_package_snapshot_lock_sha256=%s\n' \
                "$NIGHTLY_PACKAGE_SNAPSHOT_LOCK_SHA256"
        fi
    fi
    printf 'source_commit=%s\n' "$IMMORTALWRT_COMMIT"
    printf 'version_code=%s\n' "$IMMORTALWRT_VERSION_CODE"
    printf 'source_date_epoch=%s\n' "$IMMORTALWRT_SOURCE_DATE_EPOCH"
    printf 'project_commit=%s\n' "$project_commit"
    printf 'build_config=%s\n' "${BUILD_CONFIG_FILE#"$PROJECT_ROOT/"}"
    printf 'build_config_sha256=%s\n' "$build_config_sha256"
    printf 'artifact_lock_policy=%s\n' "$ARTIFACT_LOCK_POLICY"
    printf 'package_repository_mode=%s\n' "$PACKAGE_REPOSITORY_MODE"
    printf 'package_cache_index=%s\n' "$PACKAGE_CACHE_INDEX"
    printf 'check_latest_on_build=%s\n' "$CHECK_LATEST_ON_BUILD"
    printf 'source_fetch_mode=%s\n' "$SOURCE_FETCH_MODE"
    printf 'source_fetch_policy=%s\n' "$SOURCE_FETCH_POLICY"
    printf 'source_feed_cache_mode=%s\n' "$SOURCE_FEED_CACHE_MODE"
    printf 'source_feed_retries=%s\n' "$SOURCE_FEED_RETRIES"
    printf 'source_kmod_scope=%s\n' "$SOURCE_KMOD_SCOPE"
    printf 'source_failure_diagnostics=%s\n' "$SOURCE_FAILURE_DIAGNOSTICS"
    printf 'x86_smoke_test=%s\n' "$RUN_X86_SMOKE_TEST"
    printf 'require_clean_project=%s\n' "$REQUIRE_CLEAN_PROJECT"
    printf 'require_shellcheck=%s\n' "$REQUIRE_SHELLCHECK"
    printf 'keep_build=%s\n' "$KEEP_BUILD"
    printf 'imagebuilder_retries=%s\n' "$IMAGEBUILDER_RETRIES"
    printf 'network_proxy_mode=%s\n' "$NETWORK_PROXY_MODE"
    printf 'target=%s/%s\n' "$TARGET" "$SUBTARGET"
    printf 'profile=%s\n' "$PROFILE"
    printf 'preset=%s\n' "$PRESET_NAME"
    printf 'package_arch=%s\n' "$PACKAGE_ARCH"
    printf 'kernel_version=%s\n' "$IMMORTALWRT_KERNEL_VERSION"
    printf 'kernel_release=%s\n' "$IMMORTALWRT_KERNEL_RELEASE"
    printf 'kernel_vermagic=%s\n' "$KERNEL_VERMAGIC"
    printf 'imagebuilder_file=%s\n' "$IMAGEBUILDER_FILE"
    printf 'imagebuilder_sha256=%s\n' "$IMAGEBUILDER_SHA256"
    printf 'imagebuilder_bytes=%s\n' "$IMAGEBUILDER_BYTES"
    if [[ "$PACKAGE_REPOSITORY_MODE" == snapshot ]]; then
        printf 'package_snapshot_file=%s\n' "$PACKAGE_SNAPSHOT_FILE"
        printf 'package_snapshot_sha256=%s\n' "$PACKAGE_SNAPSHOT_SHA256"
        printf 'package_snapshot_bytes=%s\n' "$PACKAGE_SNAPSHOT_BYTES"
        printf 'package_snapshot_tree_sha256=%s\n' "$PACKAGE_SNAPSHOT_TREE_SHA256"
    fi
    if [[ -z ${EXTRA_PACKAGES:-} ]]; then
        printf 'package_count=%s\n' "$EXPECTED_PACKAGE_COUNT"
        printf 'package_manifest_sha256=%s\n' "$EXPECTED_MANIFEST_SHA256"
    fi
    printf 'rootfs_partsize_mb=%s\n' "$ROOTFS_PARTSIZE"
    printf 'nominal_media_bytes=%s\n' "$NOMINAL_MEDIA_BYTES"
    printf 'package_lists=%s\n' "$package_list_csv"
    printf 'extra_packages=%s\n' "${EXTRA_PACKAGES:-}"
} > "$artifact_staging/BUILD_INFO.txt"

(
    cd "$artifact_staging"
    find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -printf '%P\0' \
        | sort -z | xargs -0 -r sha256sum > SHA256SUMS.tmp
    mv -- SHA256SUMS.tmp SHA256SUMS
)

"$VERIFY_SCRIPTS_DIR/verify-artifacts.sh" \
    "$TARGET_NAME" "$PRESET_NAME" "$artifact_staging"
if [[ "$TARGET_NAME" == x86_64 && "$RUN_X86_SMOKE_TEST" == 1 ]]; then
    "$VERIFY_SCRIPTS_DIR/smoke-test-x86-uefi.sh" "$artifact_staging"
fi

# Publish only a fully verified directory, so a failed local rebuild cannot mix
# new files with stale artifacts from a previous preset.
publish_lock="$output_parent/.$TARGET_NAME-$PRESET_NAME.publish.lock"
require_regular_file_or_absent "$publish_lock" 'artifact publish lock'
exec {publish_lock_fd}>"$publish_lock"
flock "$publish_lock_fd"
previous_output=$(mktemp -d "$output_parent/.previous-$TARGET_NAME-$PRESET_NAME.XXXXXXXX")
rmdir -- "$previous_output"
if [[ -e "$output_dir" ]]; then
    mv -- "$output_dir" "$previous_output"
fi
if mv -- "$artifact_staging" "$output_dir"; then
    artifact_staging=
    [[ ! -e "$previous_output" ]] || rm -rf -- "$previous_output"
    previous_output=
else
    if [[ -e "$previous_output" ]]; then
        mv -- "$previous_output" "$output_dir"
        previous_output=
    fi
    die "failed to publish verified output directory"
fi
flock -u "$publish_lock_fd"
printf 'Firmware is in %s\n' "$output_dir"
