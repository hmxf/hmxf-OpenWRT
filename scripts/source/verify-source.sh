#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

load_build_config
load_release_lock
SOURCE_PATH=${1:-"$(dirname -- "$PROJECT_ROOT")/ImmortalWRT"}

git -C "$SOURCE_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    die "not an ImmortalWrt git tree: $SOURCE_PATH"
[[ -z $(git -C "$SOURCE_PATH" status --porcelain --untracked-files=no) ]] || \
    die "source contains tracked changes"

actual_commit=$(git -C "$SOURCE_PATH" rev-parse HEAD)
[[ "$actual_commit" == "$IMMORTALWRT_COMMIT" ]] || \
    die "source is $actual_commit, expected $IMMORTALWRT_COMMIT"
actual_tag_object=$(git -C "$SOURCE_PATH" rev-parse "$IMMORTALWRT_TAG")
[[ "$actual_tag_object" == "$IMMORTALWRT_TAG_OBJECT" ]] || \
    die "release tag object is $actual_tag_object, expected $IMMORTALWRT_TAG_OBJECT"
[[ $(git -C "$SOURCE_PATH" cat-file -t "$IMMORTALWRT_TAG") == tag ]] || \
    die 'release tag must be an annotated tag object'
[[ -z $(git -C "$SOURCE_PATH" symbolic-ref --quiet --short HEAD || true) ]] || \
    die "source HEAD must be detached at the locked release commit"
missing_locked_object=$(git -C "$SOURCE_PATH" rev-list --objects "$IMMORTALWRT_COMMIT" \
    --missing=print | awk '/^\?/ && first == "" { first = $0 } END { if (first != "") print first }')
[[ -z "$missing_locked_object" ]] || \
    die "source is missing an object reachable from the locked commit: $missing_locked_object"

actual_origin=$(git -C "$SOURCE_PATH" remote get-url origin)
case "$actual_origin" in
    https://github.com/immortalwrt/immortalwrt | \
    https://github.com/immortalwrt/immortalwrt.git) ;;
    *) die "unexpected source remote: $actual_origin" ;;
esac

if [[ "$SOURCE_FETCH_MODE" == full ]]; then
    [[ $(git -C "$SOURCE_PATH" rev-parse --is-shallow-repository) == false ]] || \
        die "source is shallow; select locked mode or run a full fetch"
    if git -C "$SOURCE_PATH" config --bool --get remote.origin.promisor 2>/dev/null \
            | grep -Fqx true || \
       git -C "$SOURCE_PATH" config --get remote.origin.partialclonefilter \
            >/dev/null 2>&1; then
        die "source is partial; run scripts/source/fetch-source.sh with SOURCE_FETCH_MODE=full"
    fi

    git_common_dir=$(git -C "$SOURCE_PATH" rev-parse --path-format=absolute --git-common-dir)
    promisor_marker=$(find "$git_common_dir/objects/pack" -maxdepth 1 -type f \
        -name '*.promisor' -print -quit)
    [[ -z "$promisor_marker" ]] || \
        die "source still contains partial-clone promisor packs"

    missing_object=$(git -C "$SOURCE_PATH" rev-list --objects --all --missing=print \
        | awk '/^\?/ && first == "" { first = $0 } END { if (first != "") print first }')
    [[ -z "$missing_object" ]] || die "source is missing a reachable object: $missing_object"

    full_refspec='+refs/heads/*:refs/remotes/origin/*'
    git -C "$SOURCE_PATH" config --get-all remote.origin.fetch \
        | grep -Fqx "$full_refspec" || \
        die "source does not fetch every upstream branch"
fi

feeds_file="$SOURCE_PATH/feeds.conf.default"
[[ -r "$feeds_file" ]] || die "missing feeds.conf.default"
[[ ! -e "$SOURCE_PATH/feeds.conf" && ! -L "$SOURCE_PATH/feeds.conf" ]] || \
    die 'feeds.conf overrides the locked feeds.conf.default; refusing this source tree'

if ! cmp -s <(render_locked_feeds) \
        <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$feeds_file"); then
    printf '%s\n' 'Locked feeds and feeds.conf.default differ:' >&2
    diff -u <(render_locked_feeds) \
        <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$feeds_file") >&2 || true
    die 'source feed set is not exactly locked (missing and extra feeds are both rejected)'
fi

printf 'Verified ImmortalWrt %s at %s (%s source mode)\n' \
    "$IMMORTALWRT_VERSION" "$SOURCE_PATH" "$SOURCE_FETCH_MODE"
