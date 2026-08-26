#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
STAGER="$PROJECT_ROOT/scripts/inputs/stage-locked-input-release.sh"

for tool in chmod cp find mktemp python3 rm sed sha256sum sort stat tar wc xargs zstd; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'error: missing test command: %s\n' "$tool" >&2
        exit 1
    }
done

temporary_dir=$(mktemp -d)
cleanup() {
    local status=$?
    trap - EXIT
    rm -rf -- "$temporary_dir"
    exit "$status"
}
trap cleanup EXIT

fail() {
    printf 'error: locked-input stager test: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    local label=${1:?failure label required}
    shift
    if "$@" >"$temporary_dir/expected-failure.log" 2>&1; then
        fail "$label unexpectedly succeeded"
    fi
}

sha256_file() {
    local result
    result=$(sha256sum -- "$1")
    printf '%s\n' "${result%% *}"
}

version=99.88.77
candidate="$temporary_dir/candidate"
trees="$temporary_dir/trees"
destination="$temporary_dir/staged"
mkdir -p "$candidate/locks" "$candidate/imagebuilders" \
    "$candidate/package-snapshot-bundles"

cat >"$candidate/locks/release.env" <<EOF
IMMORTALWRT_VERSION=$version
IMMORTALWRT_TAG=v$version
IMMORTALWRT_TAG_OBJECT=0000000000000000000000000000000000000000
IMMORTALWRT_COMMIT=1111111111111111111111111111111111111111
IMMORTALWRT_SOURCE_URL=https://github.com/immortalwrt/immortalwrt.git
IMMORTALWRT_DOWNLOAD_URL=https://downloads.immortalwrt.org
LOCKED_INPUT_RELEASE_TAG=hmxf-openwrt-inputs-$version
IMMORTALWRT_VERSION_CODE=r1-deadbeef
IMMORTALWRT_SOURCE_DATE_EPOCH=1700000000
IMMORTALWRT_KERNEL_VERSION=6.12.34
IMMORTALWRT_KERNEL_RELEASE=1
ROOTFS_PARTSIZE=3072
NOMINAL_MEDIA_BYTES=4000000000
EOF

printf '%s\n' \
    '# name|target|subtarget|profile|package_arch|imagebuilder_filename|sha256|kernel_vermagic|bytes' \
    > "$candidate/locks/targets.tsv"
printf '%s\n' '# target|filename|sha256|bytes|tree_sha256sums_sha256' \
    > "$candidate/locks/package-snapshots.tsv"

declare -a target_rows=(
    'x86_64|x86|64|generic|x86_64|0123456789abcdef0123456789abcdef'
    'rpi4|bcm27xx|bcm2711|rpi-4|aarch64_cortex-a72|22222222222222222222222222222222'
    'rpi5|bcm27xx|bcm2712|rpi-5|aarch64_cortex-a76|33333333333333333333333333333333'
)

for target_row in "${target_rows[@]}"; do
    IFS='|' read -r target target_dir subtarget profile arch vermagic <<< "$target_row"
    imagebuilder="immortalwrt-imagebuilder-$version-$target_dir-$subtarget.Linux-x86_64.tar.zst"
    printf 'fixture ImageBuilder for %s\n' "$target" \
        > "$candidate/imagebuilders/$imagebuilder"
    imagebuilder_sha=$(sha256_file "$candidate/imagebuilders/$imagebuilder")
    imagebuilder_bytes=$(stat -c '%s' -- "$candidate/imagebuilders/$imagebuilder")
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$target" "$target_dir" "$subtarget" "$profile" "$arch" \
        "$imagebuilder" "$imagebuilder_sha" "$vermagic" "$imagebuilder_bytes" \
        >> "$candidate/locks/targets.tsv"

    snapshot="$trees/$version/$target"
    mkdir -p "$snapshot/repo-1"
    printf '%s\n' repo-1 > "$snapshot/repositories.list"
    printf 'fixture signed index for %s\n' "$target" \
        > "$snapshot/repo-1/packages.adb"
    printf 'fixture APK for %s\n' "$target" \
        > "$snapshot/repo-1/demo-$target-1.0-r1.apk"
    snapshot_manifest="$temporary_dir/$target.SHA256SUMS"
    (
        cd "$snapshot"
        find . -type f ! -name SHA256SUMS -printf '%P\0' | sort -z | \
            xargs -0 sha256sum > "$snapshot_manifest"
    )
    mv -- "$snapshot_manifest" "$snapshot/SHA256SUMS"
    tree_sha=$(sha256_file "$snapshot/SHA256SUMS")
    bundle="immortalwrt-$version-$target-package-snapshot.tar.zst"
    raw_bundle="$temporary_dir/$target.tar"
    tar --sort=name --format=gnu --mtime='@1700000000' --owner=0 --group=0 \
        --numeric-owner -cf "$raw_bundle" -C "$trees" "$version/$target"
    zstd --quiet --force "$raw_bundle" \
        -o "$candidate/package-snapshot-bundles/$bundle"
    rm -f -- "$raw_bundle"
    bundle_sha=$(sha256_file "$candidate/package-snapshot-bundles/$bundle")
    bundle_bytes=$(stat -c '%s' -- \
        "$candidate/package-snapshot-bundles/$bundle")
    printf '%s|%s|%s|%s|%s\n' "$target" "$bundle" "$bundle_sha" \
        "$bundle_bytes" "$tree_sha" >> "$candidate/locks/package-snapshots.tsv"
done

imagebuilder_manifest="$temporary_dir/imagebuilders.SHA256SUMS"
(
    cd "$candidate/imagebuilders"
    find . -maxdepth 1 -type f -name '*.tar.zst' -printf '%P\0' | sort -z | \
        xargs -0 sha256sum > "$imagebuilder_manifest"
)
mv -- "$imagebuilder_manifest" "$candidate/imagebuilders/SHA256SUMS"

# Distribution staging must normalize restrictive cache/candidate modes instead
# of leaking the source owner's umask into the published tree.
find "$candidate/imagebuilders" "$candidate/package-snapshot-bundles" \
    -type f ! -name SHA256SUMS -exec chmod 0600 {} +
"$STAGER" --candidate "$candidate" "$destination" >/dev/null
[[ $(find "$destination" -mindepth 1 -maxdepth 1 -type f | wc -l) == 7 ]] || \
    fail 'successful staging did not publish exactly six assets and SHA256SUMS'
[[ -z $(find "$destination" -mindepth 1 -maxdepth 1 ! -type f -print -quit) ]] || \
    fail 'successful staging published a non-regular entry'
bad_mode=$(find "$destination" -mindepth 1 -maxdepth 1 -type f \
    ! -perm 0644 -print -quit)
[[ -z "$bad_mode" ]] || fail "staged release file mode is not 0644: $bad_mode"
(
    cd "$destination"
    sha256sum --strict --quiet -c SHA256SUMS
)

before=$(find "$destination" -mindepth 1 -maxdepth 1 -type f -print0 \
    | sort -z | xargs -0 stat -c '%n|%d:%i|%s|%Y')
"$STAGER" --candidate "$candidate" "$destination" >/dev/null
after=$(find "$destination" -mindepth 1 -maxdepth 1 -type f -print0 \
    | sort -z | xargs -0 stat -c '%n|%d:%i|%s|%Y')
[[ "$before" == "$after" ]] || fail 'idempotent staging rewrote the release tree'

bad_header="$temporary_dir/bad-header"
cp -a -- "$candidate" "$bad_header"
sed -i '1s/tree_sha256sums_sha256/tree_manifest_sha256/' \
    "$bad_header/locks/package-snapshots.tsv"
expect_failure 'snapshot schema header drift' "$STAGER" --candidate \
    "$bad_header" "$temporary_dir/bad-header-output"

bad_size="$temporary_dir/bad-size"
cp -a -- "$candidate" "$bad_size"
sed -i '2s/|[1-9][0-9]*$/|999999/' "$bad_size/locks/targets.tsv"
expect_failure 'positive but incorrect ImageBuilder byte lock' "$STAGER" --candidate \
    "$bad_size" "$temporary_dir/bad-size-output"

bad_digest="$temporary_dir/bad-digest"
cp -a -- "$candidate" "$bad_digest"
sed -i '2s/|[0-9a-f]\{64\}|/|ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff|/' \
    "$bad_digest/locks/package-snapshots.tsv"
expect_failure 'well-formed but incorrect bundle digest' "$STAGER" --candidate \
    "$bad_digest" "$temporary_dir/bad-digest-output"

printf '%s\n' 'Locked-input release staging tests passed.'
