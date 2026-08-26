#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

TESTS_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TESTS_ROOT/.." && pwd)
BUILD_SCRIPT="$PROJECT_ROOT/scripts/build/build-imagebuilder.sh"
PRODUCTION_CONFIG="$PROJECT_ROOT/configs/build.env"
OUTPUT_ROOT="$PROJECT_ROOT/build/test-results/firmware"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./tests/run-build.sh [canonical|development] matrix
  ./tests/run-build.sh [canonical|development] DEVICE PRESET

The mode defaults to canonical. DEVICE is x86_64, rpi4, or rpi5; PRESET is
minimal or full. Results are published below build/test-results/firmware/.

Examples:
  ./tests/run-build.sh matrix
  ./tests/run-build.sh canonical x86_64 minimal
  ./tests/run-build.sh development rpi5 full
EOF
}

[[ -f "$BUILD_SCRIPT" && ! -L "$BUILD_SCRIPT" && -x "$BUILD_SCRIPT" ]] || \
    die "build entry is missing, unsafe, or not executable: $BUILD_SCRIPT"
[[ -f "$PRODUCTION_CONFIG" && ! -L "$PRODUCTION_CONFIG" ]] || \
    die "production build configuration is missing or unsafe: $PRODUCTION_CONFIG"

mode=canonical
if [[ ${1:-} == canonical || ${1:-} == development ]]; then
    mode=$1
    shift
fi

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi

declare -a combinations=()
if [[ $# == 1 && $1 == matrix ]]; then
    combinations=(
        x86_64:minimal
        x86_64:full
        rpi4:minimal
        rpi4:full
        rpi5:minimal
        rpi5:full
    )
elif [[ $# == 2 ]]; then
    device=$1
    preset=$2
    case "$device" in
        x86_64 | rpi4 | rpi5) ;;
        *)
            usage >&2
            die "unsupported device: $device"
            ;;
    esac
    case "$preset" in
        minimal | full) ;;
        *)
            usage >&2
            die "unsupported preset: $preset"
            ;;
    esac
    combinations=("$device:$preset")
else
    usage >&2
    exit 2
fi

if [[ "$mode" == canonical && -n ${EXTRA_PACKAGES:-} ]]; then
    die 'canonical test builds do not accept EXTRA_PACKAGES'
fi
if [[ ${#combinations[@]} -gt 1 && -n ${EXTRA_PACKAGES:-} ]]; then
    die 'EXTRA_PACKAGES is only supported for one explicit development DEVICE/PRESET build'
fi

# Build-policy environment variables override configs/build.env in the production
# loader. Remove inherited policy state so each named test mode has one precise
# meaning; storage locations and locked-input source variables remain available.
unset CHECK_LATEST_ON_BUILD ARTIFACT_LOCK_POLICY PACKAGE_REPOSITORY_MODE \
    PACKAGE_CACHE_INDEX SOURCE_FETCH_MODE SOURCE_FETCH_POLICY \
    SOURCE_FEED_CACHE_MODE SOURCE_KMOD_SCOPE SOURCE_FAILURE_DIAGNOSTICS \
    RUN_X86_SMOKE_TEST REQUIRE_CLEAN_PROJECT REQUIRE_SHELLCHECK KEEP_BUILD \
    IMAGEBUILDER_RETRIES SOURCE_FEED_RETRIES NETWORK_PROXY_MODE \
    BUILD_CONFIG CONFIGS_DIR LOCKS_DIR OUTPUT_DIR

"$TESTS_ROOT/run.sh" static

release_version=$(awk -F= '
    $1 == "IMMORTALWRT_VERSION" { count += 1; value = $2 }
    END {
        if (count == 1 && value ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) print value
        else exit 1
    }
' "$PROJECT_ROOT/locks/release.env") || die 'cannot resolve the locked release version'

read_build_info_value() {
    local info=${1:?BUILD_INFO path required}
    local key=${2:?BUILD_INFO key required}
    awk -F= -v key="$key" '
        $1 == key { count += 1; value = substr($0, index($0, "=") + 1) }
        END { if (count == 1) print value; else exit 1 }
    ' "$info"
}

verify_build_identity() {
    local device=${1:?device required}
    local preset=${2:?preset required}
    local info="$OUTPUT_ROOT/$release_version/$device/$preset/BUILD_INFO.txt"
    local canonical candidate development

    [[ -f "$info" && ! -L "$info" ]] || die "build did not publish a safe BUILD_INFO: $info"
    canonical=$(read_build_info_value "$info" canonical_build) || \
        die "BUILD_INFO has no unique canonical_build field: $info"
    candidate=$(read_build_info_value "$info" candidate_build) || \
        die "BUILD_INFO has no unique candidate_build field: $info"
    development=$(read_build_info_value "$info" development_build) || \
        die "BUILD_INFO has no unique development_build field: $info"

    [[ "$candidate" == 0 ]] || die "$device/$preset unexpectedly produced a candidate build"
    if [[ "$mode" == canonical ]]; then
        [[ "$canonical" == 1 && "$development" == 0 ]] || \
            die "$device/$preset did not produce a canonical build"
    else
        [[ "$canonical" == 0 && "$development" == 1 ]] || \
            die "$device/$preset did not produce a development build"
    fi
}

run_one_build() {
    local combination=${1:?combination required}
    local device=${combination%%:*}
    local preset=${combination#*:}

    printf '\n==> Building %s/%s in %s mode\n' "$device" "$preset" "$mode"
    if [[ "$mode" == canonical ]]; then
        BUILD_CONFIG="$PRODUCTION_CONFIG" \
        OUTPUT_ROOT="$OUTPUT_ROOT" \
            "$BUILD_SCRIPT" "$device" "$preset"
    else
        BUILD_CONFIG="$PRODUCTION_CONFIG" \
        REQUIRE_CLEAN_PROJECT=0 \
        OUTPUT_ROOT="$OUTPUT_ROOT" \
            "$BUILD_SCRIPT" "$device" "$preset"
    fi
    verify_build_identity "$device" "$preset"
}

for combination in "${combinations[@]}"; do
    run_one_build "$combination"
done

printf '\n%s firmware test build passed; results: %s\n' \
    "$mode" "${OUTPUT_ROOT#"$PROJECT_ROOT/"}"
