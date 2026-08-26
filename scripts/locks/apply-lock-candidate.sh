#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

candidate_arg=${1:?usage: apply-lock-candidate.sh build/lock-refresh/VERSION}
candidate_root=$(realpath -e -- "$candidate_arg")
case "$candidate_root" in
    "$PROJECT_ROOT/build/lock-refresh/"*) ;;
    *) die "candidate must be below $PROJECT_ROOT/build/lock-refresh" ;;
esac
candidate_locks="$candidate_root/locks"
candidate_configs="$candidate_root/configs"
verification_root="$candidate_root/verification-out"
imagebuilder_bundle_root="$candidate_root/imagebuilders"
snapshot_persist_script="$INPUT_SCRIPTS_DIR/persist-package-snapshots.sh"
imagebuilder_persist_script="$INPUT_SCRIPTS_DIR/persist-imagebuilders.sh"
snapshot_verify_script="$INPUT_SCRIPTS_DIR/verify-package-snapshot.py"
[[ -x "$snapshot_persist_script" ]] || \
    die "package snapshot persister is not executable: $snapshot_persist_script"
[[ -x "$imagebuilder_persist_script" ]] || \
    die "ImageBuilder persister is not executable: $imagebuilder_persist_script"
[[ -f "$snapshot_verify_script" && ! -L "$snapshot_verify_script" ]] || \
    die "package snapshot verifier is unavailable: $snapshot_verify_script"

for tool in cmp diff env find flock git mktemp python3 realpath sha256sum sort stat zstd; do
    require_command "$tool"
done
plan_input_manifest="$candidate_root/PLAN_INPUTS.sha256"
plan_input_revision="$candidate_root/PLAN_INPUT_REVISION.txt"
verify_plan_input_contract "$plan_input_manifest" "$plan_input_revision"
recorded_plan_revision=$(<"$plan_input_revision")
[[ "$recorded_plan_revision" == uncommitted || \
   "$recorded_plan_revision" =~ ^[0-9a-f]{40}$ ]] || \
    die 'applying a lock candidate requires its original bootstrap tree or clean committed revision'
for required in README.md release.env targets.tsv feeds.tsv package-manifests.tsv \
                artifacts.tsv package-snapshots.tsv; do
    [[ -s "$candidate_locks/$required" ]] || die "candidate is missing locks/$required"
done
for target in x86_64 rpi4 rpi5; do
    [[ -s "$candidate_configs/$target.config" ]] || \
        die "candidate is missing configs/$target.config"
    for preset in minimal full; do
        [[ -s "$candidate_locks/manifests/$target-$preset.manifest" ]] || \
            die "candidate is missing the reviewed manifest for $target/$preset"
    done
done

run_locked_policy() {
    local repository_mode=${1:?repository mode required}
    local policy_locks=${2:?lock directory required}
    local policy_configs=${3:?config directory required}
    local policy_file=${4:?build policy file required}
    local package_cache_index=0
    shift 4
    [[ "$repository_mode" == snapshot ]] || package_cache_index=1
    env \
        BUILD_CONFIG="$policy_file" \
        CHECK_LATEST_ON_BUILD=0 \
        ARTIFACT_LOCK_POLICY=enforce \
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
        NETWORK_PROXY_MODE=direct \
        LOCKS_DIR="$policy_locks" \
        CONFIGS_DIR="$policy_configs" \
        "$@"
}

run_locked_policy snapshot "$candidate_locks" "$candidate_configs" \
    "$candidate_configs/build.env" "$VERIFY_SCRIPTS_DIR/validate-project.sh"

[[ -f "$imagebuilder_bundle_root/SHA256SUMS" && \
   ! -L "$imagebuilder_bundle_root/SHA256SUMS" && \
   -s "$imagebuilder_bundle_root/SHA256SUMS" ]] || \
    die 'candidate is missing imagebuilders/SHA256SUMS'
(
    cd "$imagebuilder_bundle_root"
    locked_names=$(awk '{ sub(/^\*/, "", $2); print $2 }' SHA256SUMS | sort)
    actual_names=$(find . -mindepth 1 -maxdepth 1 ! -name SHA256SUMS -printf '%P\n' | sort)
    [[ "$locked_names" == "$actual_names" ]] || \
        die 'candidate ImageBuilder bundle file set differs from SHA256SUMS'
    while IFS= read -r locked_name; do
        [[ -f "$locked_name" && ! -L "$locked_name" ]] || \
            die "candidate ImageBuilder entry is not a regular file: $locked_name"
    done <<< "$locked_names"
    sha256sum -c SHA256SUMS
)
while IFS='|' read -r target_name _target _subtarget _profile _package_arch \
        imagebuilder_file imagebuilder_sha _kernel_vermagic imagebuilder_bytes \
        target_extra; do
    [[ -n "$target_name" && ${target_name:0:1} != '#' ]] || continue
    [[ -z "$target_extra" ]] || die "invalid target row for $target_name"
    [[ -f "$imagebuilder_bundle_root/$imagebuilder_file" && \
       ! -L "$imagebuilder_bundle_root/$imagebuilder_file" ]] || \
        die "candidate ImageBuilder bundle is not a regular file: $imagebuilder_file"
    printf '%s  %s\n' "$imagebuilder_sha" \
        "$imagebuilder_bundle_root/$imagebuilder_file" | sha256sum -c -
    [[ $(stat -c '%s' "$imagebuilder_bundle_root/$imagebuilder_file") == \
       "$imagebuilder_bytes" ]] || \
        die "candidate ImageBuilder byte-size mismatch: $imagebuilder_file"
done < "$candidate_locks/targets.tsv"

# The rebuild verifies the unpacked snapshot tree; separately authenticate the
# three portable bundles that the operator must retain for future rebuilds.
candidate_version=$(sed -n 's/^IMMORTALWRT_VERSION=//p' "$candidate_locks/release.env")
IMMORTALWRT_VERSION=$candidate_version
PACKAGE_SNAPSHOT_LOCK="$candidate_locks/package-snapshots.tsv"
validate_package_snapshot_lock
mkdir -p "$PROJECT_ROOT/build"
snapshot_verify_root=$(mktemp -d "$PROJECT_ROOT/build/snapshot-bundle-check.XXXXXXXX")
cleanup_snapshot_verify() {
    rm -rf -- "$snapshot_verify_root"
}
trap cleanup_snapshot_verify EXIT
while IFS='|' read -r snapshot_target snapshot_file snapshot_sha snapshot_bytes \
        snapshot_tree_sha snapshot_extra; do
    [[ -n "$snapshot_target" && ${snapshot_target:0:1} != '#' ]] || continue
    [[ -z "$snapshot_extra" ]] || die "invalid snapshot row for $snapshot_target"
    snapshot_bundle="$candidate_root/package-snapshot-bundles/$snapshot_file"
    [[ -f "$snapshot_bundle" && ! -L "$snapshot_bundle" ]] || \
        die "candidate is missing or has an unsafe snapshot bundle: $snapshot_file"
    printf '%s  %s\n' "$snapshot_sha" "$snapshot_bundle" | sha256sum -c -
    [[ $(stat -c '%s' "$snapshot_bundle") == "$snapshot_bytes" ]] || \
        die "candidate snapshot bundle byte-size mismatch: $snapshot_file"

    # Use the same strict extractor as restore and release staging so apply can
    # never accept a link or archive shape that a fresh machine later rejects.
    extracted_parent="$snapshot_verify_root/$snapshot_target"
    mkdir -p "$extracted_parent"
    python3 "$snapshot_verify_script" extract "$snapshot_bundle" \
        "$extracted_parent" "$candidate_version" "$snapshot_target" \
        "$snapshot_tree_sha" >/dev/null
    extracted_snapshot="$extracted_parent/$candidate_version/$snapshot_target"
    candidate_snapshot="$candidate_root/package-snapshots/$candidate_version/$snapshot_target"
    [[ -s "$extracted_snapshot/SHA256SUMS" && -d "$candidate_snapshot" ]] || \
        die "snapshot bundle has an unexpected tree for $snapshot_target"
    diff -qr --no-dereference "$candidate_snapshot" "$extracted_snapshot" >/dev/null || \
        die "portable snapshot bundle differs from the verified tree for $snapshot_target"
done < "$candidate_locks/package-snapshots.tsv"
rm -rf -- "$snapshot_verify_root"
trap - EXIT

# Recheck the second, snapshot-backed build rather than trusting only the
# refresh process's success status.
for target in x86_64 rpi4 rpi5; do
    for preset in minimal full; do
        artifact_dir="$verification_root/$candidate_version/$target/$preset"
        run_locked_policy snapshot "$candidate_locks" "$candidate_configs" \
            "$candidate_configs/build.env" "$VERIFY_SCRIPTS_DIR/verify-artifacts.sh" \
            "$target" "$preset" "$artifact_dir"
    done
done

# The refresh run already gated both x86 images before recording their hashes.
# Repeat the actual boot here so a hostile environment override or a copied
# verification directory cannot turn apply into a metadata-only approval.
for preset in minimal full; do
    "$VERIFY_SCRIPTS_DIR/smoke-test-x86-uefi.sh" \
        "$verification_root/$candidate_version/x86_64/$preset"
done

verify_plan_input_contract "$plan_input_manifest" "$plan_input_revision"

apply_lock="$PROJECT_ROOT/build/.lock-candidate-apply.lock"
require_regular_file_or_absent "$apply_lock" 'candidate apply lock'
exec {apply_lock_fd}>"$apply_lock"
flock "$apply_lock_fd"

# Make every verified external binary input durable before changing the formal
# locks. A store conflict or I/O failure therefore leaves locks/configs intact.
"$imagebuilder_persist_script" "$candidate_root"
"$snapshot_persist_script" "$candidate_root"

staged_locks=$(mktemp -d "$PROJECT_ROOT/.locks-candidate.XXXXXXXX")
backup_locks=$(mktemp -d "$PROJECT_ROOT/.locks-backup.XXXXXXXX")
rmdir -- "$backup_locks"
cp -a -- "$candidate_locks/." "$staged_locks/"
config_backup=$(mktemp -d "$PROJECT_ROOT/build/config-backup.XXXXXXXX")
for target in x86_64 rpi4 rpi5; do
    cp -- "$PROJECT_ROOT/configs/$target.config" "$config_backup/$target.config"
done

applied=0
rollback() {
    local status=$?
    trap - EXIT
    if (( applied == 0 )); then
        if [[ -d "$backup_locks" ]]; then
            rm -rf -- "$PROJECT_ROOT/locks"
            mv -- "$backup_locks" "$PROJECT_ROOT/locks"
        fi
        for target in x86_64 rpi4 rpi5; do
            if [[ -f "$config_backup/$target.config" ]]; then
                cp -- "$config_backup/$target.config" "$PROJECT_ROOT/configs/$target.config"
            fi
        done
    fi
    [[ ! -d "$staged_locks" ]] || rm -rf -- "$staged_locks"
    [[ ! -d "$config_backup" ]] || rm -rf -- "$config_backup"
    exit "$status"
}
trap rollback EXIT

mv -- "$PROJECT_ROOT/locks" "$backup_locks"
mv -- "$staged_locks" "$PROJECT_ROOT/locks"
for target in x86_64 rpi4 rpi5; do
    cp -- "$candidate_configs/$target.config" "$PROJECT_ROOT/configs/$target.config"
done

run_locked_policy snapshot "$PROJECT_ROOT/locks" "$PROJECT_ROOT/configs" \
    "$PROJECT_ROOT/configs/build.env" "$VERIFY_SCRIPTS_DIR/validate-project.sh"
applied=1
rm -rf -- "$backup_locks" "$config_backup"
trap - EXIT
flock -u "$apply_lock_fd"

printf 'Applied reviewed ImmortalWrt %s locks and generated target configs.\n' \
    "$candidate_version"
printf '%s\n' \
    'Package snapshots and ImageBuilders were persisted locally; publish the six locked assets before relying on fresh CI.'
