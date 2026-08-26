#!/usr/bin/env bash

# Strict GitHub Release helpers for CI publication jobs. The caller must set
# GH_TOKEN, GITHUB_REPOSITORY, and RUNNER_TEMP and must already use
# `set -euo pipefail`.

github_release_require_tools() {
    local tool
    for tool in awk basename cat cmp diff find gh grep jq mktemp rm sha256sum \
                sleep sort; do
        command -v "$tool" >/dev/null 2>&1 || {
            printf 'error: required GitHub Release tool is unavailable: %s\n' \
                "$tool" >&2
            return 1
        }
    done
}

github_require_immutable_releases_enabled() {
    local state
    state=$(mktemp "$RUNNER_TEMP/github-immutable-releases.XXXXXXXX")
    gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
        "repos/$GITHUB_REPOSITORY/immutable-releases" > "$state"
    jq -e '.enabled == true' "$state" >/dev/null || {
        printf 'error: GitHub Immutable Releases is not enabled\n' >&2
        rm -f -- "$state"
        return 1
    }
    rm -f -- "$state"
}

github_api_get_optional() {
    local endpoint=${1:?GitHub API endpoint required}
    local destination=${2:?GitHub API output path required}
    local error_file status

    error_file=$(mktemp "$RUNNER_TEMP/github-api-error.XXXXXXXX")
    if gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
            "$endpoint" > "$destination" 2> "$error_file"; then
        rm -f -- "$error_file"
        return 0
    else
        status=$?
    fi
    if grep -Fq '(HTTP 404)' "$error_file"; then
        rm -f -- "$error_file"
        return 1
    fi
    cat "$error_file" >&2
    rm -f -- "$error_file"
    printf 'error: GitHub API request failed for %s (status %s)\n' \
        "$endpoint" "$status" >&2
    return 2
}

github_release_find_by_tag() {
    local tag=${1:?release tag required}
    local destination=${2:?release JSON output path required}
    local pages matches count

    pages=$(mktemp "$RUNNER_TEMP/github-releases-pages.XXXXXXXX")
    matches=$(mktemp "$RUNNER_TEMP/github-releases-matches.XXXXXXXX")
    if ! gh api -H 'X-GitHub-Api-Version: 2026-03-10' --paginate --slurp \
            "repos/$GITHUB_REPOSITORY/releases?per_page=100" > "$pages"; then
        printf 'error: cannot enumerate GitHub Releases\n' >&2
        rm -f -- "$pages" "$matches"
        return 2
    fi
    if ! jq --arg tag "$tag" \
            '[.[][] | select(.tag_name == $tag)]' "$pages" > "$matches"; then
        printf 'error: cannot parse GitHub Releases response\n' >&2
        rm -f -- "$pages" "$matches"
        return 2
    fi
    if ! count=$(jq -er 'length' "$matches"); then
        printf 'error: cannot count matching GitHub Releases\n' >&2
        rm -f -- "$pages" "$matches"
        return 2
    fi
    case "$count" in
        0)
            rm -f -- "$pages" "$matches"
            return 1
            ;;
        1)
            if ! jq -e '.[0]' "$matches" > "$destination"; then
                printf 'error: cannot select matching GitHub Release\n' >&2
                rm -f -- "$pages" "$matches"
                return 2
            fi
            rm -f -- "$pages" "$matches"
            return 0
            ;;
        *)
            printf 'error: multiple releases use tag %s\n' "$tag" >&2
            rm -f -- "$pages" "$matches"
            return 2
            ;;
    esac
}

github_read_lightweight_tag_commit() {
    local tag=${1:?tag required}
    local endpoint ref_json status commit
    [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || {
        printf 'error: unsafe release tag: %s\n' "$tag" >&2
        return 1
    }
    endpoint="repos/$GITHUB_REPOSITORY/git/ref/tags/$tag"
    ref_json=$(mktemp "$RUNNER_TEMP/github-tag-ref.XXXXXXXX")
    if github_api_get_optional "$endpoint" "$ref_json"; then
        if ! commit=$(jq -er --arg tag "$tag" '
                select(
                    .ref == ("refs/tags/" + $tag) and
                    .object.type == "commit" and
                    (.object.sha | test("^[0-9a-f]{40}$"))
                ) | .object.sha
            ' "$ref_json"); then
            printf 'error: release tag is not a lightweight commit ref: %s\n' \
                "$tag" >&2
            rm -f -- "$ref_json"
            return 2
        fi
        rm -f -- "$ref_json"
        printf '%s\n' "$commit"
        return 0
    else
        status=$?
        rm -f -- "$ref_json"
        return "$status"
    fi
}

github_require_lightweight_tag_at_commit() {
    local tag=${1:?tag required}
    local expected_commit=${2:?expected commit required}
    local existing_commit status

    [[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || {
        printf 'error: invalid expected tag commit: %s\n' \
            "$expected_commit" >&2
        return 1
    }
    if existing_commit=$(github_read_lightweight_tag_commit "$tag"); then
        :
    else
        status=$?
        (( status == 1 )) || return "$status"
        gh api -H 'X-GitHub-Api-Version: 2026-03-10' --method POST \
            "repos/$GITHUB_REPOSITORY/git/refs" \
            -f "ref=refs/tags/$tag" \
            -f "sha=$expected_commit" >/dev/null
        existing_commit=$(github_read_lightweight_tag_commit "$tag")
    fi
    [[ "$existing_commit" == "$expected_commit" ]]
}

github_rebind_draft_tag_at_commit() {
    local release_json=${1:?release JSON path required}
    local tag=${2:?tag required}
    local expected_commit=${3:?expected commit required}
    jq -e --arg tag "$tag" \
        '.tag_name == $tag and .draft == true' "$release_json" >/dev/null
    [[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]]
    gh api -H 'X-GitHub-Api-Version: 2026-03-10' --method PATCH \
        "repos/$GITHUB_REPOSITORY/git/refs/tags/$tag" \
        -f "sha=$expected_commit" -F force=true >/dev/null
    github_require_lightweight_tag_at_commit "$tag" "$expected_commit"
}

# Call only after github_release_find_by_tag returned its exact not-found
# status. With no Release attached, an orphan lightweight tag left by a failed
# draft creation is safe to repair and must not make the transaction permanent.
github_bind_unreleased_lightweight_tag_at_commit() {
    local tag=${1:?tag required}
    local expected_commit=${2:?expected commit required}
    local existing status release_probe
    release_probe=$(mktemp "$RUNNER_TEMP/github-orphan-release.XXXXXXXX")
    if github_release_find_by_tag "$tag" "$release_probe"; then
        printf 'error: refusing to rebind a tag attached to a Release: %s\n' \
            "$tag" >&2
        rm -f -- "$release_probe"
        return 1
    else
        status=$?
        rm -f -- "$release_probe"
        (( status == 1 )) || return "$status"
    fi
    if existing=$(github_read_lightweight_tag_commit "$tag"); then
        if [[ "$existing" != "$expected_commit" ]]; then
            gh api -H 'X-GitHub-Api-Version: 2026-03-10' --method PATCH \
                "repos/$GITHUB_REPOSITORY/git/refs/tags/$tag" \
                -f "sha=$expected_commit" -F force=true >/dev/null
        fi
    else
        status=$?
        (( status == 1 )) || return "$status"
        gh api -H 'X-GitHub-Api-Version: 2026-03-10' --method POST \
            "repos/$GITHUB_REPOSITORY/git/refs" \
            -f "ref=refs/tags/$tag" -f "sha=$expected_commit" >/dev/null
    fi
    github_require_lightweight_tag_at_commit "$tag" "$expected_commit"
}

github_publish_draft_and_require_immutable() {
    local tag=${1:?tag required}
    local prerelease=${2:?prerelease status required}
    local latest=${3:?latest status required}
    local release_dir=${4:?verified release directory required}
    local release_json attempt
    [[ "$prerelease" =~ ^(true|false)$ && "$latest" =~ ^(true|false)$ ]]
    release_json=$(mktemp "$RUNNER_TEMP/github-published-release.XXXXXXXX")
    if [[ "$prerelease" == true ]]; then
        gh release edit "$tag" --repo "$GITHUB_REPOSITORY" \
            --draft=false --prerelease --latest=false
    elif [[ "$latest" == true ]]; then
        gh release edit "$tag" --repo "$GITHUB_REPOSITORY" \
            --draft=false --latest
    else
        gh release edit "$tag" --repo "$GITHUB_REPOSITORY" \
            --draft=false --latest=false
    fi
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        github_release_find_by_tag "$tag" "$release_json"
        if jq -e --arg tag "$tag" --argjson prerelease "$prerelease" '
            .tag_name == $tag and .draft == false and
            .prerelease == $prerelease and
            has("immutable") and .immutable == true
        ' "$release_json" >/dev/null; then
            rm -f -- "$release_json"
            return 0
        fi
        (( attempt == 10 )) || sleep 3
    done
    if jq -e '.draft == false and (.immutable != true)' \
            "$release_json" >/dev/null && \
       gh release edit "$tag" --repo "$GITHUB_REPOSITORY" \
            --draft=true --latest=false; then
        github_release_find_by_tag "$tag" "$release_json"
        github_assert_release_metadata \
            "$release_json" "$tag" true "$prerelease"
        github_verify_release_assets "$release_json" "$release_dir"
        printf 'error: Release remained mutable and was rolled back to draft: %s\n' \
            "$tag" >&2
    else
        printf 'error: Release did not become immutable and could not be rolled back: %s\n' \
            "$tag" >&2
    fi
    rm -f -- "$release_json"
    return 1
}

github_assert_release_metadata() {
    local release_json=${1:?release JSON path required}
    local tag=${2:?release tag required}
    local expected_draft=${3:?expected draft status required}
    local expected_prerelease=${4:?expected prerelease status required}

    [[ "$expected_draft" =~ ^(true|false)$ ]]
    [[ "$expected_prerelease" =~ ^(true|false)$ ]]
    jq -e --arg tag "$tag" \
        --argjson draft "$expected_draft" \
        --argjson prerelease "$expected_prerelease" '
        .tag_name == $tag and .draft == $draft and
        .prerelease == $prerelease and
        ($draft == true or (has("immutable") and .immutable == true))
    ' "$release_json" >/dev/null
}

github_replace_draft_assets() {
    local release_json=${1:?release JSON path required}
    local tag=${2:?release tag required}
    local release_dir=${3:?local release directory required}
    local -a assets=()

    jq -e --arg tag "$tag" \
        '.tag_name == $tag and .draft == true' "$release_json" >/dev/null
    mapfile -d '' assets < <(find "$release_dir" -mindepth 1 -maxdepth 1 \
        -type f -print0 | sort -z)
    (( ${#assets[@]} > 0 ))
    gh release upload "$tag" "${assets[@]}" \
        --repo "$GITHUB_REPOSITORY" --clobber
}

github_verify_release_assets() {
    local release_json=${1:?release JSON path required}
    local release_dir=${2:?local release directory required}
    local local_names_json remote_dir asset name asset_id manifest_names \
        payload_names

    [[ -d "$release_dir" && ! -L "$release_dir" ]]
    [[ -z $(find "$release_dir" -mindepth 1 -maxdepth 1 ! -type f \
        -print -quit) ]]
    [[ -s "$release_dir/SHA256SUMS" && \
       ! -L "$release_dir/SHA256SUMS" ]]
    manifest_names=$(mktemp "$RUNNER_TEMP/github-manifest-names.XXXXXXXX")
    payload_names=$(mktemp "$RUNNER_TEMP/github-payload-names.XXXXXXXX")
    awk '
        NF != 2 || $1 !~ /^[0-9a-f]{64}$/ ||
          $2 !~ /^[A-Za-z0-9][A-Za-z0-9+._-]*$/ ||
          $2 == "SHA256SUMS" || seen[$2]++ { exit 1 }
        { print $2 }
        END { if (NR == 0) exit 1 }
    ' "$release_dir/SHA256SUMS" | sort > "$manifest_names"
    find "$release_dir" -mindepth 1 -maxdepth 1 -type f \
        ! -name SHA256SUMS -printf '%f\n' | sort > "$payload_names"
    cmp -- "$manifest_names" "$payload_names"
    rm -f -- "$manifest_names" "$payload_names"
    (
        cd "$release_dir" || exit 1
        sha256sum --strict --quiet -c SHA256SUMS
    )

    local_names_json=$(find "$release_dir" -mindepth 1 -maxdepth 1 \
        -type f -printf '%f\0' | sort -z | jq -Rs 'split("\u0000")[:-1]')
    jq -e --argjson expected "$local_names_json" '
        (.assets | length) == ($expected | length) and
        ([.assets[].name] | unique | length) == ($expected | length) and
        ([.assets[].state] | all(. == "uploaded")) and
        ([.assets[].name] | sort) == $expected
    ' "$release_json" >/dev/null

    remote_dir=$(mktemp -d "$RUNNER_TEMP/github-release-assets.XXXXXXXX")
    while IFS= read -r -d '' asset; do
        name=$(basename -- "$asset")
        asset_id=$(jq -er --arg name "$name" '
            [.assets[] | select(.name == $name)] |
            if length == 1 then .[0].id else error("asset is not unique") end
        ' "$release_json")
        [[ "$asset_id" =~ ^[1-9][0-9]*$ ]]
        gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
            -H 'Accept: application/octet-stream' \
            "repos/$GITHUB_REPOSITORY/releases/assets/$asset_id" \
            > "$remote_dir/$name"
    done < <(find "$release_dir" -mindepth 1 -maxdepth 1 -type f \
        -print0 | sort -z)

    diff -qr --no-dereference -- "$release_dir" "$remote_dir" >/dev/null
    (
        cd "$remote_dir" || exit 1
        sha256sum --strict --quiet -c SHA256SUMS
    )
    rm -rf -- "$remote_dir"
}
