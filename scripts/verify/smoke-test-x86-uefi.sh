#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

artifact_dir=${1:?x86 artifact directory required}
[[ -d "$artifact_dir" ]] || die "missing artifact directory: $artifact_dir"
smoke_timeout=${SMOKE_TIMEOUT_SECONDS:-240}
[[ "$smoke_timeout" =~ ^[1-9][0-9]*$ ]] || die 'SMOKE_TIMEOUT_SECONDS must be a positive integer'
(( smoke_timeout >= 30 && smoke_timeout <= 600 )) || \
    die 'SMOKE_TIMEOUT_SECONDS must be between 30 and 600'
for tool in curl dd flock gzip qemu-system-x86_64; do
    require_command "$tool"
done

# Local users may launch minimal/full builds concurrently.  Serialize this
# host-port-based test so the second image cannot collide with 127.0.0.1:18443.
mkdir -p "$PROJECT_ROOT/build"
smoke_lock="$PROJECT_ROOT/build/.x86-uefi-smoke.lock"
require_regular_file_or_absent "$smoke_lock" 'x86 smoke-test lock'
exec {smoke_lock_fd}>"$smoke_lock"
flock "$smoke_lock_fd"

shopt -s nullglob
images=("$artifact_dir"/*-squashfs-combined-efi.img.gz)
[[ ${#images[@]} -eq 1 ]] || die "expected exactly one x86 combined EFI image"
image=${images[0]}

ovmf_code=${OVMF_CODE_FILE:-}
ovmf_vars=${OVMF_VARS_FILE:-}
if [[ -n "$ovmf_code" || -n "$ovmf_vars" ]]; then
    [[ -r "$ovmf_code" && -r "$ovmf_vars" ]] || \
        die 'OVMF_CODE_FILE and OVMF_VARS_FILE must both name readable files'
else
    for pair in \
        '/usr/share/OVMF/OVMF_CODE.fd|/usr/share/OVMF/OVMF_VARS.fd' \
        '/usr/share/OVMF/OVMF_CODE_4M.fd|/usr/share/OVMF/OVMF_VARS_4M.fd' \
        '/usr/share/edk2/x64/OVMF_CODE.fd|/usr/share/edk2/x64/OVMF_VARS.fd'; do
        code=${pair%%|*}
        vars=${pair#*|}
        if [[ -r "$code" && -r "$vars" ]]; then
            ovmf_code=$code
            ovmf_vars=$vars
            break
        fi
    done
fi
[[ -n "$ovmf_code" ]] || die "OVMF firmware was not found"

temporary_dir=$(mktemp -d)
qemu_pid=
cleanup() {
    local status=$?
    if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
    if (( status != 0 )) && [[ -s ${serial_log:-} ]]; then
        printf '%s\n' '--- QEMU serial log (last 160 lines) ---' >&2
        tail -n 160 "$serial_log" >&2 || true
    fi
    rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

raw_image="$temporary_dir/firmware.img"
vars_copy="$temporary_dir/OVMF_VARS.fd"
serial_log="$temporary_dir/serial.log"
https_headers="$temporary_dir/https.headers"
https_body="$temporary_dir/https.body"
cp -- "$ovmf_vars" "$vars_copy"
gzip -dc -- "$image" | dd of="$raw_image" bs=4M conv=sparse status=none

qemu_data_args=()
if [[ -n ${QEMU_DATA_PATH:-} ]]; then
    [[ -d "$QEMU_DATA_PATH" ]] || die "QEMU_DATA_PATH is not a directory: $QEMU_DATA_PATH"
    qemu_data_args=(-L "$QEMU_DATA_PATH")
fi

qemu-system-x86_64 \
    -machine q35,accel=tcg \
    -cpu max \
    -m 512 \
    -display none \
    -vga none \
    -monitor none \
    -serial "file:$serial_log" \
    -no-reboot \
    "${qemu_data_args[@]}" \
    -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code" \
    -drive "if=pflash,format=raw,file=$vars_copy" \
    -drive "if=virtio,format=raw,file=$raw_image" \
    -netdev 'user,id=wan,net=192.168.1.0/24,host=192.168.1.254,dhcpstart=192.168.1.100,hostfwd=tcp:127.0.0.1:18443-192.168.1.1:443' \
    -device virtio-net-pci,netdev=wan,romfile= &
qemu_pid=$!

https_ready=0
smoke_start=$SECONDS
while (( SECONDS - smoke_start < smoke_timeout )); do
    http_code=$(curl --disable --insecure --silent --show-error --max-time 2 --noproxy '*' \
        --header 'Host: 192.168.1.1' \
        --dump-header "$https_headers" \
        --output "$https_body" \
        --write-out '%{http_code}' \
        https://127.0.0.1:18443/cgi-bin/luci/ 2>/dev/null || true)
    # LuCI deliberately answers an unauthenticated request with HTTP 403 and
    # a complete login page.  Treat that as success only when both its header
    # and static-resource marker are present; a generic 403 must not pass.
    if [[ "$http_code" == 200 || "$http_code" == 403 ]] && \
       grep -Eiq '^x-luci-login-required:[[:space:]]*yes' "$https_headers" && \
       grep -Fq '/luci-static/' "$https_body"; then
        https_ready=1
        break
    fi
    kill -0 "$qemu_pid" 2>/dev/null || break
    sleep 2
done

[[ -s "$serial_log" ]] || die "QEMU produced no serial boot log"
grep -Eiq 'EFI v[0-9]|UEFI' "$serial_log" || die "serial log did not confirm UEFI boot"
grep -Eiq 'squashfs.*(mounted|filesystem)|VFS: Mounted root.*squashfs' "$serial_log" || \
    die "serial log did not confirm a SquashFS root"
(( https_ready == 1 )) || die "LuCI HTTPS did not become reachable through the emulated LAN"

printf 'QEMU/OVMF booted %s to LuCI HTTPS successfully\n' "$(basename -- "$image")"
