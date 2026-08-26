#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
identity_script="$PROJECT_ROOT/scripts/inputs/nightly-build-identity.sh"
temporary_dir=$(mktemp -d)
cleanup() {
    rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

upstream=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' 'fixture plan input manifest' > "$temporary_dir/PLAN_INPUTS.sha256"

write_lock() {
    local destination=$1
    local bundle_seed=$2
    local tree_suffix=$3
    {
        printf '%s\n' '# target|filename|sha256|bytes|tree_sha256sums_sha256'
        printf 'x86_64|immortalwrt-SNAPSHOT-x86_64-package-snapshot.tar.zst|%064d|%s|%063d%s\n' \
            "$bundle_seed" "$((bundle_seed + 100))" 0 "$tree_suffix"
        printf 'rpi4|immortalwrt-SNAPSHOT-rpi4-package-snapshot.tar.zst|%064d|%s|%064d\n' \
            "$((bundle_seed + 1))" "$((bundle_seed + 101))" 2
        printf 'rpi5|immortalwrt-SNAPSHOT-rpi5-package-snapshot.tar.zst|%064d|%s|%064d\n' \
            "$((bundle_seed + 2))" "$((bundle_seed + 102))" 3
    } > "$destination"
}

write_lock "$temporary_dir/first.tsv" 10 1
write_lock "$temporary_dir/reencoded.tsv" 20 1
write_lock "$temporary_dir/changed-tree.tsv" 30 9
{
    sed -n '1p' "$temporary_dir/first.tsv"
    sed -n '4p' "$temporary_dir/first.tsv"
    sed -n '2p' "$temporary_dir/first.tsv"
    sed -n '3p' "$temporary_dir/first.tsv"
} > "$temporary_dir/reordered.tsv"

first_content=$("$identity_script" content "$temporary_dir/first.tsv")
reencoded_content=$("$identity_script" content "$temporary_dir/reencoded.tsv")
changed_content=$("$identity_script" content "$temporary_dir/changed-tree.tsv")
reordered_content=$("$identity_script" content "$temporary_dir/reordered.tsv")
[[ "$first_content" == "$reencoded_content" ]] || {
    printf '%s\n' 'error: bundle encoding changed portable tree identity' >&2
    exit 1
}
[[ "$first_content" == "$reordered_content" ]] || {
    printf '%s\n' 'error: package-snapshot row order changed portable identity' >&2
    exit 1
}
[[ "$first_content" != "$changed_content" ]] || {
    printf '%s\n' 'error: package tree change did not change portable identity' >&2
    exit 1
}

first_fingerprint=$("$identity_script" fingerprint "$upstream" \
    "$temporary_dir/PLAN_INPUTS.sha256" "$temporary_dir/first.tsv")
reencoded_fingerprint=$("$identity_script" fingerprint "$upstream" \
    "$temporary_dir/PLAN_INPUTS.sha256" "$temporary_dir/reencoded.tsv")
changed_fingerprint=$("$identity_script" fingerprint "$upstream" \
    "$temporary_dir/PLAN_INPUTS.sha256" "$temporary_dir/changed-tree.tsv")
reordered_fingerprint=$("$identity_script" fingerprint "$upstream" \
    "$temporary_dir/PLAN_INPUTS.sha256" "$temporary_dir/reordered.tsv")
[[ "$first_fingerprint" == "$reencoded_fingerprint" && \
   "$first_fingerprint" == "$reordered_fingerprint" && \
   "$first_fingerprint" != "$changed_fingerprint" ]] || {
    printf '%s\n' 'error: final nightly fingerprint has the wrong content semantics' >&2
    exit 1
}

sed -i 's/^rpi5|/rpi4|/' "$temporary_dir/changed-tree.tsv"
if "$identity_script" content "$temporary_dir/changed-tree.tsv" \
        >"$temporary_dir/invalid.log" 2>&1; then
    printf '%s\n' 'error: duplicate package-snapshot target was accepted' >&2
    exit 1
fi

printf '%s\n' 'Nightly portable tree and final fingerprint tests passed.'
