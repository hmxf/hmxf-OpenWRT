#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail

export LC_ALL=C
export TZ=UTC

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
WORKFLOW_DIR="$PROJECT_ROOT/.github/workflows"
UPSTREAM_WORKFLOW="$WORKFLOW_DIR/upstream-check.yml"
MANUAL_INPUT_WORKFLOW="$WORKFLOW_DIR/publish-locked-inputs.yml"
REFRESH_WORKFLOW="$WORKFLOW_DIR/refresh-locks.yml"
RELEASE_HELPER="$PROJECT_ROOT/scripts/lib/github-release.sh"
REVIEWED_EXTRACTOR="$PROJECT_ROOT/scripts/inputs/extract-reviewed-candidate.py"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

for tool in awk grep wc; do
    command -v "$tool" >/dev/null 2>&1 || die "missing test tool: $tool"
done
[[ -f "$UPSTREAM_WORKFLOW" && ! -L "$UPSTREAM_WORKFLOW" ]] || \
    die 'scheduled publication workflow is missing or unsafe'
[[ -x "$RELEASE_HELPER" && ! -L "$RELEASE_HELPER" ]] || \
    die 'GitHub Release helper is missing, unsafe, or not executable'
[[ -x "$REVIEWED_EXTRACTOR" && ! -L "$REVIEWED_EXTRACTOR" ]] || \
    die 'reviewed candidate extractor is missing, unsafe, or not executable'

if grep -R -nE 'github[.]run_attempt|attempt-' "$WORKFLOW_DIR"; then
    die 'workflow artifact identities must not depend on a rerun attempt'
fi
upload_count=$(grep -R -h -c 'uses: actions/upload-artifact@' "$WORKFLOW_DIR" |
    awk '{ total += $1 } END { print total + 0 }')
overwrite_count=$(grep -R -h -c '^[[:space:]]*overwrite: true$' "$WORKFLOW_DIR" |
    awk '{ total += $1 } END { print total + 0 }')
[[ "$upload_count" -gt 0 && "$upload_count" -eq "$overwrite_count" ]] || \
    die 'every artifact producer must explicitly overwrite its run-id slot'

for job in nightly-capture nightly-build nightly-stage nightly-publish; do
    grep -Fqx "  $job:" "$UPSTREAM_WORKFLOW" || \
        die "nightly phase job is missing: $job"
done
grep -Fqx '  locked-input-draft-probe:' "$UPSTREAM_WORKFLOW" || \
    die 'stable draft recovery has no push-visible isolated probe'
awk '
    $0 == "  locked-input-draft-probe:" { inside = 1 }
    $0 == "  detect:" { exit }
    inside && /contents: write/ { write_permission = 1 }
    inside && /releases[?]per_page=100/ { release_listing = 1 }
    END { exit !(write_permission && release_listing) }
' "$UPSTREAM_WORKFLOW" || \
    die 'isolated draft probe lacks push visibility or Release enumeration'
awk '
    $0 == "  locked-input-draft-probe:" { inside = 1 }
    $0 == "  detect:" { exit }
    inside && /(gh release|git push| -X (POST|PATCH|PUT|DELETE)|--method (POST|PATCH|PUT|DELETE))/ {
        forbidden = 1
    }
    END { exit forbidden }
' "$UPSTREAM_WORKFLOW" || \
    die 'the push-visible draft probe contains a mutating request'
grep -Fq 'needs: locked-input-draft-probe' "$UPSTREAM_WORKFLOW" || \
    die 'upstream detection does not wait for the isolated draft probe'
grep -Fq 'LOCKED_INPUT_DRAFT_PRESENT: ${{ needs.locked-input-draft-probe.outputs.present }}' \
    "$UPSTREAM_WORKFLOW" || \
    die 'stable recovery classification ignores the push-visible draft result'
awk '
    $0 == "  detect:" { inside = 1 }
    $0 == "  keepalive:" { exit }
    inside && /contents: write/ { forbidden = 1 }
    END { exit forbidden }
' "$UPSTREAM_WORKFLOW" || \
    die 'the upstream parser itself must remain read-only'
grep -Fq 'build/upstream/UPSTREAM_STATE.env capture' "$UPSTREAM_WORKFLOW" || \
    die 'nightly capture phase is not explicit'
grep -Fq 'build/upstream/UPSTREAM_STATE.env rebuild "${{ matrix.target }}"' \
    "$UPSTREAM_WORKFLOW" || die 'nightly final rebuild is not target-matrix isolated'
grep -Fq 'nightly-build-identity.sh content' "$UPSTREAM_WORKFLOW" || \
    die 'workflow bypasses the order-independent portable snapshot identity helper'

grep -Fq '(.assets | length) == 33' "$UPSTREAM_WORKFLOW" || \
    die 'nightly detector does not require the exact 33-asset release contract'
grep -Fq 'END { if (NR != 32) exit 1 }' "$UPSTREAM_WORKFLOW" || \
    die 'nightly detector does not require 32 SHA256SUMS entries'
grep -Fq 'NIGHTLY_BUILD_CONTEXT.tar' "$UPSTREAM_WORKFLOW" || \
    die 'nightly Release omits its durable offline build context'
grep -Fq 'immortalwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst' \
    "$UPSTREAM_WORKFLOW" || \
    die 'nightly exact-asset contract uses stable-version ImageBuilder names'
grep -Fq 'immortalwrt-SNAPSHOT-rpi5-package-snapshot.tar.zst' \
    "$UPSTREAM_WORKFLOW" || \
    die 'nightly exact-asset contract omits SNAPSHOT package bundles'
grep -Fq '$(wc -l < "$pointer") -eq 6' "$UPSTREAM_WORKFLOW" || \
    die 'nightly capture does not require the six-key build state'
grep -Fq 'tag="nightly-$FINGERPRINT"' "$UPSTREAM_WORKFLOW" || \
    die 'nightly publication tag is not the complete final fingerprint'

grep -Fq 'A malformed historical prerelease is not valid durable state.' \
    "$UPSTREAM_WORKFLOW" || \
    die 'nightly detector does not document malformed-candidate tolerance'
grep -Fq 'if ! validate_build_state "$candidate_dir/NIGHTLY_BUILD.env"; then' \
    "$UPSTREAM_WORKFLOW" || \
    die 'malformed nightly build provenance is not handled as a candidate miss'
grep -Fq 'if (( api_status == 1 )); then' "$UPSTREAM_WORKFLOW" || \
    die 'a missing historical nightly tag is not handled as a candidate miss'

grep -Fq 'github_require_immutable_releases_enabled' "$RELEASE_HELPER" || \
    die 'publication does not fail closed when Immutable Releases is disabled'
if grep -R -Fq 'github_require_immutable_releases_enabled' "$WORKFLOW_DIR"; then
    die 'Actions GITHUB_TOKEN must not require repository Administration read'
fi
grep -Fq 'has("immutable") and .immutable == true' "$RELEASE_HELPER" || \
    die 'published Release metadata must explicitly report immutable=true'
grep -Fq 'github_publish_draft_and_require_immutable' "$RELEASE_HELPER" || \
    die 'draft publication does not poll for immutable=true'
grep -Fq 'Release remained mutable and was rolled back to draft' \
    "$RELEASE_HELPER" || \
    die 'a mutable publication is not recoverably rolled back'
grep -Fq 'render_plan_input_manifest > "$current_plan_manifest"' \
    "$UPSTREAM_WORKFLOW" || \
    die 'nightly detector does not render the current build plan'
grep -Fq 'cmp -s "$candidate_dir/PLAN_INPUTS.sha256"' \
    "$UPSTREAM_WORKFLOW" || \
    die 'nightly detector can deduplicate a stale historical build plan'
grep -Fq "reason=recover-locked-input-draft" "$UPSTREAM_WORKFLOW" || \
    die 'stable locked-input draft has no next-run recovery classification'
grep -Fq 'github_rebind_draft_tag_at_commit' "$UPSTREAM_WORKFLOW" || \
    die 'stable input draft is not rebound to the pushed lock commit'
grep -Fq 'github_bind_unreleased_lightweight_tag_at_commit' \
    "$UPSTREAM_WORKFLOW" || \
    die 'a failed draft creation can strand an unrecoverable orphan tag'
grep -Fq 'git diff --quiet "$fetched_input_commit" "$GITHUB_SHA" --' \
    "$UPSTREAM_WORKFLOW" || \
    die 'same-version bootstrap does not bind the input tag tree to formal locks'
grep -Fq 'diff -qr --no-dereference -- "$candidate_dir/locks" locks' \
    "$UPSTREAM_WORKFLOW" || \
    die 'published locked inputs are not compared with candidate locks before apply'
grep -Fq 'published locked-input tag tree differs from the current formal plan' \
    "$UPSTREAM_WORKFLOW" || \
    die 'stable update lacks a pre-mutation published-tag closure gate'
grep -Fq 'RELEASE_WAS_DRAFT: ${{ steps.input_release.outputs.was_draft }}' \
    "$UPSTREAM_WORKFLOW" || \
    die 'stable finalization forgets whether an input Release was already immutable'
grep -Fq 'final_tag_commit=$EXPECTED_TAG_COMMIT' "$UPSTREAM_WORKFLOW" || \
    die 'idempotent stable update cannot preserve an older closure-equivalent input tag'

grep -Fq 'candidate_artifact_id:' "$MANUAL_INPUT_WORKFLOW" || \
    die 'manual publication does not require the reviewed Artifact ID'
grep -Fq 'candidate_artifact_sha256:' "$MANUAL_INPUT_WORKFLOW" || \
    die 'manual publication does not require the reviewed Artifact SHA-256'
grep -Fq 'ARTIFACT_ID: ${{ steps.reviewed_artifact.outputs.artifact-id }}' \
    "$REFRESH_WORKFLOW" || \
    die 'refresh summary omits the immutable Artifact ID'
grep -Fq 'ARTIFACT_SHA256: ${{ steps.reviewed_artifact.outputs.artifact-digest }}' \
    "$REFRESH_WORKFLOW" || \
    die 'refresh summary omits the immutable Artifact digest'
grep -Fq 'actions/artifacts/$CANDIDATE_ARTIFACT_ID"' \
    "$MANUAL_INPUT_WORKFLOW" || \
    die 'manual publication does not query the reviewed Artifact by ID'
grep -Fq '.digest == $digest' "$MANUAL_INPUT_WORKFLOW" || \
    die 'manual publication does not bind REST metadata to the reviewed digest'
grep -Fq '.workflow_run.id == $run_id' "$MANUAL_INPUT_WORKFLOW" || \
    die 'manual publication does not bind the Artifact to the reviewed run'
grep -Fq '.workflow_run.head_sha == $sha' "$MANUAL_INPUT_WORKFLOW" || \
    die 'manual publication does not bind the Artifact to the reviewed commit'
grep -Fq 'actions/artifacts/$CANDIDATE_ARTIFACT_ID/zip"' \
    "$MANUAL_INPUT_WORKFLOW" || \
    die 'manual publication does not download the immutable Artifact ID'
grep -Fq 'sha256sum "$archive"' "$MANUAL_INPUT_WORKFLOW" || \
    die 'manual publication does not hash the raw archive before extraction'
grep -Fq './scripts/inputs/extract-reviewed-candidate.py' \
    "$MANUAL_INPUT_WORKFLOW" || \
    die 'manual publication bypasses safe reviewed-candidate extraction'
grep -Fq 'package-cache package-snapshot-bundles package-snapshots' \
    "$MANUAL_INPUT_WORKFLOW" || \
    die 'manual publication does not enforce the exact candidate root shape'
if grep -Fq 'gh run download' "$MANUAL_INPUT_WORKFLOW"; then
    die 'manual publication can fall back to mutable name-based Artifact download'
fi
grep -Fq 'make apply-locks CANDIDATE="$CANDIDATE_DIR"' \
    "$MANUAL_INPUT_WORKFLOW" || \
    die 'manual locked-input publication does not apply its reviewed locks'
grep -Fq -- '--force-with-lease="refs/heads/$DEFAULT_BRANCH:$EXPECTED_BASE"' \
    "$MANUAL_INPUT_WORKFLOW" || \
    die 'manual locked-input publication does not use an exact lease push'
grep -Fq '"$release_json" "$RELEASE_TAG" "$PUSHED_COMMIT"' \
    "$MANUAL_INPUT_WORKFLOW" || \
    die 'manual locked-input draft is not rebound to the pushed lock commit'
prepare_line=$(grep -nF 'Prepare and remotely verify a recoverable draft' \
    "$MANUAL_INPUT_WORKFLOW" | awk -F: 'NR == 1 { print $1 }')
apply_line=$(grep -nF 'Apply the reviewed candidate and rerun its complete gates' \
    "$MANUAL_INPUT_WORKFLOW" | awk -F: 'NR == 1 { print $1 }')
publish_line=$(grep -nF 'Bind the draft to the pushed locks and publish once' \
    "$MANUAL_INPUT_WORKFLOW" | awk -F: 'NR == 1 { print $1 }')
[[ "$prepare_line" =~ ^[1-9][0-9]*$ && \
   "$apply_line" =~ ^[1-9][0-9]*$ && \
   "$publish_line" =~ ^[1-9][0-9]*$ && \
   "$prepare_line" -lt "$apply_line" && "$apply_line" -lt "$publish_line" ]] || \
    die 'manual locked-input publication transaction is ordered incorrectly'
metadata_line=$(grep -nF 'artifact_file="$RUNNER_TEMP/reviewed-candidate-artifact.json"' \
    "$MANUAL_INPUT_WORKFLOW" | awk -F: 'NR == 1 { print $1 }')
archive_hash_line=$(grep -nF '[[ $(sha256sum "$archive"' \
    "$MANUAL_INPUT_WORKFLOW" | awk -F: 'NR == 1 { print $1 }')
extract_line=$(grep -nF './scripts/inputs/extract-reviewed-candidate.py' \
    "$MANUAL_INPUT_WORKFLOW" | awk -F: 'NR == 1 { print $1 }')
[[ "$metadata_line" =~ ^[1-9][0-9]*$ && \
   "$archive_hash_line" =~ ^[1-9][0-9]*$ && \
   "$extract_line" =~ ^[1-9][0-9]*$ && \
   "$metadata_line" -lt "$archive_hash_line" && \
   "$archive_hash_line" -lt "$extract_line" && \
   "$extract_line" -lt "$prepare_line" ]] || \
    die 'reviewed Artifact identity/hash/extraction gates are ordered incorrectly'
grep -Fq 'refusing to rebind a tag attached to a Release' "$RELEASE_HELPER" || \
    die 'the orphan-tag helper can mutate a tag attached to a Release'
grep -Fq 'SNAPSHOT_PACKAGES_SHA256' "$UPSTREAM_WORKFLOW" || \
    die 'nightly workflow ignores the package-repository identity'
grep -Fq "printf '%s\\n%s\\n%s\\n%s\\n%s\\n' \"\$current_revision\"" \
    "$UPSTREAM_WORKFLOW" || \
    die 'current nightly fingerprint omits version code or full source commit'
grep -Fq '"$current_commit" =~ ^[0-9a-f]{40}$' "$UPSTREAM_WORKFLOW" || \
    die 'nightly workflow does not require a full source commit'
grep -Fq 'if (NR != 17' "$UPSTREAM_WORKFLOW" || \
    die 'nightly workflow does not require the exact 17-key upstream state'
grep -Fq 'needs.stable-input-recovery.result == '\''success'\''' \
    "$UPSTREAM_WORKFLOW" || \
    die 'recovered locked inputs do not feed the canonical stable build'
awk '
    $0 == "  stable-firmware:" { inside = 1 }
    $0 == "  stable-release:" { exit }
    inside && /!cancelled[(][)]/ { status_gate = 1 }
    inside && /needs[.]detect[.]result == '\''success'\''/ { detect = 1 }
    inside && /needs[.]stable-ref[.]result == '\''success'\''/ { stable_ref = 1 }
    END { exit !(status_gate && detect && stable_ref) }
' "$UPSTREAM_WORKFLOW" || \
    die 'canonical stable build can be suppressed by a skipped alternative ancestor'
awk '
    $0 == "  stable-release:" { inside = 1 }
    $0 == "  nightly-capture:" { exit }
    inside && /!cancelled[(][)]/ { status_gate = 1 }
    inside && /needs[.]detect[.]result == '\''success'\''/ { detect = 1 }
    inside && /needs[.]stable-ref[.]result == '\''success'\''/ { stable_ref = 1 }
    inside && /needs[.]stable-firmware[.]result == '\''success'\''/ { firmware = 1 }
    END { exit !(status_gate && detect && stable_ref && firmware) }
' "$UPSTREAM_WORKFLOW" || \
    die 'stable publication can be suppressed by a skipped alternative ancestor'
grep -Fq '! -type d -print -quit' "$UPSTREAM_WORKFLOW" || \
    die 'nightly target artifacts allow nodes beside the sole target directory'
grep -Fq "X-GitHub-Api-Version: 2026-03-10" "$RELEASE_HELPER" || \
    die 'immutable Release metadata is not requested with the required API version'
grep -Fq 'github_replace_draft_assets' "$RELEASE_HELPER" || \
    die 'draft recovery helper is missing'
grep -Fq '.draft == true' "$RELEASE_HELPER" || \
    die 'asset replacement is not restricted to draft Releases'
grep -Fq '$2 == "SHA256SUMS" || seen[$2]++' "$RELEASE_HELPER" || \
    die 'Release checksum manifests are not safe, unique basename-only indexes'
grep -Fq 'cmp -- "$manifest_names" "$payload_names"' "$RELEASE_HELPER" || \
    die 'Release checksum manifests need not cover the exact payload set'

printf '%s\n' 'Workflow publication and rerun contracts passed.'
