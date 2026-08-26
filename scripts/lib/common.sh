#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPTS_ROOT="$PROJECT_ROOT/scripts"
# These category paths are the public API of this sourced library. Each caller
# intentionally uses only the subset it needs.
# shellcheck disable=SC2034
BUILD_SCRIPTS_DIR="$SCRIPTS_ROOT/build"
# shellcheck disable=SC2034
CACHE_SCRIPTS_DIR="$SCRIPTS_ROOT/cache"
# shellcheck disable=SC2034
INPUT_SCRIPTS_DIR="$SCRIPTS_ROOT/inputs"
# shellcheck disable=SC2034
LOCK_SCRIPTS_DIR="$SCRIPTS_ROOT/locks"
# shellcheck disable=SC2034
SOURCE_SCRIPTS_DIR="$SCRIPTS_ROOT/source"
# shellcheck disable=SC2034
VERIFY_SCRIPTS_DIR="$SCRIPTS_ROOT/verify"
LOCKS_DIR=${LOCKS_DIR:-"$PROJECT_ROOT/locks"}
CONFIGS_DIR=${CONFIGS_DIR:-"$PROJECT_ROOT/configs"}
RELEASE_LOCK="$LOCKS_DIR/release.env"
TARGET_LOCK="$LOCKS_DIR/targets.tsv"
FEED_LOCK="$LOCKS_DIR/feeds.tsv"
PACKAGE_MANIFEST_LOCK="$LOCKS_DIR/package-manifests.tsv"
PACKAGE_MANIFEST_DIR="$LOCKS_DIR/manifests"
ARTIFACT_LOCK="$LOCKS_DIR/artifacts.tsv"
PACKAGE_SNAPSHOT_LOCK="$LOCKS_DIR/package-snapshots.tsv"

TARGET_LOCK_HEADER='# name|target|subtarget|profile|package_arch|imagebuilder_filename|sha256|kernel_vermagic|bytes'
PACKAGE_SNAPSHOT_LOCK_HEADER='# target|filename|sha256|bytes|tree_sha256sums_sha256'

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

array_contains_exact() {
    local wanted=${1:?value required}
    local candidate
    shift
    for candidate in "$@"; do
        [[ "$candidate" == "$wanted" ]] && return 0
    done
    return 1
}

require_regular_file_or_absent() {
    local path=${1:?path required}
    local label=${2:-file}
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" && ! -L "$path" ]] || \
            die "$label is not a regular file: $path"
    fi
}

require_assignment_columns() {
    local file=${1:?assignment file required}
    local label=${2:?assignment label required}
    require_command awk
    awk -F= '
        /^#/ || /^$/ { next }
        NF != 2 { exit 1 }
    ' "$file" || die "$label must contain exactly one KEY=VALUE assignment per data line"
}

require_pipe_columns() {
    local file=${1:?pipe-delimited file required}
    local expected=${2:?expected field count required}
    local label=${3:?pipe-delimited label required}
    require_command awk
    awk -F'|' -v expected="$expected" '
        /^#/ || /^$/ { next }
        NF != expected { exit 1 }
    ' "$file" || die "$label contains a row with the wrong number of fields"
}

require_exact_header() {
    local file=${1:?file required}
    local expected=${2:?expected header required}
    local label=${3:?header label required}
    local actual

    require_command awk
    IFS= read -r actual < "$file" || die "$label is empty: $file"
    [[ "$actual" == "$expected" ]] || die "$label has an unexpected schema header"
    awk 'NR > 1 && /^#/ { exit 1 }' "$file" || \
        die "$label contains an unexpected additional header or comment"
}

load_build_config() {
    local requested_config=${BUILD_CONFIG:-"$CONFIGS_DIR/build.env"}
    local config_file key value extra
    local seen_keys=
    local -a allowed_keys=(
        CHECK_LATEST_ON_BUILD
        ARTIFACT_LOCK_POLICY
        PACKAGE_REPOSITORY_MODE
        PACKAGE_CACHE_INDEX
        SOURCE_FETCH_MODE
        SOURCE_FETCH_POLICY
        SOURCE_FEED_CACHE_MODE
        SOURCE_KMOD_SCOPE
        SOURCE_FAILURE_DIAGNOSTICS
        RUN_X86_SMOKE_TEST
        REQUIRE_CLEAN_PROJECT
        REQUIRE_SHELLCHECK
        KEEP_BUILD
        IMAGEBUILDER_RETRIES
        SOURCE_FEED_RETRIES
        NETWORK_PROXY_MODE
    )

    if [[ "$requested_config" == /* ]]; then
        config_file=$requested_config
    else
        config_file="$PROJECT_ROOT/$requested_config"
    fi
    [[ -r "$config_file" ]] || die "missing build configuration: $config_file"
    require_assignment_columns "$config_file" 'build configuration'
    BUILD_CONFIG_FILE=$config_file
    export BUILD_CONFIG_FILE

    while IFS='=' read -r key value extra; do
        [[ -n "$key" && ${key:0:1} != '#' ]] || continue
        [[ -z "$extra" ]] || die "invalid build configuration assignment: $key"
        if ! array_contains_exact "$key" "${allowed_keys[@]}"; then
            die "unknown build configuration key: $key"
        fi
        if grep -Fqx -- "$key" <<< "$seen_keys"; then
            die "duplicate build configuration key: $key"
        fi
        seen_keys=${seen_keys:+"$seen_keys"$'\n'}$key
        [[ "$value" =~ ^[a-zA-Z0-9._/-]+$ ]] || \
            die "invalid value for build configuration key $key"
        if [[ ! -v "$key" ]]; then
            printf -v "$key" '%s' "$value"
        fi
    done < "$config_file"

    for key in CHECK_LATEST_ON_BUILD SOURCE_FAILURE_DIAGNOSTICS \
               RUN_X86_SMOKE_TEST REQUIRE_CLEAN_PROJECT REQUIRE_SHELLCHECK \
               KEEP_BUILD PACKAGE_CACHE_INDEX; do
        value=${!key:-}
        [[ "$value" == 0 || "$value" == 1 ]] || die "$key must be 0 or 1"
    done
    [[ ${SOURCE_FETCH_MODE:-} == locked || ${SOURCE_FETCH_MODE:-} == full ]] || \
        die 'SOURCE_FETCH_MODE must be locked or full'
    [[ ${ARTIFACT_LOCK_POLICY:-} == enforce || ${ARTIFACT_LOCK_POLICY:-} == record ]] || \
        die 'ARTIFACT_LOCK_POLICY must be enforce or record'
    [[ ${PACKAGE_REPOSITORY_MODE:-} == live || ${PACKAGE_REPOSITORY_MODE:-} == snapshot ]] || \
        die 'PACKAGE_REPOSITORY_MODE must be live or snapshot'
    [[ ${SOURCE_FETCH_POLICY:-} == if-missing || ${SOURCE_FETCH_POLICY:-} == always ]] || \
        die 'SOURCE_FETCH_POLICY must be if-missing or always'
    [[ ${SOURCE_FEED_CACHE_MODE:-} == auto || ${SOURCE_FEED_CACHE_MODE:-} == off ]] || \
        die 'SOURCE_FEED_CACHE_MODE must be auto or off'
    [[ ${SOURCE_KMOD_SCOPE:-} == preset || ${SOURCE_KMOD_SCOPE:-} == all ]] || \
        die 'SOURCE_KMOD_SCOPE must be preset or all'
    [[ ${NETWORK_PROXY_MODE:-} == direct || ${NETWORK_PROXY_MODE:-} == inherit ]] || \
        die 'NETWORK_PROXY_MODE must be direct or inherit'
    [[ ${IMAGEBUILDER_RETRIES:-} =~ ^[1-5]$ ]] || \
        die 'IMAGEBUILDER_RETRIES must be between 1 and 5'
    [[ ${SOURCE_FEED_RETRIES:-} =~ ^[1-5]$ ]] || \
        die 'SOURCE_FEED_RETRIES must be between 1 and 5'
}

configure_network_environment() {
    case "${NETWORK_PROXY_MODE:?load_build_config must run first}" in
        direct)
            unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
            unset GIT_PROXY_COMMAND
            # Command-scope Git configuration outranks user/system proxy and
            # TLS settings, making the production network boundary match CI.
            GIT_CONFIG_COUNT=2
            GIT_CONFIG_KEY_0=http.proxy
            GIT_CONFIG_VALUE_0=
            GIT_CONFIG_KEY_1=http.sslVerify
            GIT_CONFIG_VALUE_1=true
            export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
            export GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1
            ;;
        inherit) ;;
    esac
    GIT_TERMINAL_PROMPT=0
    export GIT_TERMINAL_PROMPT
}

project_revision() {
    local revision
    if ! revision=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null); then
        printf '%s\n' uncommitted
    elif [[ -n $(git -C "$PROJECT_ROOT" status --porcelain) ]]; then
        printf '%s-dirty\n' "$revision"
    else
        printf '%s\n' "$revision"
    fi
}

plan_input_paths() {
    local fixed directory path
    local -a fixed_inputs=(
        .gitignore
        LICENSE
        Makefile
        README.md
    )
    local -a input_directories=(
        .github
        configs
        docs
        files
        locks
        packages
        scripts
        tests
    )

    {
        for fixed in "${fixed_inputs[@]}"; do
            [[ -e "$PROJECT_ROOT/$fixed" || -L "$PROJECT_ROOT/$fixed" ]] || \
                die "missing plan input: $fixed"
            printf '%s\n' "$fixed"
        done
        for directory in "${input_directories[@]}"; do
            [[ -d "$PROJECT_ROOT/$directory" && ! -L "$PROJECT_ROOT/$directory" ]] || \
                die "missing or unsafe plan input directory: $directory"
            while IFS= read -r path; do
                case "$directory/$path" in
                    .github/*.yml | .github/*.yaml | \
                    configs/*.env | configs/*.config | \
                    docs/*.md | \
                    files/* | locks/* | packages/*.txt | \
                    scripts/*.sh | scripts/*.py | scripts/*.md | \
                    tests/*.sh | tests/*.py | tests/*.md) ;;
                    *) die "unexpected plan-input file type: $directory/$path" ;;
                esac
                printf '%s/%s\n' "$directory" "$path"
            done < <(
                find "$PROJECT_ROOT/$directory" -mindepth 1 ! -type d \
                    -printf '%P\n'
            )
        done
    } | LC_ALL=C sort -u
}

render_plan_input_manifest() {
    local path mode digest previous='' paths
    paths=$(plan_input_paths) || die 'cannot enumerate project plan inputs'
    while IFS= read -r path; do
        [[ "$path" =~ ^[A-Za-z0-9._/-]+$ && "$path" != /* && \
           "/$path/" != *'/../'* && "/$path/" != *'/./'* ]] || \
            die "unsafe plan input path: $path"
        [[ "$path" != "$previous" ]] || die "duplicate plan input path: $path"
        previous=$path
        [[ -f "$PROJECT_ROOT/$path" && ! -L "$PROJECT_ROOT/$path" ]] || \
            die "plan input is not a regular file: $path"
        mode=$(stat -c '%a' "$PROJECT_ROOT/$path")
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die "cannot record plan input mode: $path"
        digest=$(sha256sum "$PROJECT_ROOT/$path" | awk '{ print $1 }')
        printf '%s|%s|%s\n' "$mode" "$digest" "$path"
    done <<< "$paths"
}

write_plan_input_contract() {
    local manifest=${1:?plan-input manifest required}
    local revision_file=${2:?plan-input revision file required}
    render_plan_input_manifest > "$manifest"
    project_revision > "$revision_file"
}

verify_plan_input_contract() {
    local manifest=${1:?plan-input manifest required}
    local revision_file=${2:?plan-input revision file required}
    local recorded_revision current_revision expected_manifest current_manifest
    [[ -f "$manifest" && ! -L "$manifest" && -s "$manifest" ]] || \
        die "missing or unsafe plan-input manifest: $manifest"
    [[ -f "$revision_file" && ! -L "$revision_file" && -s "$revision_file" ]] || \
        die "missing or unsafe plan-input revision: $revision_file"
    awk -F'|' '
        NF != 3 || $1 !~ /^[0-7]{3,4}$/ || $2 !~ /^[0-9a-f]{64}$/ ||
        $3 !~ /^[A-Za-z0-9._\/-]+$/ || seen[$3]++ { exit 1 }
    ' "$manifest" || die 'plan-input manifest is malformed or contains duplicates'
    recorded_revision=$(sed -n '1p' "$revision_file")
    [[ $(wc -l < "$revision_file") == 1 && \
       ( "$recorded_revision" == uncommitted || \
         "$recorded_revision" =~ ^[0-9a-f]{40}(-dirty)?$ ) ]] || \
        die 'plan-input revision is malformed'
    expected_manifest=$(<"$manifest")
    current_manifest=$(render_plan_input_manifest)
    [[ "$current_manifest" == "$expected_manifest" ]] || \
        die 'project plan inputs changed after the lock candidate was generated'
    current_revision=$(project_revision)
    [[ "$current_revision" == "$recorded_revision" ]] || \
        die "project revision changed after candidate generation: $recorded_revision -> $current_revision"
}

require_clean_project_if_configured() {
    local revision
    (( REQUIRE_CLEAN_PROJECT == 1 )) || return 0
    require_command git
    revision=$(project_revision)
    [[ "$revision" != uncommitted && "$revision" != *-dirty ]] || \
        die "production build requires a committed, clean project tree (got $revision)"
}

sanitize_build_path() {
    local entry clean_path=
    local -a path_entries=()
    IFS=: read -r -a path_entries <<< "$PATH"
    for entry in "${path_entries[@]}"; do
        # OpenWrt uses find -execdir while preparing rootfs. GNU find rejects
        # relative/empty PATH elements, and WSL's inherited "Program Files"
        # entries can be split into a relative "Files" component by make.
        [[ "$entry" == /* && "$entry" != *[[:space:]]* ]] || continue
        case ":$clean_path:" in
            *":$entry:"*) ;;
            *) clean_path=${clean_path:+"$clean_path:"}$entry ;;
        esac
    done
    [[ -n "$clean_path" ]] || die 'PATH contains no safe absolute build-tool directories'
    PATH=$clean_path
    export PATH
}

load_release_lock() {
    local key value extra normalized_locks version_commit
    local seen_keys=
    local -a allowed_keys=(
        IMMORTALWRT_VERSION
        IMMORTALWRT_TAG
        IMMORTALWRT_TAG_OBJECT
        IMMORTALWRT_COMMIT
        IMMORTALWRT_SOURCE_URL
        IMMORTALWRT_DOWNLOAD_URL
        LOCKED_INPUT_RELEASE_TAG
        IMMORTALWRT_VERSION_CODE
        IMMORTALWRT_SOURCE_DATE_EPOCH
        IMMORTALWRT_KERNEL_VERSION
        IMMORTALWRT_KERNEL_RELEASE
        ROOTFS_PARTSIZE
        NOMINAL_MEDIA_BYTES
    )

    [[ -r "$RELEASE_LOCK" ]] || die "missing release lock: $RELEASE_LOCK"
    require_assignment_columns "$RELEASE_LOCK" 'release lock'
    while IFS='=' read -r key value extra; do
        [[ -n "$key" && ${key:0:1} != '#' ]] || continue
        [[ -z "$extra" ]] || die "invalid release lock assignment: $key"
        if ! array_contains_exact "$key" "${allowed_keys[@]}"; then
            die "unknown release lock key: $key"
        fi
        if grep -Fqx -- "$key" <<< "$seen_keys"; then
            die "duplicate release lock key: $key"
        fi
        [[ "$value" =~ ^[a-zA-Z0-9._:/-]+$ ]] || die "invalid release lock value for $key"
        printf -v "$key" '%s' "$value"
        seen_keys=${seen_keys:+"$seen_keys"$'\n'}$key
    done < "$RELEASE_LOCK"

    for key in "${allowed_keys[@]}"; do
        [[ -v "$key" ]] || die "missing release lock key: $key"
    done

    case ${BUILD_CHANNEL:-stable} in
        stable)
            [[ ${IMMORTALWRT_VERSION:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
                die "invalid release version"
            [[ ${IMMORTALWRT_TAG:-} == "v$IMMORTALWRT_VERSION" ]] || \
                die "tag/version mismatch"
            [[ ${IMMORTALWRT_COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || \
                die "invalid source commit"
            [[ ${IMMORTALWRT_TAG_OBJECT:-} =~ ^[0-9a-f]{40}$ ]] || \
                die "invalid tag object"
            [[ "$LOCKED_INPUT_RELEASE_TAG" == \
                "hmxf-openwrt-inputs-$IMMORTALWRT_VERSION" ]] || \
                die 'locked-input release tag/version mismatch'
            ;;
        nightly)
            [[ ${NIGHTLY_FINGERPRINT:-} =~ ^[0-9a-f]{64}$ ]] || \
                die 'nightly builds require a full NIGHTLY_FINGERPRINT'
            normalized_locks=$(realpath -m -- "$LOCKS_DIR")
            [[ "$normalized_locks" == \
               "$PROJECT_ROOT/build/nightly/$NIGHTLY_FINGERPRINT/context/locks" ]] || \
                die 'nightly locks do not match NIGHTLY_FINGERPRINT'
            [[ "$BUILD_CONFIG_FILE" == "$PROJECT_ROOT/configs/build-nightly.env" ]] || \
                die 'nightly builds require configs/build-nightly.env'
            [[ ${IMMORTALWRT_VERSION:-} == SNAPSHOT && \
               ${IMMORTALWRT_TAG:-} == SNAPSHOT ]] || \
                die 'nightly context must identify the official SNAPSHOT channel'
            [[ ${IMMORTALWRT_COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || \
                die 'nightly context has an invalid source revision'
            [[ ${IMMORTALWRT_TAG_OBJECT:-} == "$IMMORTALWRT_COMMIT" ]] || \
                die 'nightly tag object/source revision mismatch'
            [[ ${LOCKED_INPUT_RELEASE_TAG:-} == \
               "nightly-$NIGHTLY_FINGERPRINT" ]] || \
                die 'nightly context has an invalid immutable release tag'
            [[ ${REQUIRE_CLEAN_PROJECT:-} == 0 ]] || \
                die 'nightly context requires non-clean development policy'
            if [[ ${PACKAGE_REPOSITORY_MODE:-} == live ]]; then
                [[ ${ARTIFACT_LOCK_POLICY:-} == record && \
                   ${PACKAGE_CACHE_INDEX:-} == 1 ]] || \
                    die 'nightly live capture requires record/indexed policy'
            else
                [[ ${ARTIFACT_LOCK_POLICY:-} == enforce && \
                   ${PACKAGE_REPOSITORY_MODE:-} == snapshot && \
                   ${PACKAGE_CACHE_INDEX:-} == 0 ]] || \
                    die 'nightly release rebuild requires enforce/snapshot/no-index policy'
            fi
            ;;
        *) die 'BUILD_CHANNEL must be stable or nightly' ;;
    esac
    [[ ${IMMORTALWRT_VERSION_CODE:-} =~ ^r[0-9]+-[0-9a-f]{7,40}$ ]] || \
        die "invalid release version code"
    if [[ ${BUILD_CHANNEL:-stable} == nightly ]]; then
        version_commit=${IMMORTALWRT_VERSION_CODE#*-}
        [[ "${IMMORTALWRT_COMMIT:0:${#version_commit}}" == \
           "$version_commit" ]] || \
            die 'nightly version code/source commit mismatch'
    fi
    [[ ${IMMORTALWRT_SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || \
        die "invalid source date epoch"
    [[ ${IMMORTALWRT_KERNEL_VERSION:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "invalid kernel version"
    [[ ${IMMORTALWRT_KERNEL_RELEASE:-} =~ ^[1-9][0-9]*$ ]] || \
        die "invalid kernel release"
    [[ ${ROOTFS_PARTSIZE:-} =~ ^[0-9]+$ ]] || die "invalid rootfs size"
    [[ ${NOMINAL_MEDIA_BYTES:-} =~ ^[0-9]+$ ]] || die "invalid nominal media size"
    [[ "$IMMORTALWRT_SOURCE_URL" == \
        https://github.com/immortalwrt/immortalwrt.git ]] || die 'unexpected source URL'
    [[ "$IMMORTALWRT_DOWNLOAD_URL" == \
        https://downloads.immortalwrt.org ]] || die 'unexpected download URL'
    (( ROOTFS_PARTSIZE == 3072 )) || die "this release must keep a 3072 MiB rootfs"
    (( NOMINAL_MEDIA_BYTES == 4000000000 )) || die "unexpected nominal media limit"
}

load_target_lock() {
    local wanted=${1:?target name required}
    local row_name row_target row_subtarget row_profile row_arch row_file row_sha
    local row_vermagic row_bytes row_extra expected_imagebuilder_file count=0
    local seen_names=

    [[ -r "$TARGET_LOCK" ]] || die "missing target lock: $TARGET_LOCK"
    require_exact_header "$TARGET_LOCK" "$TARGET_LOCK_HEADER" 'target lock'
    require_pipe_columns "$TARGET_LOCK" 9 'target lock'
    TARGET_NAME=
    while IFS='|' read -r row_name row_target row_subtarget row_profile row_arch \
            row_file row_sha row_vermagic row_bytes row_extra; do
        [[ -n "$row_name" && ${row_name:0:1} != '#' ]] || continue
        [[ -z "$row_extra" ]] || die "too many fields in target lock for $row_name"
        if grep -Fqx -- "$row_name" <<< "$seen_names"; then
            die "duplicate target lock row: $row_name"
        fi
        seen_names=${seen_names:+"$seen_names"$'\n'}$row_name
        case "$row_name" in
            x86_64)
                [[ "$row_target|$row_subtarget|$row_profile|$row_arch" == \
                    'x86|64|generic|x86_64' ]] || die 'x86_64 target intent changed'
                ;;
            rpi4)
                [[ "$row_target|$row_subtarget|$row_profile|$row_arch" == \
                    'bcm27xx|bcm2711|rpi-4|aarch64_cortex-a72' ]] || \
                    die 'rpi4 target intent changed'
                ;;
            rpi5)
                [[ "$row_target|$row_subtarget|$row_profile|$row_arch" == \
                    'bcm27xx|bcm2712|rpi-5|aarch64_cortex-a76' ]] || \
                    die 'rpi5 target intent changed'
                ;;
            *) die "unknown target in target lock: $row_name" ;;
        esac
        if [[ ${BUILD_CHANNEL:-stable} == nightly ]]; then
            expected_imagebuilder_file="immortalwrt-imagebuilder-$row_target-$row_subtarget.Linux-x86_64.tar.zst"
        else
            expected_imagebuilder_file="immortalwrt-imagebuilder-$IMMORTALWRT_VERSION-$row_target-$row_subtarget.Linux-x86_64.tar.zst"
        fi
        [[ "$row_file" == "$expected_imagebuilder_file" ]] || \
            die "ImageBuilder filename/version mismatch for $row_name"
        [[ "$row_sha" =~ ^[0-9a-f]{64}$ ]] || \
            die "invalid ImageBuilder SHA-256 for $row_name"
        [[ "$row_vermagic" =~ ^[0-9a-f]{32}$ ]] || \
            die "invalid kernel vermagic for $row_name"
        [[ "$row_bytes" =~ ^[1-9][0-9]*$ ]] || \
            die "invalid ImageBuilder byte size for $row_name"
        ((count += 1))
        if [[ "$row_name" == "$wanted" ]]; then
            # These globals are intentionally consumed by scripts sourcing
            # this library rather than within common.sh itself.
            # shellcheck disable=SC2034
            TARGET_NAME=$row_name
            # shellcheck disable=SC2034
            TARGET=$row_target
            # shellcheck disable=SC2034
            SUBTARGET=$row_subtarget
            # shellcheck disable=SC2034
            PROFILE=$row_profile
            # shellcheck disable=SC2034
            PACKAGE_ARCH=$row_arch
            # shellcheck disable=SC2034
            IMAGEBUILDER_FILE=$row_file
            # shellcheck disable=SC2034
            IMAGEBUILDER_SHA256=$row_sha
            # shellcheck disable=SC2034
            IMAGEBUILDER_BYTES=$row_bytes
            # shellcheck disable=SC2034
            KERNEL_VERMAGIC=$row_vermagic
        fi
    done < "$TARGET_LOCK"

    (( count == 3 )) || die 'target lock must contain exactly three targets'
    [[ -n "$TARGET_NAME" ]] || die "unknown target '$wanted' (use x86_64, rpi4, or rpi5)"
}

load_preset() {
    local wanted=${1:?preset name required}
    case "$wanted" in
        minimal | full) PRESET_NAME=$wanted ;;
        *) die "unknown preset '$wanted' (use minimal or full)" ;;
    esac
}

load_package_manifest_lock() {
    local row_target row_preset row_count row_sha row_extra
    local row_key manifest_file locked_count locked_sha count=0
    local seen_keys=

    [[ -r "$PACKAGE_MANIFEST_LOCK" ]] || \
        die "missing package manifest lock: $PACKAGE_MANIFEST_LOCK"
    require_pipe_columns "$PACKAGE_MANIFEST_LOCK" 4 'package manifest lock'
    EXPECTED_PACKAGE_COUNT=
    EXPECTED_MANIFEST_SHA256=
    while IFS='|' read -r row_target row_preset row_count row_sha row_extra; do
        [[ -n "$row_target" && ${row_target:0:1} != '#' ]] || continue
        [[ -z "$row_extra" ]] || \
            die "too many fields in package manifest lock for $row_target/$row_preset"
        case "$row_target" in x86_64 | rpi4 | rpi5) ;; *)
            die "unknown target in package manifest lock: $row_target" ;;
        esac
        case "$row_preset" in minimal | full) ;; *)
            die "unknown preset in package manifest lock: $row_preset" ;;
        esac
        row_key="$row_target/$row_preset"
        if grep -Fqx -- "$row_key" <<< "$seen_keys"; then
            die "duplicate package manifest lock row: $row_key"
        fi
        seen_keys=${seen_keys:+"$seen_keys"$'\n'}$row_key
        [[ "$row_count" =~ ^[1-9][0-9]*$ ]] || \
            die "invalid package count lock for $row_key"
        [[ "$row_sha" =~ ^[0-9a-f]{64}$ ]] || \
            die "invalid package manifest SHA-256 for $row_key"
        manifest_file="$PACKAGE_MANIFEST_DIR/$row_target-$row_preset.manifest"
        [[ -s "$manifest_file" ]] || die "missing reviewed package manifest: $manifest_file"
        locked_count=$(wc -l < "$manifest_file")
        locked_sha=$(sha256sum "$manifest_file" | awk '{ print $1 }')
        [[ "$locked_count" == "$row_count" ]] || \
            die "reviewed manifest count mismatch for $row_key"
        [[ "$locked_sha" == "$row_sha" ]] || \
            die "reviewed manifest digest mismatch for $row_key"
        LC_ALL=C sort -c "$manifest_file" 2>/dev/null || \
            die "reviewed manifest is not sorted for $row_key"
        awk '
            NF != 3 || $2 != "-" || $1 !~ /^[a-z0-9][a-z0-9+._-]*$/ || $3 ~ /[[:space:]]/ {
                exit 1
            }
            seen[$1]++ { exit 1 }
        ' "$manifest_file" || die "reviewed manifest has malformed or duplicate packages for $row_key"
        ((count += 1))
        if [[ "$row_target" == "$TARGET_NAME" && "$row_preset" == "$PRESET_NAME" ]]; then
            EXPECTED_PACKAGE_COUNT=$row_count
            EXPECTED_MANIFEST_SHA256=$row_sha
        fi
    done < "$PACKAGE_MANIFEST_LOCK"

    (( count == 6 )) || \
        die 'package manifest lock must contain exactly six target/preset rows'
    [[ "$EXPECTED_PACKAGE_COUNT" =~ ^[1-9][0-9]*$ ]] || \
        die "invalid or missing package count lock for $TARGET_NAME/$PRESET_NAME"
    [[ "$EXPECTED_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
        die "invalid or missing package manifest SHA-256 for $TARGET_NAME/$PRESET_NAME"
    EXPECTED_MANIFEST_FILE="$PACKAGE_MANIFEST_DIR/$TARGET_NAME-$PRESET_NAME.manifest"
    [[ -s "$EXPECTED_MANIFEST_FILE" ]] || \
        die "missing reviewed package manifest: $EXPECTED_MANIFEST_FILE"
}

load_artifact_locks() {
    local row_target row_preset row_file row_sha row_extra
    local expected_file_a expected_file_b row_key count=0 expected_count=1
    local seen_files=

    [[ -r "$ARTIFACT_LOCK" ]] || die "missing artifact lock: $ARTIFACT_LOCK"
    require_pipe_columns "$ARTIFACT_LOCK" 4 'artifact lock'
    [[ "$TARGET_NAME" == x86_64 ]] || expected_count=2
    EXPECTED_ARTIFACT_FILES=()
    EXPECTED_ARTIFACT_SHA256S=()
    while IFS='|' read -r row_target row_preset row_file row_sha row_extra; do
        [[ -n "$row_target" && ${row_target:0:1} != '#' ]] || continue
        [[ -z "$row_extra" ]] || \
            die "too many fields in artifact lock for $row_target/$row_preset"
        case "$row_preset" in minimal | full) ;; *)
            die "unknown preset in artifact lock: $row_preset" ;;
        esac
        case "$row_target" in
            x86_64)
                expected_file_a="immortalwrt-$IMMORTALWRT_VERSION-$row_preset-x86-64-generic-squashfs-combined-efi.img.gz"
                expected_file_b=
                ;;
            rpi4)
                expected_file_a="immortalwrt-$IMMORTALWRT_VERSION-$row_preset-bcm27xx-bcm2711-rpi-4-squashfs-factory.img.gz"
                expected_file_b="immortalwrt-$IMMORTALWRT_VERSION-$row_preset-bcm27xx-bcm2711-rpi-4-squashfs-sysupgrade.img.gz"
                ;;
            rpi5)
                expected_file_a="immortalwrt-$IMMORTALWRT_VERSION-$row_preset-bcm27xx-bcm2712-rpi-5-squashfs-factory.img.gz"
                expected_file_b="immortalwrt-$IMMORTALWRT_VERSION-$row_preset-bcm27xx-bcm2712-rpi-5-squashfs-sysupgrade.img.gz"
                ;;
            *) die "unknown target in artifact lock: $row_target" ;;
        esac
        [[ "$row_file" == "$expected_file_a" || \
           ( -n "$expected_file_b" && "$row_file" == "$expected_file_b" ) ]] || \
            die "artifact filename/target intent mismatch: $row_file"
        [[ "$row_sha" =~ ^[0-9a-f]{64}$ ]] || \
            die "invalid artifact SHA-256 for $row_file"
        if grep -Fqx -- "$row_file" <<< "$seen_files"; then
            die "duplicate artifact lock: $row_file"
        fi
        seen_files=${seen_files:+"$seen_files"$'\n'}$row_file
        ((count += 1))
        if [[ "$row_target" == "$TARGET_NAME" && "$row_preset" == "$PRESET_NAME" ]]; then
            EXPECTED_ARTIFACT_FILES+=("$row_file")
            EXPECTED_ARTIFACT_SHA256S+=("$row_sha")
        fi
    done < "$ARTIFACT_LOCK"
    (( count == 10 )) || die 'artifact lock must contain exactly ten canonical images'
    [[ ${#EXPECTED_ARTIFACT_FILES[@]} -eq $expected_count ]] || \
        die "artifact lock must contain $expected_count image(s) for $TARGET_NAME/$PRESET_NAME"
}

validate_package_snapshot_lock() {
    local row_target row_file row_sha row_bytes row_tree_sha row_extra count=0
    local seen_targets='' seen_files=''

    [[ -r "$PACKAGE_SNAPSHOT_LOCK" ]] || \
        die "missing package snapshot lock: $PACKAGE_SNAPSHOT_LOCK"
    require_exact_header "$PACKAGE_SNAPSHOT_LOCK" \
        "$PACKAGE_SNAPSHOT_LOCK_HEADER" 'package snapshot lock'
    require_pipe_columns "$PACKAGE_SNAPSHOT_LOCK" 5 'package snapshot lock'
    PACKAGE_SNAPSHOT_FILE=
    PACKAGE_SNAPSHOT_SHA256=
    PACKAGE_SNAPSHOT_BYTES=
    PACKAGE_SNAPSHOT_TREE_SHA256=
    while IFS='|' read -r row_target row_file row_sha row_bytes row_tree_sha row_extra; do
        [[ -n "$row_target" && ${row_target:0:1} != '#' ]] || continue
        [[ -z "$row_extra" ]] || \
            die "too many fields in package snapshot lock for $row_target"
        case "$row_target" in
            x86_64 | rpi4 | rpi5) ;;
            *) die "unknown target in package snapshot lock: $row_target" ;;
        esac
        [[ "$row_file" == \
            "immortalwrt-$IMMORTALWRT_VERSION-$row_target-package-snapshot.tar.zst" ]] || \
            die "package snapshot filename/version mismatch: $row_file"
        [[ "$row_sha" =~ ^[0-9a-f]{64}$ ]] || \
            die "invalid package snapshot SHA-256 for $row_file"
        [[ "$row_bytes" =~ ^[1-9][0-9]*$ ]] || \
            die "invalid package snapshot byte size for $row_file"
        [[ "$row_tree_sha" =~ ^[0-9a-f]{64}$ ]] || \
            die "invalid package snapshot tree-manifest SHA-256 for $row_file"
        if grep -Fqx -- "$row_target" <<< "$seen_targets"; then
            die "duplicate package snapshot target: $row_target"
        fi
        if grep -Fqx -- "$row_file" <<< "$seen_files"; then
            die "duplicate package snapshot filename: $row_file"
        fi
        seen_targets=${seen_targets:+"$seen_targets"$'\n'}$row_target
        seen_files=${seen_files:+"$seen_files"$'\n'}$row_file
        ((count += 1))
        if [[ ${TARGET_NAME:-} == "$row_target" ]]; then
            # These globals bind an unpacked snapshot tree to its externally
            # reviewed portable bundle rather than trusting a mutable inner
            # checksum file as its own root of trust.
            PACKAGE_SNAPSHOT_FILE=$row_file
            PACKAGE_SNAPSHOT_SHA256=$row_sha
            PACKAGE_SNAPSHOT_BYTES=$row_bytes
            PACKAGE_SNAPSHOT_TREE_SHA256=$row_tree_sha
        fi
    done < "$PACKAGE_SNAPSHOT_LOCK"
    (( count == 3 )) || die 'package snapshot lock must contain exactly three targets'
}

load_package_snapshot_lock() {
    [[ -n ${TARGET_NAME:-} ]] || die 'load_target_lock must run before load_package_snapshot_lock'
    validate_package_snapshot_lock
    [[ -n "$PACKAGE_SNAPSHOT_FILE" && -n "$PACKAGE_SNAPSHOT_SHA256" && \
       -n "$PACKAGE_SNAPSHOT_BYTES" && -n "$PACKAGE_SNAPSHOT_TREE_SHA256" ]] || \
        die "missing package snapshot lock for $TARGET_NAME"
}

validate_feed_lock() {
    local row_name row_type row_url row_commit row_extra count=0
    local seen_names=

    [[ -r "$FEED_LOCK" ]] || die "missing feed lock: $FEED_LOCK"
    require_pipe_columns "$FEED_LOCK" 4 'feed lock'
    while IFS='|' read -r row_name row_type row_url row_commit row_extra; do
        [[ -n "$row_name" && ${row_name:0:1} != '#' ]] || continue
        [[ -z "$row_extra" ]] || die "too many fields in feed lock for $row_name"
        [[ "$row_name" =~ ^[a-zA-Z0-9._-]+$ ]] || die "invalid feed name: $row_name"
        [[ "$row_type" == src-git || "$row_type" == src-git-full ]] || \
            die "unsupported feed type for $row_name: $row_type"
        [[ "$row_url" == https://* ]] || \
            die "invalid feed URL for $row_name"
        [[ "$row_commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid feed commit for $row_name"
        if grep -Fqx -- "$row_name" <<< "$seen_names"; then
            die "duplicate feed name: $row_name"
        fi
        seen_names=${seen_names:+"$seen_names"$'\n'}$row_name
        ((count += 1))
    done < "$FEED_LOCK"
    (( count > 0 )) || die 'feed lock is empty'
}

render_locked_feeds() {
    local row_name row_type row_url row_commit row_extra
    validate_feed_lock
    while IFS='|' read -r row_name row_type row_url row_commit row_extra; do
        [[ -n "$row_name" && ${row_name:0:1} != '#' ]] || continue
        printf '%s %s %s^%s\n' "$row_type" "$row_name" "$row_url" "$row_commit"
    done < "$FEED_LOCK"
}

preset_package_files() {
    printf '%s\n' "$PROJECT_ROOT/packages/base-image.txt"
    if [[ "$PRESET_NAME" == full ]]; then
        printf '%s\n' \
            "$PROJECT_ROOT/packages/full-drivers-common.txt" \
            "$PROJECT_ROOT/packages/full-drivers-$TARGET_NAME.txt"
    fi
}

read_preset_packages() {
    local list
    while IFS= read -r list; do
        [[ -r "$list" ]] || die "missing package list: $list"
        sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$list"
    done < <(preset_package_files) | sort -u | paste -sd ' ' -
}

validate_extra_packages() {
    local package
    local allowed_list
    local duplicate_extra
    local -a extra_packages=()
    if [[ -n ${EXTRA_PACKAGES:-} ]]; then
        read -r -a extra_packages <<< "$EXTRA_PACKAGES"
    fi
    if (( ${#extra_packages[@]} > 0 )); then
        [[ "$PRESET_NAME" == minimal ]] || \
            die 'EXTRA_PACKAGES is supported only for the minimal preset'
        (( ${#extra_packages[@]} <= 16 )) || \
            die 'EXTRA_PACKAGES accepts at most 16 reviewed driver/firmware entries'
        duplicate_extra=$(printf '%s\n' "${extra_packages[@]}" | sort | uniq -d \
            | awk 'first == "" { first = $0 } END { if (first != "") print first }')
        [[ -z "$duplicate_extra" ]] || die "duplicate EXTRA_PACKAGES entry: $duplicate_extra"
    fi
    allowed_list=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
        "$PROJECT_ROOT/packages/full-drivers-common.txt" \
        "$PROJECT_ROOT/packages/full-drivers-$TARGET_NAME.txt" | sort -u)
    for package in "${extra_packages[@]}"; do
        [[ "$package" =~ ^[a-z0-9][a-z0-9+._-]*$ ]] || \
            die "invalid EXTRA_PACKAGES entry: $package"
        grep -Fqx -- "$package" <<< "$allowed_list" || \
            die "EXTRA_PACKAGES accepts only a driver/firmware from the $TARGET_NAME full preset: $package"
    done
}

read_package_list() {
    local list=${1:?package list required}
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$list" | paste -sd ' ' -
}
