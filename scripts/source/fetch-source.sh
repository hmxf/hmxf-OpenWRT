#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

load_build_config
configure_network_environment
load_release_lock
SOURCE_PATH=${SOURCE_PATH:-"$(dirname -- "$PROJECT_ROOT")/ImmortalWRT"}
SOURCE_PATH=$(realpath -m -- "$SOURCE_PATH")
require_command git
require_command flock
require_command realpath

source_repository_lock_held=${SOURCE_REPOSITORY_LOCK_HELD:-0}
[[ "$source_repository_lock_held" == 0 || "$source_repository_lock_held" == 1 ]] || \
    die 'SOURCE_REPOSITORY_LOCK_HELD must be 0 or 1'
if (( source_repository_lock_held == 0 )); then
    source_repository_parent=$(dirname -- "$SOURCE_PATH")
    source_repository_name=$(basename -- "$SOURCE_PATH")
    [[ "$source_repository_name" =~ ^[A-Za-z0-9._-]+$ && "$SOURCE_PATH" != / ]] || \
        die "unsafe source repository path: $SOURCE_PATH"
    mkdir -p "$source_repository_parent"
    source_repository_lock="$source_repository_parent/.$source_repository_name.hmxf-source.lock"
    require_regular_file_or_absent "$source_repository_lock" 'source repository lock'
    exec {source_repository_lock_fd}>"$source_repository_lock"
    flock "$source_repository_lock_fd"
fi

full_refspec='+refs/heads/*:refs/remotes/origin/*'

first_missing_object() {
    # Consume the full stream: using head here would make pipefail turn a
    # multi-line result into SIGPIPE before our diagnostic can run.
    git -C "$SOURCE_PATH" rev-list --objects --all --missing=print \
        | awk '/^\?/ && first == "" { first = $0 } END { if (first != "") print first }'
}

if [[ ! -e "$SOURCE_PATH" ]]; then
    if [[ "$SOURCE_FETCH_MODE" == full ]]; then
        git clone --origin origin "$IMMORTALWRT_SOURCE_URL" "$SOURCE_PATH"
    else
        # A production source build needs the complete tree for one reviewed
        # commit, not every historical branch and blob.
        git init "$SOURCE_PATH"
        git -C "$SOURCE_PATH" remote add origin "$IMMORTALWRT_SOURCE_URL"
    fi
elif [[ ! -d "$SOURCE_PATH/.git" ]]; then
    die "path exists but is not a git repository: $SOURCE_PATH"
else
    if [[ -n "$(git -C "$SOURCE_PATH" status --porcelain --untracked-files=no)" ]]; then
        die "source has tracked changes; refusing to switch revisions"
    fi

    actual_origin=$(git -C "$SOURCE_PATH" remote get-url origin)
    case "$actual_origin" in
        https://github.com/immortalwrt/immortalwrt | \
        https://github.com/immortalwrt/immortalwrt.git) ;;
        *) die "unexpected source remote: $actual_origin" ;;
    esac

    if [[ "$SOURCE_FETCH_MODE" == full ]]; then
        # Upgrade older shallow/partial clones only in the explicitly selected
        # diagnostic mode.
        git -C "$SOURCE_PATH" config --replace-all remote.origin.fetch "$full_refspec"
        was_partial=0
        if git -C "$SOURCE_PATH" config --bool --get remote.origin.promisor 2>/dev/null \
                | grep -Fqx true || \
           git -C "$SOURCE_PATH" config --get remote.origin.partialclonefilter \
                >/dev/null 2>&1; then
            was_partial=1
        fi

        if [[ $(git -C "$SOURCE_PATH" rev-parse --is-shallow-repository) == true ]]; then
            git -C "$SOURCE_PATH" fetch --unshallow --no-filter --tags --prune \
                origin "$full_refspec"
        fi

        if (( was_partial )); then
            git -C "$SOURCE_PATH" fetch --refetch --no-filter --tags \
                origin "$full_refspec"
        fi
    fi
fi

if [[ "$SOURCE_FETCH_MODE" == full ]]; then
    git -C "$SOURCE_PATH" config --replace-all remote.origin.fetch "$full_refspec"
    git -C "$SOURCE_PATH" fetch --no-filter --tags --prune origin "$full_refspec"

    # A plain fetch can negotiate around an already-known commit even when a
    # damaged repository is missing one of its historical objects.
    missing_object=$(first_missing_object)
    if [[ -n "$missing_object" ]]; then
        git -C "$SOURCE_PATH" fetch --refetch --no-filter --tags \
            origin "$full_refspec"
        missing_object=$(first_missing_object)
    fi
    [[ -z "$missing_object" ]] || \
        die "full repository hydration left a missing object: $missing_object"

    git -C "$SOURCE_PATH" config --unset-all remote.origin.promisor || true
    git -C "$SOURCE_PATH" config --unset-all remote.origin.partialclonefilter || true
    git_dir=$(git -C "$SOURCE_PATH" rev-parse --absolute-git-dir)
    while IFS= read -r -d '' promisor_marker; do
        rm -f -- "$promisor_marker"
    done < <(find "$git_dir/objects/pack" -maxdepth 1 -type f -name '*.promisor' -print0)
    git -C "$SOURCE_PATH" fsck --full --no-dangling
else
    tag_ref="refs/tags/$IMMORTALWRT_TAG"
    have_locked_tree=0
    if [[ $(git -C "$SOURCE_PATH" rev-parse "$tag_ref" 2>/dev/null || true) == \
          "$IMMORTALWRT_TAG_OBJECT" && \
          $(git -C "$SOURCE_PATH" rev-parse "$tag_ref^{}" 2>/dev/null || true) == \
          "$IMMORTALWRT_COMMIT" ]]; then
        locked_missing=$(git -C "$SOURCE_PATH" rev-list --objects "$IMMORTALWRT_COMMIT" \
            --missing=print | awk '/^\?/ { found = 1 } END { exit !found }' && printf 1 || printf 0)
        [[ "$locked_missing" == 1 ]] || have_locked_tree=1
    fi
    if [[ "$SOURCE_FETCH_POLICY" == always || $have_locked_tree -eq 0 ]]; then
        fetch_depth=()
        if [[ $(git -C "$SOURCE_PATH" rev-parse --is-shallow-repository) == true ]] || \
           ! git -C "$SOURCE_PATH" rev-parse --verify HEAD >/dev/null 2>&1; then
            fetch_depth=(--depth=1)
        fi
        git -C "$SOURCE_PATH" fetch "${fetch_depth[@]}" --no-tags --no-filter origin \
            "$tag_ref:$tag_ref"
    fi
fi

fetched_commit=$(git -C "$SOURCE_PATH" rev-list -n 1 "$IMMORTALWRT_TAG")
[[ "$fetched_commit" == "$IMMORTALWRT_COMMIT" ]] || die "tag resolved to unexpected commit"
actual_commit=$(git -C "$SOURCE_PATH" rev-parse HEAD)
current_branch=$(git -C "$SOURCE_PATH" symbolic-ref --quiet --short HEAD || true)
if [[ "$actual_commit" != "$IMMORTALWRT_COMMIT" || -n "$current_branch" ]]; then
    git -C "$SOURCE_PATH" checkout --detach "$IMMORTALWRT_COMMIT"
fi

"$SOURCE_SCRIPTS_DIR/verify-source.sh" "$SOURCE_PATH"
