#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

load_build_config
load_release_lock
load_target_lock "${1:-}"
load_preset "${2:-}"
validate_extra_packages
SOURCE_PATH=${SOURCE_PATH:-"$(dirname -- "$PROJECT_ROOT")/ImmortalWRT"}

"$SOURCE_SCRIPTS_DIR/verify-source.sh" "$SOURCE_PATH"
cp -- "$CONFIGS_DIR/$TARGET_NAME.config" "$SOURCE_PATH/.config"

if [[ "$SOURCE_KMOD_SCOPE" == all ]]; then
    printf 'CONFIG_ALL_KMODS=y\n' >> "$SOURCE_PATH/.config"
else
    printf '# CONFIG_ALL_KMODS is not set\n' >> "$SOURCE_PATH/.config"
fi

while IFS= read -r package; do
    printf 'CONFIG_PACKAGE_%s=y\n' "$package" >> "$SOURCE_PATH/.config"
done < <(read_preset_packages | tr ' ' '\n')
extra_packages=()
if [[ -n ${EXTRA_PACKAGES:-} ]]; then
    read -r -a extra_packages <<< "$EXTRA_PACKAGES"
fi
for package in "${extra_packages[@]}"; do
    printf 'CONFIG_PACKAGE_%s=y\n' "$package" >> "$SOURCE_PATH/.config"
done

printf 'Loaded %s/%s into %s/.config\n' "$TARGET_NAME" "$PRESET_NAME" "$SOURCE_PATH"
printf 'No tracked upstream source files, feed definitions, defaults, or downloaded binaries were modified.\n'
