#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC
umask 022

TESTS_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TESTS_ROOT/.." && pwd)
STATIC_VALIDATOR="$PROJECT_ROOT/scripts/verify/validate-project.sh"

declare -ar CONTRACT_TESTS=(
    "$TESTS_ROOT/contract/test-documentation.sh"
    "$TESTS_ROOT/contract/test-lock-contract.sh"
    "$TESTS_ROOT/contract/test-workflow-contract.sh"
)

declare -ar COMPONENT_TESTS=(
    "$TESTS_ROOT/component/test-fwtool-identity.sh"
    "$TESTS_ROOT/component/test-nightly-build-identity.sh"
    "$TESTS_ROOT/component/test-nightly-context.sh"
    "$TESTS_ROOT/component/test-nightly-package-capture.sh"
    "$TESTS_ROOT/component/test-nightly-phase-contract.sh"
    "$TESTS_ROOT/component/test-package-cache-index.sh"
    "$TESTS_ROOT/component/test-persist-imagebuilders.sh"
    "$TESTS_ROOT/component/test-persist-package-snapshots.sh"
    "$TESTS_ROOT/component/test-reviewed-candidate-extractor.sh"
    "$TESTS_ROOT/component/test-restore-locked-inputs.sh"
    "$TESTS_ROOT/component/test-stage-locked-input-release.sh"
    "$TESTS_ROOT/component/test-stage-firmware-release.sh"
    "$TESTS_ROOT/component/test-upstream-update-classifier.sh"
)

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./tests/run.sh [all|static|contract|component]

  all        Run static validation, then contract and component tests (default).
  static     Run the production project validator only.
  contract   Run documentation and lock/configuration contract tests.
  component  Run the isolated cache, persistence, restore, and staging tests.
EOF
}

require_executable() {
    local path=${1:?path required}
    local label=${2:-test executable}
    [[ -f "$path" && ! -L "$path" && -x "$path" ]] || \
        die "$label is missing, unsafe, or not executable: $path"
}

run_executable() {
    local path=${1:?test path required}
    require_executable "$path"
    printf '\n==> %s\n' "${path#"$PROJECT_ROOT/"}"
    "$path"
}

run_static() {
    require_executable "$STATIC_VALIDATOR" 'static validator'
    printf '\n==> %s\n' "${STATIC_VALIDATOR#"$PROJECT_ROOT/"}"
    "$STATIC_VALIDATOR"
}

run_contract() {
    local test_path
    for test_path in "${CONTRACT_TESTS[@]}"; do
        run_executable "$test_path"
    done
}

run_component() {
    local test_path
    for test_path in "${COMPONENT_TESTS[@]}"; do
        run_executable "$test_path"
    done
}

[[ $# -le 1 ]] || {
    usage >&2
    exit 2
}

suite=${1:-all}
case "$suite" in
    all)
        run_static
        run_contract
        run_component
        ;;
    static)
        run_static
        ;;
    contract)
        run_contract
        ;;
    component)
        run_component
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        die "unknown test suite: $suite"
        ;;
esac

printf '\nTest suite %s passed.\n' "$suite"
