#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
PERSIST_SCRIPT="$PROJECT_ROOT/scripts/inputs/persist-package-snapshots.sh"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

for tool in awk bash chmod cmp cp diff env find grep ln mkdir mktemp mv rm sha256sum stat; do
    command -v "$tool" >/dev/null 2>&1 || die "required test command not found: $tool"
done
[[ -x "$PERSIST_SCRIPT" ]] || die "snapshot persister is not executable: $PERSIST_SCRIPT"

temporary_dir=$(mktemp -d /tmp/hmxf-package-snapshot-persist-test.XXXXXXXX)
candidate="$temporary_dir/candidate"
snapshot_store="$temporary_dir/persisted snapshots"
bundle_store="$temporary_dir/persisted bundles"
version=25.12.1
cleanup() {
    rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

expect_failure() {
    local description=$1
    shift
    if "$@" >"$temporary_dir/failure.log" 2>&1; then
        die "negative snapshot persistence test unexpectedly passed: $description"
    fi
}

create_candidate() {
    local target target_dir apk_name bundle_name bundle_sha bundle_bytes tree_sha

    rm -rf -- "$candidate"
    mkdir -p "$candidate/locks" "$candidate/package-snapshot-bundles"
    printf 'IMMORTALWRT_VERSION=%s\n' "$version" > "$candidate/locks/release.env"
    printf '%s\n' '# target|filename|sha256|bytes|tree_sha256sums_sha256' \
        > "$candidate/locks/package-snapshots.tsv"
    for target in x86_64 rpi4 rpi5; do
        target_dir="$candidate/package-snapshots/$version/$target"
        apk_name="fixture-$target-1.0-r1.12345678.apk"
        mkdir -p "$target_dir/repo-1"
        printf '%s\n' repo-1 > "$target_dir/repositories.list"
        printf 'signed fixture index for %s\n' "$target" \
            > "$target_dir/repo-1/packages.adb"
        printf 'fixture APK payload for %s\n' "$target" \
            > "$target_dir/repo-1/$apk_name"
        (
            cd "$target_dir"
            sha256sum repositories.list repo-1/packages.adb "repo-1/$apk_name" \
                > SHA256SUMS
        )

        bundle_name="immortalwrt-$version-$target-package-snapshot.tar.zst"
        printf 'portable fixture bundle for %s\n' "$target" \
            > "$candidate/package-snapshot-bundles/$bundle_name"
        bundle_sha=$(sha256sum "$candidate/package-snapshot-bundles/$bundle_name" \
            | awk '{ print $1 }')
        bundle_bytes=$(stat -c '%s' \
            "$candidate/package-snapshot-bundles/$bundle_name")
        tree_sha=$(sha256sum "$target_dir/SHA256SUMS" | awk '{ print $1 }')
        printf '%s|%s|%s|%s|%s\n' "$target" "$bundle_name" "$bundle_sha" \
            "$bundle_bytes" "$tree_sha" \
            >> "$candidate/locks/package-snapshots.tsv"
    done
}

run_persist() {
    PACKAGE_SNAPSHOT_STORE_DIR="$snapshot_store" \
    PACKAGE_SNAPSHOT_BUNDLE_STORE_DIR="$bundle_store" \
        "$PERSIST_SCRIPT" "$candidate"
}

assert_no_staging() {
    local root stage
    for root in "$@"; do
        [[ -d "$root" ]] || continue
        stage=$(find "$root" -mindepth 1 -maxdepth 1 -type d \
            -name ".persist-$version-*" -print -quit)
        [[ -z "$stage" ]] || die "snapshot persistence left a staging directory: $stage"
    done
}

# The standalone helper authenticates each unpacked target before it writes a
# store. A changed payload and an unindexed extra file must both fail closed.
create_candidate
printf '%s\n' tampered >> \
    "$candidate/package-snapshots/$version/x86_64/repo-1/fixture-x86_64-1.0-r1.12345678.apk"
expect_failure 'candidate snapshot payload tamper' run_persist
[[ ! -e "$snapshot_store/$version" && ! -e "$bundle_store/$version" ]] || \
    die 'tampered candidate created a persistent version'

create_candidate
printf '%s\n' extra > \
    "$candidate/package-snapshots/$version/rpi4/repo-1/extra-1.0-r1.87654321.apk"
expect_failure 'candidate snapshot file missing from SHA256SUMS' run_persist
[[ ! -e "$snapshot_store/$version" && ! -e "$bundle_store/$version" ]] || \
    die 'candidate with an extra file created a persistent version'

# First publication copies both trees beneath a version directory. A second
# invocation is idempotent and leaves existing destination inodes untouched.
create_candidate
run_persist >/dev/null
diff -qr --no-dereference \
    "$candidate/package-snapshots/$version" "$snapshot_store/$version" >/dev/null || \
    die 'persisted unpacked snapshot differs from its candidate'
diff -qr --no-dereference \
    "$candidate/package-snapshot-bundles" "$bundle_store/$version" >/dev/null || \
    die 'persisted snapshot bundles differ from their candidate'
snapshot_inode_before=$(stat -c '%d:%i' "$snapshot_store/$version")
bundle_inode_before=$(stat -c '%d:%i' "$bundle_store/$version")
run_persist >/dev/null
[[ $(stat -c '%d:%i' "$snapshot_store/$version") == "$snapshot_inode_before" && \
   $(stat -c '%d:%i' "$bundle_store/$version") == "$bundle_inode_before" ]] || \
    die 'idempotent persistence replaced an existing version directory'
assert_no_staging "$snapshot_store" "$bundle_store"

# Existing content is immutable: neither a changed tree nor an incomplete
# bundle directory may be repaired or overwritten implicitly.
printf '%s\n' destination-tamper >> \
    "$snapshot_store/$version/x86_64/repo-1/fixture-x86_64-1.0-r1.12345678.apk"
bundle_digest_before=$(sha256sum \
    "$bundle_store/$version/immortalwrt-$version-x86_64-package-snapshot.tar.zst" \
    | awk '{ print $1 }')
expect_failure 'conflicting persisted snapshot tree' run_persist
grep -Fq destination-tamper \
    "$snapshot_store/$version/x86_64/repo-1/fixture-x86_64-1.0-r1.12345678.apk" || \
    die 'conflicting persisted snapshot was silently overwritten'
[[ $(sha256sum \
        "$bundle_store/$version/immortalwrt-$version-x86_64-package-snapshot.tar.zst" \
        | awk '{ print $1 }') == "$bundle_digest_before" ]] || \
    die 'snapshot conflict changed the existing bundle store'
assert_no_staging "$snapshot_store" "$bundle_store"

missing_snapshot_store="$temporary_dir/missing-snapshot-store"
missing_bundle_store="$temporary_dir/missing-bundle-store"
PACKAGE_SNAPSHOT_STORE_DIR="$missing_snapshot_store" \
PACKAGE_SNAPSHOT_BUNDLE_STORE_DIR="$missing_bundle_store" \
    "$PERSIST_SCRIPT" "$candidate" >/dev/null
missing_bundle="$missing_bundle_store/$version/immortalwrt-$version-rpi5-package-snapshot.tar.zst"
rm -f -- "$missing_bundle"
expect_failure 'incomplete existing bundle version' env \
    PACKAGE_SNAPSHOT_STORE_DIR="$missing_snapshot_store" \
    PACKAGE_SNAPSHOT_BUNDLE_STORE_DIR="$missing_bundle_store" \
    "$PERSIST_SCRIPT" "$candidate"
[[ ! -e "$missing_bundle" ]] || die 'incomplete existing bundle version was silently repaired'

# A malicious lock symlink is rejected before the redirect can truncate its
# victim. Both configurable roots are isolated from the project for this test.
safe_snapshot_store="$temporary_dir/safe-snapshot-store"
safe_bundle_store="$temporary_dir/safe-bundle-store"
mkdir -p "$safe_snapshot_store" "$safe_bundle_store"
lock_victim="$temporary_dir/lock-victim"
printf '%s\n' keep-this-content > "$lock_victim"
ln -s -- "$lock_victim" \
    "$safe_snapshot_store/.package-snapshot-persist-$version.lock"
expect_failure 'symbolic-link persistence lock' env \
    PACKAGE_SNAPSHOT_STORE_DIR="$safe_snapshot_store" \
    PACKAGE_SNAPSHOT_BUNDLE_STORE_DIR="$safe_bundle_store" \
    "$PERSIST_SCRIPT" "$candidate"
[[ $(<"$lock_victim") == keep-this-content ]] || \
    die 'persistence lock symlink caused victim truncation'

# Force the second mktemp call to fail after the first staging directory was
# created. The EXIT trap must remove that staging directory and publish nothing.
failure_snapshot_store="$temporary_dir/failure-snapshot-store"
failure_bundle_store="$temporary_dir/failure-bundle-store"
fake_bin="$temporary_dir/fake-bin"
mkdir -p "$failure_snapshot_store" "$failure_bundle_store" "$fake_bin"
real_mktemp=$(command -v mktemp)
# The single quotes deliberately preserve variables for the generated wrapper.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'count=0' \
    '[[ ! -f "$MKTEMP_CALL_STATE" ]] || read -r count < "$MKTEMP_CALL_STATE"' \
    'count=$((count + 1))' \
    'printf "%s\\n" "$count" > "$MKTEMP_CALL_STATE"' \
    '(( count == 1 )) || exit 73' \
    'exec "$REAL_MKTEMP" "$@"' \
    > "$fake_bin/mktemp"
chmod +x "$fake_bin/mktemp"
expect_failure 'second staging allocation failure' env \
    PATH="$fake_bin:$PATH" \
    MKTEMP_CALL_STATE="$temporary_dir/mktemp.calls" \
    REAL_MKTEMP="$real_mktemp" \
    PACKAGE_SNAPSHOT_STORE_DIR="$failure_snapshot_store" \
    PACKAGE_SNAPSHOT_BUNDLE_STORE_DIR="$failure_bundle_store" \
    "$PERSIST_SCRIPT" "$candidate"
[[ ! -e "$failure_snapshot_store/$version" && \
   ! -e "$failure_bundle_store/$version" ]] || \
    die 'failed persistence published a partial version'
assert_no_staging "$failure_snapshot_store" "$failure_bundle_store"

printf '%s\n' 'Package snapshot persistence tests passed.'
