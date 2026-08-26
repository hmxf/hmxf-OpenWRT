#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
    cat <<'EOF'
Usage: capture-nightly-package-snapshots.sh UPSTREAM_FINGERPRINT \
       CONTEXT_DIR CAPTURE_OUTPUT_ROOT PACKAGE_CACHE_ROOT DOWNLOAD_DIR

Freeze the APKs resolved by all six nightly warm-up builds, bind the package
snapshot and current project plan into a final nightly fingerprint, and create
the immutable final context below build/nightly/<final-fingerprint>/.
EOF
}

[[ $# -eq 5 ]] || { usage >&2; exit 2; }
upstream_fingerprint=$1
context_input=$2
capture_output_input=$3
package_cache_input=$4
download_input=$5
[[ "$upstream_fingerprint" =~ ^[0-9a-f]{64}$ ]] || \
    die 'upstream nightly fingerprint must be a complete SHA-256'

BUILD_CONFIG=${BUILD_CONFIG:-configs/build-nightly.env}
load_build_config
configure_network_environment
sanitize_build_path
[[ "$BUILD_CONFIG_FILE" == "$PROJECT_ROOT/configs/build-nightly.env" ]] || \
    die 'nightly package capture requires configs/build-nightly.env'
for tool in awk basename chmod cmp cp curl diff find flock grep mkdir mktemp mv \
            python3 realpath rm sed sha256sum sort stat tar wc xargs zstd; do
    require_command "$tool"
done

upstream_root="$PROJECT_ROOT/build/nightly/$upstream_fingerprint"
[[ -d "$upstream_root" && ! -L "$upstream_root" ]] || \
    die "nightly upstream work root is unsafe: $upstream_root"
context_dir=$(realpath -e -- "$context_input")
capture_output=$(realpath -e -- "$capture_output_input")
package_cache_root=$(realpath -e -- "$package_cache_input")
download_dir=$(realpath -e -- "$download_input")
[[ "$context_dir" == "$upstream_root/context" && ! -L "$context_dir" ]] || \
    die 'nightly capture context does not match the upstream fingerprint'
[[ "$capture_output" == "$upstream_root/capture-out/SNAPSHOT" && \
   ! -L "$capture_output" ]] || \
    die 'nightly warm-up output is outside its upstream fingerprint root'
for directory in "$package_cache_root" "$download_dir"; do
    [[ -d "$directory" && ! -L "$directory" ]] || \
        die "nightly capture input is not a real directory: $directory"
done
(
    cd "$context_dir"
    sha256sum --strict --quiet -c CONTEXT.sha256
) || die 'nightly capture context failed checksum verification'

state_fingerprint=$(awk -F= '
    $1 == "SNAPSHOT_FINGERPRINT" { count += 1; value = $2 }
    END { if (count == 1) print value; else exit 1 }
' "$context_dir/UPSTREAM_STATE.env") || die 'nightly context has no unique upstream fingerprint'
[[ "$state_fingerprint" == "$upstream_fingerprint" ]] || \
    die 'nightly context state/upstream fingerprint mismatch'
source_epoch=$(awk -F= '
    $1 == "IMMORTALWRT_SOURCE_DATE_EPOCH" { count += 1; value = $2 }
    END { if (count == 1) print value; else exit 1 }
' "$context_dir/locks/release.env") || die 'nightly context has no unique source epoch'
[[ "$source_epoch" =~ ^[0-9]+$ ]] || die 'nightly source epoch is invalid'

capture_lock="$upstream_root/.package-capture.lock"
require_regular_file_or_absent "$capture_lock" 'nightly package capture lock'
exec {capture_lock_fd}>"$capture_lock"
flock "$capture_lock_fd"

work_dir=$(mktemp -d "$upstream_root/.package-work.XXXXXXXX")
final_stage=$(mktemp -d "$PROJECT_ROOT/build/nightly/.nightly-final.XXXXXXXX")
cleanup() {
    rm -rf -- "$work_dir" "$final_stage"
}
trap cleanup EXIT
mkdir -p -- "$final_stage/context/locks/manifests" \
    "$final_stage/context/repositories" \
    "$final_stage/package-snapshots/SNAPSHOT" \
    "$final_stage/package-snapshot-bundles" "$final_stage/imagebuilders"

target_lock="$context_dir/locks/targets.tsv"
while IFS='|' read -r archive_target _target _subtarget _profile _arch \
        archive_file archive_sha _vermagic archive_bytes archive_extra; do
    [[ -n "$archive_target" && ${archive_target:0:1} != '#' ]] || continue
    [[ -z "$archive_extra" && \
       "$archive_target" =~ ^(x86_64|rpi4|rpi5)$ && \
       "$archive_file" =~ ^[A-Za-z0-9._-]+[.]tar[.]zst$ && \
       "$archive_sha" =~ ^[0-9a-f]{64}$ && \
       "$archive_bytes" =~ ^[1-9][0-9]*$ ]] || \
        die "nightly ImageBuilder lock row is unsafe: $archive_target"
    archive_source="$download_dir/$archive_file"
    [[ -f "$archive_source" && ! -L "$archive_source" && \
       $(stat -c '%s' "$archive_source") == "$archive_bytes" ]] || \
        die "nightly ImageBuilder cache entry has the wrong type or size: $archive_file"
    printf '%s  %s\n' "$archive_sha" "$archive_source" | \
        sha256sum --strict --quiet -c - || \
        die "nightly ImageBuilder cache entry failed digest verification: $archive_file"
    cp --reflink=auto -- "$archive_source" \
        "$final_stage/imagebuilders/$archive_file"
done < "$target_lock"
[[ $(find "$final_stage/imagebuilders" -mindepth 1 -maxdepth 1 \
    -type f | wc -l) == 3 ]] || \
    die 'nightly capture did not preserve exactly three ImageBuilders'
x86_archive=$(awk -F'|' '$1 == "x86_64" { count += 1; value = $6 }
    END { if (count == 1) print value; else exit 1 }' "$target_lock") || \
    die 'nightly target lock has no unique x86 ImageBuilder'
x86_archive_sha=$(awk -F'|' '$1 == "x86_64" { count += 1; value = $7 }
    END { if (count == 1) print value; else exit 1 }' "$target_lock") || \
    die 'nightly target lock has no unique x86 ImageBuilder digest'
x86_archive_bytes=$(awk -F'|' '$1 == "x86_64" { count += 1; value = $9 }
    END { if (count == 1) print value; else exit 1 }' "$target_lock") || \
    die 'nightly target lock has no unique x86 ImageBuilder size'
[[ "$x86_archive" =~ ^[A-Za-z0-9._-]+[.]tar[.]zst$ && \
   "$x86_archive_sha" =~ ^[0-9a-f]{64}$ && \
   "$x86_archive_bytes" =~ ^[1-9][0-9]*$ ]] || \
    die 'nightly x86 ImageBuilder identity is unsafe'
archive_path="$final_stage/imagebuilders/$x86_archive"
[[ -f "$archive_path" && ! -L "$archive_path" && \
   $(stat -c '%s' "$archive_path") == "$x86_archive_bytes" ]] || \
    die 'nightly x86 ImageBuilder cache entry has the wrong type or size'
printf '%s  %s\n' "$x86_archive_sha" "$archive_path" | \
    sha256sum --strict --quiet -c - || \
    die 'nightly x86 ImageBuilder cache entry failed digest verification'
tar --zstd -xf "$archive_path" -C "$work_dir"
apk_tool="$work_dir/${x86_archive%.tar.zst}/staging_dir/host/bin/apk"
[[ -f "$apk_tool" && ! -L "$apk_tool" && -x "$apk_tool" ]] || \
    die 'nightly ImageBuilder does not contain an executable apk metadata tool'

# Record the live warm-up result as a temporary enforce lock.  Only an offline
# rebuild with byte-identical package manifests and firmware images may become
# a publishable nightly candidate.
package_manifest_lock="$final_stage/context/locks/package-manifests.tsv"
artifact_lock="$final_stage/context/locks/artifacts.tsv"
printf '%s\n' '# target|preset|package_count|manifest_sha256' \
    > "$package_manifest_lock"
printf '%s\n' '# target|preset|filename|sha256' > "$artifact_lock"
artifact_count=0
package_index_rows="$work_dir/package-index-rows.tsv"
: > "$package_index_rows"
for target_name in x86_64 rpi4 rpi5; do
    for preset in minimal full; do
        artifact_dir="$capture_output/$target_name/$preset"
        [[ -d "$artifact_dir" && ! -L "$artifact_dir" ]] || \
            die "nightly warm-up output is missing: $target_name/$preset"
        shopt -s nullglob
        manifests=("$artifact_dir"/*.manifest)
        images=("$artifact_dir"/*.img.gz)
        shopt -u nullglob
        [[ ${#manifests[@]} -eq 1 && -f ${manifests[0]} && \
           ! -L ${manifests[0]} ]] || \
            die "nightly warm-up manifest is missing or ambiguous: $target_name/$preset"
        expected_images=1
        [[ "$target_name" == x86_64 ]] || expected_images=2
        [[ ${#images[@]} -eq $expected_images ]] || \
            die "nightly warm-up image set is incomplete: $target_name/$preset"
        locked_manifest="$final_stage/context/locks/manifests/$target_name-$preset.manifest"
        cp -- "${manifests[0]}" "$locked_manifest"
        manifest_count=$(wc -l < "$locked_manifest")
        manifest_sha=$(sha256sum "$locked_manifest" | awk '{ print $1 }')
        [[ "$manifest_count" =~ ^[1-9][0-9]*$ ]] || \
            die "nightly warm-up manifest is empty: $target_name/$preset"
        printf '%s|%s|%s|%s\n' "$target_name" "$preset" \
            "$manifest_count" "$manifest_sha" >> "$package_manifest_lock"
        for image in "${images[@]}"; do
            [[ -f "$image" && ! -L "$image" ]] || \
                die "nightly warm-up image is unsafe: $image"
            printf '%s|%s|%s|%s\n' "$target_name" "$preset" \
                "$(basename -- "$image")" \
                "$(sha256sum "$image" | awk '{ print $1 }')" >> "$artifact_lock"
            artifact_count=$((artifact_count + 1))
        done
    done
done
(( artifact_count == 10 )) || die 'nightly warm-up did not produce ten images'

for target_name in x86_64 rpi4 rpi5; do
    APK_METADATA_TOOL="$apk_tool" \
        "$CACHE_SCRIPTS_DIR/index-package-cache.sh" verify \
        "$package_cache_root" SNAPSHOT "$target_name" >/dev/null

    target_snapshot="$final_stage/package-snapshots/SNAPSHOT/$target_name"
    mkdir -p -- "$target_snapshot"
    repositories_file="$context_dir/repositories/$target_name.list"
    [[ -f "$repositories_file" && ! -L "$repositories_file" && \
       -s "$repositories_file" ]] || \
        die "nightly context has no repository list for $target_name"
    repository_number=0
    repository_specs=()
    while IFS= read -r repository_url; do
        [[ "$repository_url" =~ ^https://downloads[.]immortalwrt[.]org/snapshots/[A-Za-z0-9._~/-]+/packages[.]adb$ && \
           "$repository_url" != *'/../'* ]] || \
            die "unsafe nightly package repository: $repository_url"
        repository_number=$((repository_number + 1))
        repository_name="repo-$repository_number"
        repository_dir="$target_snapshot/$repository_name"
        mkdir -p -- "$repository_dir"
        printf '%s\n' "$repository_name" >> "$target_snapshot/repositories.list"
        curl --disable --proto '=https' --proto-redir '=https' \
            --fail --location --silent --show-error --retry 3 --retry-all-errors \
            --output "$repository_dir/packages.adb" "$repository_url"
        [[ -s "$repository_dir/packages.adb" && \
           ! -L "$repository_dir/packages.adb" ]] || \
            die "nightly repository returned an empty or unsafe index: $repository_url"
        printf '%s|%s\n' "$repository_url" \
            "$(sha256sum "$repository_dir/packages.adb" | awk '{ print $1 }')" \
            >> "$package_index_rows"
        repository_json="$work_dir/$target_name.$repository_name.json"
        "$apk_tool" adbdump --format json -- \
            "$repository_dir/packages.adb" > "$repository_json" || \
            die "cannot decode nightly package index: $repository_url"
        repository_specs+=("$repository_name" "$repository_json")
    done < "$repositories_file"
    (( repository_number > 0 )) || \
        die "nightly repository list is empty for $target_name"

    manifest_paths=()
    for preset in minimal full; do
        artifact_dir="$capture_output/$target_name/$preset"
        [[ -d "$artifact_dir" && ! -L "$artifact_dir" ]] || \
            die "nightly warm-up output is missing: $target_name/$preset"
        shopt -s nullglob
        manifests=("$artifact_dir"/*.manifest)
        shopt -u nullglob
        [[ ${#manifests[@]} -eq 1 && -f ${manifests[0]} && \
           ! -L ${manifests[0]} ]] || \
            die "nightly warm-up manifest is missing or ambiguous: $target_name/$preset"
        manifest_paths+=("${manifests[0]}")
    done
    selected_apks="$work_dir/$target_name.selected-apks.tsv"
    python3 "$CACHE_SCRIPTS_DIR/map-package-snapshot.py" \
        "$package_cache_root/index.tsv" SNAPSHOT "$target_name" \
        "${manifest_paths[@]}" -- "${repository_specs[@]}" > "$selected_apks"
    [[ -s "$selected_apks" ]] || \
        die "nightly warm-up resolved no cached APKs for $target_name"
    while IFS=$'\t' read -r repository_name canonical_name cache_name mapping_extra; do
        [[ -z "$mapping_extra" && \
           "$repository_name" =~ ^repo-[1-9][0-9]*$ && \
           "$canonical_name" =~ ^[A-Za-z0-9][A-Za-z0-9+._~:-]*[.]apk$ && \
           "$cache_name" =~ ^[A-Za-z0-9][A-Za-z0-9+._~:-]*[.]apk$ ]] || \
            die "unsafe nightly package mapping for $target_name"
        source_apk="$package_cache_root/SNAPSHOT/$target_name/$cache_name"
        destination="$target_snapshot/$repository_name/$canonical_name"
        [[ -f "$source_apk" && ! -L "$source_apk" ]] || \
            die "nightly package cache is missing selected APK: $source_apk"
        if [[ -e "$destination" || -L "$destination" ]]; then
            [[ -f "$destination" && ! -L "$destination" ]] || \
                die "nightly package snapshot collision is unsafe: $destination"
            cmp -s "$source_apk" "$destination" || \
                die "nightly package snapshot filename collision: $destination"
        else
            cp --reflink=auto -- "$source_apk" "$destination"
        fi
    done < "$selected_apks"
    (
        cd "$target_snapshot"
        find . -type f ! -name 'SHA256SUMS*' -printf '%P\0' | sort -z \
            | xargs -0 -r sha256sum > SHA256SUMS.tmp
        mv -- SHA256SUMS.tmp SHA256SUMS
        sha256sum --strict --quiet -c SHA256SUMS
    )
done

sort -u -o "$package_index_rows" "$package_index_rows"
package_index_lock="$context_dir/repositories/PACKAGES.sha256.tsv"
[[ -f "$package_index_lock" && ! -L "$package_index_lock" && \
   $(sed -n '1p' "$package_index_lock") == '# url|sha256' ]] || \
    die 'nightly context has no safe package-index aggregate lock'
locked_package_rows="$work_dir/locked-package-index-rows.tsv"
sed '1d' "$package_index_lock" > "$locked_package_rows"
[[ -s "$locked_package_rows" ]] || die 'nightly package-index aggregate is empty'
cmp -s "$package_index_rows" "$locked_package_rows" || \
    die 'captured package indexes differ from the classified upstream state'
state_packages_sha=$(awk -F= '
    $1 == "SNAPSHOT_PACKAGES_SHA256" { count += 1; value = $2 }
    END { if (count == 1) print value; else exit 1 }
' "$context_dir/UPSTREAM_STATE.env") || \
    die 'nightly state has no unique package-index fingerprint'
[[ "$state_packages_sha" =~ ^[0-9a-f]{64}$ && \
   $(sha256sum "$package_index_rows" | awk '{ print $1 }') == \
       "$state_packages_sha" ]] || \
    die 'nightly package-index aggregate digest mismatch'

snapshot_lock="$final_stage/context/locks/package-snapshots.tsv"
printf '%s\n' "$PACKAGE_SNAPSHOT_LOCK_HEADER" > "$snapshot_lock"
for target_name in x86_64 rpi4 rpi5; do
    target_snapshot="$final_stage/package-snapshots/SNAPSHOT/$target_name"
    bundle_file="immortalwrt-SNAPSHOT-$target_name-package-snapshot.tar.zst"
    bundle_path="$final_stage/package-snapshot-bundles/$bundle_file"
    tar --zstd --sort=name --mtime="@$source_epoch" --owner=0 --group=0 \
        --numeric-owner -cf "$bundle_path" -C "$final_stage/package-snapshots" \
        "SNAPSHOT/$target_name"
    bundle_sha=$(sha256sum "$bundle_path" | awk '{ print $1 }')
    bundle_bytes=$(stat -c '%s' "$bundle_path")
    tree_sha=$(sha256sum "$target_snapshot/SHA256SUMS" | awk '{ print $1 }')
    printf '%s|%s|%s|%s|%s\n' "$target_name" "$bundle_file" \
        "$bundle_sha" "$bundle_bytes" "$tree_sha" >> "$snapshot_lock"
done
package_snapshots_sha256=$(sha256sum "$snapshot_lock" | awk '{ print $1 }')
package_snapshot_content_sha256=$(
    "$INPUT_SCRIPTS_DIR/nightly-build-identity.sh" content "$snapshot_lock"
)
[[ "$package_snapshot_content_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    die 'cannot derive the nightly package-snapshot content identity'

cp -- "$context_dir/UPSTREAM_STATE.env" "$final_stage/context/UPSTREAM_STATE.env"
cp -- "$context_dir/locks/feeds.tsv" "$final_stage/context/locks/feeds.tsv"
cp -- "$context_dir/locks/targets.tsv" "$final_stage/context/locks/targets.tsv"
cp -- "$context_dir"/repositories/*.list "$final_stage/context/repositories/"
cp -- "$package_index_lock" "$final_stage/context/repositories/PACKAGES.sha256.tsv"
write_plan_input_contract "$final_stage/context/PLAN_INPUTS.sha256" \
    "$final_stage/context/PLAN_INPUT_REVISION.txt"
plan_inputs_sha256=$(sha256sum \
    "$final_stage/context/PLAN_INPUTS.sha256" | awk '{ print $1 }')
nightly_fingerprint=$(
    "$INPUT_SCRIPTS_DIR/nightly-build-identity.sh" fingerprint \
        "$upstream_fingerprint" "$final_stage/context/PLAN_INPUTS.sha256" \
        "$snapshot_lock"
)
[[ "$nightly_fingerprint" =~ ^[0-9a-f]{64}$ && \
   "$nightly_fingerprint" != "$upstream_fingerprint" ]] || \
    die 'cannot derive a distinct final nightly fingerprint'

awk -F= -v release_tag="nightly-$nightly_fingerprint" '
    $1 == "LOCKED_INPUT_RELEASE_TAG" {
        count += 1
        print "LOCKED_INPUT_RELEASE_TAG=" release_tag
        next
    }
    { print }
    END { if (count != 1) exit 1 }
' "$context_dir/locks/release.env" > "$final_stage/context/locks/release.env" || \
    die 'cannot bind final nightly release lock to its fingerprint'

build_state="$final_stage/NIGHTLY_BUILD.env"
{
    printf 'NIGHTLY_BUILD_SCHEMA=1\n'
    printf 'UPSTREAM_FINGERPRINT=%s\n' "$upstream_fingerprint"
    printf 'PLAN_INPUTS_SHA256=%s\n' "$plan_inputs_sha256"
    printf 'PACKAGE_SNAPSHOTS_SHA256=%s\n' \
        "$package_snapshot_content_sha256"
    printf 'PACKAGE_SNAPSHOT_LOCK_SHA256=%s\n' \
        "$package_snapshots_sha256"
    printf 'NIGHTLY_FINGERPRINT=%s\n' "$nightly_fingerprint"
} > "$build_state"
cp -- "$build_state" "$final_stage/context/NIGHTLY_BUILD.env"
(
    cd "$final_stage/context"
    sha256sum NIGHTLY_BUILD.env PLAN_INPUTS.sha256 PLAN_INPUT_REVISION.txt \
        UPSTREAM_STATE.env locks/artifacts.tsv locks/feeds.tsv \
        locks/manifests/rpi4-full.manifest \
        locks/manifests/rpi4-minimal.manifest \
        locks/manifests/rpi5-full.manifest \
        locks/manifests/rpi5-minimal.manifest \
        locks/manifests/x86_64-full.manifest \
        locks/manifests/x86_64-minimal.manifest \
        locks/package-manifests.tsv locks/package-snapshots.tsv \
        locks/release.env locks/targets.tsv repositories/PACKAGES.sha256.tsv \
        repositories/rpi4.list \
        repositories/rpi5.list repositories/x86_64.list > CONTEXT.sha256
    sha256sum --strict --quiet -c CONTEXT.sha256
)
find "$final_stage" -type d -exec chmod 0755 {} +
find "$final_stage" -type f -exec chmod 0644 {} +
context_archive="$final_stage/NIGHTLY_BUILD_CONTEXT.tar"
tar --sort=name --format=gnu --mtime="@$source_epoch" --owner=0 --group=0 \
    --numeric-owner --mode='u+rwX,go+rX,go-w' -cf "$context_archive" \
    -C "$final_stage" NIGHTLY_BUILD.env context
chmod 0644 "$context_archive"

final_root="$PROJECT_ROOT/build/nightly/$nightly_fingerprint"
if [[ -e "$final_root" || -L "$final_root" ]]; then
    [[ -d "$final_root" && ! -L "$final_root" ]] || \
        die "existing final nightly root is unsafe: $final_root"
    for relative in NIGHTLY_BUILD.env NIGHTLY_BUILD_CONTEXT.tar context \
                    imagebuilders package-snapshots package-snapshot-bundles; do
        diff -qr --no-dereference -- "$final_stage/$relative" \
            "$final_root/$relative" >/dev/null || \
            die "existing final nightly inputs conflict: $final_root/$relative"
    done
    rm -rf -- "$final_stage"
    final_stage=
else
    mv -- "$final_stage" "$final_root"
    final_stage=
fi

pointer_tmp=$(mktemp "$upstream_root/.NIGHTLY_BUILD_POINTER.env.XXXXXXXX")
cp -- "$final_root/NIGHTLY_BUILD.env" "$pointer_tmp"
chmod 0644 "$pointer_tmp"
mv -- "$pointer_tmp" "$upstream_root/NIGHTLY_BUILD_POINTER.env"

rm -rf -- "$work_dir"
work_dir=
trap - EXIT
flock -u "$capture_lock_fd"
printf '%s\n' "$nightly_fingerprint"
