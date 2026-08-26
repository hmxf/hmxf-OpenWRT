#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: index-package-cache.sh MODE [CACHE_ROOT [RELEASE TARGET]]

MODE is one of:
  update   Verify previously indexed APKs, add new APKs, and forget evicted APKs.
  verify   Require the index and cache to match exactly; do not change either.
  rebuild  Recreate the selected portion of the index after external validation.

CACHE_ROOT defaults to .cache/packages below the project root.  RELEASE and
TARGET must be supplied together.  When omitted, every release/target cache is
indexed.  The deterministic TSV index is written to CACHE_ROOT/index.tsv.

Set APK_METADATA_TOOL to an apk-tools 3 executable with the "adbdump" applet.
Without it, package/version/architecture are recorded as unavailable; hashes,
sizes, paths, and subsequent integrity checks remain fully functional.
EOF
}

[[ $# -le 4 ]] || { usage >&2; exit 2; }
mode=${1:-}
case "$mode" in
    update | verify | rebuild) ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
cache_root_input=${2:-"$PROJECT_ROOT/.cache/packages"}
release_scope=${3:-}
target_scope=${4:-}
if [[ -n "$release_scope" || -n "$target_scope" ]]; then
    [[ -n "$release_scope" && -n "$target_scope" ]] || \
        die 'RELEASE and TARGET must be supplied together'
    [[ "$release_scope" == SNAPSHOT || \
       "$release_scope" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || \
        die "unsafe release name: $release_scope"
    [[ "$target_scope" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
        die "unsafe target name: $target_scope"
fi

for tool in awk cmp find flock mktemp python3 realpath sha256sum sort stat; do
    command -v "$tool" >/dev/null 2>&1 || die "required command not found: $tool"
done

[[ -d "$cache_root_input" && ! -L "$cache_root_input" ]] || \
    die "cache root must be a real directory, not a symlink: $cache_root_input"
cache_root=$(realpath -e -- "$cache_root_input")
[[ "$cache_root" != / ]] || die 'refusing to index the filesystem root'

unsafe_entry=$(find "$cache_root" -mindepth 1 ! -type d ! -type f -print -quit)
[[ -z "$unsafe_entry" ]] || die "cache contains a symbolic link or special file: $unsafe_entry"

index_file="$cache_root/index.tsv"
index_lock="$cache_root/.package-cache-index.lock"
if [[ -e "$index_file" || -L "$index_file" ]]; then
    [[ -f "$index_file" && ! -L "$index_file" ]] || \
        die "index is not a regular file: $index_file"
fi
if [[ -e "$index_lock" || -L "$index_lock" ]]; then
    [[ -f "$index_lock" && ! -L "$index_lock" ]] || \
        die "index lock is not a regular file: $index_lock"
fi
exec {index_lock_fd}>"$index_lock"
flock "$index_lock_fd"

header_schema='# package-cache-index-v1'
header_columns=$'# release\ttarget\tfilename\tpackage\tversion\tarchitecture\tsize\tsha256\tmetadata_status'

validate_index() {
    local candidate=$1
    awk -F '\t' -v schema="$header_schema" -v columns="$header_columns" '
        NR == 1 { if ($0 != schema) exit 1; next }
        NR == 2 { if ($0 != columns) exit 1; next }
        NR >= 3 {
            if (NF != 9 ||
                $1 !~ /^([0-9]+[.][0-9]+[.][0-9]+|SNAPSHOT)$/ ||
                $2 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ ||
                $3 !~ /^[A-Za-z0-9][A-Za-z0-9+._~:-]*[.]apk$/ ||
                ($4 != "-" && $4 !~ /^[A-Za-z0-9][A-Za-z0-9+._~:-]*$/) ||
                ($5 != "-" && $5 !~ /^[A-Za-z0-9][A-Za-z0-9+._~:-]*$/) ||
                ($6 != "-" && $6 !~ /^[A-Za-z0-9][A-Za-z0-9+._~-]*$/) ||
                $7 !~ /^(0|[1-9][0-9]*)$/ ||
                $8 !~ /^[0-9a-f]{64}$/ ||
                $9 !~ /^(apk-adbdump|unavailable)$/) exit 1
            if (($9 == "unavailable") != ($4 == "-" && $5 == "-" && $6 == "-"))
                exit 1
            if ($9 == "apk-adbdump" && ($4 == "-" || $5 == "-" || $6 == "-"))
                exit 1
            key = $1 SUBSEP $2 SUBSEP $3
            if (seen[key]++) exit 1
            if (previous != "" && $0 < previous) exit 1
            previous = $0
        }
        END { if (NR < 2) exit 1 }
    ' "$candidate" || die "invalid or non-deterministically sorted cache index: $candidate"
}

declare -A old_row=()
if [[ -e "$index_file" ]]; then
    validate_index "$index_file"
    while IFS=$'\t' read -r release target filename package version architecture size digest status; do
        [[ "$release" != '# package-cache-index-v1' && "$release" != '# release' ]] || continue
        old_row["$release"$'\t'"$target"$'\t'"$filename"]="$release"$'\t'"$target"$'\t'"$filename"$'\t'"$package"$'\t'"$version"$'\t'"$architecture"$'\t'"$size"$'\t'"$digest"$'\t'"$status"
    done < "$index_file"
elif [[ "$mode" == verify ]]; then
    die "cache index does not exist: $index_file"
fi

apk_tool=
if [[ -n ${APK_METADATA_TOOL:-} ]]; then
    apk_tool=$(realpath -e -- "$APK_METADATA_TOOL") || \
        die "APK_METADATA_TOOL does not exist: $APK_METADATA_TOOL"
    [[ -f "$apk_tool" && -x "$apk_tool" ]] || \
        die "APK_METADATA_TOOL is not an executable regular file: $apk_tool"
elif command -v apk >/dev/null 2>&1; then
    apk_help=$(apk adbdump --help 2>&1 || true)
    [[ "$apk_help" == *'Usage: apk adbdump'* ]] && \
        apk_tool=$(realpath -e -- "$(command -v apk)")
fi
if [[ -n "$apk_tool" ]]; then
    apk_help=$("$apk_tool" adbdump --help 2>&1 || true)
    [[ "$apk_help" == *'Usage: apk adbdump'* ]] || \
        die "APK metadata tool lacks the adbdump applet: $apk_tool"
fi

work_dir=
output_tmp=
cleanup() {
    [[ -z "$work_dir" || ! -d "$work_dir" ]] || rm -rf -- "$work_dir"
    [[ -z "$output_tmp" || ! -e "$output_tmp" ]] || rm -f -- "$output_tmp"
}
trap cleanup EXIT
work_dir=$(mktemp -d /tmp/hmxf-package-index.XXXXXXXX)
output_tmp=$(mktemp "$cache_root/.package-cache-index.XXXXXXXX")

scope_matches() {
    local release=$1
    local target=$2
    [[ -z "$release_scope" || \
       "$release" == "$release_scope" && "$target" == "$target_scope" ]]
}

declare -a cache_dirs=()
if [[ -n "$release_scope" ]]; then
    scoped_dir="$cache_root/$release_scope/$target_scope"
    [[ -d "$scoped_dir" && ! -L "$scoped_dir" ]] || \
        die "cache scope does not exist: $scoped_dir"
    [[ $(realpath -e -- "$scoped_dir") == "$scoped_dir" ]] || \
        die "cache scope resolves outside its canonical path: $scoped_dir"
    cache_dirs+=("$scoped_dir")
else
    while IFS= read -r -d '' apk_file; do
        relative=${apk_file#"$cache_root/"}
        IFS=/ read -r release target filename extra <<< "$relative"
        [[ -z ${extra:-} && -n "$release" && -n "$target" && -n "$filename" ]] || \
            die "APK is not stored as RELEASE/TARGET/FILENAME: $apk_file"
        [[ ( "$release" == SNAPSHOT || \
              "$release" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ) && \
           "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
            die "unsafe cache path: $relative"
        cache_dirs+=("$cache_root/$release/$target")
    done < <(find "$cache_root" -mindepth 1 \( -type f -o -type l \) \
        -name '*.apk' -print0 | sort -z)
    if (( ${#cache_dirs[@]} > 0 )); then
        mapfile -t cache_dirs < <(printf '%s\n' "${cache_dirs[@]}" | sort -u)
    fi
fi
(( ${#cache_dirs[@]} > 0 )) || die "cache contains no APK files: $cache_root"

# Serialize with ImageBuilder's per-target writer.  Integrations must call this
# script after releasing the same lock, never while holding it.
declare -a cache_lock_fds=()
for cache_dir in "${cache_dirs[@]}"; do
    [[ -d "$cache_dir" && ! -L "$cache_dir" ]] || \
        die "cache target is not a real directory: $cache_dir"
    unsafe_entry=$(find "$cache_dir" -mindepth 1 -maxdepth 1 \
        ! -type d ! -type f -print -quit)
    [[ -z "$unsafe_entry" ]] || \
        die "cache target contains a symbolic link or special file: $unsafe_entry"
    target_lock="$cache_dir/.imagebuilder.lock"
    if [[ -e "$target_lock" || -L "$target_lock" ]]; then
        [[ -f "$target_lock" && ! -L "$target_lock" ]] || \
            die "cache target lock is not a regular file: $target_lock"
    fi
    exec {target_lock_fd}>"$target_lock"
    flock "$target_lock_fd"
    cache_lock_fds+=("$target_lock_fd")
done

metadata_for_apk() {
    local apk_file=$1
    local filename=$2
    local json_file="$work_dir/metadata.json"
    local values_file="$work_dir/metadata.tsv"
    local package version architecture

    if [[ -z "$apk_tool" ]]; then
        printf '%s\t%s\t%s\t%s\n' - - - unavailable
        return
    fi
    "$apk_tool" adbdump --format json -- "$apk_file" > "$json_file" || \
        die "cannot read APK metadata: $apk_file"
    python3 - "$json_file" "$values_file" <<'PY'
import json
import re
import sys

def reject_constant(value):
    raise ValueError(f"invalid JSON constant: {value}")

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result

with open(sys.argv[1], "r", encoding="utf-8") as source:
    data = json.load(
        source,
        object_pairs_hook=reject_duplicates,
        parse_constant=reject_constant,
    )
info = data.get("info") if isinstance(data, dict) else None
if not isinstance(info, dict):
    raise SystemExit("APK metadata has no info object")
values = [info.get("name"), info.get("version"), info.get("arch")]
patterns = [
    r"[A-Za-z0-9][A-Za-z0-9+._~:-]*",
    r"[A-Za-z0-9][A-Za-z0-9+._~:-]*",
    r"[A-Za-z0-9][A-Za-z0-9+._~-]*",
]
if any(not isinstance(value, str) or not re.fullmatch(pattern, value)
       for value, pattern in zip(values, patterns)):
    raise SystemExit("APK metadata contains an unsafe package, version, or architecture")
with open(sys.argv[2], "w", encoding="utf-8", newline="") as output:
    output.write("\t".join(values) + "\n")
PY
    IFS=$'\t' read -r package version architecture < "$values_file"
    [[ "$filename" == "$package-$version."*.apk ]] || \
        die "APK filename disagrees with its metadata: $filename ($package $version)"
    printf '%s\t%s\t%s\t%s\n' "$package" "$version" "$architecture" apk-adbdump
}

read_apk_metadata() {
    local apk_file=$1
    local filename=$2
    local metadata
    metadata=$(metadata_for_apk "$apk_file" "$filename") || \
        die "cannot extract package identity: $apk_file"
    IFS=$'\t' read -r package version architecture status <<< "$metadata"
    [[ -n "$package" && -n "$version" && -n "$architecture" && -n "$status" ]] || \
        die "incomplete package identity: $apk_file"
}

rows_file="$work_dir/rows.tsv"
: > "$rows_file"
declare -A current_key=()
apk_count=0
for cache_dir in "${cache_dirs[@]}"; do
    relative_dir=${cache_dir#"$cache_root/"}
    IFS=/ read -r release target extra <<< "$relative_dir"
    [[ -z ${extra:-} && \
       ( "$release" == SNAPSHOT || \
         "$release" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ) && \
       "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
        die "unsafe cache target path: $relative_dir"
    while IFS= read -r -d '' apk_file; do
        [[ -f "$apk_file" && ! -L "$apk_file" ]] || \
            die "cached APK is not a regular file: $apk_file"
        filename=${apk_file##*/}
        [[ "$filename" =~ ^[A-Za-z0-9][A-Za-z0-9+._~:-]*[.]apk$ ]] || \
            die "unsafe APK filename: $filename"
        key="$release"$'\t'"$target"$'\t'"$filename"
        [[ -z ${current_key[$key]+present} ]] || die "duplicate cached APK: $key"
        current_key[$key]=1
        before=$(stat -c '%d:%i:%s:%Y:%Z' -- "$apk_file")
        size=$(stat -c '%s' -- "$apk_file")
        digest=$(sha256sum -- "$apk_file" | awk '{ print $1 }')
        after=$(stat -c '%d:%i:%s:%Y:%Z' -- "$apk_file")
        [[ "$before" == "$after" ]] || die "cached APK changed while hashing: $apk_file"

        if [[ -n ${old_row[$key]+present} && "$mode" != rebuild ]]; then
            IFS=$'\t' read -r _ _ _ old_package old_version old_architecture \
                old_size old_digest old_status <<< "${old_row[$key]}"
            [[ "$size" == "$old_size" && "$digest" == "$old_digest" ]] || \
                die "cached APK differs from its index (remove it to redownload): $apk_file"
            if [[ -z "$apk_tool" ]]; then
                package=$old_package
                version=$old_version
                architecture=$old_architecture
                status=$old_status
            else
                read_apk_metadata "$apk_file" "$filename"
                if [[ "$old_status" == apk-adbdump && \
                      ( "$package" != "$old_package" || \
                        "$version" != "$old_version" || \
                        "$architecture" != "$old_architecture" || \
                        "$status" != "$old_status" ) ]]; then
                    die "cached APK metadata differs from its index: $apk_file"
                fi
            fi
        else
            read_apk_metadata "$apk_file" "$filename"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$release" "$target" "$filename" "$package" "$version" \
            "$architecture" "$size" "$digest" "$status" >> "$rows_file"
        apk_count=$((apk_count + 1))
    done < <(find "$cache_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) \
        -name '*.apk' -print0 | sort -z)
done
(( apk_count > 0 )) || die 'selected cache scope contains no APK files'

if [[ "$mode" == verify ]]; then
    if [[ -z "$apk_tool" ]]; then
        printf '%s\n' \
            'Warning: APK metadata tool unavailable; verify checked paths, sizes, and SHA-256 only.' \
            >&2
    fi
    for key in "${!old_row[@]}"; do
        IFS=$'\t' read -r release target filename <<< "$key"
        scope_matches "$release" "$target" || continue
        [[ -n ${current_key[$key]+present} ]] || \
            die "indexed APK is missing from cache: $release/$target/$filename"
    done
    while IFS= read -r row; do
        IFS=$'\t' read -r release target filename _ <<< "$row"
        key="$release"$'\t'"$target"$'\t'"$filename"
        [[ -n ${old_row[$key]+present} && "$row" == "${old_row[$key]}" ]] || \
            die "cache has an unindexed or changed APK: $release/$target/$filename"
    done < "$rows_file"
    printf 'Verified %d cached APKs against %s\n' "$apk_count" "$index_file"
    exit 0
fi

# A scoped update retains validated rows for other targets.  Selected rows are
# regenerated so intentional cache eviction is reflected in the inventory.
if [[ -n "$release_scope" ]]; then
    for key in "${!old_row[@]}"; do
        IFS=$'\t' read -r release target _ <<< "$key"
        scope_matches "$release" "$target" && continue
        printf '%s\n' "${old_row[$key]}" >> "$rows_file"
    done
fi
{
    printf '%s\n' "$header_schema" "$header_columns"
    sort -u "$rows_file"
} > "$output_tmp"
validate_index "$output_tmp"
chmod 0644 "$output_tmp"
mv -- "$output_tmp" "$index_file"
printf 'Indexed %d cached APKs in %s\n' "$apk_count" "$index_file"
