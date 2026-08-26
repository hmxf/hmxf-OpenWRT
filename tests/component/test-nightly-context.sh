#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
preparer="$PROJECT_ROOT/scripts/build/prepare-nightly-context.sh"
temporary_dir=$(mktemp -d)
fingerprint=
tampered_fingerprint=
cleanup() {
    rm -rf -- "$temporary_dir"
    if [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
        rm -rf -- "$PROJECT_ROOT/build/nightly/$fingerprint"
    fi
    if [[ "$tampered_fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
        rm -rf -- "$PROJECT_ROOT/build/nightly/$tampered_fingerprint"
    fi
}
trap cleanup EXIT

source_commit=$(printf 'nightly-context:%s\n' "$temporary_dir" | \
    sha256sum | awk '{ print substr($1, 1, 40) }')
revision=r40001-$source_commit
source_epoch=1780000000
kernel_tuple=6.6.1~11111111111111111111111111111111-r1
feed_commit=2222222222222222222222222222222222222222
fixture_root="$temporary_dir/downloads"
archive_root="$temporary_dir/archives"
mkdir -p -- "$fixture_root/snapshots/targets" "$archive_root"

target_specs=(
    'x86_64|x86|64|generic|x86_64'
    'rpi4|bcm27xx|bcm2711|rpi-4|aarch64_cortex-a72'
    'rpi5|bcm27xx|bcm2712|rpi-5|aarch64_cortex-a76'
)
target_rows="$temporary_dir/target-rows"
: > "$target_rows"
for spec in "${target_specs[@]}"; do
    IFS='|' read -r name target subtarget profile package_arch <<< "$spec"
    archive="immortalwrt-imagebuilder-$target-$subtarget.Linux-x86_64.tar.zst"
    imagebuilder="$temporary_dir/imagebuilder-$name/${archive%.tar.zst}"
    mkdir -p -- "$imagebuilder/include"
    {
        printf 'REVISION:=%s\n' "$revision"
        printf 'SOURCE_DATE_EPOCH:=%s\n' "$source_epoch"
        printf 'KERNEL_VERSION:=%s\n' "$kernel_tuple"
    } > "$imagebuilder/include/version.mk"
    printf 'CONFIG_TARGET_ARCH_PACKAGES="%s"\n' "$package_arch" \
        > "$imagebuilder/.config"
    printf 'https://downloads.immortalwrt.org/snapshots/packages/%s/base/packages.adb\n' \
        "$package_arch" > "$imagebuilder/repositories"
    package_index="$fixture_root/snapshots/packages/$package_arch/base/packages.adb"
    mkdir -p -- "$(dirname -- "$package_index")"
    printf 'ADBd fixture package index for %s\n' "$package_arch" \
        > "$package_index"
    {
        printf 'info:\n'
        printf '\t@printf '\''Current Target: "%s/%s"\\n%s:\\n'\''\n' \
            "$target" "$subtarget" "$profile"
    } > "$imagebuilder/Makefile"
    tar --zstd -cf "$archive_root/$archive" \
        -C "$(dirname -- "$imagebuilder")" "$(basename -- "$imagebuilder")"
    archive_sha=$(sha256sum "$archive_root/$archive" | awk '{ print $1 }')
    printf '%s|%s|%s\n' "$name" "$archive" "$archive_sha" >> "$target_rows"

    metadata_dir="$fixture_root/snapshots/targets/$target/$subtarget"
    mkdir -p -- "$metadata_dir"
    printf '%s\n' "$revision" > "$metadata_dir/version.buildinfo"
    printf 'src-git packages https://github.com/immortalwrt/packages.git^%s\n' \
        "$feed_commit" > "$metadata_dir/feeds.buildinfo"
done

feeds_sha=$(sha256sum \
    "$fixture_root/snapshots/targets/x86/64/feeds.buildinfo" | awk '{ print $1 }')
targets_sha=$(sha256sum "$target_rows" | awk '{ print $1 }')
package_rows="$temporary_dir/package-rows"
: > "$package_rows"
for spec in "${target_specs[@]}"; do
    IFS='|' read -r _ _ _ _ package_arch <<< "$spec"
    package_url="https://downloads.immortalwrt.org/snapshots/packages/$package_arch/base/packages.adb"
    package_index="$fixture_root/snapshots/packages/$package_arch/base/packages.adb"
    printf '%s|%s\n' "$package_url" \
        "$(sha256sum "$package_index" | awk '{ print $1 }')" >> "$package_rows"
done
sort -u -o "$package_rows" "$package_rows"
packages_sha=$(sha256sum "$package_rows" | awk '{ print $1 }')
fingerprint=$(printf '%s\n%s\n%s\n%s\n%s\n' "$revision" \
    "$source_commit" "$feeds_sha" "$targets_sha" "$packages_sha" | \
    sha256sum | awk '{ print $1 }')
state_file="$temporary_dir/UPSTREAM_STATE.env"
{
    printf 'STATE_SCHEMA=1\nCHANNEL=nightly\nREASON=test\n'
    printf 'SNAPSHOT_VERSION_CODE=%s\n' "$revision"
    printf 'SNAPSHOT_SOURCE_COMMIT=%s\n' "$source_commit"
    printf 'SNAPSHOT_FEEDS_SHA256=%s\n' "$feeds_sha"
    printf 'SNAPSHOT_TARGETS_SHA256=%s\n' "$targets_sha"
    printf 'SNAPSHOT_PACKAGES_SHA256=%s\n' "$packages_sha"
    printf 'SNAPSHOT_FINGERPRINT=%s\n' "$fingerprint"
    while IFS='|' read -r name archive archive_sha; do
        printf 'NIGHTLY_IMAGEBUILDER_%s_FILE=%s\n' "${name^^}" "$archive"
        printf 'NIGHTLY_IMAGEBUILDER_%s_SHA256=%s\n' "${name^^}" "$archive_sha"
    done < "$target_rows"
} > "$state_file"

stub_bin="$temporary_dir/bin"
mkdir -p -- "$stub_bin"
cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
destination=
url=
while (( $# > 0 )); do
    case "$1" in
        --output) destination=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
[[ -n "$destination" && -n "$url" ]]
relative=${url#https://downloads.immortalwrt.org/}
cp -- "$NIGHTLY_TEST_FIXTURE/$relative" "$destination"
STUB
chmod +x "$stub_bin/curl"

expected_context="$PROJECT_ROOT/build/nightly/$fingerprint/context"
actual_context=$(PATH="$stub_bin:$PATH" NIGHTLY_TEST_FIXTURE="$fixture_root" \
    DOWNLOAD_DIR="$archive_root" BUILD_CONFIG=configs/build-nightly.env \
    "$preparer" "$state_file")
[[ "$actual_context" == "$expected_context" ]] || {
    printf 'error: nightly preparer wrote unexpected stdout: %q\n' \
        "$actual_context" >&2
    exit 1
}
(
    cd "$expected_context"
    sha256sum --strict --quiet -c CONTEXT.sha256
)
[[ $(awk 'NR > 1 { count += 1 } END { print count + 0 }' \
    "$expected_context/repositories/PACKAGES.sha256.tsv") == 3 ]]
[[ $(awk 'NR > 1 { print }' \
    "$expected_context/repositories/PACKAGES.sha256.tsv" | \
    sha256sum | awk '{ print $1 }') == "$packages_sha" ]]

printf '# tampered\n' >> "$expected_context/locks/feeds.tsv"
if PATH="$stub_bin:$PATH" NIGHTLY_TEST_FIXTURE="$fixture_root" \
        DOWNLOAD_DIR="$archive_root" BUILD_CONFIG=configs/build-nightly.env \
        "$preparer" "$state_file" >"$temporary_dir/reuse.log" 2>&1; then
    printf '%s\n' 'error: tampered nightly context was reused' >&2
    exit 1
fi

rm -rf -- "$PROJECT_ROOT/build/nightly/$fingerprint"
bad_state="$temporary_dir/BAD_STATE.env"
sed "s/^SNAPSHOT_FINGERPRINT=.*/SNAPSHOT_FINGERPRINT=$(printf 0%.0s {1..64})/" \
    "$state_file" > "$bad_state"
if PATH="$stub_bin:$PATH" NIGHTLY_TEST_FIXTURE="$fixture_root" \
        DOWNLOAD_DIR="$archive_root" BUILD_CONFIG=configs/build-nightly.env \
        "$preparer" "$bad_state" >"$temporary_dir/fingerprint.log" 2>&1; then
    printf '%s\n' 'error: inconsistent nightly fingerprint was accepted' >&2
    exit 1
fi

tampered_packages_sha=$(printf '%064d' 0)
tampered_fingerprint=$(printf '%s\n%s\n%s\n%s\n%s\n' "$revision" \
    "$source_commit" "$feeds_sha" "$targets_sha" "$tampered_packages_sha" | \
    sha256sum | awk '{ print $1 }')
tampered_state="$temporary_dir/TAMPERED_PACKAGES_STATE.env"
sed -e "s/^SNAPSHOT_PACKAGES_SHA256=.*/SNAPSHOT_PACKAGES_SHA256=$tampered_packages_sha/" \
    -e "s/^SNAPSHOT_FINGERPRINT=.*/SNAPSHOT_FINGERPRINT=$tampered_fingerprint/" \
    "$state_file" > "$tampered_state"
if PATH="$stub_bin:$PATH" NIGHTLY_TEST_FIXTURE="$fixture_root" \
        DOWNLOAD_DIR="$archive_root" BUILD_CONFIG=configs/build-nightly.env \
        "$preparer" "$tampered_state" \
        >"$temporary_dir/package-fingerprint.log" 2>&1; then
    printf '%s\n' \
        'error: recomputed fingerprint accepted a false package-index identity' >&2
    exit 1
fi

grep -Fq "printf 'release_channel=stable" \
    "$PROJECT_ROOT/scripts/build/build-source.sh" || {
    printf '%s\n' 'error: source BUILD_INFO does not declare the stable channel' >&2
    exit 1
}

printf '%s\n' 'Nightly context integrity and source identity tests passed.'
