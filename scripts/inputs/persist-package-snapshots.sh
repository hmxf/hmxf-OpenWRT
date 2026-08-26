#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
    cat <<'EOF'
Usage: persist-package-snapshots.sh CANDIDATE_ROOT

Persist a verified lock candidate's unpacked package snapshots and portable
snapshot bundles below versioned local roots. Relative override paths are
resolved from the project root.

Environment overrides:
  PACKAGE_SNAPSHOT_STORE_DIR         unpacked snapshot root
  PACKAGE_SNAPSHOT_BUNDLE_STORE_DIR  portable bundle root
EOF
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }

for tool in awk cp diff find flock grep mktemp mv realpath sha256sum sort stat; do
    require_command "$tool"
done

candidate_input=$1
[[ -d "$candidate_input" && ! -L "$candidate_input" ]] || \
    die "candidate root must be a real directory: $candidate_input"
candidate_root=$(realpath -e -- "$candidate_input")
[[ "$candidate_root" != / ]] || die 'candidate root may not be the filesystem root'

candidate_release_lock="$candidate_root/locks/release.env"
[[ -f "$candidate_release_lock" && ! -L "$candidate_release_lock" ]] || \
    die "candidate is missing a safe locks/release.env"
mapfile -t candidate_versions < <(
    awk -F= '$1 == "IMMORTALWRT_VERSION" { print $2 }' "$candidate_release_lock"
)
(( ${#candidate_versions[@]} == 1 )) || \
    die 'candidate release lock must contain exactly one IMMORTALWRT_VERSION'
candidate_version=${candidate_versions[0]}
[[ "$candidate_version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || \
    die "candidate has an unsafe release version: $candidate_version"

IMMORTALWRT_VERSION=$candidate_version
PACKAGE_SNAPSHOT_LOCK="$candidate_root/locks/package-snapshots.tsv"
validate_package_snapshot_lock

candidate_snapshot_version="$candidate_root/package-snapshots/$candidate_version"
candidate_bundle_root="$candidate_root/package-snapshot-bundles"
[[ -d "$candidate_snapshot_version" && ! -L "$candidate_snapshot_version" ]] || \
    die "candidate is missing a safe package snapshot tree for $candidate_version"
[[ -d "$candidate_bundle_root" && ! -L "$candidate_bundle_root" ]] || \
    die 'candidate is missing a safe package-snapshot-bundles directory'

validate_regular_tree() {
    local tree=${1:?tree required}
    local label=${2:?tree label required}
    local unsafe_entry

    [[ -d "$tree" && ! -L "$tree" ]] || die "$label is not a real directory: $tree"
    unsafe_entry=$(find "$tree" -mindepth 1 ! -type d ! -type f -print -quit)
    [[ -z "$unsafe_entry" ]] || die "$label contains a symbolic link or special file: $unsafe_entry"
}

validate_regular_tree "$candidate_snapshot_version" 'candidate package snapshot tree'
validate_regular_tree "$candidate_bundle_root" 'candidate package snapshot bundle tree'

declare -a expected_targets=()
declare -a expected_bundle_names=()
declare -a expected_bundle_hashes=()
declare -a expected_bundle_bytes=()
declare -a expected_tree_hashes=()
while IFS='|' read -r snapshot_target snapshot_file snapshot_sha snapshot_bytes \
        snapshot_tree_sha snapshot_extra; do
    [[ -n "$snapshot_target" && ${snapshot_target:0:1} != '#' ]] || continue
    [[ -z "$snapshot_extra" ]] || die "invalid snapshot row for $snapshot_target"
    expected_targets+=("$snapshot_target")
    expected_bundle_names+=("$snapshot_file")
    expected_bundle_hashes+=("$snapshot_sha")
    expected_bundle_bytes+=("$snapshot_bytes")
    expected_tree_hashes+=("$snapshot_tree_sha")
done < "$PACKAGE_SNAPSHOT_LOCK"

expected_target_list=$(printf '%s\n' "${expected_targets[@]}" | sort)
actual_target_list=$(find "$candidate_snapshot_version" -mindepth 1 -maxdepth 1 \
    -type d -printf '%f\n' | sort)
[[ "$actual_target_list" == "$expected_target_list" ]] || \
    die 'candidate package snapshot target set differs from package-snapshots.tsv'
unexpected_snapshot_root_file=$(find "$candidate_snapshot_version" -mindepth 1 -maxdepth 1 \
    -type f -print -quit)
[[ -z "$unexpected_snapshot_root_file" ]] || \
    die "candidate snapshot version root contains an unexpected file: $unexpected_snapshot_root_file"

validate_snapshot_target() {
    local target_snapshot=${1:?target snapshot required}
    local snapshot_target=${2:?snapshot target required}
    local expected_tree_sha=${3:?expected tree-manifest SHA-256 required}

    [[ -f "$target_snapshot/SHA256SUMS" && ! -L "$target_snapshot/SHA256SUMS" && \
       -s "$target_snapshot/SHA256SUMS" ]] || \
        die "candidate snapshot target has no safe SHA256SUMS: $snapshot_target"
    [[ -f "$target_snapshot/repositories.list" && \
       ! -L "$target_snapshot/repositories.list" && \
       -s "$target_snapshot/repositories.list" ]] || \
        die "candidate snapshot target has no safe repositories.list: $snapshot_target"

    (
        cd "$target_snapshot"
        printf '%s  %s\n' "$expected_tree_sha" SHA256SUMS \
            | sha256sum --strict --quiet -c - || \
            die "candidate snapshot tree manifest differs from its external lock: $snapshot_target"
        awk '
            NF != 2 || $1 !~ /^[0-9a-f]{64}$/ { exit 1 }
            {
                name = $2
                sub(/^\*/, "", name)
                if (name !~ /^(repositories[.]list|repo-[1-9][0-9]*\/[A-Za-z0-9][A-Za-z0-9+._~:-]*)$/ ||
                    seen[name]++) exit 1
            }
        ' SHA256SUMS || die "candidate snapshot has unsafe checksum entries: $snapshot_target"
        locked_names=$(awk '{ sub(/^\*/, "", $2); print $2 }' SHA256SUMS | sort)
        actual_names=$(find . -type f ! -name SHA256SUMS -printf '%P\n' | sort)
        [[ "$locked_names" == "$actual_names" ]] || \
            die "candidate snapshot file set differs from SHA256SUMS: $snapshot_target"
        while IFS= read -r locked_name; do
            [[ -f "$locked_name" && ! -L "$locked_name" ]] || \
                die "candidate snapshot entry is not a regular file: $snapshot_target/$locked_name"
        done <<< "$locked_names"
        sha256sum --strict --quiet -c SHA256SUMS || \
            die "candidate snapshot content failed SHA-256 verification: $snapshot_target"

        repository_number=0
        expected_repository_dirs=
        while IFS= read -r repository_name; do
            repository_number=$((repository_number + 1))
            [[ "$repository_name" == "repo-$repository_number" ]] || \
                die "candidate snapshot repository list is not contiguous: $snapshot_target"
            repository_dir="$target_snapshot/$repository_name"
            [[ -d "$repository_dir" && ! -L "$repository_dir" && \
               -f "$repository_dir/packages.adb" && \
               ! -L "$repository_dir/packages.adb" && \
               -s "$repository_dir/packages.adb" ]] || \
                die "candidate snapshot repository has no safe index: $snapshot_target/$repository_name"
            expected_repository_dirs=${expected_repository_dirs:+"$expected_repository_dirs"$'\n'}$repository_name
            while IFS= read -r repository_file; do
                [[ "$repository_file" == packages.adb || \
                   "$repository_file" =~ ^[A-Za-z0-9][A-Za-z0-9+._~:-]*[.]apk$ ]] || \
                    die "unsafe candidate snapshot file: $snapshot_target/$repository_name/$repository_file"
            done < <(find "$repository_dir" -mindepth 1 -maxdepth 1 \
                -type f -printf '%f\n' | sort)
        done < repositories.list
        (( repository_number > 0 )) || \
            die "candidate snapshot repository list is empty: $snapshot_target"
        actual_repository_dirs=$(find . -mindepth 1 -maxdepth 1 -type d \
            -printf '%f\n' | sort -V)
        [[ "$actual_repository_dirs" == "$expected_repository_dirs" ]] || \
            die "candidate snapshot directory set differs from repositories.list: $snapshot_target"
        nested_repository_dir=$(find . -mindepth 2 -type d -print -quit)
        [[ -z "$nested_repository_dir" ]] || \
            die "candidate snapshot contains a nested directory: $snapshot_target/$nested_repository_dir"
    )
}

for snapshot_index in "${!expected_targets[@]}"; do
    snapshot_target=${expected_targets[$snapshot_index]}
    target_snapshot="$candidate_snapshot_version/$snapshot_target"
    validate_snapshot_target "$target_snapshot" "$snapshot_target" \
        "${expected_tree_hashes[$snapshot_index]}"
done

expected_bundle_list=$(printf '%s\n' "${expected_bundle_names[@]}" | sort)
actual_bundle_list=$(find "$candidate_bundle_root" -mindepth 1 -maxdepth 1 \
    -type f -printf '%f\n' | sort)
[[ "$actual_bundle_list" == "$expected_bundle_list" ]] || \
    die 'candidate package snapshot bundle set differs from package-snapshots.tsv'
unexpected_bundle_entry=$(find "$candidate_bundle_root" -mindepth 1 -maxdepth 1 \
    ! -type f -print -quit)
[[ -z "$unexpected_bundle_entry" ]] || \
    die "candidate bundle root contains an unexpected entry: $unexpected_bundle_entry"
for ((bundle_index = 0; bundle_index < ${#expected_bundle_names[@]}; bundle_index++)); do
    bundle_name=${expected_bundle_names[$bundle_index]}
    bundle_file="$candidate_bundle_root/$bundle_name"
    [[ -f "$bundle_file" && ! -L "$bundle_file" ]] || \
        die "candidate snapshot bundle is not a regular file: $bundle_name"
    [[ $(stat -c '%s' "$bundle_file") == "${expected_bundle_bytes[$bundle_index]}" ]] || \
        die "candidate snapshot bundle byte-size mismatch: $bundle_name"
    printf '%s  %s\n' "${expected_bundle_hashes[$bundle_index]}" "$bundle_file" \
        | sha256sum --strict --quiet -c - || \
        die "candidate snapshot bundle digest mismatch: $bundle_name"
done

resolve_store_root() {
    local input=${1:?store root required}
    local label=${2:?store label required}
    local path

    [[ "$input" != *$'\n'* ]] || die "$label contains a newline"
    if [[ "$input" == /* ]]; then
        path=$input
    else
        path="$PROJECT_ROOT/$input"
    fi
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -d "$path" && ! -L "$path" ]] || \
            die "$label must be a real directory: $path"
    else
        mkdir -p -- "$path"
    fi
    path=$(realpath -e -- "$path")
    [[ "$path" != / ]] || die "$label may not be the filesystem root"
    printf '%s\n' "$path"
}

snapshot_store_root=$(resolve_store_root \
    "${PACKAGE_SNAPSHOT_STORE_DIR:-$PROJECT_ROOT/.cache/package-snapshots}" \
    'package snapshot store root')
bundle_store_root=$(resolve_store_root \
    "${PACKAGE_SNAPSHOT_BUNDLE_STORE_DIR:-$PROJECT_ROOT/.cache/package-snapshot-bundles}" \
    'package snapshot bundle store root')
snapshot_destination="$snapshot_store_root/$candidate_version"
bundle_destination="$bundle_store_root/$candidate_version"

case "$snapshot_destination/" in
    "$bundle_destination/"*) die 'snapshot and bundle version destinations overlap' ;;
esac
case "$bundle_destination/" in
    "$snapshot_destination/"*) die 'snapshot and bundle version destinations overlap' ;;
esac
for store_root in "$snapshot_store_root" "$bundle_store_root"; do
    case "$store_root/" in
        "$candidate_snapshot_version/"* | "$candidate_bundle_root/"*)
            die "persistent store root may not be inside candidate snapshot data: $store_root"
            ;;
    esac
done

# Acquire both store locks in lexical order. This also serializes callers that
# share only one of the two configurable roots without introducing lock-order
# inversions.
snapshot_store_lock="$snapshot_store_root/.package-snapshot-persist-$candidate_version.lock"
bundle_store_lock="$bundle_store_root/.package-snapshot-persist-$candidate_version.lock"
mapfile -t store_locks < <(printf '%s\n' "$snapshot_store_lock" "$bundle_store_lock" | sort -u)
declare -a store_lock_fds=()
for store_lock in "${store_locks[@]}"; do
    require_regular_file_or_absent "$store_lock" 'package snapshot persistence lock'
    exec {store_lock_fd}>"$store_lock"
    flock "$store_lock_fd"
    store_lock_fds+=("$store_lock_fd")
done

trees_equal() {
    local left=${1:?left tree required}
    local right=${2:?right tree required}
    diff -qr --no-dereference -- "$left" "$right" >/dev/null
}

snapshot_needed=1
if [[ -e "$snapshot_destination" || -L "$snapshot_destination" ]]; then
    validate_regular_tree "$snapshot_destination" 'persisted package snapshot tree'
    trees_equal "$candidate_snapshot_version" "$snapshot_destination" || \
        die "persisted package snapshot conflicts with candidate version $candidate_version"
    snapshot_needed=0
fi

bundle_needed=1
if [[ -e "$bundle_destination" || -L "$bundle_destination" ]]; then
    validate_regular_tree "$bundle_destination" 'persisted package snapshot bundle tree'
    trees_equal "$candidate_bundle_root" "$bundle_destination" || \
        die "persisted package snapshot bundles conflict with candidate version $candidate_version"
    bundle_needed=0
fi

snapshot_stage_parent=
snapshot_stage=
bundle_stage_parent=
bundle_stage=
snapshot_published=0
bundle_published=0
transaction_complete=0
cleanup() {
    local status=$?
    trap - EXIT
    [[ -z "$snapshot_stage_parent" || ! -d "$snapshot_stage_parent" ]] || \
        rm -rf -- "$snapshot_stage_parent"
    [[ -z "$bundle_stage_parent" || ! -d "$bundle_stage_parent" ]] || \
        rm -rf -- "$bundle_stage_parent"
    if (( status != 0 && transaction_complete == 0 )); then
        if (( bundle_published == 1 )); then
            rm -rf -- "$bundle_destination"
        fi
        if (( snapshot_published == 1 )); then
            rm -rf -- "$snapshot_destination"
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

if (( snapshot_needed == 1 )); then
    snapshot_stage_parent=$(mktemp -d \
        "$snapshot_store_root/.persist-$candidate_version-snapshots.XXXXXXXX")
    snapshot_stage="$snapshot_stage_parent/payload"
    cp -a --reflink=auto -- "$candidate_snapshot_version" "$snapshot_stage"
    validate_regular_tree "$snapshot_stage" 'staged package snapshot tree'
    trees_equal "$candidate_snapshot_version" "$snapshot_stage" || \
        die 'staged package snapshot tree differs from its candidate source'
fi
if (( bundle_needed == 1 )); then
    bundle_stage_parent=$(mktemp -d \
        "$bundle_store_root/.persist-$candidate_version-bundles.XXXXXXXX")
    bundle_stage="$bundle_stage_parent/payload"
    cp -a --reflink=auto -- "$candidate_bundle_root" "$bundle_stage"
    validate_regular_tree "$bundle_stage" 'staged package snapshot bundle tree'
    trees_equal "$candidate_bundle_root" "$bundle_stage" || \
        die 'staged package snapshot bundle tree differs from its candidate source'
fi

publish_staged_tree() {
    local staged=${1:?staged tree required}
    local destination=${2:?destination required}
    local source=${3:?source tree required}
    local label=${4:?tree label required}

    mv -Tn -- "$staged" "$destination" || die "cannot publish $label"
    if [[ -e "$staged" || -L "$staged" ]]; then
        validate_regular_tree "$destination" "$label"
        trees_equal "$source" "$destination" || \
            die "$label appeared concurrently with conflicting content"
        return 1
    fi
    return 0
}

if (( snapshot_needed == 1 )); then
    if publish_staged_tree "$snapshot_stage" "$snapshot_destination" \
            "$candidate_snapshot_version" 'persisted package snapshot tree'; then
        snapshot_published=1
    fi
fi
if (( bundle_needed == 1 )); then
    if publish_staged_tree "$bundle_stage" "$bundle_destination" \
            "$candidate_bundle_root" 'persisted package snapshot bundle tree'; then
        bundle_published=1
    fi
fi

validate_regular_tree "$snapshot_destination" 'persisted package snapshot tree'
validate_regular_tree "$bundle_destination" 'persisted package snapshot bundle tree'
trees_equal "$candidate_snapshot_version" "$snapshot_destination" || \
    die 'published package snapshot tree failed its final comparison'
trees_equal "$candidate_bundle_root" "$bundle_destination" || \
    die 'published package snapshot bundle tree failed its final comparison'
transaction_complete=1

printf 'Persisted package snapshots for %s in %s and %s\n' \
    "$candidate_version" "$snapshot_destination" "$bundle_destination"
