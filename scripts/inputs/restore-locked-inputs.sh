#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

DEFAULT_LOCKED_INPUT_GITHUB_REPOSITORY=hmxf/hmxf-OpenWRT

usage() {
    cat <<'EOF'
Usage: restore-locked-inputs.sh TARGET

Restore and verify the locked ImageBuilder archive and package snapshot for
TARGET (x86_64, rpi4, or rpi5). Valid destination objects are reused without
contacting a source. Relative filesystem paths are resolved from the project
root.

Destination overrides:
  DOWNLOAD_DIR                 ImageBuilder archive directory
  PACKAGE_SNAPSHOT_DIR         unpacked package-snapshot root
  PACKAGE_SNAPSHOT_BUNDLE_DIR  portable package-snapshot bundle root

Ordered source overrides:
  LOCKED_INPUT_SOURCE_DIR        flat local directory containing release assets
  LOCKED_INPUT_BASE_URL          HTTPS directory containing release assets
  LOCKED_INPUT_GITHUB_REPOSITORY owner/repository for the locked GitHub Release

GITHUB_REPOSITORY is used when LOCKED_INPUT_GITHUB_REPOSITORY is unset; outside
GitHub Actions the canonical hmxf/hmxf-OpenWRT repository is the final default.
The release tag always comes from locks/release.env; source-side names never
select the version or target.
EOF
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }

for tool in awk chmod cp curl dirname flock grep mkdir mktemp mv python3 \
            realpath rm sha256sum stat zstd; do
    require_command "$tool"
done

snapshot_verifier="$INPUT_SCRIPTS_DIR/verify-package-snapshot.py"
[[ -f "$snapshot_verifier" && ! -L "$snapshot_verifier" ]] || \
    die "package snapshot verifier is unavailable: $snapshot_verifier"

load_release_lock
load_target_lock "$1"
load_package_snapshot_lock

resolve_store_root() {
    local input=${1:?store path required}
    local label=${2:?store label required}
    local path probe parent resolved

    [[ "$input" != *$'\n'* && "$input" != *$'\r'* && "$input" != *\\* ]] || \
        die "$label contains an unsafe character"
    if [[ "$input" == /* ]]; then
        path=$(realpath -ms -- "$input")
    else
        path=$(realpath -ms -- "$PROJECT_ROOT/$input")
    fi
    [[ "$path" != / ]] || die "$label may not be the filesystem root"

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        probe=$path
        while [[ ! -e "$probe" && ! -L "$probe" ]]; do
            parent=$(dirname -- "$probe")
            [[ "$parent" != "$probe" ]] || die "cannot find a safe parent for $label"
            probe=$parent
        done
        [[ -d "$probe" && ! -L "$probe" ]] || \
            die "$label has a non-directory or symbolic-link ancestor: $probe"
        resolved=$(realpath -e -- "$probe")
        [[ "$resolved" == "$probe" ]] || \
            die "$label traverses a symbolic-link ancestor: $probe"
        mkdir -p -- "$path"
    fi
    [[ -d "$path" && ! -L "$path" ]] || die "$label must be a real directory: $path"
    resolved=$(realpath -e -- "$path")
    [[ "$resolved" == "$path" ]] || die "$label traverses a symbolic link: $path"
    printf '%s\n' "$path"
}

resolve_source_root() {
    local input=${1:?source path required}
    local path resolved

    [[ "$input" != *$'\n'* && "$input" != *$'\r'* && "$input" != *\\* ]] || \
        die 'LOCKED_INPUT_SOURCE_DIR contains an unsafe character'
    if [[ "$input" == /* ]]; then
        path=$(realpath -ms -- "$input")
    else
        path=$(realpath -ms -- "$PROJECT_ROOT/$input")
    fi
    [[ "$path" != / && -d "$path" && ! -L "$path" ]] || \
        die "LOCKED_INPUT_SOURCE_DIR must be a real non-root directory: $path"
    resolved=$(realpath -e -- "$path")
    [[ "$resolved" == "$path" ]] || \
        die "LOCKED_INPUT_SOURCE_DIR traverses a symbolic link: $path"
    printf '%s\n' "$path"
}

paths_overlap() {
    local first=${1:?first path required}
    local second=${2:?second path required}
    [[ "$first" == "$second" || "$first" == "$second/"* || "$second" == "$first/"* ]]
}

verify_locked_file() {
    local path=${1:?file required}
    local expected_bytes=${2:?byte size required}
    local expected_sha256=${3:?SHA-256 required}
    local label=${4:?file label required}
    local actual_sha256

    [[ -f "$path" && ! -L "$path" ]] || die "$label is not a regular file: $path"
    [[ $(stat -c '%s' -- "$path") == "$expected_bytes" ]] || \
        die "$label has the wrong byte size: $path"
    actual_sha256=$(sha256sum -- "$path")
    actual_sha256=${actual_sha256%% *}
    [[ "$actual_sha256" == "$expected_sha256" ]] || \
        die "$label has the wrong SHA-256: $path"
}

normalize_base_url() {
    python3 - "$1" <<'PY'
import re
import sys
from urllib.parse import urlsplit

raw = sys.argv[1]
try:
    parsed = urlsplit(raw)
    port = parsed.port
except ValueError as error:
    raise SystemExit(f"error: invalid LOCKED_INPUT_BASE_URL: {error}")
if (
    parsed.scheme != "https"
    or not parsed.hostname
    or parsed.username is not None
    or parsed.password is not None
    or parsed.query
    or parsed.fragment
    or "\\" in raw
    or "%" in parsed.path
    or not re.fullmatch(
        r"(?:[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?|"
        r"\[[0-9A-Fa-f:]+\])(?::[0-9]{1,5})?",
        parsed.netloc,
    )
    or not re.fullmatch(r"/[A-Za-z0-9._~+/-]*|", parsed.path)
    or any(part in (".", "..") for part in parsed.path.split("/"))
    or (port is not None and not 1 <= port <= 65535)
):
    raise SystemExit("error: LOCKED_INPUT_BASE_URL must be a simple HTTPS directory URL")
print(raw.rstrip("/"))
PY
}

download_https() {
    local url=${1:?URL required}
    local destination=${2:?destination required}
    local expected_bytes=${3:?byte size required}

    curl --disable --proto '=https' --proto-redir '=https' \
        --fail --location --retry 3 --retry-all-errors --retry-delay 1 \
        --connect-timeout 30 --max-time 1800 --max-filesize "$expected_bytes" \
        --output "$destination" -- "$url" || \
        die "failed to download locked input: $url"
}

source_root=
base_url=
github_repository=

fetch_locked_asset() {
    local filename=${1:?asset filename required}
    local expected_bytes=${2:?asset byte size required}
    local expected_sha256=${3:?asset SHA-256 required}
    local destination=${4:?staging destination required}
    local label=${5:?asset label required}
    local source_file token

    [[ ! -e "$destination" && ! -L "$destination" ]] || \
        die "staging destination already exists: $destination"
    if [[ -n "$source_root" && ( -e "$source_root/$filename" || \
            -L "$source_root/$filename" ) ]]; then
        source_file="$source_root/$filename"
        [[ -f "$source_file" && ! -L "$source_file" ]] || \
            die "$label source is not a regular file: $source_file"
        cp --reflink=auto -- "$source_file" "$destination"
    elif [[ -n "$base_url" ]]; then
        download_https "$base_url/$filename" "$destination" "$expected_bytes"
    elif [[ -n "$github_repository" ]]; then
        token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
        if [[ -n "$token" && $(command -v gh || true) ]]; then
            gh release download "$LOCKED_INPUT_RELEASE_TAG" \
                --repo "$github_repository" --pattern "$filename" \
                --output "$destination" || \
                die "failed to download $filename from GitHub Release $LOCKED_INPUT_RELEASE_TAG"
        else
            download_https \
                "https://github.com/$github_repository/releases/download/$LOCKED_INPUT_RELEASE_TAG/$filename" \
                "$destination" "$expected_bytes"
        fi
    else
        die "no source is available for locked input $filename"
    fi
    chmod 0644 -- "$destination"
    verify_locked_file "$destination" "$expected_bytes" "$expected_sha256" "$label"
}

download_root=$(resolve_store_root \
    "${DOWNLOAD_DIR:-$PROJECT_ROOT/.cache/imagebuilders}" 'ImageBuilder store')
snapshot_root=$(resolve_store_root \
    "${PACKAGE_SNAPSHOT_DIR:-$PROJECT_ROOT/.cache/package-snapshots}" \
    'package snapshot store')
bundle_root=$(resolve_store_root \
    "${PACKAGE_SNAPSHOT_BUNDLE_DIR:-$PROJECT_ROOT/.cache/package-snapshot-bundles}" \
    'package snapshot bundle store')

paths_overlap "$download_root" "$snapshot_root" && \
    die 'ImageBuilder and package snapshot stores may not overlap'
paths_overlap "$download_root" "$bundle_root" && \
    die 'ImageBuilder and package snapshot bundle stores may not overlap'
paths_overlap "$snapshot_root" "$bundle_root" && \
    die 'package snapshot and bundle stores may not overlap'

snapshot_version=$(resolve_store_root "$snapshot_root/$IMMORTALWRT_VERSION" \
    'package snapshot version store')
bundle_version=$(resolve_store_root "$bundle_root/$IMMORTALWRT_VERSION" \
    'package snapshot bundle version store')

archive="$download_root/$IMAGEBUILDER_FILE"
snapshot="$snapshot_version/$TARGET_NAME"
bundle="$bundle_version/$PACKAGE_SNAPSHOT_FILE"

restore_lock="$snapshot_root/.locked-input-restore-$IMMORTALWRT_VERSION-$TARGET_NAME.lock"
require_regular_file_or_absent "$restore_lock" 'locked-input restore lock'
exec {restore_lock_fd}>"$restore_lock"
flock "$restore_lock_fd"

imagebuilder_ready=0
snapshot_ready=0
bundle_ready=0
if [[ -e "$archive" || -L "$archive" ]]; then
    verify_locked_file "$archive" "$IMAGEBUILDER_BYTES" "$IMAGEBUILDER_SHA256" \
        'cached ImageBuilder'
    imagebuilder_ready=1
fi
if [[ -e "$snapshot" || -L "$snapshot" ]]; then
    python3 "$snapshot_verifier" verify "$snapshot" "$IMMORTALWRT_VERSION" \
        "$TARGET_NAME" "$PACKAGE_SNAPSHOT_TREE_SHA256" >/dev/null
    snapshot_ready=1
fi

if (( imagebuilder_ready == 1 && snapshot_ready == 1 )); then
    printf 'Reused verified locked inputs for %s (%s)\n' \
        "$TARGET_NAME" "$IMMORTALWRT_VERSION"
    exit 0
fi

if (( snapshot_ready == 0 )) && [[ -e "$bundle" || -L "$bundle" ]]; then
    verify_locked_file "$bundle" "$PACKAGE_SNAPSHOT_BYTES" \
        "$PACKAGE_SNAPSHOT_SHA256" 'cached package snapshot bundle'
    bundle_ready=1
fi

source_needed=0
if (( imagebuilder_ready == 0 || \
      (snapshot_ready == 0 && bundle_ready == 0) )); then
    source_needed=1
fi
if (( source_needed == 1 )); then
    if [[ -n ${LOCKED_INPUT_SOURCE_DIR:-} ]]; then
        source_root=$(resolve_source_root "$LOCKED_INPUT_SOURCE_DIR")
    fi
    if [[ -n ${LOCKED_INPUT_BASE_URL:-} ]]; then
        base_url=$(normalize_base_url "$LOCKED_INPUT_BASE_URL")
    fi
    github_repository=${LOCKED_INPUT_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-$DEFAULT_LOCKED_INPUT_GITHUB_REPOSITORY}}
    if [[ -n "$github_repository" && \
          ! "$github_repository" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        die "unsafe locked-input GitHub repository: $github_repository"
    fi
fi

imagebuilder_stage_root=
bundle_stage_root=
snapshot_stage_root=
cleanup() {
    local status=$?
    trap - EXIT
    [[ -z "$imagebuilder_stage_root" || ! -d "$imagebuilder_stage_root" ]] || \
        rm -rf -- "$imagebuilder_stage_root"
    [[ -z "$bundle_stage_root" || ! -d "$bundle_stage_root" ]] || \
        rm -rf -- "$bundle_stage_root"
    [[ -z "$snapshot_stage_root" || ! -d "$snapshot_stage_root" ]] || \
        rm -rf -- "$snapshot_stage_root"
    exit "$status"
}
trap cleanup EXIT

staged_imagebuilder=
staged_bundle=
bundle_input=$bundle
if (( imagebuilder_ready == 0 )); then
    imagebuilder_stage_root=$(mktemp -d \
        "$download_root/.locked-input-$IMMORTALWRT_VERSION-$TARGET_NAME.XXXXXXXX")
    staged_imagebuilder="$imagebuilder_stage_root/$IMAGEBUILDER_FILE"
    fetch_locked_asset "$IMAGEBUILDER_FILE" "$IMAGEBUILDER_BYTES" \
        "$IMAGEBUILDER_SHA256" "$staged_imagebuilder" 'locked ImageBuilder'
fi

if (( snapshot_ready == 0 && bundle_ready == 0 )); then
    bundle_stage_root=$(mktemp -d \
        "$bundle_version/.locked-input-$TARGET_NAME.XXXXXXXX")
    staged_bundle="$bundle_stage_root/$PACKAGE_SNAPSHOT_FILE"
    fetch_locked_asset "$PACKAGE_SNAPSHOT_FILE" "$PACKAGE_SNAPSHOT_BYTES" \
        "$PACKAGE_SNAPSHOT_SHA256" "$staged_bundle" \
        'locked package snapshot bundle'
    bundle_input=$staged_bundle
fi

staged_snapshot=
if (( snapshot_ready == 0 )); then
    snapshot_stage_root=$(mktemp -d \
        "$snapshot_version/.locked-input-$TARGET_NAME.XXXXXXXX")
    python3 "$snapshot_verifier" extract "$bundle_input" "$snapshot_stage_root" \
        "$IMMORTALWRT_VERSION" "$TARGET_NAME" \
        "$PACKAGE_SNAPSHOT_TREE_SHA256" >/dev/null
    staged_snapshot="$snapshot_stage_root/$IMMORTALWRT_VERSION/$TARGET_NAME"
fi

# Each object is published by a same-filesystem rename only after all missing
# inputs have passed their complete validation. A crash may leave a valid
# subset, which a subsequent invocation safely verifies and completes.
if [[ -n "$staged_bundle" ]]; then
    mv -Tn -- "$staged_bundle" "$bundle" || \
        die "cannot publish package snapshot bundle: $bundle"
    verify_locked_file "$bundle" "$PACKAGE_SNAPSHOT_BYTES" \
        "$PACKAGE_SNAPSHOT_SHA256" 'published package snapshot bundle'
fi
if [[ -n "$staged_snapshot" ]]; then
    mv -Tn -- "$staged_snapshot" "$snapshot" || \
        die "cannot publish package snapshot tree: $snapshot"
    python3 "$snapshot_verifier" verify "$snapshot" "$IMMORTALWRT_VERSION" \
        "$TARGET_NAME" "$PACKAGE_SNAPSHOT_TREE_SHA256" >/dev/null
fi
if [[ -n "$staged_imagebuilder" ]]; then
    mv -Tn -- "$staged_imagebuilder" "$archive" || \
        die "cannot publish ImageBuilder archive: $archive"
    verify_locked_file "$archive" "$IMAGEBUILDER_BYTES" "$IMAGEBUILDER_SHA256" \
        'published ImageBuilder'
fi

verify_locked_file "$archive" "$IMAGEBUILDER_BYTES" "$IMAGEBUILDER_SHA256" \
    'restored ImageBuilder'
python3 "$snapshot_verifier" verify "$snapshot" "$IMMORTALWRT_VERSION" \
    "$TARGET_NAME" "$PACKAGE_SNAPSHOT_TREE_SHA256" >/dev/null

printf 'Restored verified locked inputs for %s (%s)\n' \
    "$TARGET_NAME" "$IMMORTALWRT_VERSION"
