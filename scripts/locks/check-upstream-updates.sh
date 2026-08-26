#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

state_file=
output_file=
fixture_root=
stable_release_present=1
force_mode=auto
requested_stable=latest

usage() {
    cat <<'EOF'
usage: check-upstream-updates.sh [options]

Options:
  --state FILE                 Previous UPSTREAM_STATE.env, if one exists
  --output FILE                Write the new state to FILE instead of stdout
  --stable-release-present 0|1 Whether firmware-<locked-version> exists
  --force auto|stable|nightly|check
  --stable-version latest|X.Y.Z
  --fixture-root DIR           Read a mirrored download tree (tests only)
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --state)
            [[ $# -ge 2 ]] || die '--state requires a file'
            state_file=$2
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || die '--output requires a file'
            output_file=$2
            shift 2
            ;;
        --stable-release-present)
            [[ $# -ge 2 ]] || die '--stable-release-present requires 0 or 1'
            stable_release_present=$2
            shift 2
            ;;
        --force)
            [[ $# -ge 2 ]] || die '--force requires a mode'
            force_mode=$2
            shift 2
            ;;
        --stable-version)
            [[ $# -ge 2 ]] || die '--stable-version requires a value'
            requested_stable=$2
            shift 2
            ;;
        --fixture-root)
            [[ $# -ge 2 ]] || die '--fixture-root requires a directory'
            fixture_root=$2
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
done

[[ "$stable_release_present" == 0 || "$stable_release_present" == 1 ]] || \
    die '--stable-release-present must be 0 or 1'
case "$force_mode" in auto | stable | nightly | check) ;; *)
    die '--force must be auto, stable, nightly, or check'
esac
[[ "$requested_stable" == latest || \
   "$requested_stable" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die '--stable-version must be latest or X.Y.Z'

load_build_config
configure_network_environment
load_release_lock
require_command awk
require_command cmp
require_command curl
require_command mktemp
require_command python3
require_command sha256sum
require_command sleep
require_command sort
require_command stat

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/hmxf-upstream-check.XXXXXXXX")
cleanup() {
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

if [[ -n "$fixture_root" ]]; then
    fixture_root=$(realpath -e -- "$fixture_root")
    [[ -d "$fixture_root" && ! -L "$fixture_root" ]] || \
        die "fixture root is not a safe directory: $fixture_root"
fi

fetch_path() {
    local relative=${1:?relative upstream path required}
    local destination=${2:?destination required}
    local fixture_path
    [[ "$relative" =~ ^[A-Za-z0-9._/-]+$ && "$relative" != /* && \
       "/$relative/" != *'/../'* ]] || die "unsafe upstream path: $relative"
    if [[ -n "$fixture_root" ]]; then
        fixture_path="$fixture_root/$relative"
        if [[ -n "${fixture_sample:-}" && \
              -f "$fixture_root/.sample-$fixture_sample/$relative" && \
              ! -L "$fixture_root/.sample-$fixture_sample/$relative" ]]; then
            fixture_path="$fixture_root/.sample-$fixture_sample/$relative"
        fi
        [[ "$relative" != */ ]] || fixture_path="${fixture_path}index.html"
        [[ -f "$fixture_path" && ! -L "$fixture_path" ]] || \
            die "fixture is missing $relative"
        cp -- "$fixture_path" "$destination"
    else
        curl --disable --proto '=https' --proto-redir '=https' \
            --fail --location --silent --show-error \
            --retry 3 --retry-all-errors --max-filesize 33554432 \
            --output "$destination" \
            "$IMMORTALWRT_DOWNLOAD_URL/$relative"
    fi
    [[ -s "$destination" && ! -L "$destination" ]] || \
        die "upstream returned an empty or unsafe file: $relative"
}

try_fetch_path() {
    local relative=${1:?relative upstream path required}
    local destination=${2:?destination required}
    local fixture_path
    [[ "$relative" =~ ^[A-Za-z0-9._/-]+$ && "$relative" != /* && \
       "/$relative/" != *'/../'* ]] || return 1
    if [[ -n "$fixture_root" ]]; then
        fixture_path="$fixture_root/$relative"
        if [[ -n "${fixture_sample:-}" && \
              -f "$fixture_root/.sample-$fixture_sample/$relative" && \
              ! -L "$fixture_root/.sample-$fixture_sample/$relative" ]]; then
            fixture_path="$fixture_root/.sample-$fixture_sample/$relative"
        fi
        [[ "$relative" != */ ]] || fixture_path="${fixture_path}index.html"
        [[ -f "$fixture_path" && ! -L "$fixture_path" ]] || \
            return 1
        cp -- "$fixture_path" "$destination"
    else
        curl --disable --proto '=https' --proto-redir '=https' \
            --fail --location --silent --show-error \
            --retry 3 --retry-all-errors --max-filesize 33554432 \
            --output "$destination" \
            "$IMMORTALWRT_DOWNLOAD_URL/$relative" || return 1
    fi
    [[ -s "$destination" && ! -L "$destination" ]]
}

state_value() {
    local key=${1:?state key required}
    local file=${2:-$state_file}
    local value
    [[ -n "$file" && -f "$file" && ! -L "$file" ]] || return 1
    value=$(awk -F= -v wanted="$key" '
        $1 == wanted { count += 1; value = substr($0, length($1) + 2) }
        END { if (count == 1) print value; else exit 1 }
    ' "$file") || return 1
    [[ "$value" =~ ^[A-Za-z0-9._:/-]+$ ]] || return 1
    printf '%s\n' "$value"
}

release_index="$work_dir/releases.html"
fetch_path releases/ "$release_index"
latest_stable=$(python3 - "$release_index" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
versions = {
    match.group(1)
    for match in re.finditer(r'href=["\x27]([0-9]+\.[0-9]+\.[0-9]+)/["\x27]', text)
}
if not versions:
    raise SystemExit("official release index contains no stable X.Y.Z directory")
print(max(versions, key=lambda value: tuple(map(int, value.split(".")))))
PY
)
[[ "$latest_stable" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "invalid latest stable version: $latest_stable"
if [[ "$requested_stable" != latest ]]; then
    latest_stable=$requested_stable
fi

version_relation=$(python3 - "$IMMORTALWRT_VERSION" "$latest_stable" <<'PY'
import sys

locked = tuple(map(int, sys.argv[1].split(".")))
latest = tuple(map(int, sys.argv[2].split(".")))
print("newer" if latest > locked else "same" if latest == locked else "older")
PY
)
[[ "$version_relation" != older ]] || \
    die "requested stable $latest_stable is older than locked $IMMORTALWRT_VERSION"

target_specs=(
    'x86_64|x86|64'
    'rpi4|bcm27xx|bcm2711'
    'rpi5|bcm27xx|bcm2712'
)

verify_release_ready() {
    local version=${1:?stable version required}
    local spec name target subtarget checksum_file expected_file digest
    for spec in "${target_specs[@]}"; do
        IFS='|' read -r name target subtarget <<< "$spec"
        checksum_file="$work_dir/stable-$name.sha256sums"
        if ! try_fetch_path \
                "releases/$version/targets/$target/$subtarget/sha256sums" \
                "$checksum_file"; then
            printf 'Stable %s is still missing checksums for %s.\n' \
                "$version" "$name" >&2
            return 1
        fi
        expected_file="immortalwrt-imagebuilder-$version-$target-$subtarget.Linux-x86_64.tar.zst"
        if ! digest=$(awk -v wanted="$expected_file" '
            NF == 2 {
                name = $2
                sub(/^\*/, "", name)
                if (name == wanted) {
                    count += 1
                    value = $1
                }
            }
            END { if (count == 1) print value; else exit 1 }
        ' "$checksum_file"); then
            printf 'Stable %s is still missing %s.\n' \
                "$version" "$expected_file" >&2
            return 1
        fi
        if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
            printf 'Stable %s has an invalid ImageBuilder digest for %s.\n' \
                "$version" "$name" >&2
            return 1
        fi
    done
}

channel=none
reason=unchanged
if [[ "$force_mode" == stable || \
      ( "$force_mode" == auto && \
        ( "$version_relation" == newer || \
          "$version_relation" == same && "$stable_release_present" == 0 ) ) ]]; then
    if verify_release_ready "$latest_stable"; then
        channel=stable
        if [[ "$force_mode" == stable ]]; then
            reason=manual-stable
        elif [[ "$version_relation" == newer ]]; then
            reason=new-stable
        else
            reason=missing-stable-firmware-release
        fi
    else
        channel=deferred
        reason=stable-publishing-in-progress
    fi
fi

snapshot_revision=
snapshot_commit=
snapshot_feeds_sha256=
snapshot_targets_sha256=
snapshot_packages_sha256=
snapshot_fingerprint=
snapshot_ready=1
declare -A snapshot_files=()
declare -A snapshot_digests=()
fixture_sample=

snapshot_sample_unready() {
    printf 'Snapshot publication is not yet consistent: %s.\n' "$1" >&2
    sample_ready=0
    fixture_sample=
}

checksum_entry() {
    local checksum_file=${1:?checksum file required}
    local wanted=${2:?checksum entry required}
    awk -v wanted="$wanted" '
        NF == 2 {
            name = $2
            sub(/^\*/, "", name)
            if (name == wanted) {
                count += 1
                value = $1
            }
        }
        END { if (count == 1) print value; else exit 1 }
    ' "$checksum_file"
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

collect_snapshot_sample() {
    local sample_number=${1:?sample number required}
    local sample_dir=${2:?sample directory required}
    local common_revision='' common_commit='' common_feeds=''
    local common_source_epoch=''
    local common_kernel_version='' common_kernel_release=''
    local spec name target subtarget expected_arch target_dir
    local version_file feeds_file profiles_file checksum_file revision
    local imagebuilder_file imagebuilder_digest metadata_name metadata_path
    local metadata_digest feeds_digest profile_values profile_arch
    local profile_kernel_version profile_kernel_release profile_kernel_vermagic
    local profile_revision profile_commit profile_source_epoch revision_commit
    local feed_names repository_paths repository_path package_index
    local package_digest package_url targets_sha packages_sha
    local package_row_count

    sample_ready=1
    fixture_sample=$sample_number
    mkdir -p -- "$sample_dir/package-indexes" || die 'cannot create snapshot sample'
    : > "$sample_dir/targets.txt"
    : > "$sample_dir/packages.raw"

    local -a snapshot_target_specs=(
        'x86_64|x86|64|x86_64'
        'rpi4|bcm27xx|bcm2711|aarch64_cortex-a72'
        'rpi5|bcm27xx|bcm2712|aarch64_cortex-a76'
    )
    for spec in "${snapshot_target_specs[@]}"; do
        IFS='|' read -r name target subtarget expected_arch <<< "$spec"
        target_dir="snapshots/targets/$target/$subtarget"
        version_file="$sample_dir/$name.version.buildinfo"
        feeds_file="$sample_dir/$name.feeds.buildinfo"
        profiles_file="$sample_dir/$name.profiles.json"
        checksum_file="$sample_dir/$name.sha256sums"
        if ! try_fetch_path "$target_dir/version.buildinfo" "$version_file" ||
           ! try_fetch_path "$target_dir/feeds.buildinfo" "$feeds_file" ||
           ! try_fetch_path "$target_dir/profiles.json" "$profiles_file" ||
           ! try_fetch_path "$target_dir/sha256sums" "$checksum_file"; then
            snapshot_sample_unready "metadata is incomplete for $name"
            return 0
        fi

        revision=$(sed -n '1p' "$version_file")
        if [[ $(wc -l < "$version_file") != 1 ||
              ! "$revision" =~ ^r[0-9]+-[0-9a-f]{7,40}$ ]]; then
            snapshot_sample_unready "version metadata is invalid for $name"
            return 0
        fi
        if ! awk '
            NF != 3 || $1 !~ /^src-git(-full)?$/ ||
              $2 !~ /^[A-Za-z0-9._-]+$/ || $2 == "base" ||
              $3 !~ /^https:\/\/[^[:space:]]+[.]git\^[0-9a-f]{40}$/ {
                exit 1
            }
            { key = $2; if (seen[key]++) exit 1 }
            END { if (NR == 0) exit 1 }
        ' "$feeds_file"; then
            snapshot_sample_unready "feed metadata is invalid for $name"
            return 0
        fi

        imagebuilder_file="immortalwrt-imagebuilder-$target-$subtarget.Linux-x86_64.tar.zst"
        if ! imagebuilder_digest=$(checksum_entry "$checksum_file" \
                "$imagebuilder_file") ||
           [[ ! "$imagebuilder_digest" =~ ^[0-9a-f]{64}$ ]]; then
            snapshot_sample_unready "ImageBuilder checksum is missing for $name"
            return 0
        fi

        for metadata_name in version.buildinfo feeds.buildinfo profiles.json; do
            case "$metadata_name" in
                version.buildinfo) metadata_path=$version_file ;;
                feeds.buildinfo) metadata_path=$feeds_file ;;
                profiles.json) metadata_path=$profiles_file ;;
            esac
            if ! metadata_digest=$(checksum_entry "$checksum_file" \
                    "$metadata_name") ||
               [[ ! "$metadata_digest" =~ ^[0-9a-f]{64}$ ]] ||
               [[ $(sha256sum "$metadata_path" | awk '{ print $1 }') != \
                    "$metadata_digest" ]]; then
                snapshot_sample_unready \
                    "$metadata_name is not checksum-bound for $name"
                return 0
            fi
        done

        if ! profile_values=$(python3 - "$profiles_file" <<'PY'
import json
from pathlib import Path
import re
import sys

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
kernel = data.get("linux_kernel")
values = (
    data.get("arch_packages"),
    kernel.get("version") if isinstance(kernel, dict) else None,
    kernel.get("release") if isinstance(kernel, dict) else None,
    kernel.get("vermagic") if isinstance(kernel, dict) else None,
    data.get("version_code"),
    data.get("git_commit"),
    data.get("source_date_epoch"),
)
patterns = (
    r"[A-Za-z0-9._+-]+",
    r"[0-9]+\.[0-9]+\.[0-9]+",
    r"[1-9][0-9]*",
    r"[0-9a-f]{32}",
    r"r[0-9]+-[0-9a-f]{7,40}",
    r"[0-9a-f]{40}",
)
if any(not isinstance(value, str) for value in values[:6]):
    raise SystemExit(1)
if any(re.fullmatch(pattern, value) is None
       for pattern, value in zip(patterns, values[:6])):
    raise SystemExit(1)
if isinstance(values[6], str) and re.fullmatch(r"[1-9][0-9]*", values[6]):
    values = (*values[:6], int(values[6]))
if not isinstance(values[6], int) or isinstance(values[6], bool) or values[6] <= 0:
    raise SystemExit(1)
print("|".join(map(str, values)))
PY
        ); then
            snapshot_sample_unready "profiles metadata is invalid for $name"
            return 0
        fi
        IFS='|' read -r profile_arch profile_kernel_version \
            profile_kernel_release profile_kernel_vermagic profile_revision \
            profile_commit profile_source_epoch <<< "$profile_values"
        revision_commit=${revision#*-}
        if [[ "$profile_arch" != "$expected_arch" ||
              "$profile_revision" != "$revision" ||
              "${profile_commit:0:${#revision_commit}}" != "$revision_commit" ]]; then
            snapshot_sample_unready \
                "profiles/source identity differs for $name"
            return 0
        fi

        feeds_digest=$(sha256sum "$feeds_file" | awk '{ print $1 }')
        if [[ -z "$common_revision" ]]; then
            common_revision=$revision
            common_commit=$profile_commit
            common_feeds=$feeds_digest
            common_source_epoch=$profile_source_epoch
            common_kernel_version=$profile_kernel_version
            common_kernel_release=$profile_kernel_release
            cp -- "$feeds_file" "$sample_dir/common-feeds.buildinfo"
        elif [[ "$revision" != "$common_revision" ||
                "$profile_commit" != "$common_commit" ||
                "$feeds_digest" != "$common_feeds" ||
                "$profile_source_epoch" != "$common_source_epoch" ||
                "$profile_kernel_version" != "$common_kernel_version" ||
                "$profile_kernel_release" != "$common_kernel_release" ]]; then
            snapshot_sample_unready \
                'target source/feed/kernel views are not synchronized'
            return 0
        fi

        feed_names="$sample_dir/$name.feed-names"
        awk '{ print $2 }' "$feeds_file" | sort -u > "$feed_names"
        repository_paths="$sample_dir/$name.repository-paths"
        {
            printf 'snapshots/targets/%s/%s/packages/packages.adb\n' \
                "$target" "$subtarget"
            printf 'snapshots/targets/%s/%s/kmods/%s-%s-%s/packages.adb\n' \
                "$target" "$subtarget" "$profile_kernel_version" \
                "$profile_kernel_release" "$profile_kernel_vermagic"
            printf 'snapshots/packages/%s/base/packages.adb\n' "$profile_arch"
            while IFS= read -r metadata_name; do
                printf 'snapshots/packages/%s/%s/packages.adb\n' \
                    "$profile_arch" "$metadata_name"
            done < "$feed_names"
        } | sort -u > "$repository_paths"

        package_row_count=0
        while IFS= read -r repository_path; do
            package_row_count=$((package_row_count + 1))
            package_index="$sample_dir/package-indexes/$name-$package_row_count.adb"
            if ! try_fetch_path "$repository_path" "$package_index" ||
               ! validate_package_index "$package_index"; then
                snapshot_sample_unready \
                    "package index is unavailable or invalid: $repository_path"
                return 0
            fi
            package_digest=$(sha256sum "$package_index" | awk '{ print $1 }')
            package_url="$IMMORTALWRT_DOWNLOAD_URL/$repository_path"
            printf '%s|%s\n' "$package_url" "$package_digest" \
                >> "$sample_dir/packages.raw"
        done < "$repository_paths"
        if (( package_row_count < 4 || package_row_count > 64 )); then
            snapshot_sample_unready \
                "repository count is unsafe for $name: $package_row_count"
            return 0
        fi

        printf '%s|%s|%s\n' "$name" "$imagebuilder_file" \
            "$imagebuilder_digest" >> "$sample_dir/targets.txt"
    done

    sort -u "$sample_dir/packages.raw" > "$sample_dir/packages.txt"
    if [[ ! -s "$sample_dir/packages.txt" ]]; then
        snapshot_sample_unready 'package index identity is empty'
        return 0
    fi
    targets_sha=$(sha256sum "$sample_dir/targets.txt" | awk '{ print $1 }')
    packages_sha=$(sha256sum "$sample_dir/packages.txt" | awk '{ print $1 }')
    {
        printf 'SNAPSHOT_VERSION_CODE=%s\n' "$common_revision"
        printf 'SNAPSHOT_SOURCE_COMMIT=%s\n' "$common_commit"
        printf 'SNAPSHOT_FEEDS_SHA256=%s\n' "$common_feeds"
        printf 'SNAPSHOT_TARGETS_SHA256=%s\n' "$targets_sha"
        printf 'SNAPSHOT_PACKAGES_SHA256=%s\n' "$packages_sha"
    } > "$sample_dir/identity.env"
    fixture_sample=
}

if [[ "$channel" != stable && "$channel" != deferred ]]; then
    first_sample="$work_dir/snapshot-sample-1"
    second_sample="$work_dir/snapshot-sample-2"
    collect_snapshot_sample 1 "$first_sample"
    if (( sample_ready == 1 )); then
        if [[ -z "$fixture_root" ]]; then
            # Two complete byte samples plus a short quiet interval avoid
            # classifying a rolling CDN publication while it is changing.
            sleep 5
        fi
        collect_snapshot_sample 2 "$second_sample"
    fi
    if (( sample_ready == 0 )) ||
       ! cmp -s "$first_sample/identity.env" "$second_sample/identity.env" ||
       ! cmp -s "$first_sample/targets.txt" "$second_sample/targets.txt" ||
       ! cmp -s "$first_sample/packages.txt" "$second_sample/packages.txt"; then
        snapshot_ready=0
        channel=none
        reason=snapshot-publishing-in-progress
    else
        snapshot_revision=$(awk -F= '$1 == "SNAPSHOT_VERSION_CODE" { print $2 }' \
            "$first_sample/identity.env")
        snapshot_commit=$(awk -F= \
            '$1 == "SNAPSHOT_SOURCE_COMMIT" { print $2 }' \
            "$first_sample/identity.env")
        snapshot_feeds_sha256=$(awk -F= \
            '$1 == "SNAPSHOT_FEEDS_SHA256" { print $2 }' \
            "$first_sample/identity.env")
        snapshot_targets_sha256=$(awk -F= \
            '$1 == "SNAPSHOT_TARGETS_SHA256" { print $2 }' \
            "$first_sample/identity.env")
        snapshot_packages_sha256=$(awk -F= \
            '$1 == "SNAPSHOT_PACKAGES_SHA256" { print $2 }' \
            "$first_sample/identity.env")
        [[ "$snapshot_commit" =~ ^[0-9a-f]{40}$ ]] || \
            die 'synchronized snapshot has no full source commit identity'
        snapshot_fingerprint=$(printf '%s\n%s\n%s\n%s\n%s\n' \
            "$snapshot_revision" "$snapshot_commit" \
            "$snapshot_feeds_sha256" "$snapshot_targets_sha256" \
            "$snapshot_packages_sha256" | \
            sha256sum | awk '{ print $1 }')
        while IFS='|' read -r name imagebuilder_file imagebuilder_digest; do
            snapshot_files[$name]=$imagebuilder_file
            snapshot_digests[$name]=$imagebuilder_digest
        done < "$first_sample/targets.txt"
    fi
fi

if [[ "$channel" != stable && "$channel" != deferred && $snapshot_ready -eq 1 ]]; then
    previous_fingerprint=$(state_value SNAPSHOT_FINGERPRINT 2>/dev/null || true)
    previous_revision=$(state_value SNAPSHOT_VERSION_CODE 2>/dev/null || true)
    previous_commit=$(state_value SNAPSHOT_SOURCE_COMMIT 2>/dev/null || true)
    previous_feeds=$(state_value SNAPSHOT_FEEDS_SHA256 2>/dev/null || true)
    previous_packages=$(state_value SNAPSHOT_PACKAGES_SHA256 2>/dev/null || true)
    if [[ "$force_mode" == nightly ]]; then
        channel=nightly
        reason=manual-nightly
    elif [[ "$force_mode" == check ]]; then
        channel=none
        reason=check-only
    elif [[ "$snapshot_fingerprint" != "$previous_fingerprint" ]]; then
        channel=nightly
        if [[ -z "$previous_fingerprint" ]]; then
            reason=no-previous-nightly
        elif [[ "$snapshot_commit" != "$previous_commit" ||
                "$snapshot_revision" != "$previous_revision" ]]; then
            reason=snapshot-source-update
        elif [[ "$snapshot_feeds_sha256" != "$previous_feeds" ]]; then
            reason=snapshot-feed-update
        elif [[ "$snapshot_packages_sha256" != "$previous_packages" ]]; then
            reason=snapshot-package-update
        else
            reason=snapshot-binary-update
        fi
    else
        channel=none
        reason=unchanged
    fi
fi

state_output="$work_dir/UPSTREAM_STATE.env"
{
    printf 'STATE_SCHEMA=1\n'
    printf 'CHANNEL=%s\n' "$channel"
    printf 'REASON=%s\n' "$reason"
    printf 'LOCKED_STABLE_VERSION=%s\n' "$IMMORTALWRT_VERSION"
    printf 'LATEST_STABLE_VERSION=%s\n' "$latest_stable"
    if [[ -n "$snapshot_fingerprint" ]]; then
        printf 'SNAPSHOT_VERSION_CODE=%s\n' "$snapshot_revision"
        printf 'SNAPSHOT_SOURCE_COMMIT=%s\n' "$snapshot_commit"
        printf 'SNAPSHOT_FEEDS_SHA256=%s\n' "$snapshot_feeds_sha256"
        printf 'SNAPSHOT_TARGETS_SHA256=%s\n' "$snapshot_targets_sha256"
        printf 'SNAPSHOT_PACKAGES_SHA256=%s\n' "$snapshot_packages_sha256"
        printf 'SNAPSHOT_FINGERPRINT=%s\n' "$snapshot_fingerprint"
        for name in x86_64 rpi4 rpi5; do
            key=${name^^}
            printf 'NIGHTLY_IMAGEBUILDER_%s_FILE=%s\n' "$key" \
                "${snapshot_files[$name]}"
            printf 'NIGHTLY_IMAGEBUILDER_%s_SHA256=%s\n' "$key" \
                "${snapshot_digests[$name]}"
        done
    fi
} > "$state_output"

if [[ -n "$output_file" ]]; then
    output_parent=$(dirname -- "$output_file")
    mkdir -p -- "$output_parent"
    output_file=$(realpath -m -- "$output_file")
    output_tmp=$(mktemp "$output_parent/.UPSTREAM_STATE.env.XXXXXXXX")
    cp -- "$state_output" "$output_tmp"
    chmod 0644 "$output_tmp"
    mv -- "$output_tmp" "$output_file"
else
    cat "$state_output"
fi
