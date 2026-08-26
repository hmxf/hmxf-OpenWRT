#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

load_build_config
configure_network_environment
sanitize_build_path
load_release_lock
load_target_lock "${1:-}"
load_preset "${2:-}"
validate_extra_packages
require_clean_project_if_configured
if (( CHECK_LATEST_ON_BUILD == 1 )); then
    "$LOCK_SCRIPTS_DIR/check-latest-release.sh"
fi
require_command cmp
require_command flock
require_command git
require_command python3
require_command realpath
SOURCE_REPOSITORY=${SOURCE_PATH:-"$(dirname -- "$PROJECT_ROOT")/ImmortalWRT"}
SOURCE_REPOSITORY=$(realpath -m -- "$SOURCE_REPOSITORY")
JOBS=${JOBS:-$(nproc)}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
check_only=${CHECK_ONLY:-0}
[[ "$check_only" == 0 || "$check_only" == 1 ]] || die 'CHECK_ONLY must be 0 or 1'

source_repository_parent=$(dirname -- "$SOURCE_REPOSITORY")
source_repository_name=$(basename -- "$SOURCE_REPOSITORY")
[[ "$source_repository_name" =~ ^[A-Za-z0-9._-]+$ && \
   "$SOURCE_REPOSITORY" != / ]] || die "unsafe source repository path: $SOURCE_REPOSITORY"
mkdir -p "$source_repository_parent"
source_repository_lock="$source_repository_parent/.$source_repository_name.hmxf-source.lock"
require_regular_file_or_absent "$source_repository_lock" 'source repository lock'
exec {source_repository_lock_fd}>"$source_repository_lock"
flock "$source_repository_lock_fd"

SOURCE_REPOSITORY_LOCK_HELD=1 SOURCE_PATH="$SOURCE_REPOSITORY" \
    "$SOURCE_SCRIPTS_DIR/fetch-source.sh"

# The complete sibling clone is a read-only source repository.  Every check or
# build gets a fresh detached worktree, so old .config, feeds, bin, build_dir or
# untracked patches can never leak from a previous target into this one.
source_build_parent=${SOURCE_BUILD_DIR:-"$PROJECT_ROOT/build/source"}
source_download_cache=${SOURCE_DOWNLOAD_DIR:-"$PROJECT_ROOT/.cache/source-dl"}
mkdir -p "$source_build_parent" "$source_download_cache"
SOURCE_PATH=
requested_config=
source_files=
artifact_staging=
previous_output=
cleanup_source_build() {
    [[ -z "$artifact_staging" || ! -d "$artifact_staging" ]] || rm -rf -- "$artifact_staging"
    [[ -z "$requested_config" || ! -f "$requested_config" ]] || rm -f -- "$requested_config"
    if [[ -n "$previous_output" && -e "$previous_output" ]]; then
        if [[ ! -e "$output_dir" && ! -L "$output_dir" ]]; then
            mv -- "$previous_output" "$output_dir" || true
        else
            rm -rf -- "$previous_output"
        fi
    fi
    if [[ -n "$SOURCE_PATH" && \
          ( -e "$SOURCE_PATH/.git" || -d "$SOURCE_PATH" ) ]]; then
        if [[ ${KEEP_BUILD:-0} == 1 ]]; then
            printf 'Preserved source worktree: %s\n' "$SOURCE_PATH"
        else
            if ! git -C "$SOURCE_REPOSITORY" worktree remove --force "$SOURCE_PATH"; then
                rm -rf -- "$SOURCE_PATH"
                git -C "$SOURCE_REPOSITORY" worktree prune || true
            fi
        fi
    fi
    flock -u "$source_repository_lock_fd" || true
}
trap cleanup_source_build EXIT

SOURCE_PATH=$(mktemp -d "$source_build_parent/$TARGET_NAME-$PRESET_NAME.XXXXXXXX")
rmdir -- "$SOURCE_PATH"
git -C "$SOURCE_REPOSITORY" worktree add --detach "$SOURCE_PATH" "$IMMORTALWRT_COMMIT"
ln -s -- "$source_download_cache" "$SOURCE_PATH/dl"
source_files="$SOURCE_PATH/files"

# Fail on missing host headers/tools before spending time cloning and indexing
# five fixed feeds.  The feeds scanner invokes this same prerequisite target,
# but only after network work unless we make it explicit here.
make -s -C "$SOURCE_PATH" prepare-mk

seed_locked_feed_checkouts() {
    local feed_seed_root=${SOURCE_FEED_SEED_DIR:-"$SOURCE_REPOSITORY/feeds"}
    local feed_name _feed_type feed_url feed_commit _feed_extra seed_dir feed_dir

    [[ "$SOURCE_FEED_CACHE_MODE" == auto && -d "$feed_seed_root" ]] || return 0
    mkdir -p "$SOURCE_PATH/feeds"
    while IFS='|' read -r feed_name _feed_type feed_url feed_commit _feed_extra; do
        [[ -n "$feed_name" && ${feed_name:0:1} != '#' ]] || continue
        seed_dir="$feed_seed_root/$feed_name"
        feed_dir="$SOURCE_PATH/feeds/$feed_name"
        [[ ! -e "$feed_dir" && -d "$seed_dir/.git" ]] || continue
        [[ $(git -C "$seed_dir" remote get-url origin 2>/dev/null || true) == \
            "$feed_url" ]] || continue
        git -C "$seed_dir" cat-file -e "$feed_commit^{commit}" 2>/dev/null || continue

        git clone --quiet --shared --no-checkout "$seed_dir" "$feed_dir"
        git -C "$feed_dir" remote set-url origin "$feed_url"
        git -C "$feed_dir" -c advice.detachedHead=false checkout --quiet --detach \
            "$feed_commit"
        mkdir -p "$SOURCE_PATH/feeds/$feed_name.tmp"
        printf '%s^%s\n' "$feed_url" "$feed_commit" \
            > "$SOURCE_PATH/feeds/$feed_name.tmp/location"
    done < "$FEED_LOCK"
}

discard_incomplete_feed_checkouts() {
    local feed_name _feed_type feed_url feed_commit _feed_extra feed_dir
    local actual_commit actual_origin
    while IFS='|' read -r feed_name _feed_type feed_url feed_commit _feed_extra; do
        [[ -n "$feed_name" && ${feed_name:0:1} != '#' ]] || continue
        feed_dir="$SOURCE_PATH/feeds/$feed_name"
        actual_commit=
        actual_origin=
        if [[ -d "$feed_dir/.git" ]]; then
            actual_commit=$(git -C "$feed_dir" rev-parse HEAD 2>/dev/null || true)
            actual_origin=$(git -C "$feed_dir" remote get-url origin 2>/dev/null || true)
        fi
        if [[ -e "$feed_dir" && \
              ( "$actual_commit" != "$feed_commit" || "$actual_origin" != "$feed_url" ) ]]; then
            rm -rf -- "$feed_dir" "$SOURCE_PATH/feeds/$feed_name.tmp"
        fi
    done < "$FEED_LOCK"
}

verify_feed_checkouts() {
    local feed_name _feed_type feed_url feed_commit _feed_extra feed_dir
    local actual_commit actual_origin
    while IFS='|' read -r feed_name _feed_type feed_url feed_commit _feed_extra; do
        [[ -n "$feed_name" && ${feed_name:0:1} != '#' ]] || continue
        feed_dir="$SOURCE_PATH/feeds/$feed_name"
        [[ -d "$feed_dir/.git" ]] || die "feed checkout is missing: $feed_name"
        actual_commit=$(git -C "$feed_dir" rev-parse HEAD)
        actual_origin=$(git -C "$feed_dir" remote get-url origin)
        [[ "$actual_commit" == "$feed_commit" ]] || \
            die "feed $feed_name is at $actual_commit, expected $feed_commit"
        [[ "$actual_origin" == "$feed_url" ]] || \
            die "feed $feed_name has unexpected origin: $actual_origin"
    done < "$FEED_LOCK"
}

seed_locked_feed_checkouts
feed_update_ok=0
for ((feed_attempt = 1; feed_attempt <= SOURCE_FEED_RETRIES; feed_attempt++)); do
    if (
        cd "$SOURCE_PATH"
        GIT_HTTP_LOW_SPEED_LIMIT=1024 GIT_HTTP_LOW_SPEED_TIME=120 \
            ./scripts/feeds update -a
    ); then
        feed_update_ok=1
        break
    fi
    discard_incomplete_feed_checkouts
    if (( feed_attempt < SOURCE_FEED_RETRIES )); then
        printf 'Feed update attempt %d/%d failed; retrying incomplete locked checkouts\n' \
            "$feed_attempt" "$SOURCE_FEED_RETRIES" >&2
    fi
done
(( feed_update_ok == 1 )) || die "locked feed update failed after $SOURCE_FEED_RETRIES attempts"
verify_feed_checkouts
(
    cd "$SOURCE_PATH"
    ./scripts/feeds install -a
)

SOURCE_PATH="$SOURCE_PATH" "$SOURCE_SCRIPTS_DIR/apply-source-config.sh" \
    "$TARGET_NAME" "$PRESET_NAME"
requested_config=$(mktemp)
cp -- "$SOURCE_PATH/.config" "$requested_config"

make -C "$SOURCE_PATH" defconfig

while IFS= read -r requested; do
    grep -Fqx -- "$requested" "$SOURCE_PATH/.config" || die "defconfig dropped requested symbol: $requested"
done < <(grep -E '^CONFIG_(TARGET|GRUB|ALL_KMODS|PACKAGE_).*=y$' "$requested_config")
grep -Fqx "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" "$SOURCE_PATH/.config" || \
    die "defconfig changed the rootfs partition size"
grep -Fqx 'CONFIG_TARGET_ROOTFS_SQUASHFS=y' "$SOURCE_PATH/.config" || \
    die 'defconfig disabled SquashFS'
grep -Fqx '# CONFIG_TARGET_ROOTFS_EXT4FS is not set' "$SOURCE_PATH/.config" || \
    die 'defconfig enabled ext4 output'
grep -Fqx '# CONFIG_TARGET_ROOTFS_TARGZ is not set' "$SOURCE_PATH/.config" || \
    die 'defconfig enabled tar rootfs output'
if [[ "$SOURCE_KMOD_SCOPE" == all ]]; then
    grep -Fqx 'CONFIG_ALL_KMODS=y' "$SOURCE_PATH/.config" || \
        die 'defconfig dropped diagnostic ALL_KMODS scope'
else
    grep -Fqx '# CONFIG_ALL_KMODS is not set' "$SOURCE_PATH/.config" || \
        die 'defconfig enabled ALL_KMODS outside diagnostic mode'
fi
if [[ "$TARGET_NAME" == x86_64 ]]; then
    grep -Fqx 'CONFIG_TARGET_KERNEL_PARTSIZE=32' "$SOURCE_PATH/.config" || \
        die 'defconfig changed x86 boot partition size'
    grep -Fqx 'CONFIG_GRUB_EFI_IMAGES=y' "$SOURCE_PATH/.config" || \
        die 'defconfig disabled x86 UEFI output'
    grep -Fqx '# CONFIG_GRUB_IMAGES is not set' "$SOURCE_PATH/.config" || \
        die 'defconfig enabled x86 legacy GRUB output'
else
    grep -Fqx 'CONFIG_TARGET_KERNEL_PARTSIZE=64' "$SOURCE_PATH/.config" || \
        die 'defconfig changed Raspberry Pi boot partition size'
fi

if (( check_only == 1 )); then
    printf 'defconfig validation completed for %s/%s\n' "$TARGET_NAME" "$PRESET_NAME"
    exit 0
fi

# A full buildroot reads custom rootfs files only from $(TOPDIR)/files. Attach
# this repository's static data overlay as an untracked symlink for the build.
source_files="$SOURCE_PATH/files"
[[ ! -e "$source_files" && ! -L "$source_files" ]] || \
    die "$source_files already exists; refusing to overwrite a source overlay"
ln -s -- "$PROJECT_ROOT/files" "$source_files"

make -C "$SOURCE_PATH" download -j"$JOBS"
bad_download=$(find -L "$SOURCE_PATH/dl" -type f -size -1024c -print -quit)
[[ -z "$bad_download" ]] || die "download smaller than 1 KiB: $bad_download"

if ! make -C "$SOURCE_PATH" -j"$JOBS"; then
    if (( SOURCE_FAILURE_DIAGNOSTICS == 1 )); then
        printf 'Parallel build failed; running a single-thread diagnostic pass.\n' >&2
        make -C "$SOURCE_PATH" -j1 V=sc || true
    fi
    exit 1
fi

embedded_asu=
while IFS= read -r candidate; do
    if cmp -s "$PROJECT_ROOT/files/etc/config/attendedsysupgrade" "$candidate"; then
        embedded_asu=$candidate
        break
    fi
done < <(find "$SOURCE_PATH/build_dir" -path '*/root-*/etc/config/attendedsysupgrade' -type f -print)
[[ -n "$embedded_asu" ]] || die "static attendedsysupgrade config was not embedded"
embedded_root=${embedded_asu%/etc/config/attendedsysupgrade}
embedded_uhttpd="$embedded_root/etc/config/uhttpd"
[[ -s "$embedded_uhttpd" ]] || die "static HTTPS uhttpd config was not embedded"
cmp -s "$PROJECT_ROOT/files/etc/config/uhttpd" "$embedded_uhttpd" || \
    die "embedded uhttpd config differs from the locked static file"

bin_dir="$SOURCE_PATH/bin/targets/$TARGET/$SUBTARGET"
output_dir=$(realpath -m -- \
    "${OUTPUT_DIR:-"$PROJECT_ROOT/out/$IMMORTALWRT_VERSION/source/$TARGET_NAME/$PRESET_NAME"}")
case "$output_dir" in
    / | "$PROJECT_ROOT" | "$(dirname -- "$PROJECT_ROOT")")
        die "unsafe output directory: $output_dir"
        ;;
esac
output_parent=$(dirname -- "$output_dir")
mkdir -p "$output_parent"
artifact_staging=$(mktemp -d "$output_parent/.$PRESET_NAME.XXXXXXXX")
shopt -s nullglob

case "$TARGET_NAME" in
    x86_64)
        images=("$bin_dir"/*-squashfs-combined-efi.img.gz)
        ;;
    rpi4)
        factory_images=("$bin_dir"/*-rpi-4-squashfs-factory.img.gz)
        sysupgrade_images=("$bin_dir"/*-rpi-4-squashfs-sysupgrade.img.gz)
        [[ ${#factory_images[@]} -eq 1 && ${#sysupgrade_images[@]} -eq 1 ]] || \
            die "source build did not create exactly one Pi 4 factory and sysupgrade image"
        images=("${factory_images[@]}" "${sysupgrade_images[@]}")
        ;;
    rpi5)
        factory_images=("$bin_dir"/*-rpi-5-squashfs-factory.img.gz)
        sysupgrade_images=("$bin_dir"/*-rpi-5-squashfs-sysupgrade.img.gz)
        [[ ${#factory_images[@]} -eq 1 && ${#sysupgrade_images[@]} -eq 1 ]] || \
            die "source build did not create exactly one Pi 5 factory and sysupgrade image"
        images=("${factory_images[@]}" "${sysupgrade_images[@]}")
        ;;
esac
expected_images=1
[[ "$TARGET_NAME" == x86_64 ]] || expected_images=2
[[ ${#images[@]} -eq $expected_images ]] || die "source build did not create the complete requested image set"
cp -- "${images[@]}" "$artifact_staging/"

for item in "$bin_dir"/*.manifest "$bin_dir"/profiles.json "$bin_dir"/config.buildinfo \
            "$bin_dir"/feeds.buildinfo "$bin_dir"/version.buildinfo; do
    [[ -f "$item" ]] && cp -- "$item" "$artifact_staging/"
done
cp -- "$SOURCE_PATH/.config" "$artifact_staging/source.config"

[[ -s "$artifact_staging/profiles.json" ]] || die 'source build did not emit profiles.json'
read -r source_kernel_version source_kernel_release source_kernel_vermagic < <(
    python3 - "$artifact_staging/profiles.json" <<'PY'
import json
from pathlib import Path
import sys

metadata = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
kernel = metadata.get("linux_kernel")
if not isinstance(kernel, dict):
    raise SystemExit("source profiles.json has no linux_kernel metadata")
print(kernel.get("version", ""), kernel.get("release", ""), kernel.get("vermagic", ""))
PY
)
[[ "$source_kernel_version" == "$IMMORTALWRT_KERNEL_VERSION" ]] || \
    die "source kernel version changed: $source_kernel_version"
[[ "$source_kernel_release" == "$IMMORTALWRT_KERNEL_RELEASE" ]] || \
    die "source kernel release changed: $source_kernel_release"
[[ "$source_kernel_vermagic" =~ ^[0-9a-f]{32}$ ]] || \
    die "source profiles.json has invalid kernel vermagic: $source_kernel_vermagic"

package_list_names=()
while IFS= read -r package_file; do
    package_list_names+=("${package_file#"$PROJECT_ROOT/"}")
done < <(preset_package_files)
package_list_csv=$(IFS=,; printf '%s' "${package_list_names[*]}")
project_commit=$(project_revision)
build_config_sha256=$(sha256sum "$BUILD_CONFIG_FILE" | awk '{ print $1 }')
{
    printf 'build_mode=source\n'
    printf 'release_channel=stable\n'
    printf 'canonical_build=0\n'
    printf 'candidate_build=0\n'
    printf 'development_build=1\n'
    printf 'release=%s\n' "$IMMORTALWRT_VERSION"
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
    printf 'kernel_version=%s\n' "$source_kernel_version"
    printf 'kernel_release=%s\n' "$source_kernel_release"
    printf 'kernel_vermagic=%s\n' "$source_kernel_vermagic"
    printf 'official_imagebuilder_kernel_vermagic=%s\n' "$KERNEL_VERMAGIC"
    printf 'rootfs_partsize_mb=%s\n' "$ROOTFS_PARTSIZE"
    printf 'nominal_media_bytes=%s\n' "$NOMINAL_MEDIA_BYTES"
    printf 'package_lists=%s\n' "$package_list_csv"
    printf 'extra_packages=%s\n' "${EXTRA_PACKAGES:-}"
    printf 'warning=Use only kmods produced by this exact source build unless ABI identity is independently verified.\n'
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
publish_lock="$output_parent/.$TARGET_NAME-$PRESET_NAME-source.publish.lock"
require_regular_file_or_absent "$publish_lock" 'source artifact publish lock'
exec {publish_lock_fd}>"$publish_lock"
flock "$publish_lock_fd"
previous_output=$(mktemp -d "$output_parent/.previous-source-$TARGET_NAME-$PRESET_NAME.XXXXXXXX")
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
    die "failed to publish verified source output directory"
fi
flock -u "$publish_lock_fd"
printf 'Source-built firmware is in %s\n' "$output_dir"
