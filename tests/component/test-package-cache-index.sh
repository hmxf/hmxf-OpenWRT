#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
INDEX_SCRIPT="$PROJECT_ROOT/scripts/cache/index-package-cache.sh"
MAP_SCRIPT="$PROJECT_ROOT/scripts/cache/map-package-snapshot.py"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

for tool in awk bash chmod cmp cp dirname find flock ln mkdir mkfifo mktemp mv \
    python3 realpath rm sed sha256sum sort stat; do
    command -v "$tool" >/dev/null 2>&1 || die "required test command not found: $tool"
done
[[ -x "$INDEX_SCRIPT" ]] || die "package cache indexer is not executable: $INDEX_SCRIPT"
[[ -x "$MAP_SCRIPT" ]] || die "package snapshot mapper is not executable: $MAP_SCRIPT"

temporary_dir=$(mktemp -d /tmp/hmxf-package-cache-test.XXXXXXXX)
cache_root="$temporary_dir/cache"
isolated_bin="$temporary_dir/bin"
mkdir -p "$isolated_bin"
cleanup() {
    rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

# The production host may have apk-tools installed.  Build an explicit PATH
# containing every command used by the indexer except apk, so these fixtures
# always exercise its deterministic metadata-unavailable path.
for tool in awk bash chmod cmp dirname find flock mktemp mv python3 realpath rm \
    sha256sum sort stat; do
    ln -s -- "$(command -v "$tool")" "$isolated_bin/$tool"
done

run_index() {
    PATH="$isolated_bin" APK_METADATA_TOOL='' \
        "$isolated_bin/bash" "$INDEX_SCRIPT" "$@"
}

expect_failure() {
    local description=$1
    shift
    if "$@" >"$temporary_dir/failure.log" 2>&1; then
        die "negative package-cache test unexpectedly passed: $description"
    fi
}

reset_fixture() {
    rm -rf -- "$cache_root"
    mkdir -p "$cache_root/25.12.1/x86_64"
    printf '%s\n' 'fixture alpha' \
        > "$cache_root/25.12.1/x86_64/alpha-1.0-r1.11111111.apk"
}

# Basic inventory and exact verification, with metadata extraction explicitly
# unavailable rather than guessed from the filename.
reset_fixture
run_index update "$cache_root" 25.12.1 x86_64 >/dev/null
run_index verify "$cache_root" 25.12.1 x86_64 >/dev/null
awk -F '\t' '
    NR == 3 && $1 == "25.12.1" && $2 == "x86_64" &&
    $3 == "alpha-1.0-r1.11111111.apk" &&
    $4 == "-" && $5 == "-" && $6 == "-" &&
    $7 ~ /^[1-9][0-9]*$/ && $8 ~ /^[0-9a-f]{64}$/ &&
    $9 == "unavailable" { valid = 1 }
    END { exit !valid }
' "$cache_root/index.tsv" || die 'basic cache index row is malformed'

# Updating unchanged input must reproduce the exact same index bytes.
cp -- "$cache_root/index.tsv" "$temporary_dir/index.before"
run_index update "$cache_root" 25.12.1 x86_64 >/dev/null
cmp -s "$temporary_dir/index.before" "$cache_root/index.tsv" || \
    die 'unchanged cache produced a non-deterministic index'

# A cached path may not silently acquire different content after it is indexed.
printf '%s\n' 'tampered payload' \
    > "$cache_root/25.12.1/x86_64/alpha-1.0-r1.11111111.apk"
expect_failure 'cached APK content tamper' \
    run_index verify "$cache_root" 25.12.1 x86_64

# A syntactically valid but false digest in the index must also be detected.
reset_fixture
run_index update "$cache_root" 25.12.1 x86_64 >/dev/null
sed -i '3s/[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' \
    "$cache_root/index.tsv"
expect_failure 'cache index digest tamper' \
    run_index verify "$cache_root" 25.12.1 x86_64

# Symbolic links anywhere below the cache root are rejected before hashing.
reset_fixture
ln -s -- alpha-1.0-r1.11111111.apk \
    "$cache_root/25.12.1/x86_64/alias-1.0-r1.22222222.apk"
expect_failure 'symbolic link in cache' \
    run_index update "$cache_root" 25.12.1 x86_64

# Special nodes cannot masquerade as either cache data or synchronization state.
reset_fixture
mkfifo "$cache_root/25.12.1/x86_64/.imagebuilder.lock"
expect_failure 'special cache lock node' \
    run_index update "$cache_root" 25.12.1 x86_64

# Updating one release/target scope must retain byte-identical rows belonging to
# another target while deterministically adding new rows to the selected scope.
reset_fixture
mkdir -p "$cache_root/25.12.1/rpi4"
printf '%s\n' 'fixture beta' \
    > "$cache_root/25.12.1/rpi4/beta-2.0-r3.22222222.apk"
run_index update "$cache_root" >/dev/null
rpi4_before=$(awk -F '\t' '$1 == "25.12.1" && $2 == "rpi4" { print }' \
    "$cache_root/index.tsv")
[[ -n "$rpi4_before" ]] || die 'fixture did not create the other-target row'
printf '%s\n' 'fixture gamma' \
    > "$cache_root/25.12.1/x86_64/gamma-3.0-r2.33333333.apk"
run_index update "$cache_root" 25.12.1 x86_64 >/dev/null
rpi4_after=$(awk -F '\t' '$1 == "25.12.1" && $2 == "rpi4" { print }' \
    "$cache_root/index.tsv")
[[ "$rpi4_after" == "$rpi4_before" ]] || \
    die 'scoped update changed an unrelated target row'
[[ $(awk -F '\t' '$1 == "25.12.1" && $2 == "x86_64" { count++ } END { print count + 0 }' \
    "$cache_root/index.tsv") == 2 ]] || die 'scoped update did not add the new APK'
run_index verify "$cache_root" >/dev/null

# Repository indexes use canonical name-version.apk paths, while the download
# cache adds the first eight characters of the repository package hash.  Build
# a strict fixture with a stale and a current variant of the same name/version.
mapping_root="$temporary_dir/mapping-cache"
mapping_rows="$temporary_dir/mapping.rows"
mapping_manifest="$temporary_dir/mapping.manifest"
repository_one="$temporary_dir/repo-1.json"
repository_two="$temporary_dir/repo-2.json"
repository_two_missing="$temporary_dir/repo-2-missing.json"
mapping_output="$temporary_dir/mapping.out"
expected_mapping="$temporary_dir/mapping.expected"
mkdir -p \
    "$mapping_root/25.12.1/x86_64" \
    "$mapping_root/25.12.1/rpi4" \
    "$mapping_root/26.1.0/x86_64"
printf '%s\n' 'stale x86 alpha' \
    > "$mapping_root/25.12.1/x86_64/alpha-1.0-r1.11111111.apk"
printf '%s\n' 'current x86 alpha' \
    > "$mapping_root/25.12.1/x86_64/alpha-1.0-r1.aaaaaaaa.apk"
printf '%s\n' 'current x86 beta' \
    > "$mapping_root/25.12.1/x86_64/beta-2.0-r1.bbbbbbbb.apk"
printf '%s\n' 'other target alpha' \
    > "$mapping_root/25.12.1/rpi4/alpha-1.0-r1.aaaaaaaa.apk"
printf '%s\n' 'other release alpha' \
    > "$mapping_root/26.1.0/x86_64/alpha-1.0-r1.aaaaaaaa.apk"

: > "$mapping_rows"
mapping_index_row() {
    local release=$1
    local target=$2
    local filename=$3
    local package=$4
    local version=$5
    local architecture=$6
    local apk_path="$mapping_root/$release/$target/$filename"
    local size digest
    size=$(stat -c '%s' -- "$apk_path")
    digest=$(sha256sum -- "$apk_path" | awk '{ print $1 }')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tapk-adbdump\n' \
        "$release" "$target" "$filename" "$package" "$version" \
        "$architecture" "$size" "$digest" >> "$mapping_rows"
}
mapping_index_row 25.12.1 rpi4 alpha-1.0-r1.aaaaaaaa.apk alpha 1.0-r1 aarch64_cortex-a72
mapping_index_row 25.12.1 x86_64 alpha-1.0-r1.11111111.apk alpha 1.0-r1 x86_64
mapping_index_row 25.12.1 x86_64 alpha-1.0-r1.aaaaaaaa.apk alpha 1.0-r1 x86_64
mapping_index_row 25.12.1 x86_64 beta-2.0-r1.bbbbbbbb.apk beta 2.0-r1 noarch
mapping_index_row 26.1.0 x86_64 alpha-1.0-r1.aaaaaaaa.apk alpha 1.0-r1 x86_64
{
    printf '%s\n' '# package-cache-index-v1'
    printf '%s\n' $'# release\ttarget\tfilename\tpackage\tversion\tarchitecture\tsize\tsha256\tmetadata_status'
    sort "$mapping_rows"
} > "$mapping_root/index.tsv"

printf '%s\n' \
    'alpha - 1.0-r1' \
    'base-files - 1' \
    'beta - 2.0-r1' \
    'kernel - 1' \
    'libc - 1' > "$mapping_manifest"
printf '%s\n' \
    '{"packages":[' \
    '{"name":"alpha","version":"1.0-r1","hashes":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","arch":"x86_64"}' \
    ']}' > "$repository_one"
printf '%s\n' \
    '{"packages":[' \
    '{"name":"beta","version":"2.0-r1","hashes":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","arch":"noarch"}' \
    ']}' > "$repository_two"

"$MAP_SCRIPT" "$mapping_root/index.tsv" 25.12.1 x86_64 \
    "$mapping_manifest" -- repo-1 "$repository_one" repo-2 "$repository_two" \
    > "$mapping_output"
printf '%s\n' \
    $'repo-1\talpha-1.0-r1.apk\talpha-1.0-r1.aaaaaaaa.apk' \
    $'repo-2\tbeta-2.0-r1.apk\tbeta-2.0-r1.bbbbbbbb.apk' \
    > "$expected_mapping"
cmp -s "$mapping_output" "$expected_mapping" || \
    die 'snapshot mapping did not select current hashes from the correct repositories'

# Successful mapping above also proves that only the three ImageBuilder builtin
# packages may lack cache entries.  Removing in-scope alpha must still fail even
# though matching filenames remain under another target and another release.
mv -- "$mapping_root/25.12.1/x86_64/alpha-1.0-r1.aaaaaaaa.apk" \
    "$temporary_dir/current-alpha.apk"
expect_failure 'release/target cache isolation' \
    "$MAP_SCRIPT" "$mapping_root/index.tsv" 25.12.1 x86_64 \
        "$mapping_manifest" -- repo-1 "$repository_one" repo-2 "$repository_two"
mv -- "$temporary_dir/current-alpha.apk" \
    "$mapping_root/25.12.1/x86_64/alpha-1.0-r1.aaaaaaaa.apk"

# A package resolved by a repository but absent from this cache is a genuine
# snapshot completeness failure, not another builtin-package exception.
printf '%s\n' \
    'alpha - 1.0-r1' \
    'base-files - 1' \
    'beta - 2.0-r1' \
    'gamma - 3.0-r1' \
    'kernel - 1' \
    'libc - 1' > "$temporary_dir/missing.manifest"
printf '%s\n' \
    '{"packages":[' \
    '{"name":"beta","version":"2.0-r1","hashes":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","arch":"noarch"},' \
    '{"name":"gamma","version":"3.0-r1","hashes":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","arch":"x86_64"}' \
    ']}' > "$repository_two_missing"
expect_failure 'resolved package missing from cache' \
    "$MAP_SCRIPT" "$mapping_root/index.tsv" 25.12.1 x86_64 \
        "$temporary_dir/missing.manifest" -- \
        repo-1 "$repository_one" repo-2 "$repository_two_missing"

printf '%s\n' 'Package cache index tests passed.'
