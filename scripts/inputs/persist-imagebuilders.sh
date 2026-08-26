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
Usage: persist-imagebuilders.sh CANDIDATE_ROOT

Validate the three ImageBuilder archives in a reviewed lock candidate and
persist them in the local download store. Existing identical files are reused;
an existing conflicting file is never overwritten.

Environment overrides:
  IMAGEBUILDER_STORE_DIR  persistent archive directory
  DOWNLOAD_DIR            fallback for IMAGEBUILDER_STORE_DIR
EOF
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
for tool in cp find flock mktemp mv realpath sha256sum sort stat; do
    require_command "$tool"
done

candidate_input=$1
[[ -d "$candidate_input" && ! -L "$candidate_input" ]] || \
    die "candidate root must be a real directory: $candidate_input"
candidate_root=$(realpath -e -- "$candidate_input")
[[ "$candidate_root" != / ]] || die 'candidate root may not be the filesystem root'

RELEASE_LOCK="$candidate_root/locks/release.env"
TARGET_LOCK="$candidate_root/locks/targets.tsv"
load_release_lock
candidate_archives="$candidate_root/imagebuilders"
[[ -d "$candidate_archives" && ! -L "$candidate_archives" ]] || \
    die 'candidate is missing a safe imagebuilders directory'

declare -a archive_names=()
declare -a archive_hashes=()
declare -a archive_bytes=()
for target_name in x86_64 rpi4 rpi5; do
    load_target_lock "$target_name"
    archive_names+=("$IMAGEBUILDER_FILE")
    archive_hashes+=("$IMAGEBUILDER_SHA256")
    archive_bytes+=("$IMAGEBUILDER_BYTES")
done

expected_names=$(printf '%s\n' "${archive_names[@]}" | sort)
actual_names=$(find "$candidate_archives" -mindepth 1 -maxdepth 1 -type f \
    ! -name SHA256SUMS -printf '%f\n' | sort)
[[ "$actual_names" == "$expected_names" ]] || \
    die 'candidate ImageBuilder archive set differs from targets.tsv'
unsafe_entry=$(find "$candidate_archives" -mindepth 1 -maxdepth 1 \
    ! -type f -print -quit)
[[ -z "$unsafe_entry" ]] || \
    die "candidate ImageBuilder directory contains an unsafe entry: $unsafe_entry"

for index in "${!archive_names[@]}"; do
    source_file="$candidate_archives/${archive_names[$index]}"
    [[ -f "$source_file" && ! -L "$source_file" ]] || \
        die "candidate ImageBuilder is not a regular file: ${archive_names[$index]}"
    [[ $(stat -c '%s' "$source_file") == "${archive_bytes[$index]}" ]] || \
        die "candidate ImageBuilder byte-size mismatch: ${archive_names[$index]}"
    printf '%s  %s\n' "${archive_hashes[$index]}" "$source_file" \
        | sha256sum --strict --quiet -c - || \
        die "candidate ImageBuilder digest mismatch: ${archive_names[$index]}"
done

store_input=${IMAGEBUILDER_STORE_DIR:-${DOWNLOAD_DIR:-$PROJECT_ROOT/.cache/imagebuilders}}
[[ "$store_input" != *$'\n'* ]] || die 'ImageBuilder store contains a newline'
if [[ "$store_input" == /* ]]; then
    store_root=$store_input
else
    store_root="$PROJECT_ROOT/$store_input"
fi
if [[ -e "$store_root" || -L "$store_root" ]]; then
    [[ -d "$store_root" && ! -L "$store_root" ]] || \
        die "ImageBuilder store must be a real directory: $store_root"
else
    mkdir -p -- "$store_root"
fi
store_root=$(realpath -e -- "$store_root")
[[ "$store_root" != / ]] || die 'ImageBuilder store may not be the filesystem root'
case "$store_root/" in
    "$candidate_archives/"*) die 'ImageBuilder store may not be inside candidate data' ;;
esac

store_lock="$store_root/.imagebuilder-persist-$IMMORTALWRT_VERSION.lock"
require_regular_file_or_absent "$store_lock" 'ImageBuilder persistence lock'
exec {store_lock_fd}>"$store_lock"
flock "$store_lock_fd"

stage_root=$(mktemp -d "$store_root/.persist-imagebuilders.XXXXXXXX")
declare -a staged_names=()
declare -a published_names=()
transaction_complete=0
cleanup() {
    local status=$?
    trap - EXIT
    [[ ! -d "$stage_root" ]] || rm -rf -- "$stage_root"
    if (( status != 0 && transaction_complete == 0 )); then
        for name in "${published_names[@]}"; do
            rm -f -- "$store_root/$name"
        done
    fi
    exit "$status"
}
trap cleanup EXIT

for index in "${!archive_names[@]}"; do
    name=${archive_names[$index]}
    destination="$store_root/$name"
    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -f "$destination" && ! -L "$destination" ]] || \
            die "persisted ImageBuilder is not a regular file: $destination"
        [[ $(stat -c '%s' "$destination") == "${archive_bytes[$index]}" ]] || \
            die "persisted ImageBuilder conflicts with candidate: $name"
        printf '%s  %s\n' "${archive_hashes[$index]}" "$destination" \
            | sha256sum --strict --quiet -c - || \
            die "persisted ImageBuilder conflicts with candidate: $name"
        continue
    fi
    cp --reflink=auto -- "$candidate_archives/$name" "$stage_root/$name"
    staged_names+=("$name")
done

for name in "${staged_names[@]}"; do
    if mv -Tn -- "$stage_root/$name" "$store_root/$name"; then
        if [[ ! -e "$stage_root/$name" ]]; then
            published_names+=("$name")
            continue
        fi
    fi
    # Another writer may have won between the initial check and publication.
    index=-1
    for candidate_index in "${!archive_names[@]}"; do
        [[ ${archive_names[$candidate_index]} == "$name" ]] && index=$candidate_index
    done
    (( index >= 0 )) || die "internal archive index failure: $name"
    destination="$store_root/$name"
    [[ -f "$destination" && ! -L "$destination" && \
       $(stat -c '%s' "$destination") == "${archive_bytes[$index]}" ]] || \
        die "concurrent ImageBuilder publication conflicted: $name"
    printf '%s  %s\n' "${archive_hashes[$index]}" "$destination" \
        | sha256sum --strict --quiet -c - || \
        die "concurrent ImageBuilder publication conflicted: $name"
done

transaction_complete=1
rm -rf -- "$stage_root"
trap - EXIT
flock -u "$store_lock_fd"
printf 'Persisted ImageBuilders for %s in %s\n' "$IMMORTALWRT_VERSION" "$store_root"
