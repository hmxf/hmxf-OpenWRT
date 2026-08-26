#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

state_arg=${1:?usage: prepare-nightly-context.sh UPSTREAM_STATE.env [CONTEXT_DIR]}
state_file=$(realpath -e -- "$state_arg")
[[ -f "$state_file" && ! -L "$state_file" ]] || \
    die "nightly state is not a safe regular file: $state_arg"
download_base=https://downloads.immortalwrt.org

BUILD_CONFIG=${BUILD_CONFIG:-configs/build-nightly.env}
load_build_config
configure_network_environment
sanitize_build_path
[[ "$BUILD_CONFIG_FILE" == "$PROJECT_ROOT/configs/build-nightly.env" ]] || \
    die 'nightly context preparation requires configs/build-nightly.env'

for tool in awk cmp cp curl find flock make mktemp realpath sed sha256sum sort stat tar; do
    require_command "$tool"
done

state_value() {
    local key=${1:?state key required}
    local value
    value=$(awk -F= -v wanted="$key" '
        $1 == wanted { count += 1; value = substr($0, length($1) + 2) }
        END { if (count == 1) print value; else exit 1 }
    ' "$state_file") || die "nightly state is missing unique key $key"
    [[ "$value" =~ ^[A-Za-z0-9._:/-]+$ ]] || \
        die "nightly state contains an unsafe value for $key"
    printf '%s\n' "$value"
}

validate_package_index() {
    local package_index=${1:?package index required}
    python3 - "$package_index" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
size = path.stat().st_size
if size < 8 or size > 32 * 1024 * 1024:
    raise SystemExit(1)
with path.open("rb") as stream:
    if stream.read(4) != b"ADBd":
        raise SystemExit(1)
PY
}

[[ $(state_value STATE_SCHEMA) == 1 ]] || die 'unsupported nightly state schema'
state_channel=$(state_value CHANNEL)
[[ "$state_channel" == nightly ]] || \
    die "state does not request a nightly build: $state_channel"
fingerprint=$(state_value SNAPSHOT_FINGERPRINT)
version_code=$(state_value SNAPSHOT_VERSION_CODE)
source_commit=$(state_value SNAPSHOT_SOURCE_COMMIT)
feeds_sha=$(state_value SNAPSHOT_FEEDS_SHA256)
targets_sha=$(state_value SNAPSHOT_TARGETS_SHA256)
packages_sha=$(state_value SNAPSHOT_PACKAGES_SHA256)
version_commit=${version_code#*-}
[[ "$fingerprint" =~ ^[0-9a-f]{64}$ && \
   "$version_code" =~ ^r[0-9]+-[0-9a-f]{7,40}$ && \
   "$source_commit" =~ ^[0-9a-f]{40}$ && \
   "${source_commit:0:${#version_commit}}" == "$version_commit" && \
   "$feeds_sha" =~ ^[0-9a-f]{64}$ && \
   "$targets_sha" =~ ^[0-9a-f]{64}$ && \
   "$packages_sha" =~ ^[0-9a-f]{64}$ ]] || \
    die 'nightly state has invalid source or fingerprint metadata'
calculated_fingerprint=$(printf '%s\n%s\n%s\n%s\n%s\n' \
    "$version_code" "$source_commit" "$feeds_sha" "$targets_sha" \
    "$packages_sha" | \
    sha256sum | awk '{ print $1 }')
[[ "$calculated_fingerprint" == "$fingerprint" ]] || \
    die 'nightly state fingerprint does not match its source/feed/target inputs'

default_context="$PROJECT_ROOT/build/nightly/$fingerprint/context"
context_dir=$(realpath -m -- "${2:-$default_context}")
[[ "$context_dir" == "$default_context" ]] || \
    die "nightly context must use its fingerprint path: $default_context"
context_parent=$(dirname -- "$context_dir")
mkdir -p -- "$context_parent"

download_dir=${DOWNLOAD_DIR:-"$PROJECT_ROOT/.cache/nightly/imagebuilders/$fingerprint"}
mkdir -p -- "$download_dir"
download_dir=$(realpath -e -- "$download_dir")
[[ -d "$download_dir" && ! -L "$download_dir" ]] || \
    die "nightly download directory is unsafe: $download_dir"

verify_context() {
    local candidate=${1:?nightly context required}
    local actual_layout actual_manifest_names
    local expected_layout expected_manifest_names
    local actual_package_sha actual_repository_urls locked_repository_urls

    [[ -d "$candidate" && ! -L "$candidate" ]] || \
        die "nightly context is not a safe directory: $candidate"
    expected_layout=$'d|locks\nd|repositories\nf|CONTEXT.sha256\nf|UPSTREAM_STATE.env\nf|locks/feeds.tsv\nf|locks/release.env\nf|locks/targets.tsv\nf|repositories/PACKAGES.sha256.tsv\nf|repositories/rpi4.list\nf|repositories/rpi5.list\nf|repositories/x86_64.list'
    actual_layout=$(find "$candidate" -mindepth 1 -printf '%y|%P\n' | sort)
    [[ "$actual_layout" == "$expected_layout" ]] || \
        die "nightly context contains an incomplete or unexpected file set: $candidate"
    cmp -s "$state_file" "$candidate/UPSTREAM_STATE.env" || \
        die "existing nightly context conflicts with fingerprint $fingerprint"

    awk '
        NF != 2 || $1 !~ /^[0-9a-f]{64}$/ { exit 1 }
        {
            name = $2
            sub(/^\*/, "", name)
            if (name !~ /^(UPSTREAM_STATE[.]env|locks\/(feeds[.]tsv|release[.]env|targets[.]tsv)|repositories\/(PACKAGES[.]sha256[.]tsv|(rpi4|rpi5|x86_64)[.]list))$/ ||
                seen[name]++) exit 1
        }
        END { if (NR != 8) exit 1 }
    ' "$candidate/CONTEXT.sha256" || \
        die "nightly context checksum index is invalid: $candidate"
    expected_manifest_names=$'UPSTREAM_STATE.env\nlocks/feeds.tsv\nlocks/release.env\nlocks/targets.tsv\nrepositories/PACKAGES.sha256.tsv\nrepositories/rpi4.list\nrepositories/rpi5.list\nrepositories/x86_64.list'
    actual_manifest_names=$(awk '{ sub(/^\*/, "", $2); print $2 }' \
        "$candidate/CONTEXT.sha256" | sort)
    [[ "$actual_manifest_names" == "$expected_manifest_names" ]] || \
        die "nightly context checksum index is incomplete: $candidate"
    (
        cd "$candidate"
        sha256sum --strict --quiet -c CONTEXT.sha256
    ) || die "nightly context checksum verification failed: $candidate"

    awk -F'|' '
        NR == 1 { if ($0 != "# url|sha256") exit 1; next }
        NF != 2 ||
          $1 !~ /^https:\/\/downloads[.]immortalwrt[.]org\/snapshots\/[A-Za-z0-9._~\/-]+\/packages[.]adb$/ ||
          $1 ~ /\/\.\.?\// || $2 !~ /^[0-9a-f]{64}$/ || seen[$1]++ {
            exit 1
        }
        END { if (NR < 2 || NR > 193) exit 1 }
    ' "$candidate/repositories/PACKAGES.sha256.tsv" || \
        die "nightly package checksum map is invalid: $candidate"
    actual_package_sha=$(awk 'NR > 1 { print }' \
        "$candidate/repositories/PACKAGES.sha256.tsv" | \
        sha256sum | awk '{ print $1 }')
    [[ "$actual_package_sha" == "$packages_sha" ]] || \
        die "nightly package checksum map has the wrong identity: $candidate"
    actual_repository_urls=$(cat \
        "$candidate/repositories/rpi4.list" \
        "$candidate/repositories/rpi5.list" \
        "$candidate/repositories/x86_64.list" | sort -u)
    locked_repository_urls=$(awk -F'|' 'NR > 1 { print $1 }' \
        "$candidate/repositories/PACKAGES.sha256.tsv" | sort -u)
    [[ -n "$actual_repository_urls" && \
       "$actual_repository_urls" == "$locked_repository_urls" ]] || \
        die "nightly repository lists differ from their checksum map: $candidate"
}

if [[ -d "$context_dir" ]]; then
    verify_context "$context_dir"
    printf '%s\n' "$context_dir"
    exit 0
elif [[ -e "$context_dir" || -L "$context_dir" ]]; then
    die "nightly context path is not a directory: $context_dir"
fi

context_lock="$context_parent/.context.lock"
require_regular_file_or_absent "$context_lock" 'nightly context lock'
exec {context_lock_fd}>"$context_lock"
flock "$context_lock_fd"
if [[ -d "$context_dir" ]]; then
    verify_context "$context_dir"
    printf '%s\n' "$context_dir"
    exit 0
fi

staging=$(mktemp -d "$context_parent/.context.XXXXXXXX")
cleanup() {
    rm -rf -- "$staging"
}
trap cleanup EXIT
mkdir -p -- "$staging/locks" "$staging/repositories"
cp -- "$state_file" "$staging/UPSTREAM_STATE.env"
chmod 0644 "$staging/UPSTREAM_STATE.env"

target_specs=(
    'x86_64|x86|64|generic|x86_64'
    'rpi4|bcm27xx|bcm2711|rpi-4|aarch64_cortex-a72'
    'rpi5|bcm27xx|bcm2712|rpi-5|aarch64_cortex-a76'
)
target_rows="$staging/locks/targets.tsv"
printf '%s\n' "$TARGET_LOCK_HEADER" > "$target_rows"
fingerprint_rows="$staging/fingerprint-targets.txt"
: > "$fingerprint_rows"
package_index_rows="$staging/package-index-rows"
package_index_dir="$staging/package-indexes"
: > "$package_index_rows"
mkdir -p -- "$package_index_dir"
package_index_number=0

common_revision=
common_epoch=
common_kernel_version=
common_kernel_release=
common_feeds=
for spec in "${target_specs[@]}"; do
    IFS='|' read -r name target subtarget profile expected_arch <<< "$spec"
    key=${name^^}
    imagebuilder_file=$(state_value "NIGHTLY_IMAGEBUILDER_${key}_FILE")
    imagebuilder_sha=$(state_value "NIGHTLY_IMAGEBUILDER_${key}_SHA256")
    expected_file="immortalwrt-imagebuilder-$target-$subtarget.Linux-x86_64.tar.zst"
    [[ "$imagebuilder_file" == "$expected_file" && \
       "$imagebuilder_sha" =~ ^[0-9a-f]{64}$ ]] || \
        die "nightly ImageBuilder state mismatch for $name"
    printf '%s|%s|%s\n' "$name" "$imagebuilder_file" \
        "$imagebuilder_sha" >> "$fingerprint_rows"

    archive="$download_dir/$imagebuilder_file"
    archive_lock="$download_dir/.$imagebuilder_file.lock"
    require_regular_file_or_absent "$archive_lock" 'nightly ImageBuilder cache lock'
    exec {archive_lock_fd}>"$archive_lock"
    flock "$archive_lock_fd"
    if [[ -e "$archive" || -L "$archive" ]]; then
        [[ -f "$archive" && ! -L "$archive" ]] || \
            die "nightly ImageBuilder cache entry is unsafe: $archive"
        printf '%s  %s\n' "$imagebuilder_sha" "$archive" | \
            sha256sum --strict --quiet -c -
    else
        partial="$archive.part"
        rm -f -- "$partial"
        url="$download_base/snapshots/targets/$target/$subtarget/$imagebuilder_file"
        if ! curl --disable --proto '=https' --proto-redir '=https' \
                --fail --location --retry 3 --retry-all-errors \
                --output "$partial" "$url"; then
            rm -f -- "$partial"
            die "cannot download nightly ImageBuilder: $url"
        fi
        if ! printf '%s  %s\n' "$imagebuilder_sha" "$partial" | \
                sha256sum --strict --quiet -c -; then
            rm -f -- "$partial"
            die "nightly ImageBuilder digest mismatch: $imagebuilder_file"
        fi
        mv -- "$partial" "$archive"
    fi
    imagebuilder_bytes=$(stat -c '%s' "$archive")
    [[ "$imagebuilder_bytes" =~ ^[1-9][0-9]*$ ]] || \
        die "nightly ImageBuilder has invalid size: $imagebuilder_file"
    flock -u "$archive_lock_fd"
    exec {archive_lock_fd}>&-

    extract_dir=$(mktemp -d "$staging/$name-imagebuilder.XXXXXXXX")
    tar --zstd -xf "$archive" -C "$extract_dir"
    imagebuilder_dir="$extract_dir/${imagebuilder_file%.tar.zst}"
    [[ -d "$imagebuilder_dir" ]] || \
        die "unexpected nightly ImageBuilder layout for $name"
    revision=$(sed -n 's/^REVISION:=//p' "$imagebuilder_dir/include/version.mk")
    source_epoch=$(sed -n 's/^SOURCE_DATE_EPOCH:=//p' \
        "$imagebuilder_dir/include/version.mk")
    kernel_tuple=$(sed -n 's/^KERNEL_VERSION:=//p' \
        "$imagebuilder_dir/include/version.mk")
    package_arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\([^"]*\)"$/\1/p' \
        "$imagebuilder_dir/.config")
    [[ "$revision" == "$version_code" && "$source_epoch" =~ ^[0-9]+$ ]] || \
        die "nightly source metadata differs for $name"
    [[ "$kernel_tuple" =~ ^([0-9]+\.[0-9]+\.[0-9]+)~([0-9a-f]{32})-r([1-9][0-9]*)$ ]] || \
        die "cannot parse nightly kernel tuple for $name: $kernel_tuple"
    kernel_version=${BASH_REMATCH[1]}
    kernel_vermagic=${BASH_REMATCH[2]}
    kernel_release=${BASH_REMATCH[3]}
    [[ "$package_arch" == "$expected_arch" ]] || \
        die "nightly package architecture changed for $name: $package_arch"
    info_file="$staging/$name.info"
    make -s -C "$imagebuilder_dir" info > "$info_file"
    grep -Fqx "Current Target: \"$target/$subtarget\"" "$info_file" || \
        die "nightly ImageBuilder target changed for $name"
    grep -Fqx "$profile:" "$info_file" || \
        die "nightly profile $profile is absent for $name"
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        NF != 1 || $1 !~ /^https:\/\/downloads[.]immortalwrt[.]org\/snapshots\/[A-Za-z0-9._~\/-]+\/packages[.]adb$/ ||
            $1 ~ /\/\.\.?\// || seen[$1]++ { exit 1 }
        { print $1; count += 1 }
        END { if (count == 0) exit 1 }
    ' "$imagebuilder_dir/repositories" > "$staging/repositories/$name.list" || \
        die "nightly ImageBuilder has unsafe package repositories for $name"

    while IFS= read -r repository_url; do
        [[ "$repository_url" == "$download_base/"* ]] || \
            die "nightly package repository uses an unexpected origin: $repository_url"
        repository_path=${repository_url#"$download_base/"}
        [[ "$repository_path" =~ ^snapshots/[A-Za-z0-9._~/-]+/packages[.]adb$ && \
           "$repository_path" != *'/../'* ]] || \
            die "nightly package repository path is unsafe: $repository_url"
        package_index_number=$((package_index_number + 1))
        package_index="$package_index_dir/$package_index_number.adb"
        curl --disable --proto '=https' --proto-redir '=https' \
            --fail --location --silent --show-error --retry 3 \
            --retry-all-errors --max-filesize 33554432 \
            --output "$package_index" "$repository_url" || \
            die "cannot revalidate nightly package index: $repository_url"
        validate_package_index "$package_index" || \
            die "nightly package index is invalid: $repository_url"
        package_index_sha=$(sha256sum "$package_index" | awk '{ print $1 }')
        printf '%s|%s\n' "$repository_url" "$package_index_sha" \
            >> "$package_index_rows"
    done < "$staging/repositories/$name.list"

    if [[ -z "$common_revision" ]]; then
        common_revision=$revision
        common_epoch=$source_epoch
        common_kernel_version=$kernel_version
        common_kernel_release=$kernel_release
    else
        [[ "$revision" == "$common_revision" && \
           "$source_epoch" == "$common_epoch" && \
           "$kernel_version" == "$common_kernel_version" && \
           "$kernel_release" == "$common_kernel_release" ]] || \
            die 'snapshot targets are not yet built from one consistent source/kernel revision'
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$name" "$target" "$subtarget" "$profile" "$package_arch" \
        "$imagebuilder_file" "$imagebuilder_sha" "$kernel_vermagic" \
        "$imagebuilder_bytes" >> "$target_rows"
    rm -rf -- "$extract_dir"

    version_metadata="$staging/$name.version.buildinfo"
    feeds_metadata="$staging/$name.feeds.buildinfo"
    curl --disable --proto '=https' --proto-redir '=https' \
        --fail --location --silent --show-error --retry 3 --retry-all-errors \
        --output "$version_metadata" \
        "$download_base/snapshots/targets/$target/$subtarget/version.buildinfo"
    curl --disable --proto '=https' --proto-redir '=https' \
        --fail --location --silent --show-error --retry 3 --retry-all-errors \
        --output "$feeds_metadata" \
        "$download_base/snapshots/targets/$target/$subtarget/feeds.buildinfo"
    grep -Fqx "$version_code" "$version_metadata" || \
        die "snapshot changed while preparing $name context"
    feeds_digest=$(sha256sum "$feeds_metadata" | awk '{ print $1 }')
    [[ "$feeds_digest" == "$feeds_sha" ]] || \
        die "snapshot feeds changed while preparing $name context"
    if [[ -z "$common_feeds" ]]; then
        common_feeds=$feeds_digest
        cp -- "$feeds_metadata" "$staging/feeds.buildinfo"
    else
        cmp -s "$staging/feeds.buildinfo" "$feeds_metadata" || \
            die 'snapshot targets expose different feed revisions'
    fi
done

[[ $(sha256sum "$fingerprint_rows" | awk '{ print $1 }') == "$targets_sha" ]] || \
    die 'nightly target fingerprint changed during context preparation'
package_index_canonical="$staging/package-index-canonical"
sort -u "$package_index_rows" > "$package_index_canonical"
awk -F'|' '
    NF != 2 ||
      $1 !~ /^https:\/\/downloads[.]immortalwrt[.]org\/snapshots\/[A-Za-z0-9._~\/-]+\/packages[.]adb$/ ||
      $1 ~ /\/\.\.?\// || $2 !~ /^[0-9a-f]{64}$/ || seen[$1]++ {
        exit 1
    }
    END { if (NR == 0 || NR > 192) exit 1 }
' "$package_index_canonical" || die 'nightly package checksum map is unsafe'
calculated_packages_sha=$(sha256sum "$package_index_canonical" | \
    awk '{ print $1 }')
[[ "$calculated_packages_sha" == "$packages_sha" ]] || \
    die 'nightly package indexes changed during context preparation'
{
    printf '%s\n' '# url|sha256'
    cat "$package_index_canonical"
} > "$staging/repositories/PACKAGES.sha256.tsv"

cat > "$staging/locks/release.env" <<EOF
IMMORTALWRT_VERSION=SNAPSHOT
IMMORTALWRT_TAG=SNAPSHOT
IMMORTALWRT_TAG_OBJECT=$source_commit
IMMORTALWRT_COMMIT=$source_commit
IMMORTALWRT_SOURCE_URL=https://github.com/immortalwrt/immortalwrt.git
IMMORTALWRT_DOWNLOAD_URL=https://downloads.immortalwrt.org
LOCKED_INPUT_RELEASE_TAG=nightly-$fingerprint
IMMORTALWRT_VERSION_CODE=$common_revision
IMMORTALWRT_SOURCE_DATE_EPOCH=$common_epoch
IMMORTALWRT_KERNEL_VERSION=$common_kernel_version
IMMORTALWRT_KERNEL_RELEASE=$common_kernel_release
ROOTFS_PARTSIZE=3072
NOMINAL_MEDIA_BYTES=4000000000
EOF

awk '
    {
        split($3, source, "\\^")
        if (length(source) != 2) exit 1
        print $2 "|" $1 "|" source[1] "|" source[2]
    }
' "$staging/feeds.buildinfo" > "$staging/locks/feeds.tsv"
chmod 0644 "$staging/locks/release.env" "$staging/locks/targets.tsv" \
    "$staging/locks/feeds.tsv"
rm -f -- "$staging"/*.info "$staging"/*.version.buildinfo \
    "$staging"/*.feeds.buildinfo "$staging/fingerprint-targets.txt" \
    "$staging/feeds.buildinfo" "$package_index_rows" \
    "$package_index_canonical"
rm -rf -- "$package_index_dir"

(
    cd "$staging"
    sha256sum UPSTREAM_STATE.env locks/feeds.tsv locks/release.env \
        locks/targets.tsv repositories/PACKAGES.sha256.tsv \
        repositories/rpi4.list repositories/rpi5.list \
        repositories/x86_64.list > CONTEXT.sha256
)
chmod 0644 "$staging/CONTEXT.sha256"
verify_context "$staging"

mv -- "$staging" "$context_dir"
staging=
trap - EXIT
flock -u "$context_lock_fd"
printf '%s\n' "$context_dir"
