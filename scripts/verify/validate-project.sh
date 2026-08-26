#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

load_build_config
load_release_lock
require_command python3
validate_feed_lock
[[ -r "$LOCKS_DIR/README.md" ]] || die 'missing lock contract documentation'
validate_package_snapshot_lock

expected_lock_files=$(printf '%s\n' \
    README.md artifacts.tsv feeds.tsv package-manifests.tsv release.env targets.tsv \
    manifests/rpi4-full.manifest manifests/rpi4-minimal.manifest \
    manifests/rpi5-full.manifest manifests/rpi5-minimal.manifest \
    manifests/x86_64-full.manifest manifests/x86_64-minimal.manifest \
    package-snapshots.tsv)
expected_lock_files=$(printf '%s\n' "$expected_lock_files" | sort)
actual_lock_files=$(find "$LOCKS_DIR" -mindepth 1 -type f -printf '%P\n' | sort)
[[ "$actual_lock_files" == "$expected_lock_files" ]] || \
    die 'lock directory has missing or unexpected files'
unexpected_lock_node=$(find "$LOCKS_DIR" -mindepth 1 ! -type d ! -type f -print -quit)
[[ -z "$unexpected_lock_node" ]] || die "lock directory has an unsafe node: $unexpected_lock_node"
actual_lock_dirs=$(find "$LOCKS_DIR" -mindepth 1 -type d -printf '%P\n' | sort)
[[ "$actual_lock_dirs" == manifests ]] || die 'lock directory has an unexpected subdirectory'

expected_script_dirs=$(printf '%s\n' build cache inputs lib locks source verify | sort)
actual_script_dirs=$(find "$SCRIPTS_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
[[ "$actual_script_dirs" == "$expected_script_dirs" ]] || \
    die 'scripts/ must contain exactly the documented production categories'
actual_script_root_files=$(find "$SCRIPTS_ROOT" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
[[ "$actual_script_root_files" == README.md ]] || \
    die 'only scripts/README.md may live outside a production script category'
for nightly_input_tool in extract-nightly-build-context.py \
                          restore-nightly-inputs.sh; do
    nightly_input_path="$INPUT_SCRIPTS_DIR/$nightly_input_tool"
    [[ -f "$nightly_input_path" && ! -L "$nightly_input_path" && \
       -x "$nightly_input_path" ]] || \
        die "nightly durable-input tool is missing or unsafe: $nightly_input_tool"
done

expected_test_dirs=$(printf '%s\n' component contract | sort)
actual_test_dirs=$(find "$PROJECT_ROOT/tests" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
[[ "$actual_test_dirs" == "$expected_test_dirs" ]] || \
    die 'tests/ must contain exactly the component and contract categories'
expected_test_root_files=$(printf '%s\n' README.md run-build.sh run.sh | sort)
actual_test_root_files=$(find "$PROJECT_ROOT/tests" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
[[ "$actual_test_root_files" == "$expected_test_root_files" ]] || \
    die 'tests/ has a missing or unexpected top-level file'

unexpected_code_node=$(find "$SCRIPTS_ROOT" "$PROJECT_ROOT/tests" -mindepth 1 \
    ! -type d ! -type f -print -quit)
[[ -z "$unexpected_code_node" ]] || die "script/test tree has an unsafe node: $unexpected_code_node"
misplaced_test=$(find "$SCRIPTS_ROOT" -type f \
    \( -name 'test-*.sh' -o -name '*-test.sh' \) -print -quit)
[[ -z "$misplaced_test" ]] || die "test belongs below tests/, not scripts/: $misplaced_test"

mapfile -d '' python_scripts < <(
    find "$SCRIPTS_ROOT" "$PROJECT_ROOT/tests" -type f -name '*.py' -print0 | sort -z
)
(( ${#python_scripts[@]} > 0 )) || die 'no Python verifier scripts found'
python3 - "${python_scripts[@]}" <<'PY'
from pathlib import Path
import sys

for name in sys.argv[1:]:
    source = Path(name).read_bytes()
    compile(source, name, "exec")
PY

for target in x86_64 rpi4 rpi5; do
    load_target_lock "$target"
    for preset in minimal full; do
        load_preset "$preset"
        load_package_manifest_lock
        load_artifact_locks
        read_preset_packages >/dev/null
    done
done

load_target_lock x86_64
load_preset minimal
EXTRA_PACKAGES=kmod-ice validate_extra_packages
if (EXTRA_PACKAGES=luci-app-passwall; validate_extra_packages) >/dev/null 2>&1; then
    die "EXTRA_PACKAGES accepted an application outside the reviewed driver lists"
fi

[[ $(grep -Evc '^[[:space:]]*(#|$)' "$TARGET_LOCK") -eq 3 ]] || \
    die "target lock must contain exactly three targets"
[[ $(grep -Evc '^[[:space:]]*(#|$)' "$PACKAGE_MANIFEST_LOCK") -eq 6 ]] || \
    die "package manifest lock must contain exactly six target/preset rows"
[[ $(grep -Evc '^[[:space:]]*(#|$)' "$ARTIFACT_LOCK") -eq 10 ]] || \
    die "artifact lock must contain exactly ten canonical images"

for build_config in "$CONFIGS_DIR"/build.env "$CONFIGS_DIR"/build-debug.env \
                    "$CONFIGS_DIR"/build-refresh.env \
                    "$CONFIGS_DIR"/build-nightly.env; do
    (
        unset CHECK_LATEST_ON_BUILD ARTIFACT_LOCK_POLICY PACKAGE_REPOSITORY_MODE \
            PACKAGE_CACHE_INDEX \
            SOURCE_FETCH_MODE SOURCE_FETCH_POLICY SOURCE_KMOD_SCOPE \
            SOURCE_FEED_CACHE_MODE SOURCE_FAILURE_DIAGNOSTICS RUN_X86_SMOKE_TEST REQUIRE_CLEAN_PROJECT \
            REQUIRE_SHELLCHECK KEEP_BUILD IMAGEBUILDER_RETRIES SOURCE_FEED_RETRIES \
            NETWORK_PROXY_MODE
        BUILD_CONFIG=$build_config load_build_config
    )
done

assert_build_policy() (
    local policy_file=${1:?policy file required}
    shift
    local expected key value
    unset CHECK_LATEST_ON_BUILD ARTIFACT_LOCK_POLICY PACKAGE_REPOSITORY_MODE \
        PACKAGE_CACHE_INDEX SOURCE_FETCH_MODE SOURCE_FETCH_POLICY \
        SOURCE_KMOD_SCOPE SOURCE_FEED_CACHE_MODE SOURCE_FAILURE_DIAGNOSTICS \
        RUN_X86_SMOKE_TEST REQUIRE_CLEAN_PROJECT REQUIRE_SHELLCHECK KEEP_BUILD \
        IMAGEBUILDER_RETRIES SOURCE_FEED_RETRIES NETWORK_PROXY_MODE
    BUILD_CONFIG="$policy_file" load_build_config
    for expected in "$@"; do
        key=${expected%%=*}
        value=${expected#*=}
        [[ ${!key} == "$value" ]] || \
            die "build policy $policy_file must set $expected"
    done
)

assert_build_policy "$CONFIGS_DIR/build.env" \
    CHECK_LATEST_ON_BUILD=0 ARTIFACT_LOCK_POLICY=enforce \
    PACKAGE_REPOSITORY_MODE=snapshot PACKAGE_CACHE_INDEX=0 \
    SOURCE_FETCH_MODE=locked SOURCE_FETCH_POLICY=if-missing \
    SOURCE_FEED_CACHE_MODE=auto SOURCE_KMOD_SCOPE=preset \
    SOURCE_FAILURE_DIAGNOSTICS=0 RUN_X86_SMOKE_TEST=1 \
    REQUIRE_CLEAN_PROJECT=1 REQUIRE_SHELLCHECK=1 KEEP_BUILD=0 \
    IMAGEBUILDER_RETRIES=3 SOURCE_FEED_RETRIES=3 NETWORK_PROXY_MODE=direct
assert_build_policy "$CONFIGS_DIR/build-debug.env" \
    CHECK_LATEST_ON_BUILD=0 ARTIFACT_LOCK_POLICY=enforce \
    PACKAGE_REPOSITORY_MODE=live PACKAGE_CACHE_INDEX=1 \
    SOURCE_FETCH_MODE=full SOURCE_FETCH_POLICY=always \
    SOURCE_FEED_CACHE_MODE=off SOURCE_KMOD_SCOPE=all \
    SOURCE_FAILURE_DIAGNOSTICS=1 RUN_X86_SMOKE_TEST=1 \
    REQUIRE_CLEAN_PROJECT=0 REQUIRE_SHELLCHECK=0 KEEP_BUILD=1 \
    IMAGEBUILDER_RETRIES=3 SOURCE_FEED_RETRIES=3 NETWORK_PROXY_MODE=inherit
assert_build_policy "$CONFIGS_DIR/build-refresh.env" \
    CHECK_LATEST_ON_BUILD=0 ARTIFACT_LOCK_POLICY=record \
    PACKAGE_REPOSITORY_MODE=live PACKAGE_CACHE_INDEX=1 \
    SOURCE_FETCH_MODE=locked SOURCE_FETCH_POLICY=if-missing \
    SOURCE_FEED_CACHE_MODE=auto SOURCE_KMOD_SCOPE=preset \
    SOURCE_FAILURE_DIAGNOSTICS=0 RUN_X86_SMOKE_TEST=1 \
    REQUIRE_CLEAN_PROJECT=0 REQUIRE_SHELLCHECK=1 KEEP_BUILD=0 \
    IMAGEBUILDER_RETRIES=3 SOURCE_FEED_RETRIES=3 NETWORK_PROXY_MODE=direct
assert_build_policy "$CONFIGS_DIR/build-nightly.env" \
    CHECK_LATEST_ON_BUILD=0 ARTIFACT_LOCK_POLICY=record \
    PACKAGE_REPOSITORY_MODE=live PACKAGE_CACHE_INDEX=1 \
    SOURCE_FETCH_MODE=locked SOURCE_FETCH_POLICY=if-missing \
    SOURCE_FEED_CACHE_MODE=auto SOURCE_KMOD_SCOPE=preset \
    SOURCE_FAILURE_DIAGNOSTICS=0 RUN_X86_SMOKE_TEST=1 \
    REQUIRE_CLEAN_PROJECT=0 REQUIRE_SHELLCHECK=1 KEEP_BUILD=0 \
    IMAGEBUILDER_RETRIES=3 SOURCE_FEED_RETRIES=3 NETWORK_PROXY_MODE=direct

mapfile -d '' shell_scripts < <(
    find "$SCRIPTS_ROOT" "$PROJECT_ROOT/tests" -type f -name '*.sh' -print0 | sort -z
)
(( ${#shell_scripts[@]} > 0 )) || die 'no shell scripts found'
for script in "${shell_scripts[@]}"; do
    bash -n "$script"
    [[ -x "$script" ]] || die "shell entry point is not executable: $script"
done

runtime_installer=$(find "$SCRIPTS_ROOT" -type f -name install-runtime.sh -print -quit)
[[ -z "$runtime_installer" ]] || die "device-side installer must not exist: $runtime_installer"
[[ ! -d "$PROJECT_ROOT/files/etc/uci-defaults" ]] || die "device-side uci-default scripts are forbidden"
device_executable=$(find "$PROJECT_ROOT/files" -type f -perm /111 -print -quit)
[[ -z "$device_executable" ]] || die "device overlay contains an executable script: $device_executable"

asu_config="$PROJECT_ROOT/files/etc/config/attendedsysupgrade"
[[ -r "$asu_config" ]] || die "missing static attendedsysupgrade configuration"
grep -Eq "^[[:space:]]+option url 'https://sysupgrade[.]immortalwrt[.]org'$" "$asu_config" || \
    die "unexpected ImmortalWrt ASU URL"
grep -Eq "^[[:space:]]+option rootfs_size '$ROOTFS_PARTSIZE'$" "$asu_config" || \
    die "ASU rootfs size differs from the image lock"

uhttpd_config="$PROJECT_ROOT/files/etc/config/uhttpd"
[[ -r "$uhttpd_config" ]] || die "missing static HTTPS uhttpd configuration"
grep -Eq '^[[:space:]]+list listen_http[[:space:]]+0[.]0[.]0[.]0:80$' "$uhttpd_config" || \
    die "uhttpd IPv4 HTTP listener is missing"
grep -Eq '^[[:space:]]+list listen_https[[:space:]]+0[.]0[.]0[.]0:443$' "$uhttpd_config" || \
    die "uhttpd IPv4 HTTPS listener is missing"
grep -Eq '^[[:space:]]+list listen_https[[:space:]]+\[::\]:443$' "$uhttpd_config" || \
    die "uhttpd IPv6 HTTPS listener is missing"
grep -Eq '^[[:space:]]+option redirect_https[[:space:]]+1$' "$uhttpd_config" || \
    die "uhttpd HTTP-to-HTTPS redirect is disabled"

for target in x86_64 rpi4 rpi5; do
    config="$CONFIGS_DIR/$target.config"
    [[ -r "$config" ]] || die "missing source config for $target"
    grep -Fqx "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" "$config" || \
        die "rootfs size mismatch in $config"
    grep -Fqx 'CONFIG_TARGET_ROOTFS_SQUASHFS=y' "$config" || die "SquashFS disabled in $config"
    grep -Fqx '# CONFIG_TARGET_ROOTFS_EXT4FS is not set' "$config" || die "ext4 enabled in $config"
    grep -Fqx '# CONFIG_TARGET_ROOTFS_TARGZ is not set' "$config" || die "tar rootfs enabled in $config"
    if grep -Eq '^CONFIG_ALL_KMODS=' "$config"; then
        die "ALL_KMODS belongs to the selected build policy, not $config"
    fi
    if grep -Eq '^CONFIG_PACKAGE_.*=[ym]$' "$config"; then
        die "package selections belong in packages/*.txt, not $config"
    fi
    generated_config=$(mktemp)
    "$BUILD_SCRIPTS_DIR/render-source-config.sh" "$target" > "$generated_config"
    cmp -s "$generated_config" "$config" || {
        diff -u "$config" "$generated_config" >&2 || true
        rm -f -- "$generated_config"
        die "source config is not the generated form: $config"
    }
    rm -f -- "$generated_config"
done

grep -Fqx 'CONFIG_TARGET_x86_64_DEVICE_generic=y' "$CONFIGS_DIR/x86_64.config" || die "bad x86 config"
grep -Fqx 'CONFIG_TARGET_KERNEL_PARTSIZE=32' "$CONFIGS_DIR/x86_64.config" || die "bad x86 boot partition"
grep -Fqx 'CONFIG_GRUB_EFI_IMAGES=y' "$CONFIGS_DIR/x86_64.config" || die "x86 UEFI image disabled"
grep -Fqx '# CONFIG_GRUB_IMAGES is not set' "$CONFIGS_DIR/x86_64.config" || die "x86 BIOS image enabled"
grep -Fqx 'CONFIG_TARGET_bcm27xx_bcm2711_DEVICE_rpi-4=y' "$CONFIGS_DIR/rpi4.config" || die "bad Pi 4 config"
grep -Fqx 'CONFIG_TARGET_bcm27xx_bcm2712_DEVICE_rpi-5=y' "$CONFIGS_DIR/rpi5.config" || die "bad Pi 5 config"
grep -Fqx 'CONFIG_TARGET_KERNEL_PARTSIZE=64' "$CONFIGS_DIR/rpi4.config" || die "bad Pi 4 boot partition"
grep -Fqx 'CONFIG_TARGET_KERNEL_PARTSIZE=64' "$CONFIGS_DIR/rpi5.config" || die "bad Pi 5 boot partition"

package_lists=(
    "$PROJECT_ROOT/packages/base-image.txt"
    "$PROJECT_ROOT/packages/runtime-apps.txt"
    "$PROJECT_ROOT/packages/full-drivers-common.txt"
    "$PROJECT_ROOT/packages/full-drivers-x86_64.txt"
    "$PROJECT_ROOT/packages/full-drivers-rpi4.txt"
    "$PROJECT_ROOT/packages/full-drivers-rpi5.txt"
)
for package_list in "${package_lists[@]}"; do
    [[ -r "$package_list" ]] || die "missing package list: $package_list"
    normalized_packages=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$package_list")
    if printf '%s\n' "$normalized_packages" | grep -Evq '^[a-z0-9][a-z0-9+._-]*$'; then
        die "invalid package name in $package_list"
    fi
    duplicate_package=$(printf '%s\n' "$normalized_packages" | sort | uniq -d \
        | awk 'first == "" { first = $0 } END { if (first != "") print first }')
    [[ -z "$duplicate_package" ]] || die "duplicate package in $package_list: $duplicate_package"
done

locked_manifest_has_package() {
    local manifest=${1:?manifest required}
    local package=${2:?package required}
    awk -v package="$package" \
        '$1 == package && $2 == "-" { found = 1 } END { exit !found }' "$manifest"
}

# Catch package-list drift during `make test`, before paying for six image
# builds. The raw manifest remains the authoritative resolved dependency set;
# this checks that every requested top-level package is present and every
# post-flash-only LuCI application remains absent.
for target in x86_64 rpi4 rpi5; do
    load_target_lock "$target"
    for preset in minimal full; do
        load_preset "$preset"
        load_package_manifest_lock
        while IFS= read -r package_file; do
            while IFS= read -r required_package; do
                locked_manifest_has_package "$EXPECTED_MANIFEST_FILE" "$required_package" || \
                    die "$target/$preset lock is missing requested package: $required_package"
            done < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$package_file")
        done < <(preset_package_files)
        while IFS= read -r runtime_package; do
            if locked_manifest_has_package "$EXPECTED_MANIFEST_FILE" "$runtime_package"; then
                die "$target/$preset lock embeds runtime-only package: $runtime_package"
            fi
        done < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
            "$PROJECT_ROOT/packages/runtime-apps.txt")
    done
done

runtime_sorted=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
    "$PROJECT_ROOT/packages/runtime-apps.txt" | sort)
for target in x86_64 rpi4 rpi5; do
    load_target_lock "$target"
    load_preset full
    full_sorted=$(read_preset_packages | tr ' ' '\n' | sort)
    overlap=$(comm -12 <(printf '%s\n' "$runtime_sorted") <(printf '%s\n' "$full_sorted"))
    [[ -z "$overlap" ]] || die "runtime applications leaked into $target/full: $overlap"

    duplicate_package=$(while IFS= read -r list; do
        sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$list"
    done < <(preset_package_files) | sort | uniq -d \
        | awk 'first == "" { first = $0 } END { if (first != "") print first }')
    [[ -z "$duplicate_package" ]] || die "duplicate package in $target/full: $duplicate_package"
done

x86_drivers="$PROJECT_ROOT/packages/full-drivers-x86_64.txt"
rpi4_drivers="$PROJECT_ROOT/packages/full-drivers-rpi4.txt"
rpi5_drivers="$PROJECT_ROOT/packages/full-drivers-rpi5.txt"
for forbidden in kmod-r8169 kmod-usb-net-rtl8152; do
    ! grep -Fqx "$forbidden" "$x86_drivers" || die "x86 Realtek conflict: $forbidden"
done
for rpi_drivers in "$rpi4_drivers" "$rpi5_drivers"; do
    for forbidden in kmod-r8101 kmod-r8168 kmod-r8125 kmod-r8126 kmod-r8127 \
                     kmod-usb-net-rtl8152-vendor kmod-hinic; do
        ! grep -Fqx "$forbidden" "$rpi_drivers" || die "Raspberry Pi driver conflict: $forbidden"
    done
done
cmp -s "$rpi4_drivers" "$rpi5_drivers" || die "Pi 4 and Pi 5 Realtek policy drifted"

# Locked partition declarations must fit a decimal 4 GB device, not merely a
# 4 GiB test disk.  Pi has the larger end offset and is therefore the bound.
x86_declared_end=$(( (66048 + ROOTFS_PARTSIZE * 2048) * 512 ))
pi_declared_end=$(( (147456 + ROOTFS_PARTSIZE * 2048) * 512 ))
(( x86_declared_end < NOMINAL_MEDIA_BYTES )) || die "x86 partition layout exceeds 4 GB"
(( pi_declared_end < NOMINAL_MEDIA_BYTES )) || die "Pi partition layout exceeds 4 GB"

while IFS= read -r runtime_package; do
    grep -Fq "$runtime_package" "$PROJECT_ROOT/README.md" || die "README is missing $runtime_package"
done <<< "$runtime_sorted"
# The dollar sign below is a regular-expression anchor, not shell expansion.
# shellcheck disable=SC2016
if grep -En 'install-runtime|(^|[[:space:]`])(ssh|scp|apk[[:space:]]+(add|del|upgrade)|uci[[:space:]]|modprobe|dmesg)([[:space:]`]|$)' \
        "$PROJECT_ROOT/README.md"; then
    die "README contains a forbidden post-flash command; use LuCI instructions only"
fi

mapfile -d '' execution_files < <(
    find "$SCRIPTS_ROOT" "$PROJECT_ROOT/tests" "$PROJECT_ROOT/.github" -type f \
        \( -name '*.sh' -o -name '*.yml' -o -name '*.yaml' \) \
        ! -path "$SCRIPT_DIR/validate-project.sh" -print0 | sort -z
)
if (( ${#execution_files[@]} > 0 )) && unsafe_output=$(grep -nHE \
        'curl[^|]*\|[[:space:]]*(sh|bash)|wget[^|]*\|[[:space:]]*(sh|bash)|--allow-untrusted' \
        "${execution_files[@]}" 2>/dev/null); then
    printf '%s\n' "$unsafe_output" >&2
    die 'unsafe download/execution pattern found'
fi

uses_lines=$(grep -REn '^[[:space:]]*uses:' "$PROJECT_ROOT/.github/workflows" 2>/dev/null || true)
unpinned_uses=$(printf '%s\n' "$uses_lines" \
    | grep -Ev 'uses:[[:space:]]+\./\.github/workflows/[A-Za-z0-9._/-]+[.]ya?ml([[:space:]]+#.*)?$' \
    | grep -Ev '@[0-9a-f]{40}([[:space:]]+#.*)?$' || true)
if [[ -n "$unpinned_uses" ]]; then
    printf '%s\n' "$unpinned_uses" >&2
    die 'every GitHub Action must be pinned to a full 40-character commit SHA'
fi

if (( REQUIRE_SHELLCHECK == 1 )); then
    require_command shellcheck
fi
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x -P SCRIPTDIR -P "$PROJECT_ROOT" -P "$PROJECT_ROOT/scripts" \
        "${shell_scripts[@]}"
fi

printf 'Static validation passed for ImmortalWrt %s (six target/preset combinations).\n' \
    "$IMMORTALWRT_VERSION"
