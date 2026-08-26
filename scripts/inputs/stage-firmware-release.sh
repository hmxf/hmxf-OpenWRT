#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

channel=${1:?usage: stage-firmware-release.sh stable|nightly INPUT_ROOT DESTINATION [IDENTITY]}
input_arg=${2:?input root required}
destination_arg=${3:?destination required}
identity=${4:-}
case "$channel" in stable | nightly) ;; *) die 'channel must be stable or nightly' ;; esac

for tool in awk basename chmod cmp cp diff dirname find grep mkdir mktemp mv \
            python3 realpath rm sed sha256sum sort stat tar xargs zstd; do
    require_command "$tool"
done

resolve_existing_real_directory() {
    local input=${1:?directory required}
    local label=${2:?directory label required}
    local path resolved

    [[ "$input" != *$'\n'* && "$input" != *$'\r'* && "$input" != *\\* ]] || \
        die "$label contains an unsafe character"
    path=$(realpath -ms -- "$input")
    [[ "$path" != / && -d "$path" && ! -L "$path" ]] || \
        die "$label must be a real non-root directory: $path"
    resolved=$(realpath -e -- "$path")
    [[ "$resolved" == "$path" ]] || \
        die "$label traverses a symbolic link: $path"
    printf '%s\n' "$path"
}

prepare_destination_parent() {
    local path=${1:?destination parent required}
    local probe resolved

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        probe=$path
        while [[ ! -e "$probe" && ! -L "$probe" ]]; do
            resolved=$(dirname -- "$probe")
            [[ "$resolved" != "$probe" ]] || \
                die 'cannot find a safe firmware destination parent'
            probe=$resolved
        done
        [[ -d "$probe" && ! -L "$probe" ]] || \
            die "firmware destination has an unsafe ancestor: $probe"
        resolved=$(realpath -e -- "$probe")
        [[ "$resolved" == "$probe" ]] || \
            die "firmware destination traverses a symbolic-link ancestor: $probe"
        mkdir -p -- "$path"
    fi
    [[ -d "$path" && ! -L "$path" ]] || \
        die "firmware destination parent is unsafe: $path"
    resolved=$(realpath -e -- "$path")
    [[ "$resolved" == "$path" ]] || \
        die "firmware destination parent traverses a symbolic link: $path"
}

env_value() {
    local file=${1:?environment file required}
    local key=${2:?environment key required}
    awk -F= -v wanted="$key" '
        $1 == wanted { count += 1; value = substr($0, length($1) + 2) }
        END { if (count == 1) print value; else exit 1 }
    ' "$file"
}

validate_env_schema() {
    local file=${1:?environment file required}
    local label=${2:?environment label required}
    shift 2
    local expected_key line key
    local -A allowed=()
    local -A seen=()

    for expected_key in "$@"; do
        allowed[$expected_key]=1
    done
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9._:/+~-]+)$ ]] || \
            die "$label contains a malformed or unsafe line"
        key=${BASH_REMATCH[1]}
        [[ -n ${allowed[$key]+present} ]] || \
            die "$label contains unexpected key $key"
        [[ -z ${seen[$key]+present} ]] || \
            die "$label contains duplicate key $key"
        seen[$key]=1
    done < "$file"
    (( ${#seen[@]} == ${#allowed[@]} )) || \
        die "$label is missing a required key"
}

require_build_info_value() {
    local file=${1:?BUILD_INFO required}
    local key=${2:?BUILD_INFO key required}
    local expected=${3-}
    local combination=${4:?combination required}
    local actual

    actual=$(env_value "$file" "$key") || \
        die "firmware BUILD_INFO has no unique $key: $combination"
    [[ "$actual" == "$expected" ]] || \
        die "firmware BUILD_INFO $key mismatch: $combination"
}

verify_artifact_manifest() {
    local artifact_dir=${1:?artifact directory required}
    local combination=${2:?combination required}
    local locked_names actual_names locked_name

    [[ -s "$artifact_dir/SHA256SUMS" && ! -L "$artifact_dir/SHA256SUMS" ]] || \
        die "firmware artifact has no safe SHA256SUMS: $combination"
    locked_names=$(mktemp "$stage_dir/.locked-names.XXXXXXXX")
    actual_names=$(mktemp "$stage_dir/.actual-names.XXXXXXXX")
    awk '
        {
            digest = substr($0, 1, 64)
            separator = substr($0, 65, 2)
            name = substr($0, 67)
            if (length(digest) != 64 || digest !~ /^[0-9a-f]+$/ ||
                separator != "  " ||
                name !~ /^[A-Za-z0-9][A-Za-z0-9+._-]*$/ || seen[name]++) {
                exit 1
            }
            print name
        }
        END { if (NR == 0) exit 1 }
    ' "$artifact_dir/SHA256SUMS" | sort > "$locked_names" || \
        die "firmware SHA256SUMS is unsafe or contains duplicates: $combination"
    find "$artifact_dir" -mindepth 1 -maxdepth 1 -type f \
        ! -name SHA256SUMS -printf '%f\n' | sort > "$actual_names"
    cmp -s "$locked_names" "$actual_names" || \
        die "firmware SHA256SUMS does not cover the exact file set: $combination"
    while IFS= read -r locked_name; do
        [[ -f "$artifact_dir/$locked_name" && \
           ! -L "$artifact_dir/$locked_name" ]] || \
            die "firmware checksum entry is not a regular file: $locked_name"
    done < "$locked_names"
    (
        cd "$artifact_dir"
        sha256sum --strict --quiet -c SHA256SUMS
    ) || die "firmware checksum verification failed: $combination"
    rm -f -- "$locked_names" "$actual_names"
}

input_root=$(resolve_existing_real_directory "$input_arg" \
    'firmware input root')
[[ "$destination_arg" != *$'\n'* && "$destination_arg" != *$'\r'* && \
   "$destination_arg" != *\\* ]] || \
    die 'firmware release destination contains an unsafe character'
destination=$(realpath -ms -- "$destination_arg")
case "$destination" in / | "$PROJECT_ROOT" | "$(dirname -- "$PROJECT_ROOT")")
    die "unsafe firmware release destination: $destination"
    ;;
esac
destination_parent=$(dirname -- "$destination")
case "$destination" in
    "$input_root" | "$input_root/"*) \
        die 'firmware release destination overlaps its input root' ;;
esac
case "$input_root" in
    "$destination/"*) die 'firmware release destination contains its input root' ;;
esac
prepare_destination_parent "$destination_parent"
if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -d "$destination" && ! -L "$destination" && \
       $(realpath -e -- "$destination") == "$destination" ]] || \
        die "firmware release destination is unsafe: $destination"
fi

if [[ "$channel" == stable ]]; then
    [[ "$identity" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die 'stable release identity must be X.Y.Z'
    release_label=$identity
else
    [[ "$identity" =~ ^[0-9a-f]{64}$ ]] || \
        die 'nightly release identity must be a complete fingerprint'
    release_label="nightly-$identity"
fi

stage_dir=$(mktemp -d "$destination_parent/.firmware-release.XXXXXXXX")
cleanup() {
    rm -rf -- "$stage_dir"
}
trap cleanup EXIT

validate_nightly_provenance() {
    local provenance_root=${1:?nightly provenance root required}
    local state_file="$provenance_root/UPSTREAM_STATE.env"
    local build_file="$provenance_root/NIGHTLY_BUILD.env"
    local release_file="$provenance_root/NIGHTLY_RELEASE.env"
    local targets_file="$provenance_root/NIGHTLY_TARGETS.tsv"
    local feeds_file="$provenance_root/NIGHTLY_FEEDS.tsv"
    local snapshots_file="$provenance_root/NIGHTLY_PACKAGE_SNAPSHOTS.tsv"
    local plan_file="$provenance_root/PLAN_INPUTS.sha256"
    local plan_revision_file="$provenance_root/PLAN_INPUT_REVISION.txt"
    local provenance source_file resolved
    local state_version state_version_commit state_commit state_feeds_sha
    local state_targets_sha
    local state_packages_sha
    local state_fingerprint calculated_fingerprint plan_sha snapshots_sha
    local snapshot_content_sha build_plan_sha build_snapshots_sha
    local build_snapshot_lock_sha build_upstream build_fingerprint
    local target_rows fingerprint_rows feeds_reconstructed
    local index row_name row_target row_subtarget row_profile row_arch row_file
    local row_sha row_vermagic row_bytes row_extra state_prefix
    local feed_name feed_type feed_url feed_commit feed_extra feed_count=0
    local -A seen_feeds=()
    local -a names=(x86_64 rpi4 rpi5)
    local -a targets=(x86 bcm27xx bcm27xx)
    local -a subtargets=(64 bcm2711 bcm2712)
    local -a profiles=(generic rpi-4 rpi-5)
    local -a arches=(x86_64 aarch64_cortex-a72 aarch64_cortex-a76)
    local -a state_prefixes=(X86_64 RPI4 RPI5)
    local -a expected_files=(
        immortalwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst
        immortalwrt-imagebuilder-bcm27xx-bcm2711.Linux-x86_64.tar.zst
        immortalwrt-imagebuilder-bcm27xx-bcm2712.Linux-x86_64.tar.zst
    )

    for provenance in UPSTREAM_STATE.env NIGHTLY_BUILD.env NIGHTLY_RELEASE.env \
                      NIGHTLY_TARGETS.tsv NIGHTLY_FEEDS.tsv \
                      NIGHTLY_PACKAGE_SNAPSHOTS.tsv PLAN_INPUTS.sha256 \
                      PLAN_INPUT_REVISION.txt NIGHTLY_CONTEXT.sha256; do
        source_file="$provenance_root/$provenance"
        [[ -f "$source_file" && ! -L "$source_file" && -s "$source_file" ]] || \
            die "nightly release is missing safe provenance file: $provenance"
        resolved=$(realpath -e -- "$source_file")
        [[ "$resolved" == "$source_file" ]] || \
            die "nightly provenance traverses a symbolic link: $provenance"
    done

    validate_env_schema "$state_file" 'UPSTREAM_STATE.env' \
        STATE_SCHEMA CHANNEL REASON LOCKED_STABLE_VERSION LATEST_STABLE_VERSION \
        SNAPSHOT_VERSION_CODE SNAPSHOT_SOURCE_COMMIT SNAPSHOT_FEEDS_SHA256 \
        SNAPSHOT_TARGETS_SHA256 SNAPSHOT_PACKAGES_SHA256 SNAPSHOT_FINGERPRINT \
        NIGHTLY_IMAGEBUILDER_X86_64_FILE NIGHTLY_IMAGEBUILDER_X86_64_SHA256 \
        NIGHTLY_IMAGEBUILDER_RPI4_FILE NIGHTLY_IMAGEBUILDER_RPI4_SHA256 \
        NIGHTLY_IMAGEBUILDER_RPI5_FILE NIGHTLY_IMAGEBUILDER_RPI5_SHA256
    [[ $(env_value "$state_file" STATE_SCHEMA) == 1 && \
       $(env_value "$state_file" CHANNEL) == nightly ]] || \
        die 'nightly state has the wrong schema or channel'
    [[ $(env_value "$state_file" LOCKED_STABLE_VERSION) =~ \
       ^[0-9]+\.[0-9]+\.[0-9]+$ && \
       $(env_value "$state_file" LATEST_STABLE_VERSION) =~ \
       ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die 'nightly state contains an invalid stable version'
    state_version=$(env_value "$state_file" SNAPSHOT_VERSION_CODE)
    state_commit=$(env_value "$state_file" SNAPSHOT_SOURCE_COMMIT)
    state_feeds_sha=$(env_value "$state_file" SNAPSHOT_FEEDS_SHA256)
    state_targets_sha=$(env_value "$state_file" SNAPSHOT_TARGETS_SHA256)
    state_packages_sha=$(env_value "$state_file" SNAPSHOT_PACKAGES_SHA256)
    state_fingerprint=$(env_value "$state_file" SNAPSHOT_FINGERPRINT)
    state_version_commit=${state_version#*-}
    [[ "$state_version" =~ ^r[0-9]+-[0-9a-f]{7,40}$ && \
       "$state_commit" =~ ^[0-9a-f]{40}$ && \
       "${state_commit:0:${#state_version_commit}}" == \
           "$state_version_commit" && \
       "$state_feeds_sha" =~ ^[0-9a-f]{64}$ && \
       "$state_targets_sha" =~ ^[0-9a-f]{64}$ && \
       "$state_packages_sha" =~ ^[0-9a-f]{64}$ && \
       "$state_fingerprint" =~ ^[0-9a-f]{64}$ ]] || \
        die 'nightly state source identity is inconsistent'

    validate_env_schema "$build_file" 'NIGHTLY_BUILD.env' \
        NIGHTLY_BUILD_SCHEMA UPSTREAM_FINGERPRINT PLAN_INPUTS_SHA256 \
        PACKAGE_SNAPSHOTS_SHA256 PACKAGE_SNAPSHOT_LOCK_SHA256 \
        NIGHTLY_FINGERPRINT
    build_upstream=$(env_value "$build_file" UPSTREAM_FINGERPRINT)
    build_plan_sha=$(env_value "$build_file" PLAN_INPUTS_SHA256)
    build_snapshots_sha=$(env_value "$build_file" PACKAGE_SNAPSHOTS_SHA256)
    build_snapshot_lock_sha=$(env_value \
        "$build_file" PACKAGE_SNAPSHOT_LOCK_SHA256)
    build_fingerprint=$(env_value "$build_file" NIGHTLY_FINGERPRINT)
    [[ $(env_value "$build_file" NIGHTLY_BUILD_SCHEMA) == 1 && \
       "$build_upstream" == "$state_fingerprint" && \
       "$build_plan_sha" =~ ^[0-9a-f]{64}$ && \
       "$build_snapshots_sha" =~ ^[0-9a-f]{64}$ && \
       "$build_snapshot_lock_sha" =~ ^[0-9a-f]{64}$ && \
       "$build_fingerprint" == "$identity" ]] || \
        die 'nightly build state is inconsistent with its release identity'
    plan_sha=$(sha256sum "$plan_file" | awk '{ print $1 }')
    snapshots_sha=$(sha256sum "$snapshots_file" | awk '{ print $1 }')
    [[ "$plan_sha" == "$build_plan_sha" && \
       "$snapshots_sha" == "$build_snapshot_lock_sha" ]] || \
        die 'nightly plan/package lock digest differs from NIGHTLY_BUILD.env'
    # These globals are the explicit input contract of the common lock parser.
    # shellcheck disable=SC2034
    IMMORTALWRT_VERSION=SNAPSHOT
    # shellcheck disable=SC2034
    PACKAGE_SNAPSHOT_LOCK=$snapshots_file
    validate_package_snapshot_lock
    snapshot_content_sha=$(
        "$INPUT_SCRIPTS_DIR/nightly-build-identity.sh" content "$snapshots_file"
    )
    [[ "$snapshot_content_sha" == "$build_snapshots_sha" ]] || \
        die 'nightly package snapshot content identity mismatch'
    verify_plan_input_contract "$plan_file" "$plan_revision_file"
    calculated_fingerprint=$(
        "$INPUT_SCRIPTS_DIR/nightly-build-identity.sh" fingerprint \
            "$build_upstream" "$plan_file" "$snapshots_file"
    )
    [[ "$calculated_fingerprint" == "$identity" ]] || \
        die 'nightly build provenance does not reproduce its final fingerprint'

    validate_env_schema "$release_file" 'NIGHTLY_RELEASE.env' \
        IMMORTALWRT_VERSION IMMORTALWRT_TAG IMMORTALWRT_TAG_OBJECT \
        IMMORTALWRT_COMMIT IMMORTALWRT_SOURCE_URL IMMORTALWRT_DOWNLOAD_URL \
        LOCKED_INPUT_RELEASE_TAG IMMORTALWRT_VERSION_CODE \
        IMMORTALWRT_SOURCE_DATE_EPOCH IMMORTALWRT_KERNEL_VERSION \
        IMMORTALWRT_KERNEL_RELEASE ROOTFS_PARTSIZE NOMINAL_MEDIA_BYTES
    [[ $(env_value "$release_file" IMMORTALWRT_VERSION) == SNAPSHOT && \
       $(env_value "$release_file" IMMORTALWRT_TAG) == SNAPSHOT && \
       $(env_value "$release_file" IMMORTALWRT_TAG_OBJECT) == "$state_commit" && \
       $(env_value "$release_file" IMMORTALWRT_COMMIT) == "$state_commit" && \
       $(env_value "$release_file" IMMORTALWRT_SOURCE_URL) == \
           https://github.com/immortalwrt/immortalwrt.git && \
       $(env_value "$release_file" IMMORTALWRT_DOWNLOAD_URL) == \
           https://downloads.immortalwrt.org && \
       $(env_value "$release_file" LOCKED_INPUT_RELEASE_TAG) == \
           "nightly-$identity" && \
       $(env_value "$release_file" IMMORTALWRT_VERSION_CODE) == "$state_version" && \
       $(env_value "$release_file" IMMORTALWRT_SOURCE_DATE_EPOCH) =~ ^[0-9]+$ && \
       $(env_value "$release_file" IMMORTALWRT_KERNEL_VERSION) =~ \
           ^[0-9]+\.[0-9]+\.[0-9]+$ && \
       $(env_value "$release_file" IMMORTALWRT_KERNEL_RELEASE) =~ ^[1-9][0-9]*$ && \
       $(env_value "$release_file" ROOTFS_PARTSIZE) =~ ^[1-9][0-9]*$ && \
       $(env_value "$release_file" NOMINAL_MEDIA_BYTES) =~ ^[1-9][0-9]*$ ]] || \
        die 'nightly release provenance is inconsistent with its state'

    mapfile -t target_rows < "$targets_file"
    (( ${#target_rows[@]} == 4 )) || \
        die 'NIGHTLY_TARGETS.tsv must contain one header and three targets'
    [[ ${target_rows[0]} == "$TARGET_LOCK_HEADER" ]] || \
        die 'NIGHTLY_TARGETS.tsv has the wrong header'
    fingerprint_rows=$(mktemp "$stage_dir/.nightly-targets.XXXXXXXX")
    for index in "${!names[@]}"; do
        IFS='|' read -r row_name row_target row_subtarget row_profile row_arch \
            row_file row_sha row_vermagic row_bytes row_extra \
            <<< "${target_rows[$((index + 1))]}"
        state_prefix=${state_prefixes[$index]}
        [[ -z "$row_extra" && "$row_name" == "${names[$index]}" && \
           "$row_target" == "${targets[$index]}" && \
           "$row_subtarget" == "${subtargets[$index]}" && \
           "$row_profile" == "${profiles[$index]}" && \
           "$row_arch" == "${arches[$index]}" && \
           "$row_file" == "${expected_files[$index]}" && \
           "$row_file" == \
               "$(env_value "$state_file" "NIGHTLY_IMAGEBUILDER_${state_prefix}_FILE")" && \
           "$row_sha" == \
               "$(env_value "$state_file" "NIGHTLY_IMAGEBUILDER_${state_prefix}_SHA256")" && \
           "$row_sha" =~ ^[0-9a-f]{64}$ && \
           "$row_vermagic" =~ ^[0-9a-f]{32}$ && \
           "$row_bytes" =~ ^[1-9][0-9]*$ ]] || \
            die "nightly target provenance mismatch for ${names[$index]}"
        printf '%s|%s|%s\n' "$row_name" "$row_file" "$row_sha" \
            >> "$fingerprint_rows"
    done
    [[ $(sha256sum "$fingerprint_rows" | awk '{ print $1 }') == \
       "$state_targets_sha" ]] || \
        die 'nightly target provenance digest mismatch'

    feeds_reconstructed=$(mktemp "$stage_dir/.nightly-feeds.XXXXXXXX")
    while IFS='|' read -r feed_name feed_type feed_url feed_commit feed_extra || \
            [[ -n "$feed_name$feed_type$feed_url$feed_commit$feed_extra" ]]; do
        [[ -z "$feed_extra" && "$feed_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && \
           "$feed_type" =~ ^src-git(-full)?$ && \
           "$feed_url" == https://* && "$feed_url" != *[[:space:]\\]* && \
           "$feed_commit" =~ ^[0-9a-f]{40}$ && \
           -z ${seen_feeds[$feed_name]+present} ]] || \
            die 'NIGHTLY_FEEDS.tsv contains an unsafe or duplicate row'
        seen_feeds[$feed_name]=1
        printf '%s %s %s^%s\n' "$feed_type" "$feed_name" "$feed_url" \
            "$feed_commit" >> "$feeds_reconstructed"
        feed_count=$((feed_count + 1))
    done < "$feeds_file"
    (( feed_count > 0 )) || die 'NIGHTLY_FEEDS.tsv is empty'
    [[ $(sha256sum "$feeds_reconstructed" | awk '{ print $1 }') == \
       "$state_feeds_sha" ]] || die 'nightly feed provenance digest mismatch'

    calculated_fingerprint=$(printf '%s\n%s\n%s\n%s\n%s\n' \
        "$state_version" "$state_commit" "$state_feeds_sha" \
        "$state_targets_sha" "$state_packages_sha" | \
        sha256sum | awk '{ print $1 }')
    [[ "$calculated_fingerprint" == "$state_fingerprint" ]] || \
        die 'nightly upstream provenance does not reproduce its fingerprint'
    rm -f -- "$fingerprint_rows" "$feeds_reconstructed"

    for provenance in UPSTREAM_STATE.env NIGHTLY_BUILD.env NIGHTLY_RELEASE.env \
                      NIGHTLY_TARGETS.tsv NIGHTLY_FEEDS.tsv \
                      NIGHTLY_PACKAGE_SNAPSHOTS.tsv PLAN_INPUTS.sha256 \
                      PLAN_INPUT_REVISION.txt; do
        cp -- "$provenance_root/$provenance" "$stage_dir/$provenance"
    done
}

validate_context_tree() {
    local context=${1:?context directory required}
    local expected actual
    [[ -d "$context" && ! -L "$context" && \
       -s "$context/CONTEXT.sha256" && ! -L "$context/CONTEXT.sha256" ]] || \
        die 'nightly context tree is incomplete or unsafe'
    expected=$(mktemp "$stage_dir/.context-expected.XXXXXXXX")
    actual=$(mktemp "$stage_dir/.context-actual.XXXXXXXX")
    awk '
        NF != 2 || $1 !~ /^[0-9a-f]{64}$/ ||
          $2 !~ /^[A-Za-z0-9][A-Za-z0-9+._/-]*$/ ||
          $2 ~ /(^|\/)[.][.]?(\/|$)/ || seen[$2]++ { exit 1 }
        { print $2 }
        END { if (NR == 0) exit 1 }
    ' "$context/CONTEXT.sha256" | sort > "$expected" || \
        die 'nightly context checksum index is unsafe'
    printf '%s\n' CONTEXT.sha256 >> "$expected"
    sort -o "$expected" "$expected"
    find "$context" -mindepth 1 -type f -printf '%P\n' | sort > "$actual"
    [[ -z $(find "$context" -mindepth 1 ! -type f ! -type d -print -quit) ]] || \
        die 'nightly context contains a link or special node'
    cmp -s "$expected" "$actual" || \
        die 'nightly context file set differs from its checksum index'
    (
        cd "$context"
        sha256sum --strict --quiet -c CONTEXT.sha256
    ) || die 'nightly context checksum verification failed'
    rm -f -- "$expected" "$actual"
}

stage_nightly_durable_inputs() {
    local provenance_root=${1:?nightly provenance root required}
    local final_root context_archive extract_root source_epoch
    local target row file sha bytes tree extra source snapshot_extract
    local package_rows repositories_file repository_url repository_count index_sha
    local target_lock="$provenance_root/NIGHTLY_TARGETS.tsv"
    local snapshot_lock="$provenance_root/NIGHTLY_PACKAGE_SNAPSHOTS.tsv"

    final_root=$(dirname -- "$provenance_root")
    [[ "$provenance_root" == "$final_root/out" && \
       $(basename -- "$final_root") == "$identity" && \
       -d "$final_root/context" && ! -L "$final_root" ]] || \
        die 'nightly release input is not below its complete final root'
    context_archive="$final_root/NIGHTLY_BUILD_CONTEXT.tar"
    [[ -f "$context_archive" && ! -L "$context_archive" ]] || \
        die 'nightly final root has no safe NIGHTLY_BUILD_CONTEXT.tar'
    source_epoch=$(env_value "$provenance_root/NIGHTLY_RELEASE.env" \
        IMMORTALWRT_SOURCE_DATE_EPOCH)
    extract_root=$(mktemp -d "$stage_dir/.nightly-context.XXXXXXXX")
    PYTHONDONTWRITEBYTECODE=1 python3 \
        "$INPUT_SCRIPTS_DIR/extract-nightly-build-context.py" \
        "$context_archive" "$extract_root" "$source_epoch" || \
        die 'nightly build-context archive failed safe extraction'
    cmp -s "$extract_root/NIGHTLY_BUILD.env" \
        "$provenance_root/NIGHTLY_BUILD.env" || \
        die 'nightly build-context archive has the wrong build state'
    diff -qr --no-dereference "$extract_root/context" \
        "$final_root/context" >/dev/null || \
        die 'nightly build-context archive differs from the final context'
    validate_context_tree "$extract_root/context"
    for pair in \
        'UPSTREAM_STATE.env|UPSTREAM_STATE.env' \
        'NIGHTLY_BUILD.env|NIGHTLY_BUILD.env' \
        'locks/release.env|NIGHTLY_RELEASE.env' \
        'locks/targets.tsv|NIGHTLY_TARGETS.tsv' \
        'locks/feeds.tsv|NIGHTLY_FEEDS.tsv' \
        'locks/package-snapshots.tsv|NIGHTLY_PACKAGE_SNAPSHOTS.tsv' \
        'PLAN_INPUTS.sha256|PLAN_INPUTS.sha256' \
        'PLAN_INPUT_REVISION.txt|PLAN_INPUT_REVISION.txt'; do
        IFS='|' read -r context_name release_name <<< "$pair"
        cmp -s "$extract_root/context/$context_name" \
            "$provenance_root/$release_name" || \
            die "nightly context/release provenance mismatch: $release_name"
    done
    cp -- "$context_archive" "$stage_dir/NIGHTLY_BUILD_CONTEXT.tar"
    package_rows=$(mktemp "$stage_dir/.package-index-rows.XXXXXXXX")

    for target in x86_64 rpi4 rpi5; do
        row=$(awk -F'|' -v wanted="$target" '
            $1 == wanted { count += 1; value = $0 }
            END { if (count == 1) print value; else exit 1 }
        ' "$target_lock") || die "nightly target lock has no unique $target row"
        IFS='|' read -r _ _ _ _ _ file sha _ bytes extra <<< "$row"
        [[ -z "$extra" && "$file" =~ ^[A-Za-z0-9._-]+[.]tar[.]zst$ && \
           "$sha" =~ ^[0-9a-f]{64}$ && "$bytes" =~ ^[1-9][0-9]*$ ]] || \
            die "nightly target archive lock is unsafe: $target"
        source="$final_root/imagebuilders/$file"
        [[ -f "$source" && ! -L "$source" && \
           $(stat -c '%s' "$source") == "$bytes" && \
           $(sha256sum "$source" | awk '{ print $1 }') == "$sha" ]] || \
            die "nightly ImageBuilder archive differs from its lock: $target"
        cp -- "$source" "$stage_dir/$file"

        row=$(awk -F'|' -v wanted="$target" '
            $1 == wanted { count += 1; value = $0 }
            END { if (count == 1) print value; else exit 1 }
        ' "$snapshot_lock") || \
            die "nightly package snapshot lock has no unique $target row"
        IFS='|' read -r _ file sha bytes tree extra <<< "$row"
        [[ -z "$extra" && "$file" =~ ^[A-Za-z0-9._-]+[.]tar[.]zst$ && \
           "$sha" =~ ^[0-9a-f]{64}$ && "$bytes" =~ ^[1-9][0-9]*$ && \
           "$tree" =~ ^[0-9a-f]{64}$ ]] || \
            die "nightly package archive lock is unsafe: $target"
        source="$final_root/package-snapshot-bundles/$file"
        [[ -f "$source" && ! -L "$source" && \
           $(stat -c '%s' "$source") == "$bytes" && \
           $(sha256sum "$source" | awk '{ print $1 }') == "$sha" ]] || \
            die "nightly package snapshot archive differs from its lock: $target"
        snapshot_extract=$(mktemp -d "$stage_dir/.snapshot-$target.XXXXXXXX")
        PYTHONDONTWRITEBYTECODE=1 python3 \
            "$INPUT_SCRIPTS_DIR/verify-package-snapshot.py" extract \
            "$source" "$snapshot_extract" SNAPSHOT "$target" "$tree" \
            >/dev/null || die "nightly package snapshot archive is invalid: $target"
        repositories_file="$extract_root/context/repositories/$target.list"
        [[ -f "$repositories_file" && ! -L "$repositories_file" && \
           -s "$repositories_file" ]] || \
            die "nightly context has no repository URL list: $target"
        repository_count=0
        while IFS= read -r repository_url || [[ -n "$repository_url" ]]; do
            repository_count=$((repository_count + 1))
            [[ "$repository_url" =~ ^https://downloads[.]immortalwrt[.]org/snapshots/[A-Za-z0-9._~/-]+/packages[.]adb$ && \
               "$repository_url" != *'/../'* ]] || \
                die "nightly repository URL is unsafe: $target"
            index_sha=$(sha256sum \
                "$snapshot_extract/SNAPSHOT/$target/repo-$repository_count/packages.adb" \
                | awk '{ print $1 }') || \
                die "nightly snapshot is missing a package index: $target"
            printf '%s|%s\n' "$repository_url" "$index_sha" >> "$package_rows"
        done < "$repositories_file"
        [[ "$repository_count" -gt 0 && \
           $(wc -l < "$snapshot_extract/SNAPSHOT/$target/repositories.list") == \
               "$repository_count" ]] || \
            die "nightly repository URL/index count mismatch: $target"
        cp -- "$source" "$stage_dir/$file"
        rm -rf -- "$snapshot_extract"
    done
    sort -u -o "$package_rows" "$package_rows"
    package_lock="$extract_root/context/repositories/PACKAGES.sha256.tsv"
    package_lock_rows=$(mktemp "$stage_dir/.package-lock-rows.XXXXXXXX")
    [[ -f "$package_lock" && ! -L "$package_lock" && \
       $(sed -n '1p' "$package_lock") == '# url|sha256' ]] || \
        die 'nightly context package-index aggregate is missing or unsafe'
    sed '1d' "$package_lock" > "$package_lock_rows"
    cmp -s "$package_rows" "$package_lock_rows" || \
        die 'nightly context repository URLs differ from its package-index aggregate'
    [[ $(sha256sum "$package_rows" | awk '{ print $1 }') == \
       $(env_value "$provenance_root/UPSTREAM_STATE.env" \
           SNAPSHOT_PACKAGES_SHA256) ]] || \
        die 'nightly package indexes do not reproduce upstream package identity'
    rm -f -- "$package_rows" "$package_lock_rows"
    rm -rf -- "$extract_root"
}

if [[ "$channel" == nightly ]]; then
    nightly_provenance_root=$(dirname -- "$input_root")
    validate_nightly_provenance "$nightly_provenance_root"
    nightly_state_file="$nightly_provenance_root/UPSTREAM_STATE.env"
    nightly_build_state_file="$nightly_provenance_root/NIGHTLY_BUILD.env"
    nightly_snapshot_lock="$nightly_provenance_root/NIGHTLY_PACKAGE_SNAPSHOTS.tsv"
    nightly_source_commit=$(env_value "$nightly_state_file" SNAPSHOT_SOURCE_COMMIT)
    nightly_version_code=$(env_value "$nightly_state_file" SNAPSHOT_VERSION_CODE)
    nightly_package_snapshots_sha=$(env_value \
        "$nightly_build_state_file" PACKAGE_SNAPSHOTS_SHA256)
    nightly_package_snapshot_lock_sha=$(env_value \
        "$nightly_build_state_file" PACKAGE_SNAPSHOT_LOCK_SHA256)
    nightly_context_sha=$(sha256sum \
        "$nightly_provenance_root/NIGHTLY_CONTEXT.sha256" | awk '{ print $1 }')
    stage_nightly_durable_inputs "$nightly_provenance_root"
fi

combinations=(
    'x86_64|minimal' 'x86_64|full'
    'rpi4|minimal' 'rpi4|full'
    'rpi5|minimal' 'rpi5|full'
)
image_count=0
archive_epoch=
for combination in "${combinations[@]}"; do
    IFS='|' read -r target preset <<< "$combination"
    artifact_dir=$(resolve_existing_real_directory \
        "$input_root/$target/$preset" "firmware artifact $target/$preset")
    special_node=$(find "$artifact_dir" -mindepth 1 ! -type f -print -quit)
    [[ -z "$special_node" ]] || \
        die "firmware artifact contains a directory, link, or special node: $special_node"
    verify_artifact_manifest "$artifact_dir" "$target/$preset"
    build_info="$artifact_dir/BUILD_INFO.txt"
    [[ -s "$build_info" && ! -L "$build_info" ]] || \
        die "firmware artifact has no BUILD_INFO.txt: $target/$preset"
    require_build_info_value "$build_info" build_mode imagebuilder "$target/$preset"
    require_build_info_value "$build_info" release_channel "$channel" "$target/$preset"
    require_build_info_value "$build_info" preset "$preset" "$target/$preset"
    require_build_info_value "$build_info" development_build 0 "$target/$preset"
    combination_epoch=$(env_value "$build_info" source_date_epoch) || \
        die "firmware BUILD_INFO has no unique source_date_epoch: $target/$preset"
    [[ "$combination_epoch" =~ ^[0-9]+$ ]] || \
        die "firmware BUILD_INFO source_date_epoch is invalid: $target/$preset"
    if [[ -z "$archive_epoch" ]]; then
        archive_epoch=$combination_epoch
    else
        [[ "$archive_epoch" == "$combination_epoch" ]] || \
            die 'firmware combinations have different source epochs'
    fi
    if [[ "$channel" == nightly ]]; then
        [[ "$combination_epoch" == $(env_value \
            "$nightly_provenance_root/NIGHTLY_RELEASE.env" \
            IMMORTALWRT_SOURCE_DATE_EPOCH) ]] || \
            die "nightly firmware source epoch mismatch: $target/$preset"
    fi
    case "$target" in
        x86_64)
            expected_target=x86/64
            expected_profile=generic
            ;;
        rpi4)
            expected_target=bcm27xx/bcm2711
            expected_profile=rpi-4
            ;;
        rpi5)
            expected_target=bcm27xx/bcm2712
            expected_profile=rpi-5
            ;;
    esac
    require_build_info_value "$build_info" target "$expected_target" "$target/$preset"
    require_build_info_value "$build_info" profile "$expected_profile" "$target/$preset"
    if [[ "$channel" == stable ]]; then
        require_build_info_value "$build_info" canonical_build 1 "$target/$preset"
        require_build_info_value "$build_info" candidate_build 0 "$target/$preset"
        require_build_info_value "$build_info" release "$identity" "$target/$preset"
        ! grep -q '^nightly_fingerprint=' "$build_info" || \
            die "stable firmware contains a nightly fingerprint: $target/$preset"
        image_version=$identity
    else
        require_build_info_value "$build_info" canonical_build 0 "$target/$preset"
        require_build_info_value "$build_info" candidate_build 1 "$target/$preset"
        require_build_info_value "$build_info" release SNAPSHOT "$target/$preset"
        require_build_info_value "$build_info" nightly_fingerprint "$identity" \
            "$target/$preset"
        require_build_info_value "$build_info" source_commit \
            "$nightly_source_commit" "$target/$preset"
        require_build_info_value "$build_info" version_code \
            "$nightly_version_code" "$target/$preset"
        require_build_info_value "$build_info" nightly_context_sha256 \
            "$nightly_context_sha" "$target/$preset"
        require_build_info_value "$build_info" \
            nightly_package_snapshots_sha256 \
            "$nightly_package_snapshots_sha" "$target/$preset"
        require_build_info_value "$build_info" \
            nightly_package_snapshot_lock_sha256 \
            "$nightly_package_snapshot_lock_sha" "$target/$preset"
        require_build_info_value "$build_info" artifact_lock_policy enforce \
            "$target/$preset"
        require_build_info_value "$build_info" package_repository_mode snapshot \
            "$target/$preset"
        require_build_info_value "$build_info" package_cache_index 0 \
            "$target/$preset"
        snapshot_row=$(awk -F'|' -v wanted="$target" '
            $1 == wanted { count += 1; value = $0 }
            END { if (count == 1) print value; else exit 1 }
        ' "$nightly_snapshot_lock") || \
            die "nightly package snapshot provenance is missing: $target"
        IFS='|' read -r _snapshot_target snapshot_file snapshot_sha \
            snapshot_bytes snapshot_tree_sha snapshot_extra <<< "$snapshot_row"
        [[ -z "$snapshot_extra" ]] || \
            die "nightly package snapshot provenance has extra fields: $target"
        require_build_info_value "$build_info" package_snapshot_file \
            "$snapshot_file" "$target/$preset"
        require_build_info_value "$build_info" package_snapshot_sha256 \
            "$snapshot_sha" "$target/$preset"
        require_build_info_value "$build_info" package_snapshot_bytes \
            "$snapshot_bytes" "$target/$preset"
        require_build_info_value "$build_info" package_snapshot_tree_sha256 \
            "$snapshot_tree_sha" "$target/$preset"
        case "$target" in
            x86_64) nightly_state_prefix=X86_64 ;;
            rpi4) nightly_state_prefix=RPI4 ;;
            rpi5) nightly_state_prefix=RPI5 ;;
        esac
        require_build_info_value "$build_info" imagebuilder_file \
            "$(env_value "$nightly_state_file" \
                "NIGHTLY_IMAGEBUILDER_${nightly_state_prefix}_FILE")" \
            "$target/$preset"
        require_build_info_value "$build_info" imagebuilder_sha256 \
            "$(env_value "$nightly_state_file" \
                "NIGHTLY_IMAGEBUILDER_${nightly_state_prefix}_SHA256")" \
            "$target/$preset"
        image_version=SNAPSHOT
    fi

    mapfile -d '' images < <(
        find "$artifact_dir" -mindepth 1 -maxdepth 1 -type f \
            -name '*.img.gz' -print0 | sort -z
    )
    case "$target" in
        x86_64)
            expected_image_names=(
                "immortalwrt-$image_version-$preset-x86-64-generic-squashfs-combined-efi.img.gz"
            )
            ;;
        rpi4)
            expected_image_names=(
                "immortalwrt-$image_version-$preset-bcm27xx-bcm2711-rpi-4-squashfs-factory.img.gz"
                "immortalwrt-$image_version-$preset-bcm27xx-bcm2711-rpi-4-squashfs-sysupgrade.img.gz"
            )
            ;;
        rpi5)
            expected_image_names=(
                "immortalwrt-$image_version-$preset-bcm27xx-bcm2712-rpi-5-squashfs-factory.img.gz"
                "immortalwrt-$image_version-$preset-bcm27xx-bcm2712-rpi-5-squashfs-sysupgrade.img.gz"
            )
            ;;
    esac
    (( ${#images[@]} == ${#expected_image_names[@]} )) || \
        die "wrong firmware image count for $target/$preset"
    for index in "${!images[@]}"; do
        image=${images[$index]}
        image_name=$(basename -- "$image")
        [[ "$image_name" == "${expected_image_names[$index]}" ]] || \
            die "unexpected firmware image for $target/$preset: $image_name"
        [[ ! -e "$stage_dir/$image_name" ]] || \
            die "duplicate release image name: $image_name"
        cp -- "$image" "$stage_dir/$image_name"
        image_count=$((image_count + 1))
    done

    metadata_list="$stage_dir/.metadata-$target-$preset.list"
    find "$artifact_dir" -mindepth 1 -maxdepth 1 -type f \
        ! -name '*.img.gz' -printf '%f\0' | sort -z > "$metadata_list"
    [[ -s "$metadata_list" ]] || die "firmware metadata is empty for $target/$preset"
    manifest_count=0
    while IFS= read -r -d '' metadata_name; do
        case "$metadata_name" in
            BUILD_INFO.txt | profiles.json | config.buildinfo | feeds.buildinfo | \
                version.buildinfo | SHA256SUMS) ;;
            *.manifest) manifest_count=$((manifest_count + 1)) ;;
            *) die "unexpected firmware metadata for $target/$preset: $metadata_name" ;;
        esac
    done < "$metadata_list"
    (( manifest_count == 1 )) || \
        die "firmware metadata must contain exactly one manifest: $target/$preset"
    grep -Fzxq 'profiles.json' "$metadata_list" || \
        die "firmware metadata has no profiles.json: $target/$preset"
    metadata_bundle="$stage_dir/hmxf-openwrt-$release_label-$target-$preset-metadata.tar.zst"
    metadata_tar="$stage_dir/.metadata-$target-$preset.tar"
    tar --format=gnu --mtime="@$archive_epoch" --owner=0 --group=0 \
        --numeric-owner --mode='u+rwX,go+rX,go-w' --null \
        --verbatim-files-from -cf "$metadata_tar" -C "$artifact_dir" \
        -T "$metadata_list"
    zstd --quiet --force -T1 "$metadata_tar" -o "$metadata_bundle"
    rm -f -- "$metadata_tar"
    rm -f -- "$metadata_list"
done
(( image_count == 10 )) || die "firmware release must contain exactly ten images"

notes="$stage_dir/RELEASE_NOTES.md"
if [[ "$channel" == stable ]]; then
    cat > "$notes" <<EOF
# hmxf-OpenWRT $identity

Stable canonical firmware built from immutable ImmortalWrt $identity inputs.
Raspberry Pi assets include both factory (initial installation) and sysupgrade
images. The x86_64 combined EFI image is the complete disk image used for both
initial installation and supported image-based upgrades.

The full preset is the reviewed broad network-driver firmware preset; it is
not a mirror of every APK in the upstream package repositories.
EOF
else
    cat > "$notes" <<EOF
# hmxf-OpenWRT nightly $identity

Unreviewed prerelease firmware built from one synchronized official ImmortalWrt
snapshot revision, exact feed revisions, and one frozen set of signed package
indexes/APKs. All six published combinations were rebuilt from that same
offline snapshot and matched the live warm-up manifests and image digests. It
is not canonical stable firmware. Raspberry Pi assets include factory and
sysupgrade images; x86_64 uses the combined EFI disk image.

Fingerprint: $identity
EOF
fi

find "$stage_dir" -mindepth 1 -maxdepth 1 -type f -exec chmod 0644 {} +
(
    cd "$stage_dir"
    find . -mindepth 1 -maxdepth 1 -type f ! -name 'SHA256SUMS*' \
        -printf '%P\0' | sort -z | xargs -0 -r sha256sum -- > SHA256SUMS.tmp
    mv -- SHA256SUMS.tmp SHA256SUMS
    chmod 0644 SHA256SUMS
    sha256sum --strict --quiet -c SHA256SUMS
)

if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -d "$destination" && ! -L "$destination" && \
       $(realpath -e -- "$destination") == "$destination" ]] || \
        die "firmware release destination is unsafe: $destination"
    diff -qr --no-dereference "$stage_dir" "$destination" >/dev/null || \
        die "firmware release destination already contains different data: $destination"
    rm -rf -- "$stage_dir"
    stage_dir=
else
    mv -- "$stage_dir" "$destination"
    stage_dir=
fi
trap - EXIT
printf 'Staged %s firmware release at %s\n' "$channel" "$destination"
