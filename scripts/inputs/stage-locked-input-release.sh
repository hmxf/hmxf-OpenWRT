#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)

usage() {
    cat <<'EOF'
Usage: stage-locked-input-release.sh [--candidate CANDIDATE_ROOT] OUTPUT_DIR

Atomically stage the six externally locked build inputs and one combined
SHA256SUMS file in OUTPUT_DIR. Without --candidate, inputs come from the
formal locks and the local versioned caches.

Environment overrides used in formal-lock mode:
  LOCKS_DIR                    formal lock directory
  DOWNLOAD_DIR                 ImageBuilder cache (flat)
  PACKAGE_SNAPSHOT_BUNDLE_DIR  package-snapshot bundle cache root
EOF
}

candidate_input=
while (( $# > 0 )); do
    case "$1" in
        --candidate)
            (( $# >= 2 )) || { usage >&2; exit 2; }
            [[ -z "$candidate_input" ]] || {
                printf 'error: --candidate may be specified only once\n' >&2
                exit 2
            }
            candidate_input=$2
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --*)
            printf 'error: unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
        *) break ;;
    esac
done
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
output_input=$1

resolve_from_project() {
    local input=${1:?path required}
    if [[ "$input" == /* ]]; then
        printf '%s\n' "$input"
    else
        printf '%s/%s\n' "$PROJECT_ROOT" "$input"
    fi
}

if [[ -n "$candidate_input" ]]; then
    candidate_input=$(resolve_from_project "$candidate_input")
    [[ -d "$candidate_input" && ! -L "$candidate_input" ]] || {
        printf 'error: candidate root must be a real directory: %s\n' \
            "$candidate_input" >&2
        exit 1
    }
    candidate_root=$(realpath -e -- "$candidate_input")
    LOCKS_DIR="$candidate_root/locks"
else
    candidate_root=
    LOCKS_DIR=$(resolve_from_project "${LOCKS_DIR:-locks}")
fi

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

for tool in awk basename chmod cmp cp dirname find flock grep mkdir mktemp mv python3 \
            realpath rm sha256sum sort stat uniq wc zstd; do
    require_command "$tool"
done
[[ -f "$INPUT_SCRIPTS_DIR/verify-package-snapshot.py" && \
   ! -L "$INPUT_SCRIPTS_DIR/verify-package-snapshot.py" ]] || \
    die 'missing safe package-snapshot verifier'

[[ -d "$LOCKS_DIR" && ! -L "$LOCKS_DIR" ]] || \
    die "lock directory must be a real directory: $LOCKS_DIR"
for lock_file in release.env targets.tsv package-snapshots.tsv; do
    [[ -f "$LOCKS_DIR/$lock_file" && ! -L "$LOCKS_DIR/$lock_file" ]] || \
        die "missing safe input lock: $LOCKS_DIR/$lock_file"
done
load_release_lock

declare -a targets=(x86_64 rpi4 rpi5)
declare -a imagebuilder_names=()
declare -a imagebuilder_hashes=()
declare -a imagebuilder_sizes=()
declare -a bundle_names=()
declare -a bundle_hashes=()
declare -a bundle_sizes=()
declare -a bundle_tree_hashes=()

for target_name in "${targets[@]}"; do
    load_target_lock "$target_name"
    imagebuilder_names+=("$IMAGEBUILDER_FILE")
    imagebuilder_hashes+=("$IMAGEBUILDER_SHA256")
    imagebuilder_sizes+=("$IMAGEBUILDER_BYTES")
    load_package_snapshot_lock
    bundle_names+=("$PACKAGE_SNAPSHOT_FILE")
    bundle_hashes+=("$PACKAGE_SNAPSHOT_SHA256")
    bundle_sizes+=("$PACKAGE_SNAPSHOT_BYTES")
    bundle_tree_hashes+=("$PACKAGE_SNAPSHOT_TREE_SHA256")
done

all_names=$(printf '%s\n' "${imagebuilder_names[@]}" "${bundle_names[@]}" | sort)
[[ $(wc -l <<< "$all_names") -eq 6 && \
   -z $(uniq -d <<< "$all_names") ]] || \
    die 'locked input filenames are not six distinct assets'

resolve_real_directory() {
    local input=${1:?directory required}
    local label=${2:?directory label required}
    local path

    path=$(resolve_from_project "$input")
    [[ -d "$path" && ! -L "$path" ]] || \
        die "$label must be a real directory: $path"
    realpath -e -- "$path"
}

if [[ -n "$candidate_root" ]]; then
    imagebuilder_source=$(resolve_real_directory \
        "$candidate_root/imagebuilders" 'candidate ImageBuilder directory')
    bundle_source=$(resolve_real_directory \
        "$candidate_root/package-snapshot-bundles" \
        'candidate package-snapshot bundle directory')
else
    imagebuilder_source=$(resolve_real_directory \
        "${DOWNLOAD_DIR:-.cache/imagebuilders}" 'ImageBuilder cache')
    bundle_cache_root=$(resolve_real_directory \
        "${PACKAGE_SNAPSHOT_BUNDLE_DIR:-.cache/package-snapshot-bundles}" \
        'package-snapshot bundle cache root')
    bundle_source=$(resolve_real_directory "$bundle_cache_root/$IMMORTALWRT_VERSION" \
        'versioned package-snapshot bundle cache')
fi

expected_imagebuilder_manifest=$(mktemp)
temporary_paths=("$expected_imagebuilder_manifest")
cleanup() {
    local status=$?
    trap - EXIT
    local path
    for path in "${temporary_paths[@]}"; do
        [[ -z "$path" || ( ! -e "$path" && ! -L "$path" ) ]] || rm -rf -- "$path"
    done
    exit "$status"
}
trap cleanup EXIT

for ((index = 0; index < ${#imagebuilder_names[@]}; index++)); do
    printf '%s  %s\n' "${imagebuilder_hashes[$index]}" \
        "${imagebuilder_names[$index]}"
done | sort -k2,2 > "$expected_imagebuilder_manifest"

validate_locked_file() {
    local path=${1:?file required}
    local expected_hash=${2:?file digest required}
    local expected_size=${3:?file size required}
    local label=${4:?file label required}
    local actual_size actual_hash

    [[ -f "$path" && ! -L "$path" ]] || die "$label is not a regular file: $path"
    actual_size=$(stat -c '%s' -- "$path")
    [[ "$actual_size" == "$expected_size" ]] || \
        die "$label byte-size mismatch: $(basename -- "$path")"
    actual_hash=$(sha256sum -- "$path" | awk '{ print $1 }')
    [[ "$actual_hash" == "$expected_hash" ]] || \
        die "$label SHA-256 mismatch: $(basename -- "$path")"
}

for ((index = 0; index < ${#imagebuilder_names[@]}; index++)); do
    validate_locked_file "$imagebuilder_source/${imagebuilder_names[$index]}" \
        "${imagebuilder_hashes[$index]}" "${imagebuilder_sizes[$index]}" \
        'ImageBuilder input'
done
for ((index = 0; index < ${#bundle_names[@]}; index++)); do
    validate_locked_file "$bundle_source/${bundle_names[$index]}" \
        "${bundle_hashes[$index]}" "${bundle_sizes[$index]}" \
        'package-snapshot bundle input'
done

if [[ -n "$candidate_root" ]]; then
    expected_candidate_imagebuilders=$(printf '%s\n' \
        SHA256SUMS "${imagebuilder_names[@]}" | sort)
    actual_candidate_imagebuilders=$(find "$imagebuilder_source" -mindepth 1 \
        -maxdepth 1 -type f -printf '%f\n' | sort)
    unsafe_candidate_imagebuilder=$(find "$imagebuilder_source" -mindepth 1 \
        -maxdepth 1 ! -type f -print -quit)
    [[ -z "$unsafe_candidate_imagebuilder" && \
       "$actual_candidate_imagebuilders" == "$expected_candidate_imagebuilders" ]] || \
        die 'candidate ImageBuilder directory does not contain exactly three archives and SHA256SUMS'
    [[ -f "$imagebuilder_source/SHA256SUMS" && \
       ! -L "$imagebuilder_source/SHA256SUMS" ]] || \
        die 'candidate ImageBuilder SHA256SUMS is not a regular file'
    cmp -s -- "$expected_imagebuilder_manifest" "$imagebuilder_source/SHA256SUMS" || \
        die 'candidate ImageBuilder SHA256SUMS differs from targets.tsv'

    expected_candidate_bundles=$(printf '%s\n' "${bundle_names[@]}" | sort)
    actual_candidate_bundles=$(find "$bundle_source" -mindepth 1 -maxdepth 1 \
        -type f -printf '%f\n' | sort)
    unsafe_candidate_bundle=$(find "$bundle_source" -mindepth 1 -maxdepth 1 \
        ! -type f -print -quit)
    [[ -z "$unsafe_candidate_bundle" && \
       "$actual_candidate_bundles" == "$expected_candidate_bundles" ]] || \
        die 'candidate bundle directory does not contain exactly three locked archives'
fi

output_input=$(resolve_from_project "$output_input")
output_normalized=$(realpath -m -- "$output_input")
[[ "$output_normalized" != / && "$output_normalized" != "$PROJECT_ROOT" ]] || \
    die 'output directory may not be the filesystem or project root'
output_name=$(basename -- "$output_normalized")
[[ "$output_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    die "unsafe output directory name: $output_name"
output_parent_input=$(dirname -- "$output_normalized")
mkdir -p -- "$output_parent_input"
[[ -d "$output_parent_input" && ! -L "$output_parent_input" ]] || \
    die "output parent must be a real directory: $output_parent_input"
output_parent=$(realpath -e -- "$output_parent_input")
output_dir="$output_parent/$output_name"

paths_overlap() {
    local left=${1:?left path required}
    local right=${2:?right path required}
    case "$left/" in "$right/"*) return 0 ;; esac
    case "$right/" in "$left/"*) return 0 ;; esac
    return 1
}
for source_root in "$imagebuilder_source" "$bundle_source" "$LOCKS_DIR"; do
    ! paths_overlap "$output_dir" "$source_root" || \
        die "output directory overlaps an input directory: $source_root"
done

output_lock="$output_parent/.$output_name.lock"
require_regular_file_or_absent "$output_lock" 'locked-input staging lock'
exec {output_lock_fd}>"$output_lock"
flock "$output_lock_fd"

expected_release_manifest=$(mktemp "$output_parent/.$output_name.manifest.XXXXXXXX")
temporary_paths+=("$expected_release_manifest")
{
    for ((index = 0; index < ${#imagebuilder_names[@]}; index++)); do
        printf '%s  %s\n' "${imagebuilder_hashes[$index]}" \
            "${imagebuilder_names[$index]}"
    done
    for ((index = 0; index < ${#bundle_names[@]}; index++)); do
        printf '%s  %s\n' "${bundle_hashes[$index]}" "${bundle_names[$index]}"
    done
} | sort -k2,2 > "$expected_release_manifest"

expected_release_files=$(printf '%s\n' SHA256SUMS "$all_names" | sort)
validate_release_tree() {
    local tree=${1:?release tree required}
    local unsafe_entry actual_files

    [[ -d "$tree" && ! -L "$tree" ]] || \
        die "locked-input release is not a real directory: $tree"
    unsafe_entry=$(find "$tree" -mindepth 1 -maxdepth 1 ! -type f -print -quit)
    [[ -z "$unsafe_entry" ]] || \
        die "locked-input release contains a non-regular entry: $unsafe_entry"
    actual_files=$(find "$tree" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
    [[ "$actual_files" == "$expected_release_files" ]] || \
        die 'locked-input release does not contain exactly six assets and SHA256SUMS'
    [[ -f "$tree/SHA256SUMS" && ! -L "$tree/SHA256SUMS" ]] || \
        die 'locked-input release checksum manifest is not a regular file'
    cmp -s -- "$expected_release_manifest" "$tree/SHA256SUMS" || \
        die 'locked-input release checksum manifest differs from its locks'
    for ((index = 0; index < ${#imagebuilder_names[@]}; index++)); do
        validate_locked_file "$tree/${imagebuilder_names[$index]}" \
            "${imagebuilder_hashes[$index]}" "${imagebuilder_sizes[$index]}" \
            'staged ImageBuilder'
    done
    for ((index = 0; index < ${#bundle_names[@]}; index++)); do
        validate_locked_file "$tree/${bundle_names[$index]}" \
            "${bundle_hashes[$index]}" "${bundle_sizes[$index]}" \
            'staged package-snapshot bundle'
    done
}

verify_release_bundles() {
    local tree=${1:?release tree required}
    local extraction_root

    for ((index = 0; index < ${#bundle_names[@]}; index++)); do
        extraction_root=$(mktemp -d \
            "$output_parent/.$output_name.snapshot-${targets[$index]}.XXXXXXXX")
        temporary_paths+=("$extraction_root")
        python3 "$INPUT_SCRIPTS_DIR/verify-package-snapshot.py" extract \
            "$tree/${bundle_names[$index]}" "$extraction_root" \
            "$IMMORTALWRT_VERSION" "${targets[$index]}" \
            "${bundle_tree_hashes[$index]}" >/dev/null
        rm -rf -- "$extraction_root"
    done
}

if [[ -e "$output_dir" || -L "$output_dir" ]]; then
    validate_release_tree "$output_dir"
    verify_release_bundles "$output_dir"
    printf 'Locked-input release %s is already staged at %s\n' \
        "$LOCKED_INPUT_RELEASE_TAG" "$output_dir"
    exit 0
fi

stage_parent=$(mktemp -d "$output_parent/.$output_name.stage.XXXXXXXX")
temporary_paths+=("$stage_parent")
stage_dir="$stage_parent/payload"
mkdir -- "$stage_dir"
for name in "${imagebuilder_names[@]}"; do
    cp --reflink=auto -- "$imagebuilder_source/$name" "$stage_dir/$name"
done
for name in "${bundle_names[@]}"; do
    cp --reflink=auto -- "$bundle_source/$name" "$stage_dir/$name"
done
cp -- "$expected_release_manifest" "$stage_dir/SHA256SUMS"
chmod 0644 -- "$stage_dir"/*
validate_release_tree "$stage_dir"
verify_release_bundles "$stage_dir"

mv -Tn -- "$stage_dir" "$output_dir" || die 'cannot atomically publish staged inputs'
if [[ -e "$stage_dir" || -L "$stage_dir" ]]; then
    validate_release_tree "$output_dir"
fi
printf 'Staged locked-input release %s at %s\n' \
    "$LOCKED_INPUT_RELEASE_TAG" "$output_dir"
