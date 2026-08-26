#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
RESTORE="$PROJECT_ROOT/scripts/inputs/restore-locked-inputs.sh"
VERIFY="$PROJECT_ROOT/scripts/inputs/verify-package-snapshot.py"

for tool in chmod cmp cp diff find mkdir mkfifo mktemp python3 rm sha256sum sort \
            stat tar zstd; do
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
    printf 'error: restore-locked-inputs test: %s\n' "$*" >&2
    exit 1
}

sha256_file() {
    local output
    output=$(sha256sum -- "$1")
    printf '%s\n' "${output%% *}"
}

expect_failure() {
    local label=${1:?failure label required}
    shift
    if "$@" >"$temporary_dir/expected-failure.log" 2>&1; then
        fail "$label unexpectedly succeeded"
    fi
}

assert_no_staging_directories() {
    local root=${1:?root required}
    local leftover
    leftover=$(find "$root" -type d -name '.locked-input-*' -print -quit 2>/dev/null || true)
    [[ -z "$leftover" ]] || fail "a staging directory was left behind: $leftover"
}

VERSION=99.88.77
TARGET_NAME=x86_64
IMAGEBUILDER_FILE="immortalwrt-imagebuilder-$VERSION-x86-64.Linux-x86_64.tar.zst"
BUNDLE_FILE="immortalwrt-$VERSION-$TARGET_NAME-package-snapshot.tar.zst"
SOURCE_DIR="$temporary_dir/source"
TREE_PARENT="$temporary_dir/tree"
TREE="$TREE_PARENT/$VERSION/$TARGET_NAME"
mkdir -p "$SOURCE_DIR" "$TREE/repo-1"
printf 'fixture ImageBuilder bytes\n' >"$SOURCE_DIR/$IMAGEBUILDER_FILE"
printf 'repo-1\n' >"$TREE/repositories.list"
printf 'fixture package index\n' >"$TREE/repo-1/packages.adb"
printf 'fixture APK bytes\n' >"$TREE/repo-1/demo-1.0-r1.apk"
(
    cd "$TREE"
    while IFS= read -r name; do
        digest=$(sha256_file "$name")
        printf '%s  %s\n' "$digest" "$name"
    done < <(find . -type f ! -name SHA256SUMS -printf '%P\n' | sort)
) >"$TREE/SHA256SUMS"
TREE_MANIFEST_SHA=$(sha256_file "$TREE/SHA256SUMS")

create_bundle() {
    local tree_parent=${1:?tree parent required}
    local output=${2:?bundle output required}
    local raw="$temporary_dir/bundle.$RANDOM.tar"

    tar --sort=name --format=gnu --mtime='@1700000000' --owner=0 --group=0 \
        --numeric-owner -cf "$raw" -C "$tree_parent" "$VERSION/$TARGET_NAME"
    zstd --quiet --force "$raw" -o "$output"
    rm -f -- "$raw"
}

create_bundle "$TREE_PARENT" "$SOURCE_DIR/$BUNDLE_FILE"
IMAGEBUILDER_SHA=$(sha256_file "$SOURCE_DIR/$IMAGEBUILDER_FILE")
IMAGEBUILDER_BYTES=$(stat -c '%s' -- "$SOURCE_DIR/$IMAGEBUILDER_FILE")

write_locks() {
    local locks=${1:?lock directory required}
    local bundle=${2:?bundle required}
    local tree_manifest_sha=${3:?tree-manifest SHA required}
    local bundle_sha bundle_bytes

    mkdir -p "$locks"
    bundle_sha=$(sha256_file "$bundle")
    bundle_bytes=$(stat -c '%s' -- "$bundle")
    cat >"$locks/release.env" <<EOF
IMMORTALWRT_VERSION=$VERSION
IMMORTALWRT_TAG=v$VERSION
IMMORTALWRT_TAG_OBJECT=0000000000000000000000000000000000000000
IMMORTALWRT_COMMIT=1111111111111111111111111111111111111111
IMMORTALWRT_SOURCE_URL=https://github.com/immortalwrt/immortalwrt.git
IMMORTALWRT_DOWNLOAD_URL=https://downloads.immortalwrt.org
LOCKED_INPUT_RELEASE_TAG=hmxf-openwrt-inputs-$VERSION
IMMORTALWRT_VERSION_CODE=r1-deadbeef
IMMORTALWRT_SOURCE_DATE_EPOCH=1700000000
IMMORTALWRT_KERNEL_VERSION=6.12.34
IMMORTALWRT_KERNEL_RELEASE=1
ROOTFS_PARTSIZE=3072
NOMINAL_MEDIA_BYTES=4000000000
EOF
    cat >"$locks/targets.tsv" <<EOF
# name|target|subtarget|profile|package_arch|imagebuilder_filename|sha256|kernel_vermagic|bytes
x86_64|x86|64|generic|x86_64|$IMAGEBUILDER_FILE|$IMAGEBUILDER_SHA|0123456789abcdef0123456789abcdef|$IMAGEBUILDER_BYTES
rpi4|bcm27xx|bcm2711|rpi-4|aarch64_cortex-a72|immortalwrt-imagebuilder-$VERSION-bcm27xx-bcm2711.Linux-x86_64.tar.zst|2222222222222222222222222222222222222222222222222222222222222222|22222222222222222222222222222222|1
rpi5|bcm27xx|bcm2712|rpi-5|aarch64_cortex-a76|immortalwrt-imagebuilder-$VERSION-bcm27xx-bcm2712.Linux-x86_64.tar.zst|3333333333333333333333333333333333333333333333333333333333333333|33333333333333333333333333333333|1
EOF
    cat >"$locks/package-snapshots.tsv" <<EOF
# target|filename|sha256|bytes|tree_sha256sums_sha256
x86_64|$BUNDLE_FILE|$bundle_sha|$bundle_bytes|$tree_manifest_sha
rpi4|immortalwrt-$VERSION-rpi4-package-snapshot.tar.zst|4444444444444444444444444444444444444444444444444444444444444444|1|4444444444444444444444444444444444444444444444444444444444444444
rpi5|immortalwrt-$VERSION-rpi5-package-snapshot.tar.zst|5555555555555555555555555555555555555555555555555555555555555555|1|5555555555555555555555555555555555555555555555555555555555555555
EOF
}

LOCKS="$temporary_dir/locks"
write_locks "$LOCKS" "$SOURCE_DIR/$BUNDLE_FILE" "$TREE_MANIFEST_SHA"

run_restore() {
    local destination=${1:?destination root required}
    local source=${2-}
    local locks=${3:-$LOCKS}
    local base_url=${4-}

    LOCKS_DIR="$locks" \
    DOWNLOAD_DIR="$destination/imagebuilders" \
    PACKAGE_SNAPSHOT_DIR="$destination/snapshots" \
    PACKAGE_SNAPSHOT_BUNDLE_DIR="$destination/bundles" \
    LOCKED_INPUT_SOURCE_DIR="$source" \
    LOCKED_INPUT_BASE_URL="$base_url" \
    LOCKED_INPUT_GITHUB_REPOSITORY='' \
    GITHUB_REPOSITORY='' \
    GH_TOKEN='' \
    GITHUB_TOKEN='' \
        "$RESTORE" "$TARGET_NAME"
}

# Fresh local-source restore publishes all three independently locked objects.
happy="$temporary_dir/happy"
run_restore "$happy" "$SOURCE_DIR" >/dev/null
cmp -s "$SOURCE_DIR/$IMAGEBUILDER_FILE" "$happy/imagebuilders/$IMAGEBUILDER_FILE" || \
    fail 'restored ImageBuilder differs from the source'
cmp -s "$SOURCE_DIR/$BUNDLE_FILE" "$happy/bundles/$VERSION/$BUNDLE_FILE" || \
    fail 'restored package snapshot bundle differs from the source'
diff -r "$TREE" "$happy/snapshots/$VERSION/$TARGET_NAME" >/dev/null || \
    fail 'restored package snapshot tree differs from the source'
python3 "$VERIFY" verify "$happy/snapshots/$VERSION/$TARGET_NAME" \
    "$VERSION" "$TARGET_NAME" "$TREE_MANIFEST_SHA" >/dev/null
assert_no_staging_directories "$happy"

# A fresh checkout needs no repository placeholder: absent explicit local or
# HTTPS sources, the canonical project Release URL is used and every returned
# byte still has to satisfy the independent locks.
default_remote="$temporary_dir/default-remote"
mock_bin="$temporary_dir/mock-bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
url=
while (( $# > 0 )); do
    case "$1" in
        --output)
            output=$2
            shift 2
            ;;
        --)
            shift
            url=${1-}
            shift
            ;;
        *) shift ;;
    esac
done
[[ -n "$output" && "$url" == \
   "https://github.com/hmxf/hmxf-OpenWRT/releases/download/$MOCK_RELEASE_TAG/"* ]]
cp -- "$MOCK_RELEASE_DIR/${url##*/}" "$output"
EOF
chmod 0755 "$mock_bin/curl"
PATH="$mock_bin:$PATH" MOCK_RELEASE_DIR="$SOURCE_DIR" \
    MOCK_RELEASE_TAG="hmxf-openwrt-inputs-$VERSION" \
    run_restore "$default_remote" '' >/dev/null
cmp -s "$SOURCE_DIR/$IMAGEBUILDER_FILE" \
    "$default_remote/imagebuilders/$IMAGEBUILDER_FILE" || \
    fail 'default GitHub source returned a different ImageBuilder'
diff -r "$TREE" "$default_remote/snapshots/$VERSION/$TARGET_NAME" >/dev/null || \
    fail 'default GitHub source returned a different snapshot tree'
assert_no_staging_directories "$default_remote"

# A complete valid local pair is reused before even validating lower-priority
# source configuration, and no inode is replaced.
before_archive=$(stat -c '%i:%Y' -- "$happy/imagebuilders/$IMAGEBUILDER_FILE")
before_manifest=$(stat -c '%i:%Y' -- \
    "$happy/snapshots/$VERSION/$TARGET_NAME/SHA256SUMS")
run_restore "$happy" "$temporary_dir/does-not-exist" >/dev/null
[[ $(stat -c '%i:%Y' -- "$happy/imagebuilders/$IMAGEBUILDER_FILE") == \
   "$before_archive" ]] || fail 'valid ImageBuilder was replaced during reuse'
[[ $(stat -c '%i:%Y' -- \
    "$happy/snapshots/$VERSION/$TARGET_NAME/SHA256SUMS") == \
   "$before_manifest" ]] || fail 'valid snapshot was replaced during reuse'

# A persisted local bundle can reconstruct a missing unpacked tree offline.
rm -rf -- "$happy/snapshots/$VERSION/$TARGET_NAME"
# Lower-priority source settings are deliberately ignored because the valid
# local ImageBuilder and bundle already provide every missing object.
run_restore "$happy" "$temporary_dir/does-not-exist" "$LOCKS" \
    'http://invalid.example' >/dev/null
diff -r "$TREE" "$happy/snapshots/$VERSION/$TARGET_NAME" >/dev/null || \
    fail 'local bundle did not reconstruct the snapshot tree'

# Concurrent restorers serialize and converge on the same immutable objects.
concurrent="$temporary_dir/concurrent"
run_restore "$concurrent" "$SOURCE_DIR" >"$temporary_dir/concurrent-1.log" 2>&1 &
first_pid=$!
run_restore "$concurrent" "$SOURCE_DIR" >"$temporary_dir/concurrent-2.log" 2>&1 &
second_pid=$!
if ! wait "$first_pid"; then
    cat "$temporary_dir/concurrent-1.log" >&2
    fail 'first concurrent restore failed'
fi
if ! wait "$second_pid"; then
    cat "$temporary_dir/concurrent-2.log" >&2
    fail 'second concurrent restore failed'
fi
python3 "$VERIFY" verify "$concurrent/snapshots/$VERSION/$TARGET_NAME" \
    "$VERSION" "$TARGET_NAME" "$TREE_MANIFEST_SHA" >/dev/null
assert_no_staging_directories "$concurrent"

# Existing conflicts are never silently overwritten.
printf 'tampered APK\n' >"$happy/snapshots/$VERSION/$TARGET_NAME/repo-1/demo-1.0-r1.apk"
expect_failure 'tampered unpacked snapshot' run_restore "$happy" "$SOURCE_DIR"

wrong_imagebuilder="$temporary_dir/wrong-imagebuilder"
mkdir -p "$wrong_imagebuilder/imagebuilders"
printf 'wrong ImageBuilder\n' >"$wrong_imagebuilder/imagebuilders/$IMAGEBUILDER_FILE"
expect_failure 'conflicting ImageBuilder' run_restore \
    "$wrong_imagebuilder" "$SOURCE_DIR"

wrong_bundle="$temporary_dir/wrong-bundle"
mkdir -p "$wrong_bundle/bundles/$VERSION"
printf 'wrong bundle\n' >"$wrong_bundle/bundles/$VERSION/$BUNDLE_FILE"
expect_failure 'conflicting package snapshot bundle' run_restore \
    "$wrong_bundle" "$SOURCE_DIR"

# A corrupt source asset leaves no partially published input or staging tree.
corrupt_source="$temporary_dir/corrupt-source"
mkdir -p "$corrupt_source"
cp -- "$SOURCE_DIR/$IMAGEBUILDER_FILE" "$corrupt_source/$IMAGEBUILDER_FILE"
printf 'not the locked bundle\n' >"$corrupt_source/$BUNDLE_FILE"
corrupt_destination="$temporary_dir/corrupt-destination"
expect_failure 'corrupt source bundle' run_restore \
    "$corrupt_destination" "$corrupt_source"
[[ ! -e "$corrupt_destination/imagebuilders/$IMAGEBUILDER_FILE" ]] || \
    fail 'ImageBuilder was published before every missing input was verified'
assert_no_staging_directories "$corrupt_destination"

# The external tree-manifest hash remains the root of trust even when a bundle
# and its inner SHA256SUMS are mutually consistent.
changed_parent="$temporary_dir/changed-tree"
changed_tree="$changed_parent/$VERSION/$TARGET_NAME"
cp -a -- "$TREE_PARENT" "$changed_parent"
printf 'changed but internally re-locked APK\n' \
    >"$changed_tree/repo-1/demo-1.0-r1.apk"
(
    cd "$changed_tree"
    while IFS= read -r name; do
        digest=$(sha256_file "$name")
        printf '%s  %s\n' "$digest" "$name"
    done < <(find . -type f ! -name SHA256SUMS -printf '%P\n' | sort)
) >"$changed_tree/SHA256SUMS"
changed_source="$temporary_dir/changed-source"
mkdir -p "$changed_source"
cp -- "$SOURCE_DIR/$IMAGEBUILDER_FILE" "$changed_source/$IMAGEBUILDER_FILE"
create_bundle "$changed_parent" "$changed_source/$BUNDLE_FILE"
changed_locks="$temporary_dir/changed-locks"
write_locks "$changed_locks" "$changed_source/$BUNDLE_FILE" "$TREE_MANIFEST_SHA"
changed_destination="$temporary_dir/changed-destination"
expect_failure 'bundle with a re-locked inner tree' run_restore \
    "$changed_destination" "$changed_source" "$changed_locks"
[[ ! -e "$changed_destination/bundles/$VERSION/$BUNDLE_FILE" ]] || \
    fail 'externally mismatched bundle was published'
assert_no_staging_directories "$changed_destination"

create_malicious_bundle() {
    local kind=${1:?malicious kind required}
    local output=${2:?malicious output required}
    local raw="$temporary_dir/malicious-$kind.tar"

    python3 - "$kind" "$raw" "$VERSION" "$TARGET_NAME" <<'PY'
import io
import sys
import tarfile

kind, output, release, target = sys.argv[1:]
prefix = f"{release}/{target}"

def regular(archive, name, payload=b"x"):
    entry = tarfile.TarInfo(name)
    entry.size = len(payload)
    entry.mode = 0o644
    archive.addfile(entry, io.BytesIO(payload))

with tarfile.open(output, "w", format=tarfile.GNU_FORMAT) as archive:
    if kind == "traversal":
        regular(archive, f"{prefix}/../../escaped")
    elif kind == "wrong-prefix":
        regular(archive, f"{release}/rpi4/repo-1/evil.apk")
    elif kind == "duplicate":
        regular(archive, f"{prefix}/repo-1/evil.apk", b"first")
        regular(archive, f"{prefix}/repo-1/evil.apk", b"second")
    elif kind in ("symlink", "hardlink", "fifo"):
        entry = tarfile.TarInfo(f"{prefix}/repo-1/evil.apk")
        entry.mode = 0o644
        if kind == "symlink":
            entry.type = tarfile.SYMTYPE
            entry.linkname = "../../escaped"
        elif kind == "hardlink":
            entry.type = tarfile.LNKTYPE
            entry.linkname = f"{prefix}/repositories.list"
        else:
            entry.type = tarfile.FIFOTYPE
        archive.addfile(entry)
    else:
        raise SystemExit(f"unknown malicious kind: {kind}")
PY
    zstd --quiet --force "$raw" -o "$output"
    rm -f -- "$raw"
}

# Archive traversal, wrong roots, duplicate names, links, and special nodes are
# rejected before any locked object is published.
for kind in traversal wrong-prefix duplicate symlink hardlink fifo; do
    malicious_source="$temporary_dir/malicious-source-$kind"
    mkdir -p "$malicious_source"
    cp -- "$SOURCE_DIR/$IMAGEBUILDER_FILE" "$malicious_source/$IMAGEBUILDER_FILE"
    create_malicious_bundle "$kind" "$malicious_source/$BUNDLE_FILE"
    malicious_locks="$temporary_dir/malicious-locks-$kind"
    write_locks "$malicious_locks" "$malicious_source/$BUNDLE_FILE" \
        "$TREE_MANIFEST_SHA"
    malicious_destination="$temporary_dir/malicious-destination-$kind"
    expect_failure "malicious $kind archive" run_restore \
        "$malicious_destination" "$malicious_source" "$malicious_locks"
    [[ ! -e "$malicious_destination/imagebuilders/$IMAGEBUILDER_FILE" ]] || \
        fail "$kind archive caused a partial publication"
    [[ ! -e "$malicious_destination/escaped" ]] || \
        fail "$kind archive escaped its extraction root"
    assert_no_staging_directories "$malicious_destination"
done

# Symlinked roots/assets, special destination nodes, and insecure remote URLs
# fail closed without modifying an external victim.
symlink_case="$temporary_dir/symlink-root"
victim="$temporary_dir/victim"
mkdir -p "$symlink_case" "$victim"
printf 'keep me\n' >"$victim/marker"
ln -s -- "$victim" "$symlink_case/imagebuilders"
expect_failure 'symbolic-link destination root' run_restore \
    "$symlink_case" "$SOURCE_DIR"
[[ $(<"$victim/marker") == 'keep me' ]] || fail 'symlink victim was modified'

special_case="$temporary_dir/special-node"
mkdir -p "$special_case/imagebuilders"
mkfifo "$special_case/imagebuilders/$IMAGEBUILDER_FILE"
expect_failure 'special destination node' run_restore "$special_case" "$SOURCE_DIR"

symlink_source="$temporary_dir/symlink-source"
mkdir -p "$symlink_source"
ln -s -- "$SOURCE_DIR/$IMAGEBUILDER_FILE" "$symlink_source/$IMAGEBUILDER_FILE"
cp -- "$SOURCE_DIR/$BUNDLE_FILE" "$symlink_source/$BUNDLE_FILE"
expect_failure 'symbolic-link source asset' run_restore \
    "$temporary_dir/symlink-source-destination" "$symlink_source"

expect_failure 'non-HTTPS base URL' run_restore \
    "$temporary_dir/http-source" '' "$LOCKS" 'http://example.invalid/assets'
assert_no_staging_directories "$temporary_dir/http-source"

# A pre-existing symbolic-link lock file must not be opened or followed.
lock_case="$temporary_dir/symlink-lock"
mkdir -p "$lock_case/snapshots"
ln -s -- "$victim/marker" \
    "$lock_case/snapshots/.locked-input-restore-$VERSION-$TARGET_NAME.lock"
expect_failure 'symbolic-link restore lock' run_restore "$lock_case" "$SOURCE_DIR"
[[ $(<"$victim/marker") == 'keep me' ]] || fail 'lock symlink victim was modified'

printf 'restore-locked-inputs tests passed\n'
