#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

load_release_lock
load_target_lock "${1:-}"

case "$TARGET_NAME" in
    x86_64) description='x86/64 generic, UEFI + SquashFS only.' ;;
    rpi4) description='Raspberry Pi 4B/400/CM4, native Pi boot + SquashFS.' ;;
    rpi5) description='Raspberry Pi 5/500/CM5, native Pi boot + SquashFS.' ;;
esac

printf '# %s\n' "$description"
printf '# scripts/source/apply-source-config.sh appends the selected preset packages.\n'
printf 'CONFIG_TARGET_%s=y\n' "$TARGET"
printf 'CONFIG_TARGET_%s_%s=y\n' "$TARGET" "$SUBTARGET"
printf 'CONFIG_TARGET_%s_%s_DEVICE_%s=y\n' "$TARGET" "$SUBTARGET" "$PROFILE"
printf '\n'

if [[ "$TARGET_NAME" == x86_64 ]]; then
    printf 'CONFIG_TARGET_KERNEL_PARTSIZE=32\n'
else
    printf 'CONFIG_TARGET_KERNEL_PARTSIZE=64\n'
fi
printf 'CONFIG_TARGET_ROOTFS_PARTSIZE=%s\n' "$ROOTFS_PARTSIZE"
printf 'CONFIG_TARGET_ROOTFS_SQUASHFS=y\n'
printf '# CONFIG_TARGET_ROOTFS_EXT4FS is not set\n'
printf '# CONFIG_TARGET_ROOTFS_TARGZ is not set\n'

if [[ "$TARGET_NAME" == x86_64 ]]; then
    printf 'CONFIG_TARGET_IMAGES_GZIP=y\n'
    printf 'CONFIG_GRUB_EFI_IMAGES=y\n'
    printf '# CONFIG_GRUB_IMAGES is not set\n'
    printf '# CONFIG_ISO_IMAGES is not set\n'
    printf '# CONFIG_QCOW2_IMAGES is not set\n'
    printf '# CONFIG_VDI_IMAGES is not set\n'
    printf '# CONFIG_VHDX_IMAGES is not set\n'
    printf '# CONFIG_VMDK_IMAGES is not set\n'
fi
