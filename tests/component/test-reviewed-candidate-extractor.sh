#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
extractor="$PROJECT_ROOT/scripts/inputs/extract-reviewed-candidate.py"
tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

[[ -x "$extractor" && ! -L "$extractor" ]]

make_zip() {
    local destination=${1:?ZIP destination required}
    local fixture=${2:?fixture name required}
    python3 - "$destination" "$fixture" <<'PY'
from pathlib import Path
import stat
import sys
import zipfile

destination = Path(sys.argv[1])
fixture = sys.argv[2]
with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    if fixture == "valid":
        archive.writestr("locks/", b"")
        archive.writestr("locks/release.env", b"IMMORTALWRT_VERSION=25.12.1\n")
        archive.writestr("REPORT.md", b"reviewed\n")
    elif fixture == "traversal":
        archive.writestr("../outside", b"bad")
    elif fixture == "absolute":
        archive.writestr("/tmp/outside", b"bad")
    elif fixture == "backslash":
        archive.writestr("locks\\outside", b"bad")
    elif fixture == "duplicate":
        archive.writestr("same", b"first")
        archive.writestr("same", b"second")
    elif fixture == "prefix":
        archive.writestr("node", b"file")
        archive.writestr("node/child", b"bad")
    elif fixture in {"symlink", "fifo"}:
        member = zipfile.ZipInfo("special")
        member.create_system = 3
        kind = stat.S_IFLNK if fixture == "symlink" else stat.S_IFIFO
        member.external_attr = (kind | 0o777) << 16
        archive.writestr(member, b"target")
    else:
        raise SystemExit(f"unknown fixture: {fixture}")
PY
}

valid_zip="$tmp_dir/valid.zip"
valid_out="$tmp_dir/valid-out"
make_zip "$valid_zip" valid
"$extractor" "$valid_zip" "$valid_out"
[[ -d "$valid_out/locks" && ! -L "$valid_out/locks" ]]
[[ -f "$valid_out/locks/release.env" && \
   ! -L "$valid_out/locks/release.env" ]]
grep -Fqx 'IMMORTALWRT_VERSION=25.12.1' \
    "$valid_out/locks/release.env"
[[ $(stat -c '%a' "$valid_out/locks/release.env") == 644 ]]

sentinel="$tmp_dir/outside"
printf '%s\n' unchanged > "$sentinel"
for fixture in traversal absolute backslash duplicate prefix symlink fifo; do
    archive="$tmp_dir/$fixture.zip"
    output="$tmp_dir/$fixture-out"
    make_zip "$archive" "$fixture" 2>/dev/null
    if "$extractor" "$archive" "$output" >/dev/null 2>&1; then
        printf 'error: unsafe %s ZIP unexpectedly extracted\n' "$fixture" >&2
        exit 1
    fi
    [[ ! -e "$output" && ! -L "$output" ]]
    grep -Fqx unchanged "$sentinel"
done

archive_link="$tmp_dir/archive-link.zip"
ln -s -- "$valid_zip" "$archive_link"
if "$extractor" "$archive_link" "$tmp_dir/link-out" >/dev/null 2>&1; then
    printf '%s\n' 'error: symbolic-link artifact ZIP unexpectedly extracted' >&2
    exit 1
fi
[[ ! -e "$tmp_dir/link-out" ]]

mkdir "$tmp_dir/existing-out"
if "$extractor" "$valid_zip" "$tmp_dir/existing-out" >/dev/null 2>&1; then
    printf '%s\n' 'error: extractor accepted an existing destination' >&2
    exit 1
fi

printf '%s\n' 'Reviewed candidate ZIP extraction tests passed.'
