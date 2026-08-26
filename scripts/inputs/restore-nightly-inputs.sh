#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

[[ $# -ge 1 && $# -le 2 ]] || \
    die 'usage: restore-nightly-inputs.sh RELEASE_ASSET_DIR [BUILD_NIGHTLY_ROOT]'
for tool in awk chmod cmp cp diff dirname find flock mkdir mktemp mv python3 \
            realpath rm sed sha256sum sort stat wc zstd; do
    require_command "$tool"
done

[[ -d "$1" && ! -L "$1" ]] || \
    die 'nightly Release asset root must not be a symbolic link'
release_root=$(realpath -e -- "$1")
[[ "$release_root" != / && -d "$release_root" && ! -L "$release_root" ]] || \
    die 'nightly Release asset root must be a real non-root directory'
[[ $(realpath -ms -- "$release_root") == "$release_root" ]] || \
    die 'nightly Release asset root traverses a symbolic link'
destination_input=${2:-"$PROJECT_ROOT/build/nightly"}
destination_root=$(realpath -ms -- "$destination_input")
[[ "$destination_root" != / && "$destination_root" != "$PROJECT_ROOT" ]] || \
    die 'nightly restore destination is unsafe'
probe=$destination_root
while [[ ! -e "$probe" && ! -L "$probe" ]]; do probe=$(dirname -- "$probe"); done
[[ -d "$probe" && ! -L "$probe" && $(realpath -e -- "$probe") == "$probe" ]] || \
    die 'nightly restore destination has an unsafe ancestor'
mkdir -p -- "$destination_root"
[[ -d "$destination_root" && ! -L "$destination_root" && \
   $(realpath -e -- "$destination_root") == "$destination_root" ]] || \
    die 'nightly restore destination is unsafe'
restore_lock="$destination_root/.nightly-input-restore.lock"
require_regular_file_or_absent "$restore_lock" 'nightly input restore lock'
exec {restore_lock_fd}>"$restore_lock"
flock "$restore_lock_fd"

state="$release_root/NIGHTLY_BUILD.env"
upstream_state="$release_root/UPSTREAM_STATE.env"
release_lock="$release_root/NIGHTLY_RELEASE.env"
target_lock="$release_root/NIGHTLY_TARGETS.tsv"
snapshot_lock="$release_root/NIGHTLY_PACKAGE_SNAPSHOTS.tsv"
plan="$release_root/PLAN_INPUTS.sha256"
plan_revision="$release_root/PLAN_INPUT_REVISION.txt"
for file in "$state" "$upstream_state" "$release_lock" "$target_lock" \
            "$snapshot_lock" "$plan" "$plan_revision" \
            "$release_root/NIGHTLY_BUILD_CONTEXT.tar" \
            "$release_root/SHA256SUMS"; do
    [[ -f "$file" && ! -L "$file" && -s "$file" ]] || \
        die "nightly Release input is missing or unsafe: $(basename -- "$file")"
done

value() {
    local file=${1:?environment file required} key=${2:?key required}
    awk -F= -v wanted="$key" '
        $1 == wanted { count += 1; value = substr($0, length($1) + 2) }
        END { if (count == 1) print value; else exit 1 }
    ' "$file" || die "nightly Release state has no unique $key"
}

awk -F= '
    BEGIN {
        allowed["NIGHTLY_BUILD_SCHEMA"] = 1
        allowed["UPSTREAM_FINGERPRINT"] = 1
        allowed["PLAN_INPUTS_SHA256"] = 1
        allowed["PACKAGE_SNAPSHOTS_SHA256"] = 1
        allowed["PACKAGE_SNAPSHOT_LOCK_SHA256"] = 1
        allowed["NIGHTLY_FINGERPRINT"] = 1
    }
    $0 !~ /^[A-Z][A-Z0-9_]*=[A-Za-z0-9._:/+-]+$/ ||
      !($1 in allowed) || seen[$1]++ { exit 1 }
    END { if (NR != 6) exit 1 }
' "$state" || die 'NIGHTLY_BUILD.env violates its six-key schema'
awk -F= '
    BEGIN {
        split("STATE_SCHEMA CHANNEL REASON LOCKED_STABLE_VERSION LATEST_STABLE_VERSION SNAPSHOT_VERSION_CODE SNAPSHOT_SOURCE_COMMIT SNAPSHOT_FEEDS_SHA256 SNAPSHOT_TARGETS_SHA256 SNAPSHOT_PACKAGES_SHA256 SNAPSHOT_FINGERPRINT NIGHTLY_IMAGEBUILDER_X86_64_FILE NIGHTLY_IMAGEBUILDER_X86_64_SHA256 NIGHTLY_IMAGEBUILDER_RPI4_FILE NIGHTLY_IMAGEBUILDER_RPI4_SHA256 NIGHTLY_IMAGEBUILDER_RPI5_FILE NIGHTLY_IMAGEBUILDER_RPI5_SHA256", keys, " ")
        for (i in keys) allowed[keys[i]] = 1
    }
    $0 !~ /^[A-Z][A-Z0-9_]*=[A-Za-z0-9._:/+~-]+$/ ||
      !($1 in allowed) || seen[$1]++ { exit 1 }
    END { if (NR != 17) exit 1 }
' "$upstream_state" || die 'UPSTREAM_STATE.env violates its 17-key schema'
awk -F= '
    BEGIN {
        split("IMMORTALWRT_VERSION IMMORTALWRT_TAG IMMORTALWRT_TAG_OBJECT IMMORTALWRT_COMMIT IMMORTALWRT_SOURCE_URL IMMORTALWRT_DOWNLOAD_URL LOCKED_INPUT_RELEASE_TAG IMMORTALWRT_VERSION_CODE IMMORTALWRT_SOURCE_DATE_EPOCH IMMORTALWRT_KERNEL_VERSION IMMORTALWRT_KERNEL_RELEASE ROOTFS_PARTSIZE NOMINAL_MEDIA_BYTES", keys, " ")
        for (i in keys) allowed[keys[i]] = 1
    }
    $0 !~ /^[A-Z][A-Z0-9_]*=[A-Za-z0-9._:/+~-]+$/ ||
      !($1 in allowed) || seen[$1]++ { exit 1 }
    END { if (NR != 13) exit 1 }
' "$release_lock" || die 'NIGHTLY_RELEASE.env violates its 13-key schema'
[[ $(value "$state" NIGHTLY_BUILD_SCHEMA) == 1 ]] || \
    die 'unsupported nightly build schema'
upstream=$(value "$state" UPSTREAM_FINGERPRINT)
fingerprint=$(value "$state" NIGHTLY_FINGERPRINT)
plan_sha=$(value "$state" PLAN_INPUTS_SHA256)
snapshot_content_sha=$(value "$state" PACKAGE_SNAPSHOTS_SHA256)
snapshot_lock_sha=$(value "$state" PACKAGE_SNAPSHOT_LOCK_SHA256)
[[ "$upstream" =~ ^[0-9a-f]{64}$ && "$fingerprint" =~ ^[0-9a-f]{64}$ && \
   "$plan_sha" =~ ^[0-9a-f]{64}$ && \
   "$snapshot_content_sha" =~ ^[0-9a-f]{64}$ && \
   "$snapshot_lock_sha" =~ ^[0-9a-f]{64}$ ]] || \
    die 'nightly build state contains an invalid digest'
[[ $(value "$upstream_state" CHANNEL) == nightly && \
   $(value "$upstream_state" SNAPSHOT_FINGERPRINT) == "$upstream" ]] || \
    die 'UPSTREAM_STATE.env differs from NIGHTLY_BUILD.env'
snapshot_version=$(value "$upstream_state" SNAPSHOT_VERSION_CODE)
snapshot_commit=$(value "$upstream_state" SNAPSHOT_SOURCE_COMMIT)
feeds_sha=$(value "$upstream_state" SNAPSHOT_FEEDS_SHA256)
targets_sha=$(value "$upstream_state" SNAPSHOT_TARGETS_SHA256)
packages_sha=$(value "$upstream_state" SNAPSHOT_PACKAGES_SHA256)
snapshot_version_commit=${snapshot_version#*-}
[[ "$snapshot_version" =~ ^r[0-9]+-[0-9a-f]{7,40}$ && \
   "$snapshot_commit" =~ ^[0-9a-f]{40}$ && \
   "${snapshot_commit:0:${#snapshot_version_commit}}" == \
       "$snapshot_version_commit" && \
   "$feeds_sha" =~ ^[0-9a-f]{64}$ && "$targets_sha" =~ ^[0-9a-f]{64}$ && \
   "$packages_sha" =~ ^[0-9a-f]{64}$ && \
   $(value "$release_lock" IMMORTALWRT_VERSION) == SNAPSHOT && \
   $(value "$release_lock" IMMORTALWRT_COMMIT) == "$snapshot_commit" && \
   $(value "$release_lock" LOCKED_INPUT_RELEASE_TAG) == \
       "nightly-$fingerprint" ]] || \
    die 'nightly upstream/release identity is inconsistent'
# These globals are the explicit input contract of the common target parser.
# shellcheck disable=SC2034
BUILD_CHANNEL=nightly
# shellcheck disable=SC2034
TARGET_LOCK=$target_lock
target_fingerprint_rows=
feeds_buildinfo=
declare -A seen_feeds=()
for target in x86_64 rpi4 rpi5; do
    load_target_lock "$target"
    case "$target" in x86_64) prefix=X86_64 ;; rpi4) prefix=RPI4 ;; rpi5) prefix=RPI5 ;; esac
    [[ $(value "$upstream_state" "NIGHTLY_IMAGEBUILDER_${prefix}_FILE") == \
           "$IMAGEBUILDER_FILE" && \
       $(value "$upstream_state" "NIGHTLY_IMAGEBUILDER_${prefix}_SHA256") == \
           "$IMAGEBUILDER_SHA256" ]] || \
        die "nightly upstream state/target lock mismatch: $target"
    target_fingerprint_rows+="${target_fingerprint_rows:+$'\n'}$TARGET_NAME|$IMAGEBUILDER_FILE|$IMAGEBUILDER_SHA256"
done
[[ $(printf '%s\n' "$target_fingerprint_rows" | sha256sum | awk '{ print $1 }') == \
   "$targets_sha" ]] || die 'nightly target lock does not reproduce upstream identity'
while IFS='|' read -r feed_name feed_type feed_url feed_commit feed_extra || \
        [[ -n "$feed_name$feed_type$feed_url$feed_commit$feed_extra" ]]; do
    [[ -z "$feed_extra" && "$feed_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && \
       "$feed_type" =~ ^src-git(-full)?$ && "$feed_url" == https://* && \
       "$feed_url" != *[[:space:]\\]* && "$feed_commit" =~ ^[0-9a-f]{40}$ ]] || \
        die 'nightly feed provenance contains an unsafe row'
    [[ -z ${seen_feeds[$feed_name]+present} ]] || \
        die 'nightly feed provenance contains a duplicate name'
    seen_feeds[$feed_name]=1
    feeds_buildinfo+="${feeds_buildinfo:+$'\n'}$feed_type $feed_name $feed_url^$feed_commit"
done < "$release_root/NIGHTLY_FEEDS.tsv"
[[ -n "$feeds_buildinfo" && \
   $(printf '%s\n' "$feeds_buildinfo" | sha256sum | awk '{ print $1 }') == \
       "$feeds_sha" && \
   $(printf '%s\n%s\n%s\n%s\n%s\n' "$snapshot_version" \
       "$snapshot_commit" "$feeds_sha" "$targets_sha" "$packages_sha" | \
       sha256sum | awk '{ print $1 }') == \
       "$upstream" ]] || \
    die 'nightly feed/upstream fingerprint cannot be reproduced'
[[ $(sha256sum "$plan" | awk '{ print $1 }') == "$plan_sha" && \
   $(sha256sum "$snapshot_lock" | awk '{ print $1 }') == "$snapshot_lock_sha" ]] || \
    die 'nightly plan/package lock digest mismatch'
# These globals are the explicit input contract of the common lock parser.
# shellcheck disable=SC2034
IMMORTALWRT_VERSION=SNAPSHOT
# shellcheck disable=SC2034
PACKAGE_SNAPSHOT_LOCK=$snapshot_lock
validate_package_snapshot_lock
[[ $("$INPUT_SCRIPTS_DIR/nightly-build-identity.sh" content "$snapshot_lock") == \
   "$snapshot_content_sha" && \
   $("$INPUT_SCRIPTS_DIR/nightly-build-identity.sh" fingerprint \
       "$upstream" "$plan" "$snapshot_lock") == "$fingerprint" ]] || \
    die 'nightly final fingerprint cannot be reproduced'
verify_plan_input_contract "$plan" "$plan_revision"

manifest_names=$(mktemp "$destination_root/.release-manifest.XXXXXXXX")
actual_names=$(mktemp "$destination_root/.release-files.XXXXXXXX")
expected_names=
cleanup_files() {
    rm -f -- "$manifest_names" "$actual_names"
    [[ -z "$expected_names" ]] || rm -f -- "$expected_names"
}
trap cleanup_files EXIT
awk '
    NF != 2 || $1 !~ /^[0-9a-f]{64}$/ ||
      $2 !~ /^[A-Za-z0-9][A-Za-z0-9+._-]*$/ || seen[$2]++ { exit 1 }
    { print $2 }
    END { if (NR != 32) exit 1 }
' "$release_root/SHA256SUMS" | sort > "$manifest_names" || \
    die 'nightly Release SHA256SUMS is malformed or has the wrong row count'
find "$release_root" -mindepth 1 -maxdepth 1 -type f ! -name SHA256SUMS \
    -printf '%f\n' | sort > "$actual_names"
special_asset=$(find "$release_root" -mindepth 1 -maxdepth 1 ! -type f \
    -print -quit)
[[ -z "$special_asset" ]] || \
    die "nightly Release contains a non-regular asset: $special_asset"
actual_asset_count=$(wc -l < "$actual_names")
(( actual_asset_count == 32 )) || \
    die "nightly Release has $actual_asset_count payload assets, expected 32"
cmp -s "$manifest_names" "$actual_names" || \
    die 'nightly Release SHA256SUMS does not cover its exact file set'
(
    cd "$release_root"
    sha256sum --strict --quiet -c SHA256SUMS
) || die 'nightly Release asset checksum verification failed'

expected_names=$(mktemp "$destination_root/.release-expected.XXXXXXXX")
printf '%s\n' RELEASE_NOTES.md UPSTREAM_STATE.env NIGHTLY_BUILD.env \
    NIGHTLY_RELEASE.env NIGHTLY_TARGETS.tsv NIGHTLY_FEEDS.tsv \
    NIGHTLY_PACKAGE_SNAPSHOTS.tsv PLAN_INPUTS.sha256 PLAN_INPUT_REVISION.txt \
    NIGHTLY_BUILD_CONTEXT.tar > "$expected_names"
for target in x86_64 rpi4 rpi5; do
    for preset in minimal full; do
        printf 'hmxf-openwrt-nightly-%s-%s-%s-metadata.tar.zst\n' \
            "$fingerprint" "$target" "$preset" >> "$expected_names"
    done
done
printf '%s\n' \
    immortalwrt-SNAPSHOT-minimal-x86-64-generic-squashfs-combined-efi.img.gz \
    immortalwrt-SNAPSHOT-full-x86-64-generic-squashfs-combined-efi.img.gz \
    immortalwrt-SNAPSHOT-minimal-bcm27xx-bcm2711-rpi-4-squashfs-factory.img.gz \
    immortalwrt-SNAPSHOT-minimal-bcm27xx-bcm2711-rpi-4-squashfs-sysupgrade.img.gz \
    immortalwrt-SNAPSHOT-full-bcm27xx-bcm2711-rpi-4-squashfs-factory.img.gz \
    immortalwrt-SNAPSHOT-full-bcm27xx-bcm2711-rpi-4-squashfs-sysupgrade.img.gz \
    immortalwrt-SNAPSHOT-minimal-bcm27xx-bcm2712-rpi-5-squashfs-factory.img.gz \
    immortalwrt-SNAPSHOT-minimal-bcm27xx-bcm2712-rpi-5-squashfs-sysupgrade.img.gz \
    immortalwrt-SNAPSHOT-full-bcm27xx-bcm2712-rpi-5-squashfs-factory.img.gz \
    immortalwrt-SNAPSHOT-full-bcm27xx-bcm2712-rpi-5-squashfs-sysupgrade.img.gz \
    >> "$expected_names"

restore_stage=$(mktemp -d "$destination_root/.nightly-restore.XXXXXXXX")
cleanup_restore() {
    [[ -z "$restore_stage" ]] || rm -rf -- "$restore_stage"
    cleanup_files
}
trap cleanup_restore EXIT
mkdir -p -- "$restore_stage/context-archive" "$restore_stage/final/imagebuilders" \
    "$restore_stage/final/package-snapshot-bundles" \
    "$restore_stage/final/package-snapshots"
package_rows="$restore_stage/package-index-rows"
: > "$package_rows"
source_epoch=$(value "$release_lock" IMMORTALWRT_SOURCE_DATE_EPOCH)
[[ "$source_epoch" =~ ^[0-9]+$ ]] || die 'nightly source epoch is invalid'
PYTHONDONTWRITEBYTECODE=1 python3 \
    "$INPUT_SCRIPTS_DIR/extract-nightly-build-context.py" \
    "$release_root/NIGHTLY_BUILD_CONTEXT.tar" \
    "$restore_stage/context-archive" "$source_epoch"
cmp -s "$restore_stage/context-archive/NIGHTLY_BUILD.env" "$state" || \
    die 'nightly context archive contains the wrong build state'
mv -- "$restore_stage/context-archive/context" "$restore_stage/final/context"
cp -- "$state" "$restore_stage/final/NIGHTLY_BUILD.env"
cp -- "$release_root/NIGHTLY_BUILD_CONTEXT.tar" \
    "$restore_stage/final/NIGHTLY_BUILD_CONTEXT.tar"
for pair in UPSTREAM_STATE.env:UPSTREAM_STATE.env \
    NIGHTLY_BUILD.env:NIGHTLY_BUILD.env locks/release.env:NIGHTLY_RELEASE.env \
    locks/targets.tsv:NIGHTLY_TARGETS.tsv locks/feeds.tsv:NIGHTLY_FEEDS.tsv \
    locks/package-snapshots.tsv:NIGHTLY_PACKAGE_SNAPSHOTS.tsv \
    PLAN_INPUTS.sha256:PLAN_INPUTS.sha256 \
    PLAN_INPUT_REVISION.txt:PLAN_INPUT_REVISION.txt; do
    context_name=${pair%%:*}; release_name=${pair#*:}
    cmp -s "$restore_stage/final/context/$context_name" \
        "$release_root/$release_name" || \
        die "nightly context differs from Release provenance: $release_name"
done
(
    cd "$restore_stage/final/context"
    sha256sum --strict --quiet -c CONTEXT.sha256
) || die 'restored nightly context failed checksum verification'
context_expected="$restore_stage/context-expected"
context_actual="$restore_stage/context-actual"
awk '
    NF != 2 || $1 !~ /^[0-9a-f]{64}$/ ||
      $2 !~ /^[A-Za-z0-9][A-Za-z0-9+._/-]*$/ ||
      $2 ~ /(^|\/)[.][.]?(\/|$)/ || seen[$2]++ { exit 1 }
    { print $2 }
' "$restore_stage/final/context/CONTEXT.sha256" | sort > "$context_expected" || \
    die 'restored nightly context checksum index is unsafe'
printf '%s\n' CONTEXT.sha256 >> "$context_expected"
sort -o "$context_expected" "$context_expected"
find "$restore_stage/final/context" -mindepth 1 -type f -printf '%P\n' | \
    sort > "$context_actual"
[[ -z $(find "$restore_stage/final/context" -mindepth 1 \
    ! -type f ! -type d -print -quit) ]] || \
    die 'restored nightly context contains a link or special node'
cmp -s "$context_expected" "$context_actual" || \
    die 'restored nightly context has files outside its checksum index'

for target in x86_64 rpi4 rpi5; do
    row=$(awk -F'|' -v wanted="$target" '$1 == wanted { print; count++ }
        END { if (count != 1) exit 1 }' "$target_lock") || \
        die "nightly target lock has no unique $target row"
    IFS='|' read -r _ _ _ _ _ image_file image_sha _ image_bytes extra <<< "$row"
    [[ -z "$extra" && "$image_file" =~ ^[A-Za-z0-9._-]+[.]tar[.]zst$ && \
       "$image_sha" =~ ^[0-9a-f]{64}$ && "$image_bytes" =~ ^[1-9][0-9]*$ && \
       $(stat -c '%s' "$release_root/$image_file") == "$image_bytes" && \
       $(sha256sum "$release_root/$image_file" | awk '{ print $1 }') == \
           "$image_sha" ]] || die "nightly ImageBuilder asset mismatch: $target"
    printf '%s\n' "$image_file" >> "$expected_names"
    cp -- "$release_root/$image_file" "$restore_stage/final/imagebuilders/$image_file"

    row=$(awk -F'|' -v wanted="$target" '$1 == wanted { print; count++ }
        END { if (count != 1) exit 1 }' "$snapshot_lock") || \
        die "nightly package lock has no unique $target row"
    IFS='|' read -r _ bundle_file bundle_sha bundle_bytes tree_sha extra <<< "$row"
    [[ -z "$extra" && "$bundle_file" =~ ^[A-Za-z0-9._-]+[.]tar[.]zst$ && \
       "$bundle_sha" =~ ^[0-9a-f]{64}$ && "$bundle_bytes" =~ ^[1-9][0-9]*$ && \
       "$tree_sha" =~ ^[0-9a-f]{64}$ && \
       $(stat -c '%s' "$release_root/$bundle_file") == "$bundle_bytes" && \
       $(sha256sum "$release_root/$bundle_file" | awk '{ print $1 }') == \
           "$bundle_sha" ]] || die "nightly package bundle asset mismatch: $target"
    printf '%s\n' "$bundle_file" >> "$expected_names"
    cp -- "$release_root/$bundle_file" \
        "$restore_stage/final/package-snapshot-bundles/$bundle_file"
    extract_root=$(mktemp -d "$restore_stage/.snapshot-$target.XXXXXXXX")
    PYTHONDONTWRITEBYTECODE=1 python3 \
        "$INPUT_SCRIPTS_DIR/verify-package-snapshot.py" extract \
        "$release_root/$bundle_file" "$extract_root" SNAPSHOT "$target" \
        "$tree_sha" >/dev/null
    repository_count=0
    while IFS= read -r repository_url || [[ -n "$repository_url" ]]; do
        repository_count=$((repository_count + 1))
        [[ "$repository_url" =~ ^https://downloads[.]immortalwrt[.]org/snapshots/[A-Za-z0-9._~/-]+/packages[.]adb$ && \
           "$repository_url" != *'/../'* ]] || \
            die "restored nightly repository URL is unsafe: $target"
        index_sha=$(sha256sum \
            "$extract_root/SNAPSHOT/$target/repo-$repository_count/packages.adb" | \
            awk '{ print $1 }') || \
            die "restored nightly package index is missing: $target"
        printf '%s|%s\n' "$repository_url" "$index_sha" >> "$package_rows"
    done < "$restore_stage/final/context/repositories/$target.list"
    [[ "$repository_count" -gt 0 && \
       $(wc -l < "$extract_root/SNAPSHOT/$target/repositories.list") == \
           "$repository_count" ]] || \
        die "restored nightly repository URL/index count mismatch: $target"
    mkdir -p -- "$restore_stage/final/package-snapshots/SNAPSHOT"
    mv -- "$extract_root/SNAPSHOT/$target" \
        "$restore_stage/final/package-snapshots/SNAPSHOT/$target"
done
sort -u -o "$package_rows" "$package_rows"
package_lock="$restore_stage/final/context/repositories/PACKAGES.sha256.tsv"
package_lock_rows="$restore_stage/package-lock-rows"
[[ -f "$package_lock" && ! -L "$package_lock" && \
   $(sed -n '1p' "$package_lock") == '# url|sha256' ]] || \
    die 'restored package-index aggregate is missing or unsafe'
sed '1d' "$package_lock" > "$package_lock_rows"
cmp -s "$package_rows" "$package_lock_rows" || \
    die 'restored repository URLs differ from the package-index aggregate'
[[ $(sha256sum "$package_rows" | awk '{ print $1 }') == "$packages_sha" ]] || \
    die 'restored package indexes do not reproduce upstream package identity'
sort -o "$expected_names" "$expected_names"
cmp -s "$expected_names" "$actual_names" || \
    die 'nightly Release contains an unexpected or missing named asset'
rm -f -- "$expected_names"
find "$restore_stage/final" -type d -exec chmod 0755 {} +
find "$restore_stage/final" -type f -exec chmod 0644 {} +

final_root="$destination_root/$fingerprint"
upstream_root="$destination_root/$upstream"
if [[ -e "$final_root" || -L "$final_root" ]]; then
    [[ -d "$final_root" && ! -L "$final_root" && \
       $(realpath -e -- "$final_root") == "$final_root" ]] || \
        die "nightly final restore destination is unsafe: $final_root"
    for relative in NIGHTLY_BUILD.env NIGHTLY_BUILD_CONTEXT.tar context \
                    imagebuilders package-snapshot-bundles package-snapshots; do
        diff -qr --no-dereference "$restore_stage/final/$relative" \
            "$final_root/$relative" >/dev/null || \
            die "existing nightly final input conflicts: $relative"
    done
    rm -rf -- "$restore_stage/final"
else
    mv -- "$restore_stage/final" "$final_root"
fi
mkdir -p -- "$upstream_root"
[[ -d "$upstream_root" && ! -L "$upstream_root" ]] || \
    die 'nightly upstream pointer root is unsafe'
require_regular_file_or_absent "$upstream_root/NIGHTLY_BUILD_POINTER.env" \
    'nightly build pointer'
pointer_tmp=$(mktemp "$upstream_root/.NIGHTLY_BUILD_POINTER.env.XXXXXXXX")
cp -- "$final_root/NIGHTLY_BUILD.env" "$pointer_tmp"
chmod 0644 "$pointer_tmp"
mv -- "$pointer_tmp" "$upstream_root/NIGHTLY_BUILD_POINTER.env"
cmp -s "$upstream_root/NIGHTLY_BUILD_POINTER.env" \
    "$final_root/NIGHTLY_BUILD.env" || die 'nightly pointer publication failed'
rm -rf -- "$restore_stage"
restore_stage=
trap cleanup_files EXIT
cleanup_files
trap - EXIT
flock -u "$restore_lock_fd"
printf 'Restored nightly inputs %s below %s\n' "$fingerprint" "$destination_root"
