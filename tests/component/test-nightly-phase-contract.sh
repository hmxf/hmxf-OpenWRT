#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
builder="$PROJECT_ROOT/scripts/build/build-nightly.sh"
temporary_dir=$(mktemp -d)
upstream=$(printf 'nightly-phase-contract:%s\n' "$temporary_dir" | \
    sha256sum | awk '{ print $1 }')
upstream_root="$PROJECT_ROOT/build/nightly/$upstream"
cleanup() {
    rm -rf -- "$temporary_dir" "$upstream_root"
}
trap cleanup EXIT

state_file="$temporary_dir/UPSTREAM_STATE.env"
{
    printf 'CHANNEL=nightly\n'
    printf 'SNAPSHOT_FINGERPRINT=%s\n' "$upstream"
} > "$state_file"

expect_failure_with() {
    local expected=$1
    shift
    if "$@" >"$temporary_dir/phase.log" 2>&1; then
        printf 'error: nightly phase negative test unexpectedly passed\n' >&2
        exit 1
    fi
    grep -Fq "$expected" "$temporary_dir/phase.log" || {
        printf 'error: nightly phase failed outside the expected gate: %s\n' \
            "$expected" >&2
        sed -n '1,80p' "$temporary_dir/phase.log" >&2
        exit 1
    }
}

# A rebuild phase must never fall back to live preparation when capture state
# is absent.  The intentionally minimal state would fail a capture immediately;
# the expected pointer error proves rebuild stayed on its offline-only path.
expect_failure_with 'nightly final-input pointer is missing or unsafe' \
    "$builder" "$state_file" rebuild x86_64
[[ ! -e "$upstream_root/context" && ! -e "$upstream_root/capture-out" ]]

mkdir -p -- "$upstream_root"
final=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
{
    printf 'NIGHTLY_BUILD_SCHEMA=1\n'
    printf 'UPSTREAM_FINGERPRINT=%s\n' "$upstream"
    printf 'PLAN_INPUTS_SHA256=%064d\n' 1
    printf 'PACKAGE_SNAPSHOTS_SHA256=%064d\n' 2
    printf 'PACKAGE_SNAPSHOT_LOCK_SHA256=%064d\n' 3
    printf 'NIGHTLY_FINGERPRINT=%s\n' "$final"
} > "$upstream_root/NIGHTLY_BUILD_POINTER.env"
expect_failure_with 'nightly final inputs are incomplete or unsafe' \
    "$builder" "$state_file" rebuild rpi4
[[ ! -e "$upstream_root/context" && ! -e "$upstream_root/capture-out" ]]

expect_failure_with 'rebuild requires target x86_64, rpi4, or rpi5' \
    "$builder" "$state_file" rebuild invalid-target

printf '%s\n' 'Nightly capture/rebuild phase separation tests passed.'
