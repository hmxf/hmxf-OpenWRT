#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
capture_script="$PROJECT_ROOT/scripts/inputs/capture-nightly-package-snapshots.sh"
index_script="$PROJECT_ROOT/scripts/cache/index-package-cache.sh"
snapshot_verifier="$PROJECT_ROOT/scripts/inputs/verify-package-snapshot.py"
context_extractor="$PROJECT_ROOT/scripts/inputs/extract-nightly-build-context.py"
temporary_dir=$(mktemp -d)
upstream=$(printf 'nightly-package-capture:%s\n' "$temporary_dir" | \
    sha256sum | awk '{ print $1 }')
upstream_root="$PROJECT_ROOT/build/nightly/$upstream"
final_root=
cleanup() {
    rm -rf -- "$temporary_dir" "$upstream_root"
    [[ -z "$final_root" ]] || rm -rf -- "$final_root"
}
trap cleanup EXIT

context_dir="$upstream_root/context"
capture_output="$upstream_root/capture-out/SNAPSHOT"
package_cache="$temporary_dir/package-cache"
download_dir="$temporary_dir/imagebuilders"
fixture_dir="$temporary_dir/fixture"
stub_bin="$temporary_dir/bin"
mkdir -p -- "$context_dir/locks" "$context_dir/repositories" \
    "$capture_output" "$package_cache/SNAPSHOT" "$download_dir" \
    "$fixture_dir" "$stub_bin"

cat > "$stub_bin/apk" <<'APK'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == adbdump ]]
if [[ ${2:-} == --help ]]; then
    printf '%s\n' 'Usage: apk adbdump'
    exit 0
fi
input=${*: -1}
if [[ $(basename -- "$input") == packages.adb ]]; then
    printf '%s\n' '{"packages":[{"name":"alpha","version":"1.0-r1","arch":"noarch","hashes":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
else
    printf '%s\n' '{"info":{"name":"alpha","version":"1.0-r1","arch":"noarch"}}'
fi
APK
cat > "$stub_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
destination=
while (( $# > 0 )); do
    case "$1" in
        --output) destination=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "$destination" ]]
cp -- "$NIGHTLY_CAPTURE_INDEX" "$destination"
CURL
chmod +x "$stub_bin/apk" "$stub_bin/curl"
printf '%s\n' 'signed fixture index bytes' > "$fixture_dir/packages.adb"

target_specs=(
    'x86_64|x86|64|generic|x86_64'
    'rpi4|bcm27xx|bcm2711|rpi-4|aarch64_cortex-a72'
    'rpi5|bcm27xx|bcm2712|rpi-5|aarch64_cortex-a76'
)
printf '%s\n' '# name|target|subtarget|profile|package_arch|imagebuilder_filename|sha256|kernel_vermagic|bytes' \
    > "$context_dir/locks/targets.tsv"
for spec in "${target_specs[@]}"; do
    IFS='|' read -r target_name target subtarget profile arch <<< "$spec"
    archive="immortalwrt-imagebuilder-$target-$subtarget.Linux-x86_64.tar.zst"
    archive_source="$temporary_dir/archive-$target_name/${archive%.tar.zst}"
    mkdir -p -- "$archive_source"
    if [[ "$target_name" == x86_64 ]]; then
        mkdir -p -- "$archive_source/staging_dir/host/bin"
        cp -- "$stub_bin/apk" "$archive_source/staging_dir/host/bin/apk"
    else
        printf '%s\n' "$target_name" > "$archive_source/fixture.txt"
    fi
    tar --zstd -cf "$download_dir/$archive" \
        -C "$(dirname -- "$archive_source")" "$(basename -- "$archive_source")"
    archive_sha=$(sha256sum "$download_dir/$archive" | awk '{ print $1 }')
    archive_bytes=$(stat -c '%s' "$download_dir/$archive")
    printf '%s|%s|%s|%s|%s|%s|%s|%032d|%s\n' \
        "$target_name" "$target" "$subtarget" "$profile" "$arch" \
        "$archive" "$archive_sha" 1 "$archive_bytes" \
        >> "$context_dir/locks/targets.tsv"
    printf 'https://downloads.immortalwrt.org/snapshots/packages/%s/base/packages.adb\n' \
        "$arch" > "$context_dir/repositories/$target_name.list"

    mkdir -p -- "$package_cache/SNAPSHOT/$target_name"
    printf '%s\n' "fixture APK for $target_name" \
        > "$package_cache/SNAPSHOT/$target_name/alpha-1.0-r1.aaaaaaaa.apk"
    APK_METADATA_TOOL="$stub_bin/apk" "$index_script" update \
        "$package_cache" SNAPSHOT "$target_name" >/dev/null

    for preset in minimal full; do
        artifact_dir="$capture_output/$target_name/$preset"
        mkdir -p -- "$artifact_dir"
        printf '%s\n' \
            'alpha - 1.0-r1' \
            'base-files - 1' \
            'kernel - 1' \
            'libc - 1' > "$artifact_dir/fixture.manifest"
        if [[ "$target_name" == x86_64 ]]; then
            printf '%s\n' "$target_name-$preset" \
                > "$artifact_dir/immortalwrt-SNAPSHOT-$preset-x86-64-generic-squashfs-combined-efi.img.gz"
        else
            for kind in factory sysupgrade; do
                printf '%s\n' "$target_name-$preset-$kind" \
                    > "$artifact_dir/immortalwrt-SNAPSHOT-$preset-$target-$subtarget-$profile-squashfs-$kind.img.gz"
            done
        fi
    done
done

package_rows="$temporary_dir/package-index-rows"
: > "$package_rows"
index_sha=$(sha256sum "$fixture_dir/packages.adb" | awk '{ print $1 }')
for target_name in x86_64 rpi4 rpi5; do
    while IFS= read -r repository_url; do
        printf '%s|%s\n' "$repository_url" "$index_sha" >> "$package_rows"
    done < "$context_dir/repositories/$target_name.list"
done
sort -u -o "$package_rows" "$package_rows"
{
    printf '%s\n' '# url|sha256'
    cat "$package_rows"
} > "$context_dir/repositories/PACKAGES.sha256.tsv"
packages_sha=$(sha256sum "$package_rows" | awk '{ print $1 }')

printf '%s\n' "$upstream" > "$context_dir/UPSTREAM_STATE.env"
sed -i '1s/^/SNAPSHOT_FINGERPRINT=/' "$context_dir/UPSTREAM_STATE.env"
printf 'SNAPSHOT_PACKAGES_SHA256=%s\n' "$packages_sha" \
    >> "$context_dir/UPSTREAM_STATE.env"
printf '%s\n' '# fixture feeds' > "$context_dir/locks/feeds.tsv"
cat > "$context_dir/locks/release.env" <<EOF
IMMORTALWRT_VERSION=SNAPSHOT
LOCKED_INPUT_RELEASE_TAG=nightly-$upstream
IMMORTALWRT_SOURCE_DATE_EPOCH=1700000000
EOF
(
    cd "$context_dir"
    sha256sum UPSTREAM_STATE.env locks/feeds.tsv locks/release.env \
        locks/targets.tsv repositories/rpi4.list repositories/rpi5.list \
        repositories/x86_64.list repositories/PACKAGES.sha256.tsv \
        > CONTEXT.sha256
)

fingerprint=$(PATH="$stub_bin:$PATH" \
    NIGHTLY_CAPTURE_INDEX="$fixture_dir/packages.adb" \
    BUILD_CONFIG=configs/build-nightly.env \
    "$capture_script" "$upstream" "$context_dir" "$capture_output" \
    "$package_cache" "$download_dir")
[[ "$fingerprint" =~ ^[0-9a-f]{64}$ && "$fingerprint" != "$upstream" ]]
final_root="$PROJECT_ROOT/build/nightly/$fingerprint"
context_archive_sha=$(sha256sum "$final_root/NIGHTLY_BUILD_CONTEXT.tar" | \
    awk '{ print $1 }')
context_extract="$temporary_dir/context-extract"
mkdir -- "$context_extract"
PYTHONDONTWRITEBYTECODE=1 python3 "$context_extractor" \
    "$final_root/NIGHTLY_BUILD_CONTEXT.tar" "$context_extract" 1700000000
cmp -s "$context_extract/NIGHTLY_BUILD.env" "$final_root/NIGHTLY_BUILD.env"
diff -qr --no-dereference "$context_extract/context" \
    "$final_root/context" >/dev/null
cmp -s "$upstream_root/NIGHTLY_BUILD_POINTER.env" \
    "$final_root/NIGHTLY_BUILD.env"
grep -Fqx 'NIGHTLY_BUILD_SCHEMA=1' "$final_root/NIGHTLY_BUILD.env"
grep -Fqx "NIGHTLY_FINGERPRINT=$fingerprint" "$final_root/NIGHTLY_BUILD.env"
grep -Fqx "LOCKED_INPUT_RELEASE_TAG=nightly-$fingerprint" \
    "$final_root/context/locks/release.env"
[[ $(find "$final_root/imagebuilders" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 3 ]]
[[ $(find "$final_root/context/locks/manifests" -mindepth 1 -maxdepth 1 \
    -type f | wc -l) -eq 6 ]]
[[ $(awk '!/^#/ { count++ } END { print count + 0 }' \
    "$final_root/context/locks/artifacts.tsv") -eq 10 ]]
(
    cd "$final_root/context"
    sha256sum --strict --quiet -c CONTEXT.sha256
)
for target_name in x86_64 rpi4 rpi5; do
    tree_sha=$(awk -F'|' -v wanted="$target_name" \
        '$1 == wanted { print $5 }' \
        "$final_root/context/locks/package-snapshots.tsv")
    PYTHONDONTWRITEBYTECODE=1 python3 "$snapshot_verifier" verify \
        "$final_root/package-snapshots/SNAPSHOT/$target_name" SNAPSHOT \
        "$target_name" "$tree_sha" >/dev/null
done

second=$(PATH="$stub_bin:$PATH" \
    NIGHTLY_CAPTURE_INDEX="$fixture_dir/packages.adb" \
    BUILD_CONFIG=configs/build-nightly.env \
    "$capture_script" "$upstream" "$context_dir" "$capture_output" \
    "$package_cache" "$download_dir")
[[ "$second" == "$fingerprint" ]]
[[ $(sha256sum "$final_root/NIGHTLY_BUILD_CONTEXT.tar" | awk '{ print $1 }') == \
   "$context_archive_sha" ]]

# A packages.adb changed after classification must not be accepted even when a
# previously frozen final root exists for the old upstream fingerprint.
printf '%s\n' 'changed package index after classification' \
    > "$fixture_dir/packages.adb"
if PATH="$stub_bin:$PATH" NIGHTLY_CAPTURE_INDEX="$fixture_dir/packages.adb" \
        BUILD_CONFIG=configs/build-nightly.env \
        "$capture_script" "$upstream" "$context_dir" "$capture_output" \
        "$package_cache" "$download_dir" >/dev/null 2>&1; then
    printf '%s\n' 'error: post-classification packages.adb drift was accepted' >&2
    exit 1
fi

printf '%s\n' 'Nightly package capture and immutable-context tests passed.'
