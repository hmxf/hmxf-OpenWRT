#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

load_build_config
configure_network_environment
load_release_lock
require_command curl
require_command python3

homepage=$(curl --disable --proto '=https' --proto-redir '=https' \
    --fail --location --silent --show-error \
    --retry 3 --retry-all-errors "$IMMORTALWRT_DOWNLOAD_URL/releases/")
stable_version=$(python3 -c '
import re
import sys

matches = re.findall(
    r"href=[\"\x27]([0-9]+\.[0-9]+\.[0-9]+)/[\"\x27]",
    sys.stdin.read(),
)
if not matches:
    raise SystemExit("official download page did not expose a stable release")
print(max(set(matches), key=lambda value: tuple(map(int, value.split(".")))))
' <<< "$homepage")

[[ "$stable_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "invalid stable version reported by upstream: $stable_version"
if [[ ${1:-} == --print ]]; then
    printf '%s\n' "$stable_version"
    exit 0
elif [[ -n ${1:-} ]]; then
    die 'usage: check-latest-release.sh [--print]'
fi
[[ "$stable_version" == "$IMMORTALWRT_VERSION" ]] || \
    die "locked release $IMMORTALWRT_VERSION is no longer current; upstream stable is $stable_version"

printf 'Confirmed current ImmortalWrt stable release: %s\n' "$stable_version"
