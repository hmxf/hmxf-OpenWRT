#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

if [[ -z ${BUILD_CONFIG:-} ]]; then
    BUILD_CONFIG=configs/build-refresh.env
    export BUILD_CONFIG
fi
load_build_config
configure_network_environment
sanitize_build_path
load_release_lock
[[ "$ARTIFACT_LOCK_POLICY" == record ]] || \
    die 'refresh-locks.sh requires configs/build-refresh.env record policy'
[[ "$BUILD_CONFIG_FILE" == "$PROJECT_ROOT/configs/build-refresh.env" ]] || \
    die 'refresh-locks.sh requires configs/build-refresh.env'
[[ "$LOCKS_DIR" == "$PROJECT_ROOT/locks" && \
   "$CONFIGS_DIR" == "$PROJECT_ROOT/configs" ]] || \
    die 'refresh-locks.sh must start from the formal project locks and configs'
for required_policy in \
    CHECK_LATEST_ON_BUILD=0 \
    ARTIFACT_LOCK_POLICY=record \
    PACKAGE_REPOSITORY_MODE=live \
    PACKAGE_CACHE_INDEX=1 \
    SOURCE_FETCH_MODE=locked \
    SOURCE_FETCH_POLICY=if-missing \
    SOURCE_FEED_CACHE_MODE=auto \
    SOURCE_KMOD_SCOPE=preset \
    SOURCE_FAILURE_DIAGNOSTICS=0 \
    RUN_X86_SMOKE_TEST=1 \
    REQUIRE_CLEAN_PROJECT=0 \
    REQUIRE_SHELLCHECK=1 \
    KEEP_BUILD=0 \
    IMAGEBUILDER_RETRIES=3 \
    SOURCE_FEED_RETRIES=3; do
    required_key=${required_policy%%=*}
    required_value=${required_policy#*=}
    [[ ${!required_key} == "$required_value" ]] || \
        die "refresh policy override is forbidden: $required_policy"
done

# Every child process receives the complete policy explicitly. Values loaded
# from a caller's exported environment must not leak from record/live into the
# enforce/snapshot rebuild. NETWORK_PROXY_MODE is the sole transport-only
# exception and is still recorded explicitly in the candidate report.
run_refresh_policy() {
    local artifact_policy=${1:?artifact policy required}
    local repository_mode=${2:?repository mode required}
    local policy_file=${3:?build policy file required}
    local package_cache_index=0
    shift 3
    [[ "$repository_mode" == snapshot ]] || package_cache_index=1
    env \
        BUILD_CONFIG="$policy_file" \
        CHECK_LATEST_ON_BUILD=0 \
        ARTIFACT_LOCK_POLICY="$artifact_policy" \
        PACKAGE_REPOSITORY_MODE="$repository_mode" \
        PACKAGE_CACHE_INDEX="$package_cache_index" \
        SOURCE_FETCH_MODE=locked \
        SOURCE_FETCH_POLICY=if-missing \
        SOURCE_FEED_CACHE_MODE=auto \
        SOURCE_KMOD_SCOPE=preset \
        SOURCE_FAILURE_DIAGNOSTICS=0 \
        RUN_X86_SMOKE_TEST=1 \
        REQUIRE_CLEAN_PROJECT=0 \
        REQUIRE_SHELLCHECK=1 \
        KEEP_BUILD=0 \
        IMAGEBUILDER_RETRIES=3 \
        SOURCE_FEED_RETRIES=3 \
        NETWORK_PROXY_MODE="$NETWORK_PROXY_MODE" \
        "$@"
}

run_refresh_policy record live "$PROJECT_ROOT/configs/build-refresh.env" \
    "$VERIFY_SCRIPTS_DIR/validate-project.sh"

for tool in awk cmp curl find flock git make mktemp python3 realpath sha256sum sort stat tar zstd; do
    require_command "$tool"
done

requested_version=${1:-latest}
[[ -n "$requested_version" ]] || requested_version=latest
if [[ "$requested_version" == latest ]]; then
    requested_version=$("$LOCK_SCRIPTS_DIR/check-latest-release.sh" --print)
fi
[[ "$requested_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "invalid refresh version: $requested_version"
refresh_offline=${REFRESH_OFFLINE:-0}
[[ "$refresh_offline" == 0 || "$refresh_offline" == 1 ]] || \
    die 'REFRESH_OFFLINE must be 0 or 1'
prepare_only=${REFRESH_PREPARE_ONLY:-0}
[[ "$prepare_only" == 0 || "$prepare_only" == 1 ]] || \
    die 'REFRESH_PREPARE_ONLY must be 0 or 1'

current_version=$IMMORTALWRT_VERSION
current_target_lock=$TARGET_LOCK
source_url=$IMMORTALWRT_SOURCE_URL
download_url=$IMMORTALWRT_DOWNLOAD_URL
rootfs_partsize=$ROOTFS_PARTSIZE
nominal_media_bytes=$NOMINAL_MEDIA_BYTES

refresh_parent=${REFRESH_PARENT:-"$PROJECT_ROOT/build/lock-refresh"}
candidate_root=$(realpath -m -- "$refresh_parent/$requested_version")
case "$candidate_root" in
    "$PROJECT_ROOT/build/lock-refresh/"*) ;;
    *) die "unsafe lock-refresh directory: $candidate_root" ;;
esac
mkdir -p "$PROJECT_ROOT/build" "$refresh_parent"
refresh_lock="$PROJECT_ROOT/build/.lock-refresh.lock"
require_regular_file_or_absent "$refresh_lock" 'lock refresh lock'
exec {refresh_lock_fd}>"$refresh_lock"
flock "$refresh_lock_fd"
mkdir "$candidate_root" 2>/dev/null || \
    die "lock-refresh directory already exists; inspect or move it first: $candidate_root"

candidate_locks="$candidate_root/locks"
candidate_configs="$candidate_root/configs"
metadata_dir="$candidate_root/metadata"
candidate_output="$candidate_root/candidate-out"
verification_output="$candidate_root/verification-out"
package_cache="$candidate_root/package-cache"
snapshot_root="$candidate_root/package-snapshots"
snapshot_bundle_dir="$candidate_root/package-snapshot-bundles"
imagebuilder_bundle_dir="$candidate_root/imagebuilders"
work_dir="$candidate_root/work"
mkdir -p "$candidate_locks/manifests" "$candidate_configs" "$metadata_dir" \
    "$candidate_output" "$verification_output" "$package_cache" \
    "$snapshot_root" "$snapshot_bundle_dir" "$imagebuilder_bundle_dir" "$work_dir"
[[ -r "$PROJECT_ROOT/locks/README.md" ]] || die 'current lock contract documentation is missing'
cp -- "$PROJECT_ROOT/locks/README.md" "$candidate_locks/README.md"
plan_input_manifest="$candidate_root/PLAN_INPUTS.sha256"
plan_input_revision="$candidate_root/PLAN_INPUT_REVISION.txt"
write_plan_input_contract "$plan_input_manifest" "$plan_input_revision"

tag="v$requested_version"
tag_ref="refs/tags/$tag"
source_repository=${SOURCE_REPOSITORY:-"$(dirname -- "$PROJECT_ROOT")/ImmortalWRT"}
remote_tag_object=
remote_source_commit=
if (( refresh_offline == 0 )); then
    remote_refs=
    remote_query_ok=0
    for ((git_attempt = 1; git_attempt <= SOURCE_FEED_RETRIES; git_attempt++)); do
        if remote_refs=$(git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=120 \
                ls-remote "$source_url" "$tag_ref" "$tag_ref^{}"); then
            remote_query_ok=1
            break
        fi
        if (( git_attempt < SOURCE_FEED_RETRIES )); then
            printf 'Official tag query attempt %d/%d failed; retrying\n' \
                "$git_attempt" "$SOURCE_FEED_RETRIES" >&2
        fi
    done
    (( remote_query_ok == 1 )) || \
        die "official tag query failed after $SOURCE_FEED_RETRIES attempts"
    remote_tag_object=$(awk -v ref="$tag_ref" '$2 == ref { print $1 }' <<< "$remote_refs")
    remote_source_commit=$(awk -v ref="$tag_ref^{}" '$2 == ref { print $1 }' <<< "$remote_refs")
    [[ "$remote_tag_object" =~ ^[0-9a-f]{40}$ ]] || \
        die "official source has no annotated tag object for $tag"
    [[ "$remote_source_commit" =~ ^[0-9a-f]{40}$ ]] || \
        die "official source has no peeled commit for $tag"
fi
if git -C "$source_repository" rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
   git -C "$source_repository" rev-parse --verify "$tag" >/dev/null 2>&1; then
    release_repository=$source_repository
else
    (( refresh_offline == 0 )) || \
        die "offline refresh cannot fetch missing source tag $tag"
    release_repository="$work_dir/source"
    git init "$release_repository"
    git -C "$release_repository" remote add origin "$source_url"
    source_fetch_ok=0
    for ((git_attempt = 1; git_attempt <= SOURCE_FEED_RETRIES; git_attempt++)); do
        if git -C "$release_repository" -c http.lowSpeedLimit=1024 \
                -c http.lowSpeedTime=120 fetch --depth=1 --no-tags --no-filter origin \
                "refs/tags/$tag:refs/tags/$tag"; then
            source_fetch_ok=1
            break
        fi
        if (( git_attempt < SOURCE_FEED_RETRIES )); then
            printf 'Source tag fetch attempt %d/%d failed; retrying\n' \
                "$git_attempt" "$SOURCE_FEED_RETRIES" >&2
        fi
    done
    (( source_fetch_ok == 1 )) || \
        die "source tag fetch failed after $SOURCE_FEED_RETRIES attempts"
fi

[[ $(git -C "$release_repository" cat-file -t "$tag") == tag ]] || \
    die "upstream release tag is not annotated: $tag"
tag_object=$(git -C "$release_repository" rev-parse "$tag")
source_commit=$(git -C "$release_repository" rev-parse "$tag^{}")
if (( refresh_offline == 0 )); then
    [[ "$tag_object" == "$remote_tag_object" ]] || \
        die "local tag object differs from official $tag: $tag_object"
    [[ "$source_commit" == "$remote_source_commit" ]] || \
        die "local peeled commit differs from official $tag: $source_commit"
fi
git -C "$release_repository" show "$tag:feeds.conf.default" > "$metadata_dir/feeds.conf.default"
git -C "$release_repository" show "$tag:version" > "$metadata_dir/source.version"
git -C "$release_repository" show "$tag:include/version.mk" \
    > "$metadata_dir/source-version.mk"

python3 - "$metadata_dir/feeds.conf.default" > "$candidate_locks/feeds.tsv" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
pattern = re.compile(
    r"^(src-git(?:-full)?)\s+([A-Za-z0-9._-]+)\s+"
    r"(https://\S+)\^([0-9a-f]{40})$"
)
rows = []
seen = set()
for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    match = pattern.fullmatch(line)
    if not match:
        raise SystemExit(f"unsupported or unlocked feed at line {number}: {raw}")
    feed_type, name, url, commit = match.groups()
    if name in seen:
        raise SystemExit(f"duplicate feed name: {name}")
    seen.add(name)
    rows.append((name, feed_type, url, commit))
if not rows:
    raise SystemExit("release contains no locked feeds")
print("# name|type|url|commit")
for row in rows:
    print("|".join(row))
PY

mapfile -t target_specs < <(
    awk -F'|' '$1 !~ /^#/ && NF { print $1 "|" $2 "|" $3 "|" $4 }' \
        "$current_target_lock"
)
[[ ${#target_specs[@]} -eq 3 ]] || die 'current target lock must define three target intents'

download_dir=${DOWNLOAD_DIR:-"$PROJECT_ROOT/.cache/imagebuilders"}
mkdir -p "$download_dir"
targets_tmp="$candidate_locks/targets.tsv.tmp"
printf '%s\n' '# name|target|subtarget|profile|package_arch|imagebuilder_filename|sha256|kernel_vermagic|bytes' \
    > "$targets_tmp"

common_revision=
common_epoch=
common_kernel_version=
common_kernel_release=
for spec in "${target_specs[@]}"; do
    IFS='|' read -r target_name target subtarget profile <<< "$spec"
    imagebuilder_file="immortalwrt-imagebuilder-$requested_version-$target-$subtarget.Linux-x86_64.tar.zst"
    archive="$download_dir/$imagebuilder_file"
    target_url="$download_url/releases/$requested_version/targets/$target/$subtarget"
    archive_lock="$download_dir/.$imagebuilder_file.lock"
    require_regular_file_or_absent "$archive_lock" 'ImageBuilder cache lock'
    exec {archive_lock_fd}>"$archive_lock"
    flock "$archive_lock_fd"
    if (( refresh_offline == 1 )); then
        [[ "$requested_version" == "$current_version" ]] || \
            die 'offline metadata preparation is supported only for the current locked version'
        imagebuilder_sha=$(awk -F'|' -v name="$target_name" '$1 == name { print $7 }' \
            "$current_target_lock")
    else
        checksum_file="$metadata_dir/$target_name.sha256sums"
        curl --disable --proto '=https' --proto-redir '=https' \
            --fail --location --silent --show-error --retry 3 --retry-all-errors \
            --output "$checksum_file" "$target_url/sha256sums"
        imagebuilder_sha=$(awk -v wanted="$imagebuilder_file" '
            { name=$2; sub(/^\*/, "", name) }
            name == wanted { print $1 }
        ' "$checksum_file")
    fi
    [[ "$imagebuilder_sha" =~ ^[0-9a-f]{64}$ ]] || \
        die "official checksum is missing for $imagebuilder_file"

    if [[ -e "$archive" || -L "$archive" ]]; then
        [[ -f "$archive" && ! -L "$archive" ]] || \
            die "cached ImageBuilder is not a regular file: $archive"
    else
        (( refresh_offline == 0 )) || die "offline refresh is missing $archive"
        partial="$archive.part"
        if [[ -e "$partial" || -L "$partial" ]]; then
            [[ -f "$partial" && ! -L "$partial" ]] || \
                die "unsafe partial ImageBuilder download: $partial"
            rm -f -- "$partial"
        fi
        if ! curl --disable --proto '=https' --proto-redir '=https' \
                --fail --location --retry 3 --retry-all-errors \
                --output "$partial" "$target_url/$imagebuilder_file"; then
            rm -f -- "$partial"
            die "cannot download ImageBuilder: $target_url/$imagebuilder_file"
        fi
        if ! printf '%s  %s\n' "$imagebuilder_sha" "$partial" | sha256sum -c -; then
            rm -f -- "$partial"
            die "downloaded ImageBuilder has the wrong SHA-256: $imagebuilder_file"
        fi
        mv -- "$partial" "$archive"
    fi
    printf '%s  %s\n' "$imagebuilder_sha" "$archive" | sha256sum -c -
    imagebuilder_bytes=$(stat -c '%s' "$archive")
    [[ "$imagebuilder_bytes" =~ ^[1-9][0-9]*$ ]] || \
        die "cannot determine ImageBuilder byte size: $imagebuilder_file"
    if [[ ! -e "$imagebuilder_bundle_dir/$imagebuilder_file" ]]; then
        ln -- "$archive" "$imagebuilder_bundle_dir/$imagebuilder_file" 2>/dev/null || \
            cp --reflink=auto -- "$archive" "$imagebuilder_bundle_dir/$imagebuilder_file"
    fi
    flock -u "$archive_lock_fd"
    exec {archive_lock_fd}>&-

    extract_dir=$(mktemp -d "$work_dir/$target_name-imagebuilder.XXXXXXXX")
    tar --zstd -xf "$archive" -C "$extract_dir"
    imagebuilder_dir="$extract_dir/${imagebuilder_file%.tar.zst}"
    [[ -d "$imagebuilder_dir" ]] || die "unexpected ImageBuilder layout for $target_name"

    revision=$(sed -n 's/^REVISION:=//p' "$imagebuilder_dir/include/version.mk")
    source_epoch=$(sed -n 's/^SOURCE_DATE_EPOCH:=//p' "$imagebuilder_dir/include/version.mk")
    kernel_tuple=$(sed -n 's/^KERNEL_VERSION:=//p' "$imagebuilder_dir/include/version.mk")
    package_arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\([^"]*\)"$/\1/p' \
        "$imagebuilder_dir/.config")
    [[ "$kernel_tuple" =~ ^([0-9]+\.[0-9]+\.[0-9]+)~([0-9a-f]{32})-r([1-9][0-9]*)$ ]] || \
        die "cannot parse ImageBuilder kernel tuple: $kernel_tuple"
    kernel_version=${BASH_REMATCH[1]}
    kernel_vermagic=${BASH_REMATCH[2]}
    kernel_release=${BASH_REMATCH[3]}
    [[ "$revision" =~ ^r[0-9]+-[0-9a-f]+$ && "$source_epoch" =~ ^[0-9]+$ ]] || \
        die "invalid ImageBuilder release metadata for $target_name"
    [[ -n "$package_arch" ]] || die "ImageBuilder package architecture is missing for $target_name"

    # The applications documented for later LuCI installation are deliberately
    # absent from both image presets.  Still require every reviewed top-level
    # package to exist in each official target's package metadata so a release
    # refresh cannot silently publish documentation for a removed/renamed app.
    [[ -s "$imagebuilder_dir/.packageinfo" ]] || \
        die "ImageBuilder package metadata is missing for $target_name"
    while IFS= read -r runtime_package; do
        runtime_matches=$(grep -Fxc "Package: $runtime_package" \
            "$imagebuilder_dir/.packageinfo" || true)
        (( runtime_matches == 1 )) || \
            die "runtime package $runtime_package is absent or ambiguous for $target_name"
    done < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
        "$PROJECT_ROOT/packages/runtime-apps.txt")

    info_file="$metadata_dir/$target_name.info"
    make -s -C "$imagebuilder_dir" info > "$info_file"
    grep -Fqx "Current Target: \"$target/$subtarget\"" "$info_file" || \
        die "ImageBuilder target changed for $target_name"
    case "$package_arch" in
        aarch64_*) build_arch=aarch64 ;;
        *) build_arch=$package_arch ;;
    esac
    grep -Fqx "Current Architecture: \"$build_arch\"" "$info_file" || \
        die "ImageBuilder architecture metadata disagrees for $target_name"
    grep -Fqx "$profile:" "$info_file" || \
        die "profile $profile is absent from the $target_name ImageBuilder"
    cp -- "$imagebuilder_dir/repositories" "$metadata_dir/$target_name.repositories"

    if [[ -z "$common_revision" ]]; then
        common_revision=$revision
        common_epoch=$source_epoch
        common_kernel_version=$kernel_version
        common_kernel_release=$kernel_release
    else
        [[ "$revision" == "$common_revision" && "$source_epoch" == "$common_epoch" && \
           "$kernel_version" == "$common_kernel_version" && \
           "$kernel_release" == "$common_kernel_release" ]] || \
            die "release metadata is inconsistent across target ImageBuilders"
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$target_name" "$target" "$subtarget" "$profile" "$package_arch" \
        "$imagebuilder_file" "$imagebuilder_sha" "$kernel_vermagic" \
        "$imagebuilder_bytes" >> "$targets_tmp"
    rm -rf -- "$extract_dir"
done
mv -- "$targets_tmp" "$candidate_locks/targets.tsv"

# Bind the three official ImageBuilders back to the tagged source tree.  A
# release directory accidentally paired with another tag must fail before any
# package build or candidate lock can be recorded.
python3 - "$metadata_dir/source.version" "$metadata_dir/source-version.mk" \
    "$requested_version" "$common_revision" "$download_url" <<'PY'
from pathlib import Path
import re
import sys

version_file, version_mk_file, release, revision, download_url = sys.argv[1:]
try:
    source_revision = Path(version_file).read_text(encoding="utf-8")
    version_mk = Path(version_mk_file).read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError) as exc:
    raise SystemExit(f"cannot read tagged release metadata: {exc}")
if source_revision != revision + "\n":
    raise SystemExit(
        f"tag version file {source_revision.strip()!r} does not match ImageBuilder {revision!r}"
    )

expected = {
    "VERSION_NUMBER": release,
    "VERSION_CODE": revision,
    "VERSION_REPO": f"{download_url}/releases/{release}",
    "VERSION_DIST": "ImmortalWrt",
}
for key, wanted in expected.items():
    pattern = re.compile(
        rf"^{key}:=\$\(if \$\({key}\),\$\({key}\),([^)]*)\)$"
    )
    values = [match.group(1) for line in version_mk if (match := pattern.fullmatch(line))]
    if values != [wanted]:
        raise SystemExit(
            f"tagged include/version.mk {key} default is {values!r}, expected {[wanted]!r}"
        )
PY
(
    cd "$imagebuilder_bundle_dir"
    find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -printf '%P\0' | sort -z \
        | xargs -0 -r sha256sum > SHA256SUMS.tmp
    mv -- SHA256SUMS.tmp SHA256SUMS
)

{
    printf '%s\n' '# Immutable release lock. Update all values together in a reviewed commit.'
    printf 'IMMORTALWRT_VERSION=%s\n' "$requested_version"
    printf 'IMMORTALWRT_TAG=%s\n' "$tag"
    printf 'IMMORTALWRT_TAG_OBJECT=%s\n' "$tag_object"
    printf 'IMMORTALWRT_COMMIT=%s\n' "$source_commit"
    printf 'IMMORTALWRT_SOURCE_URL=%s\n' "$source_url"
    printf 'IMMORTALWRT_DOWNLOAD_URL=%s\n' "$download_url"
    printf 'LOCKED_INPUT_RELEASE_TAG=hmxf-openwrt-inputs-%s\n' "$requested_version"
    printf 'IMMORTALWRT_VERSION_CODE=%s\n' "$common_revision"
    printf 'IMMORTALWRT_SOURCE_DATE_EPOCH=%s\n' "$common_epoch"
    printf 'IMMORTALWRT_KERNEL_VERSION=%s\n' "$common_kernel_version"
    printf 'IMMORTALWRT_KERNEL_RELEASE=%s\n' "$common_kernel_release"
    printf 'ROOTFS_PARTSIZE=%s\n' "$rootfs_partsize"
    printf 'NOMINAL_MEDIA_BYTES=%s\n' "$nominal_media_bytes"
} > "$candidate_locks/release.env"

for policy in build.env build-debug.env build-refresh.env build-nightly.env; do
    cp -- "$PROJECT_ROOT/configs/$policy" "$candidate_configs/$policy"
done
for target_name in x86_64 rpi4 rpi5; do
    LOCKS_DIR="$candidate_locks" "$BUILD_SCRIPTS_DIR/render-source-config.sh" "$target_name" \
        > "$candidate_configs/$target_name.config"
done

printf '%s\n' '# target|preset|package_count|manifest_sha256' \
    > "$candidate_locks/package-manifests.tsv"
printf '%s\n' '# target|preset|filename|sha256' > "$candidate_locks/artifacts.tsv"

if (( prepare_only == 1 )); then
    verify_plan_input_contract "$plan_input_manifest" "$plan_input_revision"
    printf 'Prepared release metadata candidate in %s\n' "$candidate_root"
    printf 'Package and image locks are intentionally empty until a full refresh build.\n'
    exit 0
fi
(( refresh_offline == 0 )) || die 'a full lock refresh requires network access to resolve live APKs'

# A refresh starts with an empty cache so the portable snapshot contains only
# APKs selected by these six builds.  An explicit seed is a maintenance-only
# speed optimization; the signed live indexes still authenticate every reused
# APK before it can enter an image.
package_cache_seed=${REFRESH_PACKAGE_CACHE_SEED:-}
for target_name in x86_64 rpi4 rpi5; do
    if [[ -n "$package_cache_seed" && -d "$package_cache_seed/$target_name" ]]; then
        [[ ! -L "$package_cache_seed/$target_name" ]] || \
            die "package cache seed target is a symlink: $package_cache_seed/$target_name"
        mkdir -p "$package_cache/$requested_version/$target_name"
        while IFS= read -r -d '' cached_file; do
            [[ -f "$cached_file" && ! -L "$cached_file" ]] || \
                die "unsafe APK cache seed entry: $cached_file"
            cached_name=$(basename -- "$cached_file")
            [[ "$cached_name" =~ ^[A-Za-z0-9][A-Za-z0-9+._~:-]*[.]apk$ ]] || \
                die "unsafe APK cache seed filename: $cached_name"
            destination="$package_cache/$requested_version/$target_name/$cached_name"
            if [[ -e "$destination" ]]; then
                cmp -s "$cached_file" "$destination" || \
                    die "conflicting APK cache seed: $cached_name"
            else
                cp --reflink=auto -- "$cached_file" "$destination"
            fi
        done < <(find "$package_cache_seed/$target_name" -mindepth 1 -maxdepth 1 \
            \( -type f -o -type l \) -name '*.apk' -print0)
    fi
done

for target_name in x86_64 rpi4 rpi5; do
    for preset in minimal full; do
        LOCKS_DIR="$candidate_locks" \
        CONFIGS_DIR="$candidate_configs" \
        OUTPUT_ROOT="$candidate_output" \
        PACKAGE_CACHE_DIR="$package_cache/$requested_version/$target_name" \
        run_refresh_policy record live "$candidate_configs/build-refresh.env" \
            "$BUILD_SCRIPTS_DIR/build-imagebuilder.sh" "$target_name" "$preset"
    done
done

package_lock_tmp="$candidate_locks/package-manifests.tsv.tmp"
artifact_lock_tmp="$candidate_locks/artifacts.tsv.tmp"
printf '%s\n' '# target|preset|package_count|manifest_sha256' > "$package_lock_tmp"
printf '%s\n' '# target|preset|filename|sha256' > "$artifact_lock_tmp"
for target_name in x86_64 rpi4 rpi5; do
    for preset in minimal full; do
        artifact_dir="$candidate_output/$requested_version/$target_name/$preset"
        shopt -s nullglob
        manifests=("$artifact_dir"/*.manifest)
        images=("$artifact_dir"/*.img.gz)
        [[ ${#manifests[@]} -eq 1 ]] || \
            die "candidate has the wrong manifest count for $target_name/$preset"
        expected_images=1
        [[ "$target_name" == x86_64 ]] || expected_images=2
        [[ ${#images[@]} -eq $expected_images ]] || \
            die "candidate has the wrong image count for $target_name/$preset"
        locked_manifest="$candidate_locks/manifests/$target_name-$preset.manifest"
        cp -- "${manifests[0]}" "$locked_manifest"
        manifest_count=$(wc -l < "$locked_manifest")
        manifest_sha=$(sha256sum "$locked_manifest" | awk '{ print $1 }')
        printf '%s|%s|%s|%s\n' "$target_name" "$preset" \
            "$manifest_count" "$manifest_sha" >> "$package_lock_tmp"
        for image in "${images[@]}"; do
            image_sha=$(sha256sum "$image" | awk '{ print $1 }')
            printf '%s|%s|%s|%s\n' "$target_name" "$preset" \
                "$(basename -- "$image")" "$image_sha" >> "$artifact_lock_tmp"
        done
    done
done
mv -- "$package_lock_tmp" "$candidate_locks/package-manifests.tsv"
mv -- "$artifact_lock_tmp" "$candidate_locks/artifacts.tsv"

# ImageBuilder's APK cache uses name-version.<repository-hash-prefix>.apk,
# while a file:// repository must expose name-version.apk. Use the exact apk
# tool shipped in the locked x86 ImageBuilder to decode each captured signed
# index, then map only the current indexed hash to its canonical repository
# filename. This also disambiguates an old and a rebuilt APK having the same
# package/version but different signed hashes in a seeded maintenance cache.
snapshot_tool_dir=$(mktemp -d "$work_dir/snapshot-apk-tool.XXXXXXXX")
snapshot_imagebuilder_file=$(awk -F'|' '$1 == "x86_64" { print $6 }' \
    "$candidate_locks/targets.tsv")
[[ "$snapshot_imagebuilder_file" =~ ^[A-Za-z0-9._-]+[.]tar[.]zst$ ]] || \
    die 'candidate x86 ImageBuilder filename is unsafe'
tar --zstd -xf "$imagebuilder_bundle_dir/$snapshot_imagebuilder_file" \
    -C "$snapshot_tool_dir"
snapshot_apk_tool="$snapshot_tool_dir/${snapshot_imagebuilder_file%.tar.zst}/staging_dir/host/bin/apk"
[[ -f "$snapshot_apk_tool" && -x "$snapshot_apk_tool" ]] || \
    die 'locked ImageBuilder does not contain an executable apk metadata tool'

snapshot_lock="$candidate_locks/package-snapshots.tsv"
printf '%s\n' '# target|filename|sha256|bytes|tree_sha256sums_sha256' > "$snapshot_lock"
for target_name in x86_64 rpi4 rpi5; do
    target_snapshot="$snapshot_root/$requested_version/$target_name"
    mkdir -p "$target_snapshot"
    repository_number=0
    seen_repository_urls=
    repository_specs=()
    while IFS= read -r repository_url; do
        [[ -n "$repository_url" && ${repository_url:0:1} != '#' ]] || continue
        [[ "$repository_url" =~ ^https://downloads[.]immortalwrt[.]org/releases/[0-9]+[.][0-9]+[.][0-9]+/[A-Za-z0-9._~/-]+/packages[.]adb$ && \
           "$repository_url" == "$download_url/releases/$requested_version/"* && \
           "$repository_url" != *'/../'* && "$repository_url" != *'//packages.adb' ]] || \
            die "unsafe or cross-release package repository: $repository_url"
        if grep -Fqx -- "$repository_url" <<< "$seen_repository_urls"; then
            die "duplicate package repository for $target_name: $repository_url"
        fi
        seen_repository_urls=${seen_repository_urls:+"$seen_repository_urls"$'\n'}$repository_url
        repository_number=$((repository_number + 1))
        repository_name="repo-$repository_number"
        repository_dir="$target_snapshot/$repository_name"
        mkdir -p "$repository_dir"
        printf '%s\n' "$repository_name" >> "$target_snapshot/repositories.list"
        curl --disable --proto '=https' --proto-redir '=https' \
            --fail --location --silent --show-error --retry 3 --retry-all-errors \
            --output "$repository_dir/packages.adb" "$repository_url"
        repository_json="$metadata_dir/$target_name.$repository_name.json"
        "$snapshot_apk_tool" adbdump --format json -- \
            "$repository_dir/packages.adb" > "$repository_json" || \
            die "cannot decode captured package index: $repository_url"
        repository_specs+=("$repository_name" "$repository_json")
    done < "$metadata_dir/$target_name.repositories"
    (( repository_number > 0 )) || die "ImageBuilder has no repositories for $target_name"
    selected_apks="$metadata_dir/$target_name.selected-apks.tsv"
    python3 "$CACHE_SCRIPTS_DIR/map-package-snapshot.py" \
        "$package_cache/index.tsv" "$requested_version" "$target_name" \
        "$candidate_locks/manifests/$target_name-minimal.manifest" \
        "$candidate_locks/manifests/$target_name-full.manifest" -- \
        "${repository_specs[@]}" > "$selected_apks"
    [[ -s "$selected_apks" ]] || die "live build selected no cached APKs for $target_name"
    while IFS=$'\t' read -r repository_name canonical_name cache_name mapping_extra; do
        [[ -z "$mapping_extra" && \
           "$repository_name" =~ ^repo-[1-9][0-9]*$ && \
           "$canonical_name" =~ ^[A-Za-z0-9][A-Za-z0-9+._~:-]*[.]apk$ && \
           "$cache_name" =~ ^[A-Za-z0-9][A-Za-z0-9+._~:-]*[.]apk$ ]] || \
            die "unsafe package snapshot mapping for $target_name"
        repository_dir="$target_snapshot/$repository_name"
        [[ -d "$repository_dir" && ! -L "$repository_dir" ]] || \
            die "package snapshot mapping names an unknown repository: $repository_name"
        apk_file="$package_cache/$requested_version/$target_name/$cache_name"
        [[ -f "$apk_file" && ! -L "$apk_file" ]] || \
            die "selected cached APK is missing or unsafe: $apk_file"
        destination="$repository_dir/$canonical_name"
        if [[ -e "$destination" || -L "$destination" ]]; then
            [[ -f "$destination" && ! -L "$destination" ]] || \
                die "unsafe package filename collision in snapshot: $destination"
            cmp -s "$apk_file" "$destination" || \
                die "package filename collision in snapshot: $destination"
        else
            ln -- "$apk_file" "$destination"
        fi
    done < "$selected_apks"
    (
        cd "$target_snapshot"
        find . -type f ! -name 'SHA256SUMS*' -printf '%P\0' | sort -z \
            | xargs -0 -r sha256sum > SHA256SUMS.tmp
        mv -- SHA256SUMS.tmp SHA256SUMS
    )
    bundle_file="immortalwrt-$requested_version-$target_name-package-snapshot.tar.zst"
    tar --zstd --sort=name --mtime="@$common_epoch" --owner=0 --group=0 \
        --numeric-owner -cf "$snapshot_bundle_dir/$bundle_file" \
        -C "$snapshot_root" "$requested_version/$target_name"
    bundle_sha=$(sha256sum "$snapshot_bundle_dir/$bundle_file" | awk '{ print $1 }')
    bundle_bytes=$(stat -c '%s' "$snapshot_bundle_dir/$bundle_file")
    tree_manifest_sha=$(sha256sum "$target_snapshot/SHA256SUMS" | awk '{ print $1 }')
    printf '%s|%s|%s|%s|%s\n' "$target_name" "$bundle_file" "$bundle_sha" \
        "$bundle_bytes" "$tree_manifest_sha" >> "$snapshot_lock"
done
rm -rf -- "$snapshot_tool_dir"
rmdir -- "$work_dir"

# Rebuild all six combinations from the captured signed indexes and APK blobs.
# The enforce policy checks the newly generated manifests and ten image hashes.
for target_name in x86_64 rpi4 rpi5; do
    for preset in minimal full; do
        PACKAGE_SNAPSHOT_DIR="$snapshot_root" \
        LOCKS_DIR="$candidate_locks" \
        CONFIGS_DIR="$candidate_configs" \
        OUTPUT_ROOT="$verification_output" \
        run_refresh_policy enforce snapshot "$candidate_configs/build.env" \
            "$BUILD_SCRIPTS_DIR/build-imagebuilder.sh" "$target_name" "$preset"
    done
done

LOCKS_DIR="$candidate_locks" \
CONFIGS_DIR="$candidate_configs" \
run_refresh_policy enforce snapshot "$candidate_configs/build.env" \
    "$VERIFY_SCRIPTS_DIR/validate-project.sh"

verify_plan_input_contract "$plan_input_manifest" "$plan_input_revision"

cat > "$candidate_root/REPORT.md" <<EOF
# ImmortalWrt $requested_version lock candidate

- Source tag object: \`$tag_object\`
- Source commit: \`$source_commit\`
- ImageBuilder revision: \`$common_revision\`
- Kernel: \`$common_kernel_version-r$common_kernel_release\`
- Reviewed LuCI runtime packages: present in all three target metadata sets
- Candidate outputs: \`candidate-out/\` (live signed upstream repositories)
- Verification outputs: \`verification-out/\` (captured signed indexes/APKs)
- Package snapshot bundles: \`package-snapshot-bundles/\`
- Locked ImageBuilder archives: \`imagebuilders/\`
- Plan input manifest: \`PLAN_INPUTS.sha256\`
- Generating project revision: \`$(<"$plan_input_revision")\`
- Network transport policy: \`$NETWORK_PROXY_MODE\`

All six combinations were rebuilt from the captured package snapshot and
matched the candidate manifests and ten image SHA-256 values. Review package,
driver, target/profile, configuration and documentation changes before applying
the candidate. Before changing formal locks, the apply step persists unpacked
snapshots, portable bundles and all three ImageBuilders in the local cache.
Stage those six archives and remotely verify them in a draft before applying
the candidate. After the new lock commit is exact-lease pushed, rebind the draft
tag to that commit and publish it once, so a fresh CI runner can restore every
input by digest from the revision that declares it.
EOF

printf 'Complete lock candidate and offline package snapshots are in %s\n' "$candidate_root"
