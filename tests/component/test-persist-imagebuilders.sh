#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=../../scripts/lib/common.sh
source "$PROJECT_ROOT/scripts/lib/common.sh"

for tool in cp mktemp sha256sum stat; do
    require_command "$tool"
done

temporary_dir=$(mktemp -d)
cleanup() {
    rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

candidate="$temporary_dir/candidate"
store="$temporary_dir/store"
mkdir -p "$candidate/locks" "$candidate/imagebuilders" "$store"
cp -- "$PROJECT_ROOT/locks/release.env" "$candidate/locks/release.env"

declare -a target_rows=(
    'x86_64|x86|64|generic|x86_64'
    'rpi4|bcm27xx|bcm2711|rpi-4|aarch64_cortex-a72'
    'rpi5|bcm27xx|bcm2712|rpi-5|aarch64_cortex-a76'
)
printf '%s\n' \
    '# name|target|subtarget|profile|package_arch|imagebuilder_filename|sha256|kernel_vermagic|bytes' \
    > "$candidate/locks/targets.tsv"
for row in "${target_rows[@]}"; do
    IFS='|' read -r name target subtarget _profile _arch <<< "$row"
    archive_name="immortalwrt-imagebuilder-25.12.1-$target-$subtarget.Linux-x86_64.tar.zst"
    printf 'fixture-%s\n' "$name" > "$candidate/imagebuilders/$archive_name"
    digest=$(sha256sum "$candidate/imagebuilders/$archive_name" | awk '{ print $1 }')
    bytes=$(stat -c '%s' "$candidate/imagebuilders/$archive_name")
    printf '%s|%s|%s|%s\n' "$row" "$archive_name" \
        "$digest|00000000000000000000000000000000" "$bytes" \
        >> "$candidate/locks/targets.tsv"
done

IMAGEBUILDER_STORE_DIR="$store" \
    "$INPUT_SCRIPTS_DIR/persist-imagebuilders.sh" "$candidate" >/dev/null
[[ $(find "$store" -maxdepth 1 -type f ! -name '.*.lock' | wc -l) == 3 ]] || \
    die 'ImageBuilder persistence fixture did not publish three archives'

mapfile -t persisted < <(find "$store" -maxdepth 1 -type f ! -name '.*.lock' | sort)
before=$(for file in "${persisted[@]}"; do stat -c '%n|%i|%s|%Y' "$file"; done)
IMAGEBUILDER_STORE_DIR="$store" \
    "$INPUT_SCRIPTS_DIR/persist-imagebuilders.sh" "$candidate" >/dev/null
after=$(for file in "${persisted[@]}"; do stat -c '%n|%i|%s|%Y' "$file"; done)
[[ "$before" == "$after" ]] || die 'idempotent ImageBuilder persistence rewrote files'

printf 'conflict\n' > "${persisted[0]}"
if IMAGEBUILDER_STORE_DIR="$store" \
        "$INPUT_SCRIPTS_DIR/persist-imagebuilders.sh" "$candidate" \
        >"$temporary_dir/conflict.log" 2>&1; then
    die 'conflicting persisted ImageBuilder was accepted'
fi

printf '%s\n' 'ImageBuilder persistence tests passed.'
