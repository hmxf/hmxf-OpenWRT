#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=../../scripts/lib/common.sh
source "$PROJECT_ROOT/scripts/lib/common.sh"
REFRESH_SCRIPT="$PROJECT_ROOT/scripts/locks/refresh-locks.sh"

load_build_config
for tool in awk cp grep mktemp mv sed sha256sum wc; do
    require_command "$tool"
done

temporary_dir=$(mktemp -d)
cleanup() {
    rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

run_fixture_validation() {
    LOCKS_DIR="$temporary_dir/locks" \
    CONFIGS_DIR="$temporary_dir/configs" \
    BUILD_CONFIG="$temporary_dir/configs/build.env" \
    "$VERIFY_SCRIPTS_DIR/validate-project.sh"
}

reset_fixture() {
    rm -rf -- "$temporary_dir/locks" "$temporary_dir/configs"
    cp -a -- "$PROJECT_ROOT/locks" "$temporary_dir/locks"
    cp -a -- "$PROJECT_ROOT/configs" "$temporary_dir/configs"
}

expect_failure() {
    local description=$1
    if run_fixture_validation >"$temporary_dir/test.log" 2>&1; then
        die "negative lock test unexpectedly passed: $description"
    fi
}

reset_fixture
run_fixture_validation >/dev/null

grep -Fq 'build.env build-debug.env build-refresh.env build-nightly.env' \
    "$REFRESH_SCRIPT" || \
    die 'lock refresh candidate omits a required build policy'
if grep -Fq 'Stage and publish those six archives' "$REFRESH_SCRIPT"; then
    die 'generated candidate report documents the obsolete publish-before-push order'
fi
grep -Fq 'After the new lock commit is exact-lease pushed' "$REFRESH_SCRIPT" || \
    die 'generated candidate report omits the recoverable draft transaction'

reset_fixture
sed -i '1s/^# name|/# unexpected|/' "$temporary_dir/locks/targets.tsv"
expect_failure 'target lock schema header drift'

reset_fixture
sed -i '1s/tree_sha256sums_sha256/tree_manifest_sha256/' \
    "$temporary_dir/locks/package-snapshots.tsv"
expect_failure 'package snapshot lock schema header drift'

reset_fixture
sed -i '2i# unexpected second header' "$temporary_dir/locks/targets.tsv"
expect_failure 'additional target lock header'

reset_fixture
cp -- "$temporary_dir/locks/README.md" "$temporary_dir/locks/unexpected.txt"
expect_failure 'unexpected lock file'

reset_fixture
sed -i '/^x86_64|full|/d' "$temporary_dir/locks/artifacts.tsv"
expect_failure 'missing artifact row'

reset_fixture
sed -i '/^x86_64|minimal|/s/$/|/' "$temporary_dir/locks/artifacts.tsv"
expect_failure 'empty trailing artifact field'

reset_fixture
sed -i 's/^x86_64|minimal|\([^|]*|\)[0-9a-f]\{64\}$/x86_64|minimal|\1fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
    "$temporary_dir/locks/artifacts.tsv"
expect_failure 'malformed artifact digest'

reset_fixture
sed -i 's#|immortalwrt-imagebuilder-#|../immortalwrt-imagebuilder-#' \
    "$temporary_dir/locks/targets.tsv"
expect_failure 'ImageBuilder path traversal'

reset_fixture
sed -i '0,/^x86_64|minimal|immortalwrt-/s#|immortalwrt-#|../immortalwrt-#' \
    "$temporary_dir/locks/artifacts.tsv"
expect_failure 'artifact path traversal'

reset_fixture
sed -i 's/^rpi5|bcm27xx|bcm2712|/rpi4|bcm27xx|bcm2712|/' \
    "$temporary_dir/locks/targets.tsv"
expect_failure 'duplicate target identity'

reset_fixture
sed -i 's/|[1-9][0-9]*$/|0/' "$temporary_dir/locks/targets.tsv"
expect_failure 'invalid ImageBuilder byte size'

reset_fixture
sed -i 's/^LOCKED_INPUT_RELEASE_TAG=.*/LOCKED_INPUT_RELEASE_TAG=wrong-version/' \
    "$temporary_dir/locks/release.env"
expect_failure 'locked-input release tag/version mismatch'

reset_fixture
printf '%s\n' 'packages|src-git|https://example.invalid/feed.git|1111111111111111111111111111111111111111' \
    >> "$temporary_dir/locks/feeds.tsv"
expect_failure 'duplicate feed name'

reset_fixture
printf '%s\n' 'UNKNOWN_POLICY_KEY=1' >> "$temporary_dir/configs/build.env"
expect_failure 'unknown build policy key'

reset_fixture
rm -f -- "$temporary_dir/locks/package-snapshots.tsv"
expect_failure 'missing mandatory package snapshot lock'

reset_fixture
printf '%s\n' 'KEEP_BUILD=0' >> "$temporary_dir/configs/build.env"
expect_failure 'duplicate build policy key'

reset_fixture
sed -i 's/^RUN_X86_SMOKE_TEST=1$/RUN_X86_SMOKE_TEST=0/' \
    "$temporary_dir/configs/build.env"
expect_failure 'production policy silently disables the x86 boot gate'

reset_fixture
sed -i '1s/^/# changed\n/' "$temporary_dir/locks/manifests/rpi5-full.manifest"
expect_failure 'reviewed manifest content differs from its digest index'

# Even a self-consistent manifest/count/digest edit must not silently drop a
# package requested by packages/*.txt.
reset_fixture
required_package=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
    "$PROJECT_ROOT/packages/base-image.txt" | sed -n '1p')
manifest="$temporary_dir/locks/manifests/x86_64-minimal.manifest"
grep -Eq "^${required_package} - " "$manifest" || \
    die "fixture manifest does not contain $required_package"
sed -i "/^${required_package} - /d" "$manifest"
manifest_count=$(wc -l < "$manifest")
manifest_sha=$(sha256sum "$manifest" | awk '{ print $1 }')
awk -F'|' -v OFS='|' -v count="$manifest_count" -v digest="$manifest_sha" '
    $1 == "x86_64" && $2 == "minimal" { $3 = count; $4 = digest }
    { print }
' "$temporary_dir/locks/package-manifests.tsv" \
    > "$temporary_dir/locks/package-manifests.tsv.new"
mv -- "$temporary_dir/locks/package-manifests.tsv.new" \
    "$temporary_dir/locks/package-manifests.tsv"
expect_failure 'self-consistent manifest drops a requested top-level package'

reset_fixture
fixture_version=$(sed -n 's/^IMMORTALWRT_VERSION=//p' \
    "$temporary_dir/locks/release.env")
{
    printf '%s\n' '# target|filename|sha256|bytes|tree_sha256sums_sha256'
    for target in x86_64 rpi4 rpi5; do
        printf '%s|immortalwrt-%s-%s-package-snapshot.tar.zst|%064d|1|%064d\n' \
            "$target" "$fixture_version" "$target" 0 1
    done
} > "$temporary_dir/locks/package-snapshots.tsv"
run_fixture_validation >/dev/null
sed -i 's/^rpi5|/rpi4|/' "$temporary_dir/locks/package-snapshots.tsv"
expect_failure 'duplicate package snapshot target'

reset_fixture
sed -i 's/^x86_64|\([^|]*|[0-9a-f]\{64\}\)|[0-9][0-9]*|/x86_64|\1|0|/' \
    "$temporary_dir/locks/package-snapshots.tsv"
expect_failure 'invalid package snapshot byte size'

reset_fixture
sed -i 's/|[0-9a-f]\{64\}$/|not-a-tree-digest/' \
    "$temporary_dir/locks/package-snapshots.tsv"
expect_failure 'invalid package snapshot tree-manifest digest'

plan_manifest="$temporary_dir/PLAN_INPUTS.sha256"
plan_revision="$temporary_dir/PLAN_INPUT_REVISION.txt"
write_plan_input_contract "$plan_manifest" "$plan_revision"
verify_plan_input_contract "$plan_manifest" "$plan_revision"
sed -i '1s/|[A-Za-z0-9._\/-]*$/|README.md/' "$plan_manifest"
if (verify_plan_input_contract "$plan_manifest" "$plan_revision") \
        >"$temporary_dir/test.log" 2>&1; then
    die 'tampered plan-input contract unexpectedly passed'
fi

printf '%s\n' 'Lock/config negative tests passed.'
