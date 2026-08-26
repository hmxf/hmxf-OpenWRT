#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
checker="$PROJECT_ROOT/scripts/locks/check-upstream-updates.sh"
tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

digest_a=$(printf a | sha256sum | awk '{ print $1 }')
digest_b=$(printf b | sha256sum | awk '{ print $1 }')
digest_c=$(printf c | sha256sum | awk '{ print $1 }')
feed_commit_a=1111111111111111111111111111111111111111
feed_commit_b=2222222222222222222222222222222222222222

state_value() {
    local file=$1
    local key=$2
    awk -F= -v wanted="$key" '$1 == wanted { print substr($0, length($1) + 2) }' \
        "$file"
}

write_release_index() {
    local root=$1
    local version=$2
    mkdir -p "$root/releases"
    printf '<a href="%s/">%s/</a>\n' "$version" "$version" \
        > "$root/releases/index.html"
}

write_stable_checksums() {
    local root=$1
    local version=$2
    local spec target subtarget digest file directory
    for spec in 'x86|64|a' 'bcm27xx|bcm2711|b' 'bcm27xx|bcm2712|c'; do
        IFS='|' read -r target subtarget digest <<< "$spec"
        case "$digest" in a) digest=$digest_a ;; b) digest=$digest_b ;; c) digest=$digest_c ;; esac
        directory="$root/releases/$version/targets/$target/$subtarget"
        mkdir -p "$directory"
        file="immortalwrt-imagebuilder-$version-$target-$subtarget.Linux-x86_64.tar.zst"
        printf '%s *%s\n' "$digest" "$file" > "$directory/sha256sums"
    done
}

write_snapshot() {
    local root=$1
    local revision=$2
    local feed_commit=$3
    local package_generation=${4:-a}
    local spec target subtarget arch digest file directory vermagic
    local short_commit full_commit package_path
    short_commit=${revision#*-}
    full_commit=$(printf '%-40s' "$short_commit" | tr ' ' 0)
    for spec in \
            'x86|64|x86_64|a' \
            'bcm27xx|bcm2711|aarch64_cortex-a72|b' \
            'bcm27xx|bcm2712|aarch64_cortex-a76|c'; do
        IFS='|' read -r target subtarget arch digest <<< "$spec"
        case "$digest" in a) digest=$digest_a ;; b) digest=$digest_b ;; c) digest=$digest_c ;; esac
        vermagic=${digest:0:32}
        directory="$root/snapshots/targets/$target/$subtarget"
        mkdir -p "$directory"
        printf '%s\n' "$revision" > "$directory/version.buildinfo"
        printf 'src-git packages https://github.com/immortalwrt/packages.git^%s\n' \
            "$feed_commit" > "$directory/feeds.buildinfo"
        printf '{"arch_packages":"%s","git_commit":"%s","linux_kernel":{"release":"1","vermagic":"%s","version":"6.6.1"},"source_date_epoch":1780000000,"version_code":"%s"}\n' \
            "$arch" "$full_commit" "$vermagic" "$revision" \
            > "$directory/profiles.json"
        file="immortalwrt-imagebuilder-$target-$subtarget.Linux-x86_64.tar.zst"
        {
            printf '%s *%s\n' "$digest" "$file"
            sha256sum "$directory/version.buildinfo" \
                "$directory/feeds.buildinfo" "$directory/profiles.json" | \
                awk '{ sub(/^.*\//, "", $2); print $1 " *" $2 }'
        } > "$directory/sha256sums"

        for package_path in \
                "$directory/packages/packages.adb" \
                "$directory/kmods/6.6.1-1-$vermagic/packages.adb" \
                "$root/snapshots/packages/$arch/base/packages.adb" \
                "$root/snapshots/packages/$arch/packages/packages.adb"; do
            mkdir -p -- "$(dirname -- "$package_path")"
            printf 'ADBd %s %s %s %s\n' "$package_generation" "$target" \
                "$subtarget" "$package_path" > "$package_path"
        done
    done
}

stable_fixture="$tmp_dir/stable"
write_release_index "$stable_fixture" 25.12.2
write_stable_checksums "$stable_fixture" 25.12.2
stable_state="$tmp_dir/stable.env"
"$checker" --fixture-root "$stable_fixture" --output "$stable_state" \
    --stable-release-present 1
[[ $(state_value "$stable_state" CHANNEL) == stable ]]
[[ $(state_value "$stable_state" REASON) == new-stable ]]
[[ $(state_value "$stable_state" LATEST_STABLE_VERSION) == 25.12.2 ]]

rm -f "$stable_fixture/releases/25.12.2/targets/bcm27xx/bcm2712/sha256sums"
deferred_state="$tmp_dir/deferred.env"
"$checker" --fixture-root "$stable_fixture" --output "$deferred_state" \
    --stable-release-present 1
[[ $(state_value "$deferred_state" CHANNEL) == deferred ]]
[[ $(state_value "$deferred_state" REASON) == stable-publishing-in-progress ]]

snapshot_fixture="$tmp_dir/snapshot"
write_release_index "$snapshot_fixture" 25.12.1
write_snapshot "$snapshot_fixture" r40000-abcdef123456 "$feed_commit_a"
first_nightly="$tmp_dir/first-nightly.env"
"$checker" --fixture-root "$snapshot_fixture" --output "$first_nightly" \
    --stable-release-present 1
[[ $(state_value "$first_nightly" CHANNEL) == nightly ]]
[[ $(state_value "$first_nightly" REASON) == no-previous-nightly ]]
[[ $(state_value "$first_nightly" SNAPSHOT_FINGERPRINT) =~ ^[0-9a-f]{64}$ ]]
[[ $(state_value "$first_nightly" SNAPSHOT_PACKAGES_SHA256) =~ ^[0-9a-f]{64}$ ]]
[[ $(state_value "$first_nightly" SNAPSHOT_SOURCE_COMMIT) =~ ^[0-9a-f]{40}$ ]]
calculated_first_fingerprint=$(printf '%s\n%s\n%s\n%s\n%s\n' \
    "$(state_value "$first_nightly" SNAPSHOT_VERSION_CODE)" \
    "$(state_value "$first_nightly" SNAPSHOT_SOURCE_COMMIT)" \
    "$(state_value "$first_nightly" SNAPSHOT_FEEDS_SHA256)" \
    "$(state_value "$first_nightly" SNAPSHOT_TARGETS_SHA256)" \
    "$(state_value "$first_nightly" SNAPSHOT_PACKAGES_SHA256)" | \
    sha256sum | awk '{ print $1 }')
[[ "$calculated_first_fingerprint" == \
    $(state_value "$first_nightly" SNAPSHOT_FINGERPRINT) ]]

unchanged_state="$tmp_dir/unchanged.env"
"$checker" --fixture-root "$snapshot_fixture" --state "$first_nightly" \
    --output "$unchanged_state" --stable-release-present 1
[[ $(state_value "$unchanged_state" CHANNEL) == none ]]
[[ $(state_value "$unchanged_state" REASON) == unchanged ]]

write_snapshot "$snapshot_fixture" r40000-abcdef123456 "$feed_commit_a" b
package_state="$tmp_dir/package.env"
"$checker" --fixture-root "$snapshot_fixture" --state "$first_nightly" \
    --output "$package_state" --stable-release-present 1
[[ $(state_value "$package_state" CHANNEL) == nightly ]]
[[ $(state_value "$package_state" REASON) == snapshot-package-update ]]
[[ $(state_value "$package_state" SNAPSHOT_VERSION_CODE) == \
    $(state_value "$first_nightly" SNAPSHOT_VERSION_CODE) ]]
[[ $(state_value "$package_state" SNAPSHOT_FEEDS_SHA256) == \
    $(state_value "$first_nightly" SNAPSHOT_FEEDS_SHA256) ]]
[[ $(state_value "$package_state" SNAPSHOT_TARGETS_SHA256) == \
    $(state_value "$first_nightly" SNAPSHOT_TARGETS_SHA256) ]]
[[ $(state_value "$package_state" SNAPSHOT_PACKAGES_SHA256) != \
    $(state_value "$first_nightly" SNAPSHOT_PACKAGES_SHA256) ]]

write_snapshot "$snapshot_fixture" r40000-abcdef123456 "$feed_commit_b" b
feed_state="$tmp_dir/feed.env"
"$checker" --fixture-root "$snapshot_fixture" --state "$package_state" \
    --output "$feed_state" --stable-release-present 1
[[ $(state_value "$feed_state" CHANNEL) == nightly ]]
[[ $(state_value "$feed_state" REASON) == snapshot-feed-update ]]

write_snapshot "$snapshot_fixture" r40001-bcdefa234567 "$feed_commit_b" b
source_state="$tmp_dir/source.env"
"$checker" --fixture-root "$snapshot_fixture" --state "$feed_state" \
    --output "$source_state" --stable-release-present 1
[[ $(state_value "$source_state" CHANNEL) == nightly ]]
[[ $(state_value "$source_state" REASON) == snapshot-source-update ]]

# Explicit check/nightly modes must not be preempted by an available newer
# stable release.  "check" remains read-only; "nightly" selects the synchronized
# snapshot even when auto mode would prioritize stable.
write_release_index "$snapshot_fixture" 25.12.2
write_stable_checksums "$snapshot_fixture" 25.12.2
check_state="$tmp_dir/check.env"
"$checker" --fixture-root "$snapshot_fixture" --state "$source_state" \
    --output "$check_state" --stable-release-present 1 --force check
[[ $(state_value "$check_state" CHANNEL) == none ]]
[[ $(state_value "$check_state" REASON) == check-only ]]
forced_nightly_state="$tmp_dir/forced-nightly.env"
"$checker" --fixture-root "$snapshot_fixture" --state "$source_state" \
    --output "$forced_nightly_state" --stable-release-present 1 --force nightly
[[ $(state_value "$forced_nightly_state" CHANNEL) == nightly ]]
[[ $(state_value "$forced_nightly_state" REASON) == manual-nightly ]]

write_release_index "$snapshot_fixture" 25.12.1
second_sample_index="$snapshot_fixture/.sample-2/snapshots/packages/x86_64/base/packages.adb"
mkdir -p -- "$(dirname -- "$second_sample_index")"
printf '%s\n' 'ADBd index changed during the second complete sample' \
    > "$second_sample_index"
asynchronous_state="$tmp_dir/asynchronous.env"
"$checker" --fixture-root "$snapshot_fixture" --state "$source_state" \
    --output "$asynchronous_state" --stable-release-present 1
[[ $(state_value "$asynchronous_state" CHANNEL) == none ]]
[[ $(state_value "$asynchronous_state" REASON) == \
    snapshot-publishing-in-progress ]]
[[ -z $(state_value "$asynchronous_state" SNAPSHOT_FINGERPRINT) ]]
rm -rf -- "$snapshot_fixture/.sample-2"

# A shared short version suffix is not enough: all targets must identify the
# same complete 40-character source commit from profiles.json.
profile_path="$snapshot_fixture/snapshots/targets/bcm27xx/bcm2712/profiles.json"
profile_sums="$snapshot_fixture/snapshots/targets/bcm27xx/bcm2712/sha256sums"
original_commit=$(printf '%-40s' bcdefa234567 | tr ' ' 0)
different_commit=${original_commit%?}1
sed -i "s/$original_commit/$different_commit/" "$profile_path"
changed_profile_sha=$(sha256sum "$profile_path" | awk '{ print $1 }')
sed -i \
    "s/^[0-9a-f]\{64\} \*profiles[.]json$/$changed_profile_sha *profiles.json/" \
    "$profile_sums"
commit_inconsistent_state="$tmp_dir/commit-inconsistent.env"
"$checker" --fixture-root "$snapshot_fixture" --state "$source_state" \
    --output "$commit_inconsistent_state" --stable-release-present 1
[[ $(state_value "$commit_inconsistent_state" CHANNEL) == none ]]
[[ $(state_value "$commit_inconsistent_state" REASON) == \
    snapshot-publishing-in-progress ]]

write_snapshot "$snapshot_fixture" r40001-bcdefa234567 "$feed_commit_b" b
printf '%s\n' r40002-cdefab345678 \
    > "$snapshot_fixture/snapshots/targets/bcm27xx/bcm2712/version.buildinfo"
changed_version_sha=$(sha256sum \
    "$snapshot_fixture/snapshots/targets/bcm27xx/bcm2712/version.buildinfo" \
    | awk '{ print $1 }')
sed -i "s/^[0-9a-f]\{64\} \*version[.]buildinfo$/$changed_version_sha *version.buildinfo/" \
    "$snapshot_fixture/snapshots/targets/bcm27xx/bcm2712/sha256sums"
inconsistent_state="$tmp_dir/inconsistent.env"
"$checker" --fixture-root "$snapshot_fixture" --state "$source_state" \
    --output "$inconsistent_state" --stable-release-present 1
[[ $(state_value "$inconsistent_state" CHANNEL) == none ]]
[[ $(state_value "$inconsistent_state" REASON) == snapshot-publishing-in-progress ]]

printf '%s\n' 'Upstream stable/nightly classifier tests passed.'
