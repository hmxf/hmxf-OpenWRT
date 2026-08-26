#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
    cat <<'EOF'
Usage:
  nightly-build-identity.sh content PACKAGE_SNAPSHOTS.tsv
  nightly-build-identity.sh fingerprint UPSTREAM_SHA256 PLAN_INPUTS.sha256 PACKAGE_SNAPSHOTS.tsv

The portable content identity hashes canonical target|tree-manifest rows. It
deliberately excludes tar/zstd bundle bytes so equivalent repository trees
have one build identity across hosts and compression-tool versions.
EOF
}

case ${1:-} in
    content)
        [[ $# -eq 2 ]] || { usage >&2; exit 2; }
        mode=content
        snapshot_input=$2
        ;;
    fingerprint)
        [[ $# -eq 4 ]] || { usage >&2; exit 2; }
        mode=fingerprint
        upstream_fingerprint=$2
        plan_input=$3
        snapshot_input=$4
        [[ "$upstream_fingerprint" =~ ^[0-9a-f]{64}$ ]] || \
            die 'upstream fingerprint must be a complete SHA-256'
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) usage >&2; exit 2 ;;
esac

snapshot_lock=$(realpath -e -- "$snapshot_input")
[[ -f "$snapshot_lock" && ! -L "$snapshot_lock" ]] || \
    die "package snapshot lock is not a regular file: $snapshot_lock"
# These globals are the explicit input contract of the common lock parser.
# shellcheck disable=SC2034
IMMORTALWRT_VERSION=SNAPSHOT
# shellcheck disable=SC2034
PACKAGE_SNAPSHOT_LOCK=$snapshot_lock
validate_package_snapshot_lock

content_rows=
for target in x86_64 rpi4 rpi5; do
    tree_sha=$(awk -F'|' -v wanted="$target" '
        $1 == wanted { count += 1; value = $5 }
        END { if (count == 1) print value; else exit 1 }
    ' "$snapshot_lock") || die "package snapshot lock has no unique $target row"
    [[ "$tree_sha" =~ ^[0-9a-f]{64}$ ]] || \
        die "package snapshot tree identity is invalid for $target"
    content_rows+=${content_rows:+$'\n'}"$target|$tree_sha"
done
content_sha=$(printf '%s\n' "$content_rows" | sha256sum | awk '{ print $1 }')

if [[ "$mode" == content ]]; then
    printf '%s\n' "$content_sha"
    exit 0
fi

plan_manifest=$(realpath -e -- "$plan_input")
[[ -f "$plan_manifest" && ! -L "$plan_manifest" && -s "$plan_manifest" ]] || \
    die "plan-input manifest is not a nonempty regular file: $plan_manifest"
plan_sha=$(sha256sum "$plan_manifest" | awk '{ print $1 }')
printf 'nightly-build-v1\n%s\n%s\n%s\n' "$upstream_fingerprint" \
    "$plan_sha" "$content_sha" | sha256sum | awk '{ print $1 }'
