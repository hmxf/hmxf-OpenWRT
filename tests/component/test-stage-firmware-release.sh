#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../scripts/lib/common.sh
source "$PROJECT_ROOT/scripts/lib/common.sh"
stager="$PROJECT_ROOT/scripts/inputs/stage-firmware-release.sh"
nightly_restorer="$PROJECT_ROOT/scripts/inputs/restore-nightly-inputs.sh"
tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

stable_version=25.12.1
snapshot_version=r12345-deadbee
snapshot_commit=deadbee000000000000000000000000000000000
nightly_fingerprint=
upstream_fingerprint=
nightly_plan_sha=
nightly_snapshot_content_sha=
nightly_snapshot_lock_sha=
nightly_context_sha=
imagebuilder_sha_x86=1111111111111111111111111111111111111111111111111111111111111111
imagebuilder_sha_rpi4=2222222222222222222222222222222222222222222222222222222222222222
imagebuilder_sha_rpi5=3333333333333333333333333333333333333333333333333333333333333333
imagebuilder_bytes_x86=
imagebuilder_bytes_rpi4=
imagebuilder_bytes_rpi5=

rewrite_checksums() {
    local directory=${1:?artifact directory required}
    (
        cd "$directory"
        find . -mindepth 1 -maxdepth 1 -type f ! -name 'SHA256SUMS*' \
            -printf '%P\0' | sort -z | xargs -0 -r sha256sum -- \
            > SHA256SUMS.tmp
        mv -- SHA256SUMS.tmp SHA256SUMS
    )
}

expect_failure() {
    local label=${1:?failure label required}
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'error: %s unexpectedly succeeded\n' "$label" >&2
        exit 1
    fi
}

write_combination() {
    local root=$1
    local channel=$2
    local identity=$3
    local target=$4
    local preset=$5
    local directory="$root/$target/$preset"
    local release_token target_tuple profile image_stem imagebuilder_file
    local imagebuilder_sha

    mkdir -p "$directory"
    if [[ "$channel" == stable ]]; then
        release_token=$identity
    else
        release_token=SNAPSHOT
    fi
    case "$target" in
        x86_64)
            target_tuple=x86/64
            profile=generic
            imagebuilder_file=immortalwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst
            imagebuilder_sha=$imagebuilder_sha_x86
            image_stem="immortalwrt-$release_token-$preset-x86-64-generic-squashfs"
            printf '%s\n' "$target-$preset-combined" \
                > "$directory/$image_stem-combined-efi.img.gz"
            ;;
        rpi4)
            target_tuple=bcm27xx/bcm2711
            profile=rpi-4
            imagebuilder_file=immortalwrt-imagebuilder-bcm27xx-bcm2711.Linux-x86_64.tar.zst
            imagebuilder_sha=$imagebuilder_sha_rpi4
            image_stem="immortalwrt-$release_token-$preset-bcm27xx-bcm2711-rpi-4-squashfs"
            ;;
        rpi5)
            target_tuple=bcm27xx/bcm2712
            profile=rpi-5
            imagebuilder_file=immortalwrt-imagebuilder-bcm27xx-bcm2712.Linux-x86_64.tar.zst
            imagebuilder_sha=$imagebuilder_sha_rpi5
            image_stem="immortalwrt-$release_token-$preset-bcm27xx-bcm2712-rpi-5-squashfs"
            ;;
        *) printf 'error: bad fixture target %s\n' "$target" >&2; exit 1 ;;
    esac
    if [[ "$target" != x86_64 ]]; then
        for kind in factory sysupgrade; do
            printf '%s\n' "$target-$preset-$kind" \
                > "$directory/$image_stem-$kind.img.gz"
        done
    fi
    {
        printf 'build_mode=imagebuilder\n'
        printf 'release_channel=%s\n' "$channel"
        if [[ "$channel" == stable ]]; then
            printf 'canonical_build=1\n'
            printf 'candidate_build=0\n'
            printf 'development_build=0\n'
            printf 'release=%s\n' "$identity"
        else
            printf 'canonical_build=0\n'
            printf 'candidate_build=1\n'
            printf 'development_build=0\n'
            printf 'release=SNAPSHOT\n'
            printf 'nightly_fingerprint=%s\n' "$identity"
            printf 'nightly_context_sha256=%s\n' "$nightly_context_sha"
            printf 'nightly_package_snapshots_sha256=%s\n' \
                "$nightly_snapshot_content_sha"
            printf 'nightly_package_snapshot_lock_sha256=%s\n' \
                "$nightly_snapshot_lock_sha"
            printf 'source_commit=%s\n' "$snapshot_commit"
            printf 'version_code=%s\n' "$snapshot_version"
            printf 'imagebuilder_file=%s\n' "$imagebuilder_file"
            printf 'imagebuilder_sha256=%s\n' "$imagebuilder_sha"
            printf 'artifact_lock_policy=enforce\n'
            printf 'package_repository_mode=snapshot\n'
            printf 'package_cache_index=0\n'
            snapshot_row=$(awk -F'|' -v wanted="$target" \
                '$1 == wanted { print; exit }' \
                "$root/../NIGHTLY_PACKAGE_SNAPSHOTS.tsv")
            IFS='|' read -r _ snapshot_file snapshot_sha snapshot_bytes \
                snapshot_tree_sha <<< "$snapshot_row"
            printf 'package_snapshot_file=%s\n' "$snapshot_file"
            printf 'package_snapshot_sha256=%s\n' "$snapshot_sha"
            printf 'package_snapshot_bytes=%s\n' "$snapshot_bytes"
            printf 'package_snapshot_tree_sha256=%s\n' "$snapshot_tree_sha"
        fi
        printf 'target=%s\n' "$target_tuple"
        printf 'profile=%s\n' "$profile"
        printf 'preset=%s\n' "$preset"
        printf 'source_date_epoch=1700000000\n'
    } > "$directory/BUILD_INFO.txt"
    printf '%s - 1\n' base-files \
        > "$directory/immortalwrt-$release_token-$target-$preset.manifest"
    printf '{}\n' > "$directory/profiles.json"
    rewrite_checksums "$directory"
}

write_nightly_provenance() {
    local parent=${1:?nightly parent required}
    local feeds_buildinfo="$parent/feeds.buildinfo"
    local target_fingerprint_rows="$parent/target-fingerprint-rows"
    local feeds_sha targets_sha packages_sha target image_file image_path snapshot tree_sha
    local bundle bundle_sha bundle_bytes durable="$parent/.durable"
    local snapshot_rows="$parent/snapshot-rows"
    local package_rows="$parent/package-rows"

    mkdir -p "$parent" "$durable/imagebuilders" \
        "$durable/package-snapshot-bundles" "$durable/package-snapshots/SNAPSHOT"
    : > "$snapshot_rows"
    : > "$package_rows"
    for target in x86_64 rpi4 rpi5; do
        case "$target" in
            x86_64) image_file=immortalwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst ;;
            rpi4) image_file=immortalwrt-imagebuilder-bcm27xx-bcm2711.Linux-x86_64.tar.zst ;;
            rpi5) image_file=immortalwrt-imagebuilder-bcm27xx-bcm2712.Linux-x86_64.tar.zst ;;
        esac
        image_path="$durable/imagebuilders/$image_file"
        printf 'fixture ImageBuilder %s\n' "$target" > "$image_path"
        case "$target" in
            x86_64)
                imagebuilder_sha_x86=$(sha256sum "$image_path" | awk '{ print $1 }')
                imagebuilder_bytes_x86=$(stat -c '%s' "$image_path") ;;
            rpi4)
                imagebuilder_sha_rpi4=$(sha256sum "$image_path" | awk '{ print $1 }')
                imagebuilder_bytes_rpi4=$(stat -c '%s' "$image_path") ;;
            rpi5)
                imagebuilder_sha_rpi5=$(sha256sum "$image_path" | awk '{ print $1 }')
                imagebuilder_bytes_rpi5=$(stat -c '%s' "$image_path") ;;
        esac
        snapshot="$durable/package-snapshots/SNAPSHOT/$target"
        mkdir -p "$snapshot/repo-1"
        printf 'repo-1\n' > "$snapshot/repositories.list"
        printf 'signed index %s\n' "$target" > "$snapshot/repo-1/packages.adb"
        printf 'https://downloads.immortalwrt.org/snapshots/%s/base/packages.adb|%s\n' "$target" \
            "$(sha256sum "$snapshot/repo-1/packages.adb" | awk '{ print $1 }')" \
            >> "$package_rows"
        printf 'fixture apk %s\n' "$target" > "$snapshot/repo-1/alpha-1.apk"
        (
            cd "$snapshot"
            find . -type f ! -name SHA256SUMS -printf '%P\0' | sort -z | \
                xargs -0 sha256sum -- > "$parent/$target.SHA256SUMS"
            mv -- "$parent/$target.SHA256SUMS" SHA256SUMS
        )
        tree_sha=$(sha256sum "$snapshot/SHA256SUMS" | awk '{ print $1 }')
        bundle="immortalwrt-SNAPSHOT-$target-package-snapshot.tar.zst"
        tar --sort=name --format=gnu --mtime='@1700000000' --owner=0 \
            --group=0 --numeric-owner -cf "$parent/$target.tar" \
            -C "$durable/package-snapshots" "SNAPSHOT/$target"
        zstd --quiet --force -T1 "$parent/$target.tar" \
            -o "$durable/package-snapshot-bundles/$bundle"
        rm -f -- "$parent/$target.tar"
        bundle_sha=$(sha256sum "$durable/package-snapshot-bundles/$bundle" | \
            awk '{ print $1 }')
        bundle_bytes=$(stat -c '%s' "$durable/package-snapshot-bundles/$bundle")
        printf '%s|%s|%s|%s|%s\n' "$target" "$bundle" "$bundle_sha" \
            "$bundle_bytes" "$tree_sha" >> "$snapshot_rows"
    done
    {
        printf 'src-git packages https://github.com/immortalwrt/packages.git^aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
        printf 'src-git luci https://github.com/immortalwrt/luci.git^bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
    } > "$feeds_buildinfo"
    feeds_sha=$(sha256sum "$feeds_buildinfo" | awk '{ print $1 }')
    {
        printf 'packages|src-git|https://github.com/immortalwrt/packages.git|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
        printf 'luci|src-git|https://github.com/immortalwrt/luci.git|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
    } > "$parent/NIGHTLY_FEEDS.tsv"
    {
        printf 'x86_64|immortalwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst|%s\n' \
            "$imagebuilder_sha_x86"
        printf 'rpi4|immortalwrt-imagebuilder-bcm27xx-bcm2711.Linux-x86_64.tar.zst|%s\n' \
            "$imagebuilder_sha_rpi4"
        printf 'rpi5|immortalwrt-imagebuilder-bcm27xx-bcm2712.Linux-x86_64.tar.zst|%s\n' \
            "$imagebuilder_sha_rpi5"
    } > "$target_fingerprint_rows"
    targets_sha=$(sha256sum "$target_fingerprint_rows" | awk '{ print $1 }')
    sort -u -o "$package_rows" "$package_rows"
    packages_sha=$(sha256sum "$package_rows" | awk '{ print $1 }')
    upstream_fingerprint=$(printf '%s\n%s\n%s\n%s\n%s\n' \
        "$snapshot_version" "$snapshot_commit" "$feeds_sha" \
        "$targets_sha" "$packages_sha" | sha256sum | awk '{ print $1 }')

    {
        printf 'STATE_SCHEMA=1\n'
        printf 'CHANNEL=nightly\n'
        printf 'REASON=fixture-update\n'
        printf 'LOCKED_STABLE_VERSION=%s\n' "$stable_version"
        printf 'LATEST_STABLE_VERSION=%s\n' "$stable_version"
        printf 'SNAPSHOT_VERSION_CODE=%s\n' "$snapshot_version"
        printf 'SNAPSHOT_SOURCE_COMMIT=%s\n' "$snapshot_commit"
        printf 'SNAPSHOT_FEEDS_SHA256=%s\n' "$feeds_sha"
        printf 'SNAPSHOT_TARGETS_SHA256=%s\n' "$targets_sha"
        printf 'SNAPSHOT_PACKAGES_SHA256=%s\n' "$packages_sha"
        printf 'SNAPSHOT_FINGERPRINT=%s\n' "$upstream_fingerprint"
        printf 'NIGHTLY_IMAGEBUILDER_X86_64_FILE=immortalwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst\n'
        printf 'NIGHTLY_IMAGEBUILDER_X86_64_SHA256=%s\n' "$imagebuilder_sha_x86"
        printf 'NIGHTLY_IMAGEBUILDER_RPI4_FILE=immortalwrt-imagebuilder-bcm27xx-bcm2711.Linux-x86_64.tar.zst\n'
        printf 'NIGHTLY_IMAGEBUILDER_RPI4_SHA256=%s\n' "$imagebuilder_sha_rpi4"
        printf 'NIGHTLY_IMAGEBUILDER_RPI5_FILE=immortalwrt-imagebuilder-bcm27xx-bcm2712.Linux-x86_64.tar.zst\n'
        printf 'NIGHTLY_IMAGEBUILDER_RPI5_SHA256=%s\n' "$imagebuilder_sha_rpi5"
    } > "$parent/UPSTREAM_STATE.env"
    {
        printf 'IMMORTALWRT_VERSION=SNAPSHOT\n'
        printf 'IMMORTALWRT_TAG=SNAPSHOT\n'
        printf 'IMMORTALWRT_TAG_OBJECT=%s\n' "$snapshot_commit"
        printf 'IMMORTALWRT_COMMIT=%s\n' "$snapshot_commit"
        printf 'IMMORTALWRT_SOURCE_URL=https://github.com/immortalwrt/immortalwrt.git\n'
        printf 'IMMORTALWRT_DOWNLOAD_URL=https://downloads.immortalwrt.org\n'
        printf 'LOCKED_INPUT_RELEASE_TAG=nightly-placeholder\n'
        printf 'IMMORTALWRT_VERSION_CODE=%s\n' "$snapshot_version"
        printf 'IMMORTALWRT_SOURCE_DATE_EPOCH=1700000000\n'
        printf 'IMMORTALWRT_KERNEL_VERSION=6.12.94\n'
        printf 'IMMORTALWRT_KERNEL_RELEASE=1\n'
        printf 'ROOTFS_PARTSIZE=3072\n'
        printf 'NOMINAL_MEDIA_BYTES=4000000000\n'
    } > "$parent/NIGHTLY_RELEASE.env"
    {
        printf '%s\n' '# name|target|subtarget|profile|package_arch|imagebuilder_filename|sha256|kernel_vermagic|bytes'
        printf 'x86_64|x86|64|generic|x86_64|immortalwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst|%s|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|%s\n' \
            "$imagebuilder_sha_x86" "$imagebuilder_bytes_x86"
        printf 'rpi4|bcm27xx|bcm2711|rpi-4|aarch64_cortex-a72|immortalwrt-imagebuilder-bcm27xx-bcm2711.Linux-x86_64.tar.zst|%s|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|%s\n' \
            "$imagebuilder_sha_rpi4" "$imagebuilder_bytes_rpi4"
        printf 'rpi5|bcm27xx|bcm2712|rpi-5|aarch64_cortex-a76|immortalwrt-imagebuilder-bcm27xx-bcm2712.Linux-x86_64.tar.zst|%s|cccccccccccccccccccccccccccccccc|%s\n' \
            "$imagebuilder_sha_rpi5" "$imagebuilder_bytes_rpi5"
    } > "$parent/NIGHTLY_TARGETS.tsv"
    {
        printf '%s\n' '# target|filename|sha256|bytes|tree_sha256sums_sha256'
        cat "$snapshot_rows"
    } > "$parent/NIGHTLY_PACKAGE_SNAPSHOTS.tsv"
    write_plan_input_contract "$parent/PLAN_INPUTS.sha256" \
        "$parent/PLAN_INPUT_REVISION.txt"
    nightly_plan_sha=$(sha256sum "$parent/PLAN_INPUTS.sha256" | awk '{ print $1 }')
    nightly_snapshot_lock_sha=$(sha256sum \
        "$parent/NIGHTLY_PACKAGE_SNAPSHOTS.tsv" | awk '{ print $1 }')
    nightly_snapshot_content_sha=$(
        "$INPUT_SCRIPTS_DIR/nightly-build-identity.sh" content \
            "$parent/NIGHTLY_PACKAGE_SNAPSHOTS.tsv"
    )
    nightly_fingerprint=$(
        "$INPUT_SCRIPTS_DIR/nightly-build-identity.sh" fingerprint \
            "$upstream_fingerprint" "$parent/PLAN_INPUTS.sha256" \
            "$parent/NIGHTLY_PACKAGE_SNAPSHOTS.tsv"
    )
    {
        printf 'NIGHTLY_BUILD_SCHEMA=1\n'
        printf 'UPSTREAM_FINGERPRINT=%s\n' "$upstream_fingerprint"
        printf 'PLAN_INPUTS_SHA256=%s\n' "$nightly_plan_sha"
        printf 'PACKAGE_SNAPSHOTS_SHA256=%s\n' \
            "$nightly_snapshot_content_sha"
        printf 'PACKAGE_SNAPSHOT_LOCK_SHA256=%s\n' \
            "$nightly_snapshot_lock_sha"
        printf 'NIGHTLY_FINGERPRINT=%s\n' "$nightly_fingerprint"
    } > "$parent/NIGHTLY_BUILD.env"
    sed -i "s/^LOCKED_INPUT_RELEASE_TAG=.*/LOCKED_INPUT_RELEASE_TAG=nightly-$nightly_fingerprint/" \
        "$parent/NIGHTLY_RELEASE.env"
    mkdir -p "$durable/context/locks/manifests" "$durable/context/repositories"
    cp -- "$parent/NIGHTLY_BUILD.env" "$durable/NIGHTLY_BUILD.env"
    cp -- "$parent/NIGHTLY_BUILD.env" "$durable/context/NIGHTLY_BUILD.env"
    cp -- "$parent/UPSTREAM_STATE.env" "$durable/context/UPSTREAM_STATE.env"
    cp -- "$parent/PLAN_INPUTS.sha256" "$parent/PLAN_INPUT_REVISION.txt" \
        "$durable/context/"
    cp -- "$parent/NIGHTLY_RELEASE.env" "$durable/context/locks/release.env"
    cp -- "$parent/NIGHTLY_TARGETS.tsv" "$durable/context/locks/targets.tsv"
    cp -- "$parent/NIGHTLY_FEEDS.tsv" "$durable/context/locks/feeds.tsv"
    cp -- "$parent/NIGHTLY_PACKAGE_SNAPSHOTS.tsv" \
        "$durable/context/locks/package-snapshots.tsv"
    printf '# fixture\n' > "$durable/context/locks/artifacts.tsv"
    printf '# fixture\n' > "$durable/context/locks/package-manifests.tsv"
    for target in x86_64 rpi4 rpi5; do
        printf 'https://downloads.immortalwrt.org/snapshots/%s/base/packages.adb\n' "$target" \
            > "$durable/context/repositories/$target.list"
        for preset in minimal full; do
            printf 'base-files - 1\n' \
                > "$durable/context/locks/manifests/$target-$preset.manifest"
        done
    done
    {
        printf '%s\n' '# url|sha256'
        cat "$package_rows"
    } > "$durable/context/repositories/PACKAGES.sha256.tsv"
    (
        cd "$durable/context"
        find . -type f ! -name CONTEXT.sha256 -printf '%P\0' | sort -z | \
            xargs -0 sha256sum -- > "$parent/CONTEXT.sha256"
        mv -- "$parent/CONTEXT.sha256" CONTEXT.sha256
    )
    cp -- "$durable/context/CONTEXT.sha256" "$parent/NIGHTLY_CONTEXT.sha256"
    nightly_context_sha=$(sha256sum "$parent/NIGHTLY_CONTEXT.sha256" \
        | awk '{ print $1 }')
    tar --sort=name --format=gnu --mtime='@1700000000' --owner=0 --group=0 \
        --numeric-owner --mode='u+rwX,go+rX,go-w' \
        -cf "$durable/NIGHTLY_BUILD_CONTEXT.tar" -C "$durable" \
        NIGHTLY_BUILD.env context
    rm -f -- "$feeds_buildinfo" "$target_fingerprint_rows" "$snapshot_rows" \
        "$package_rows"
}

stable_input="$tmp_dir/stable-input"
for target in x86_64 rpi4 rpi5; do
    for preset in minimal full; do
        write_combination "$stable_input" stable "$stable_version" "$target" "$preset"
    done
done

stable_destination="$tmp_dir/stable-release"
"$stager" stable "$stable_input" "$stable_destination" "$stable_version"
[[ $(find "$stable_destination" -maxdepth 1 -type f -name '*.img.gz' | wc -l) -eq 10 ]]
[[ $(find "$stable_destination" -maxdepth 1 -type f -name '*-metadata.tar.zst' | wc -l) -eq 6 ]]
[[ -z $(find "$stable_destination" -maxdepth 1 -type f ! -perm 0644 -print -quit) ]]
(
    cd "$stable_destination"
    sha256sum --strict --quiet -c SHA256SUMS
)
"$stager" stable "$stable_input" "$stable_destination" "$stable_version"

conflicting_input="$tmp_dir/conflicting-stable-input"
cp -a -- "$stable_input" "$conflicting_input"
changed_image=$(find "$conflicting_input" -type f -name '*.img.gz' -print -quit)
printf 'changed\n' >> "$changed_image"
rewrite_checksums "$(dirname -- "$changed_image")"
expect_failure 'conflicting stable release staging' \
    "$stager" stable "$conflicting_input" "$stable_destination" "$stable_version"

wrong_target_input="$tmp_dir/wrong-target-input"
cp -a -- "$stable_input" "$wrong_target_input"
sed -i 's|^target=bcm27xx/bcm2711$|target=bcm27xx/bcm2712|' \
    "$wrong_target_input/rpi4/minimal/BUILD_INFO.txt"
rewrite_checksums "$wrong_target_input/rpi4/minimal"
expect_failure 'wrong target identity' "$stager" stable "$wrong_target_input" \
    "$tmp_dir/wrong-target-release" "$stable_version"

wrong_filename_input="$tmp_dir/wrong-filename-input"
cp -a -- "$stable_input" "$wrong_filename_input"
wrong_image=$(find "$wrong_filename_input/rpi4/minimal" -maxdepth 1 \
    -type f -name '*-sysupgrade.img.gz' -print -quit)
mv -- "$wrong_image" "${wrong_image%-sysupgrade.img.gz}-recovery.img.gz"
rewrite_checksums "$wrong_filename_input/rpi4/minimal"
expect_failure 'missing Pi sysupgrade filename' "$stager" stable \
    "$wrong_filename_input" "$tmp_dir/wrong-filename-release" "$stable_version"

development_input="$tmp_dir/development-identity-input"
cp -a -- "$stable_input" "$development_input"
sed -i 's/^development_build=0$/development_build=1/' \
    "$development_input/x86_64/full/BUILD_INFO.txt"
rewrite_checksums "$development_input/x86_64/full"
expect_failure 'contradictory development identity' "$stager" stable \
    "$development_input" "$tmp_dir/development-release" "$stable_version"

unsafe_sha_input="$tmp_dir/unsafe-sha-input"
cp -a -- "$stable_input" "$unsafe_sha_input"
printf 'outside\n' > "$unsafe_sha_input/x86_64/outside"
outside_sha=$(sha256sum "$unsafe_sha_input/x86_64/outside" | awk '{ print $1 }')
printf '%s  ../outside\n' "$outside_sha" \
    >> "$unsafe_sha_input/x86_64/minimal/SHA256SUMS"
expect_failure 'SHA256SUMS path traversal' "$stager" stable "$unsafe_sha_input" \
    "$tmp_dir/unsafe-sha-release" "$stable_version"

incomplete_sha_input="$tmp_dir/incomplete-sha-input"
cp -a -- "$stable_input" "$incomplete_sha_input"
sed -i '/  profiles[.]json$/d' \
    "$incomplete_sha_input/x86_64/minimal/SHA256SUMS"
expect_failure 'incomplete SHA256SUMS coverage' "$stager" stable \
    "$incomplete_sha_input" "$tmp_dir/incomplete-sha-release" "$stable_version"

unsafe_metadata_input="$tmp_dir/unsafe-metadata-input"
cp -a -- "$stable_input" "$unsafe_metadata_input"
printf 'tar option\n' > "$unsafe_metadata_input/x86_64/minimal/-C"
rewrite_checksums "$unsafe_metadata_input/x86_64/minimal"
expect_failure 'option-like metadata filename' "$stager" stable \
    "$unsafe_metadata_input" "$tmp_dir/unsafe-metadata-release" "$stable_version"

ln -s -- "$stable_input" "$tmp_dir/symlink-input"
expect_failure 'symbolic-link input root' "$stager" stable "$tmp_dir/symlink-input" \
    "$tmp_dir/symlink-input-release" "$stable_version"

intermediate_symlink_input="$tmp_dir/intermediate-symlink-input"
mkdir "$intermediate_symlink_input"
ln -s -- "$stable_input/x86_64" "$intermediate_symlink_input/x86_64"
cp -a -- "$stable_input/rpi4" "$stable_input/rpi5" "$intermediate_symlink_input/"
expect_failure 'symbolic-link target ancestor' "$stager" stable \
    "$intermediate_symlink_input" "$tmp_dir/intermediate-symlink-release" \
    "$stable_version"

mkdir "$tmp_dir/real-destination"
ln -s -- "$tmp_dir/real-destination" "$tmp_dir/symlink-destination"
expect_failure 'symbolic-link destination' "$stager" stable "$stable_input" \
    "$tmp_dir/symlink-destination" "$stable_version"

nightly_preparation="$tmp_dir/nightly-input"
write_nightly_provenance "$nightly_preparation"
nightly_final_root="$tmp_dir/$nightly_fingerprint"
nightly_parent="$nightly_final_root/out"
mkdir -p -- "$nightly_parent"
find "$nightly_preparation" -mindepth 1 -maxdepth 1 -type f \
    -exec mv -- {} "$nightly_parent/" \;
mv -- "$nightly_preparation/.durable"/* "$nightly_final_root/"
rm -rf -- "$nightly_preparation"
nightly_root="$nightly_parent/SNAPSHOT"
for target in x86_64 rpi4 rpi5; do
    for preset in minimal full; do
        write_combination "$nightly_root" nightly "$nightly_fingerprint" \
            "$target" "$preset"
    done
done
nightly_destination="$tmp_dir/nightly-release"
"$stager" nightly "$nightly_root" "$nightly_destination" "$nightly_fingerprint"
"$stager" nightly "$nightly_root" "$nightly_destination" "$nightly_fingerprint"
[[ $(find "$nightly_destination" -maxdepth 1 -type f -name '*.img.gz' | wc -l) -eq 10 ]]
[[ $(find "$nightly_destination" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 33 ]]
grep -Fq "$nightly_fingerprint" "$nightly_destination/RELEASE_NOTES.md"
for provenance in UPSTREAM_STATE.env NIGHTLY_BUILD.env NIGHTLY_RELEASE.env \
                  NIGHTLY_TARGETS.tsv NIGHTLY_FEEDS.tsv \
                  NIGHTLY_PACKAGE_SNAPSHOTS.tsv PLAN_INPUTS.sha256 \
                  PLAN_INPUT_REVISION.txt; do
    cmp -s "$nightly_parent/$provenance" \
        "$nightly_destination/$provenance"
done
[[ ! -e "$nightly_destination/NIGHTLY_CONTEXT.sha256" ]]
[[ -f "$nightly_destination/NIGHTLY_BUILD_CONTEXT.tar" ]]
for durable in \
    immortalwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst \
    immortalwrt-imagebuilder-bcm27xx-bcm2711.Linux-x86_64.tar.zst \
    immortalwrt-imagebuilder-bcm27xx-bcm2712.Linux-x86_64.tar.zst \
    immortalwrt-SNAPSHOT-x86_64-package-snapshot.tar.zst \
    immortalwrt-SNAPSHOT-rpi4-package-snapshot.tar.zst \
    immortalwrt-SNAPSHOT-rpi5-package-snapshot.tar.zst; do
    [[ -f "$nightly_destination/$durable" ]]
done
[[ $(wc -l < "$nightly_destination/SHA256SUMS") -eq 32 ]]
[[ $(find "$nightly_destination" -maxdepth 1 -type f \
    -name "hmxf-openwrt-nightly-$nightly_fingerprint-*-metadata.tar.zst" \
    | wc -l) -eq 6 ]]
(
    cd "$nightly_destination"
    sha256sum --strict --quiet -c SHA256SUMS
)

nightly_restore_root="$tmp_dir/restored-nightly"
"$nightly_restorer" "$nightly_destination" "$nightly_restore_root"
restored_final="$nightly_restore_root/$nightly_fingerprint"
restored_pointer="$nightly_restore_root/$upstream_fingerprint/NIGHTLY_BUILD_POINTER.env"
cmp -s "$restored_final/NIGHTLY_BUILD.env" "$restored_pointer"
diff -qr --no-dereference "$nightly_final_root/context" \
    "$restored_final/context" >/dev/null
for target in x86_64 rpi4 rpi5; do
    [[ -d "$restored_final/package-snapshots/SNAPSHOT/$target" ]]
done
# Repeated restore is idempotent, and a missing pointer is repaired atomically.
"$nightly_restorer" "$nightly_destination" "$nightly_restore_root"
rm -f -- "$restored_pointer"
"$nightly_restorer" "$nightly_destination" "$nightly_restore_root"
cmp -s "$restored_final/NIGHTLY_BUILD.env" "$restored_pointer"

printf 'conflict\n' >> "$restored_final/NIGHTLY_BUILD.env"
expect_failure 'conflicting existing nightly restore' "$nightly_restorer" \
    "$nightly_destination" "$nightly_restore_root"
[[ -z $(find "$nightly_restore_root" -mindepth 1 -maxdepth 1 \
    \( -name '.nightly-restore.*' -o -name '.release-*' \) -print -quit) ]]

extra_asset_release="$tmp_dir/extra-asset-release"
cp -a -- "$nightly_destination" "$extra_asset_release"
printf 'unexpected\n' > "$extra_asset_release/unexpected.txt"
expect_failure 'extra nightly durable asset' "$nightly_restorer" \
    "$extra_asset_release" "$tmp_dir/extra-asset-restore"

tampered_package_release="$tmp_dir/tampered-package-release"
cp -a -- "$nightly_destination" "$tampered_package_release"
printf 'tampered package bundle\n' >> \
    "$tampered_package_release/immortalwrt-SNAPSHOT-rpi4-package-snapshot.tar.zst"
rewrite_checksums "$tampered_package_release"
expect_failure 'tampered nightly package bundle' "$nightly_restorer" \
    "$tampered_package_release" "$tmp_dir/tampered-package-restore"

traversal_release="$tmp_dir/traversal-release"
cp -a -- "$nightly_destination" "$traversal_release"
printf 'malicious\n' > "$tmp_dir/traversal-payload"
tar --format=gnu --mtime='@1700000000' --owner=0 --group=0 --numeric-owner \
    --mode='u+rwX,go+rX,go-w' --transform='s|^|../|' \
    -cf "$traversal_release/NIGHTLY_BUILD_CONTEXT.tar" \
    -C "$tmp_dir" traversal-payload
rewrite_checksums "$traversal_release"
expect_failure 'nightly context archive traversal' "$nightly_restorer" \
    "$traversal_release" "$tmp_dir/traversal-restore"

ln -s -- "$nightly_destination" "$tmp_dir/nightly-release-link"
expect_failure 'symbolic-link nightly Release root' "$nightly_restorer" \
    "$tmp_dir/nightly-release-link" "$tmp_dir/link-restore"

wrong_provenance="$tmp_dir/wrong-provenance"
cp -a -- "$nightly_parent" "$wrong_provenance"
sed -i 's/^SNAPSHOT_FINGERPRINT=.*/SNAPSHOT_FINGERPRINT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' \
    "$wrong_provenance/UPSTREAM_STATE.env"
expect_failure 'nightly provenance fingerprint mismatch' "$stager" nightly \
    "$wrong_provenance/SNAPSHOT" "$tmp_dir/wrong-provenance-release" \
    "$nightly_fingerprint"

wrong_feed_provenance="$tmp_dir/wrong-feed-provenance"
cp -a -- "$nightly_parent" "$wrong_feed_provenance"
sed -i 's/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa$/cccccccccccccccccccccccccccccccccccccccc/' \
    "$wrong_feed_provenance/NIGHTLY_FEEDS.tsv"
expect_failure 'nightly feed provenance mismatch' "$stager" nightly \
    "$wrong_feed_provenance/SNAPSHOT" "$tmp_dir/wrong-feed-release" \
    "$nightly_fingerprint"

wrong_snapshot_provenance="$tmp_dir/wrong-snapshot-provenance"
cp -a -- "$nightly_parent" "$wrong_snapshot_provenance"
sed -i '2s/[0-9a-f]\{64\}$/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
    "$wrong_snapshot_provenance/NIGHTLY_PACKAGE_SNAPSHOTS.tsv"
expect_failure 'nightly package snapshot provenance mismatch' "$stager" nightly \
    "$wrong_snapshot_provenance/SNAPSHOT" \
    "$tmp_dir/wrong-snapshot-release" "$nightly_fingerprint"

printf '%s\n' 'Firmware release staging tests passed.'
