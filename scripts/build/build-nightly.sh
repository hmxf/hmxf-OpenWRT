#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

state_arg=${1:?usage: build-nightly.sh UPSTREAM_STATE.env [matrix|capture|rebuild TARGET|TARGET PRESET]}
selection=${2:-matrix}
preset_arg=${3:-}
[[ $# -le 3 ]] || die 'too many nightly build arguments'
state_file=$(realpath -e -- "$state_arg")

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

[[ $(state_value CHANNEL) == nightly ]] || die 'state does not request a nightly build'
upstream_fingerprint=$(state_value SNAPSHOT_FINGERPRINT)
[[ "$upstream_fingerprint" =~ ^[0-9a-f]{64}$ ]] || \
    die 'invalid upstream nightly fingerprint'

"$VERIFY_SCRIPTS_DIR/validate-project.sh"
upstream_root="$PROJECT_ROOT/build/nightly/$upstream_fingerprint"

case "$selection" in
    matrix)
        [[ -z "$preset_arg" ]] || die 'matrix does not accept a preset argument'
        action=capture-and-rebuild
        combinations=(
            'x86_64|full' 'x86_64|minimal'
            'rpi4|full' 'rpi4|minimal'
            'rpi5|full' 'rpi5|minimal'
        )
        ;;
    capture)
        [[ -z "$preset_arg" ]] || die 'capture does not accept another argument'
        action=capture-only
        combinations=()
        ;;
    rebuild)
        case "$preset_arg" in x86_64 | rpi4 | rpi5) ;; *)
            die 'rebuild requires target x86_64, rpi4, or rpi5'
        esac
        action=rebuild-only
        combinations=("$preset_arg|full" "$preset_arg|minimal")
        ;;
    x86_64 | rpi4 | rpi5)
        case "$preset_arg" in minimal | full) ;; *)
            die 'a single nightly target requires minimal or full'
        esac
        action=capture-and-rebuild
        combinations=("$selection|$preset_arg")
        ;;
    *) die 'nightly selection must be matrix, capture, rebuild, or a target' ;;
esac

build_value() {
    local file=${1:?nightly build-state file required}
    local key=${2:?nightly build-state key required}
    awk -F= -v wanted="$key" '
        $1 == wanted { count += 1; value = substr($0, length($1) + 2) }
        END { if (count == 1) print value; else exit 1 }
    ' "$file" || die "final nightly state is missing unique key $key"
}

load_final_inputs() {
    local pointer="$upstream_root/NIGHTLY_BUILD_POINTER.env"
    local calculated_fingerprint plan_inputs_sha256

    [[ -f "$pointer" && ! -L "$pointer" && $(wc -l < "$pointer") == 6 ]] || \
        die "nightly final-input pointer is missing or unsafe: $pointer"
    fingerprint=$(build_value "$pointer" NIGHTLY_FINGERPRINT)
    [[ "$fingerprint" =~ ^[0-9a-f]{64}$ && \
       "$fingerprint" != "$upstream_fingerprint" ]] || \
        die 'nightly final-input pointer has an invalid fingerprint'
    final_root="$PROJECT_ROOT/build/nightly/$fingerprint"
    context_dir="$final_root/context"
    build_state="$final_root/NIGHTLY_BUILD.env"
    [[ -d "$context_dir/locks" && ! -L "$context_dir" && \
       -f "$build_state" && ! -L "$build_state" && \
       -d "$final_root/imagebuilders" && ! -L "$final_root/imagebuilders" ]] || \
        die 'nightly final inputs are incomplete or unsafe'
    cmp -s "$pointer" "$build_state" || \
        die 'nightly final-input pointer differs from its build state'
    [[ $(build_value "$build_state" NIGHTLY_BUILD_SCHEMA) == 1 && \
       $(build_value "$build_state" UPSTREAM_FINGERPRINT) == \
           "$upstream_fingerprint" && \
       $(build_value "$build_state" NIGHTLY_FINGERPRINT) == "$fingerprint" ]] || \
        die 'final nightly state does not match its upstream/build identity'
    cmp -s "$state_file" "$context_dir/UPSTREAM_STATE.env" || \
        die 'final nightly context differs from the requested upstream state'
    package_snapshots_sha256=$(build_value \
        "$build_state" PACKAGE_SNAPSHOTS_SHA256)
    package_snapshot_lock_sha256=$(build_value \
        "$build_state" PACKAGE_SNAPSHOT_LOCK_SHA256)
    plan_inputs_sha256=$(build_value "$build_state" PLAN_INPUTS_SHA256)
    [[ "$package_snapshots_sha256" =~ ^[0-9a-f]{64}$ && \
       "$package_snapshot_lock_sha256" =~ ^[0-9a-f]{64}$ && \
       "$plan_inputs_sha256" =~ ^[0-9a-f]{64}$ && \
       $(sha256sum "$context_dir/locks/package-snapshots.tsv" | \
           awk '{ print $1 }') == "$package_snapshot_lock_sha256" && \
       $("$INPUT_SCRIPTS_DIR/nightly-build-identity.sh" content \
           "$context_dir/locks/package-snapshots.tsv") == \
           "$package_snapshots_sha256" && \
       $(sha256sum "$context_dir/PLAN_INPUTS.sha256" | awk '{ print $1 }') == \
           "$plan_inputs_sha256" ]] || \
        die 'final nightly package/plan identity is inconsistent'
    calculated_fingerprint=$(
        "$INPUT_SCRIPTS_DIR/nightly-build-identity.sh" fingerprint \
            "$upstream_fingerprint" "$context_dir/PLAN_INPUTS.sha256" \
            "$context_dir/locks/package-snapshots.tsv"
    )
    [[ "$calculated_fingerprint" == "$fingerprint" ]] || \
        die 'final nightly fingerprint formula does not match its inputs'
    context_index_sha256=$(sha256sum "$context_dir/CONTEXT.sha256" \
        | awk '{ print $1 }')
    (
        cd "$context_dir"
        sha256sum --strict --quiet -c CONTEXT.sha256
    ) || die 'final nightly context failed checksum verification'
}

capture_inputs() {
    local capture_context capture_context_sha capture_output combination
    local target preset output_dir returned_fingerprint
    local download_dir package_cache_root
    local -a capture_combinations=(
        'x86_64|full' 'x86_64|minimal'
        'rpi4|full' 'rpi4|minimal'
        'rpi5|full' 'rpi5|minimal'
    )

    capture_context=$(BUILD_CONFIG=configs/build-nightly.env \
        DOWNLOAD_DIR="${DOWNLOAD_DIR:-$PROJECT_ROOT/.cache/nightly/imagebuilders/$upstream_fingerprint}" \
        "$BUILD_SCRIPTS_DIR/prepare-nightly-context.sh" "$state_file")
    [[ "$capture_context" == "$upstream_root/context" && \
       -d "$capture_context/locks" ]] || \
        die 'nightly context helper returned an unsafe path'
    capture_context_sha=$(sha256sum "$capture_context/CONTEXT.sha256" \
        | awk '{ print $1 }')
    [[ "$capture_context_sha" =~ ^[0-9a-f]{64}$ ]] || \
        die 'nightly capture context has an invalid checksum-index identity'

    nightly_build_lock="$upstream_root/.nightly-build.lock"
    require_regular_file_or_absent "$nightly_build_lock" 'nightly build lock'
    exec {nightly_build_lock_fd}>"$nightly_build_lock"
    flock "$nightly_build_lock_fd"
    if [[ -f "$upstream_root/NIGHTLY_BUILD_POINTER.env" ]]; then
        load_final_inputs
        flock -u "$nightly_build_lock_fd"
        return
    fi

    download_dir=${DOWNLOAD_DIR:-"$PROJECT_ROOT/.cache/nightly/imagebuilders/$upstream_fingerprint"}
    package_cache_root=${PACKAGE_CACHE_ROOT:-"$PROJECT_ROOT/.cache/nightly/packages/$upstream_fingerprint"}
    capture_output="$upstream_root/capture-out/SNAPSHOT"
    for combination in "${capture_combinations[@]}"; do
        IFS='|' read -r target preset <<< "$combination"
        output_dir="$capture_output/$target/$preset"
        printf '\n==> Resolving nightly packages %s/%s (%s)\n' \
            "$target" "$preset" "${upstream_fingerprint:0:16}"
        BUILD_CHANNEL=nightly \
        NIGHTLY_FINGERPRINT="$upstream_fingerprint" \
        NIGHTLY_CONTEXT_SHA256="$capture_context_sha" \
        BUILD_CONFIG=configs/build-nightly.env \
        LOCKS_DIR="$capture_context/locks" \
        CONFIGS_DIR="$PROJECT_ROOT/configs" \
        DOWNLOAD_DIR="$download_dir" \
        PACKAGE_CACHE_DIR="$package_cache_root/SNAPSHOT/$target" \
        OUTPUT_DIR="$output_dir" \
            "$BUILD_SCRIPTS_DIR/build-imagebuilder.sh" "$target" "$preset"
    done

    returned_fingerprint=$(BUILD_CONFIG=configs/build-nightly.env \
        "$INPUT_SCRIPTS_DIR/capture-nightly-package-snapshots.sh" \
        "$upstream_fingerprint" "$capture_context" "$capture_output" \
        "$package_cache_root" "$download_dir")
    [[ "$returned_fingerprint" =~ ^[0-9a-f]{64}$ ]] || \
        die 'nightly package capture returned an invalid final fingerprint'
    rm -rf -- "$upstream_root/capture-out"
    load_final_inputs
    [[ "$fingerprint" == "$returned_fingerprint" ]] || \
        die 'nightly package capture/pointer fingerprint mismatch'
    flock -u "$nightly_build_lock_fd"
}

publish_provenance() {
    local output_root="$final_root/out"
    mkdir -p -- "$output_root"
    cp -- "$state_file" "$output_root/UPSTREAM_STATE.env"
    cp -- "$build_state" "$output_root/NIGHTLY_BUILD.env"
    cp -- "$context_dir/locks/release.env" "$output_root/NIGHTLY_RELEASE.env"
    cp -- "$context_dir/locks/targets.tsv" "$output_root/NIGHTLY_TARGETS.tsv"
    cp -- "$context_dir/locks/feeds.tsv" "$output_root/NIGHTLY_FEEDS.tsv"
    cp -- "$context_dir/locks/package-snapshots.tsv" \
        "$output_root/NIGHTLY_PACKAGE_SNAPSHOTS.tsv"
    cp -- "$context_dir/PLAN_INPUTS.sha256" "$output_root/PLAN_INPUTS.sha256"
    cp -- "$context_dir/PLAN_INPUT_REVISION.txt" \
        "$output_root/PLAN_INPUT_REVISION.txt"
    cp -- "$context_dir/CONTEXT.sha256" "$output_root/NIGHTLY_CONTEXT.sha256"
    chmod 0644 "$output_root"/*.env "$output_root"/*.sha256 \
        "$output_root"/*.tsv "$output_root"/*.txt
}

if [[ "$action" == capture-only || "$action" == capture-and-rebuild ]]; then
    capture_inputs
else
    load_final_inputs
fi

if [[ "$action" == capture-only ]]; then
    printf 'NIGHTLY_FINGERPRINT=%s\n' "$fingerprint"
    printf 'Frozen nightly inputs are in %s\n' "$final_root"
    exit 0
fi

output_root="$final_root/out"
download_dir="$final_root/imagebuilders"
for combination in "${combinations[@]}"; do
    IFS='|' read -r target preset <<< "$combination"
    output_dir="$output_root/SNAPSHOT/$target/$preset"
    printf '\n==> Building frozen nightly %s/%s (%s)\n' \
        "$target" "$preset" "${fingerprint:0:16}"
    BUILD_CHANNEL=nightly \
    NIGHTLY_FINGERPRINT="$fingerprint" \
    NIGHTLY_CONTEXT_SHA256="$context_index_sha256" \
    NIGHTLY_PACKAGE_SNAPSHOTS_SHA256="$package_snapshots_sha256" \
    NIGHTLY_PACKAGE_SNAPSHOT_LOCK_SHA256="$package_snapshot_lock_sha256" \
    BUILD_CONFIG=configs/build-nightly.env \
    ARTIFACT_LOCK_POLICY=enforce \
    PACKAGE_REPOSITORY_MODE=snapshot \
    PACKAGE_CACHE_INDEX=0 \
    LOCKS_DIR="$context_dir/locks" \
    CONFIGS_DIR="$PROJECT_ROOT/configs" \
    DOWNLOAD_DIR="$download_dir" \
    PACKAGE_SNAPSHOT_DIR="$final_root/package-snapshots" \
    PACKAGE_SNAPSHOT_BUNDLE_DIR="$final_root/package-snapshot-bundles" \
    OUTPUT_DIR="$output_dir" \
        "$BUILD_SCRIPTS_DIR/build-imagebuilder.sh" "$target" "$preset"
done

publish_provenance
printf 'NIGHTLY_FINGERPRINT=%s\n' "$fingerprint"
printf 'Nightly firmware is in %s\n' "$output_root"
