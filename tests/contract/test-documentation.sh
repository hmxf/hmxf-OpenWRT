#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
export TZ=UTC

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)

command -v python3 >/dev/null 2>&1 || {
    printf '%s\n' 'error: documentation contract test requires python3' >&2
    exit 1
}

python3 - "$PROJECT_ROOT" <<'PY'
from __future__ import annotations

import os
from pathlib import Path
import re
import sys
from urllib.parse import unquote


project_root = Path(sys.argv[1]).resolve()
readme = project_root / "README.md"
makefile = project_root / "Makefile"
excluded_directories = {".git", ".cache", "build", "out", "dist", "__pycache__"}
errors: list[str] = []


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def markdown_sources() -> list[Path]:
    sources: list[Path] = []
    for root, directories, files in os.walk(project_root, followlinks=False):
        root_path = Path(root)
        directories[:] = sorted(
            directory
            for directory in directories
            if directory not in excluded_directories
            and not (root_path / directory).is_symlink()
        )
        for filename in sorted(files):
            if filename.lower().endswith(".md"):
                path = root_path / filename
                if path.is_symlink() or not path.is_file():
                    errors.append(
                        f"{path.relative_to(project_root)}: Markdown source is not a regular file"
                    )
                else:
                    sources.append(path)
    return sources


def readable_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        errors.append(f"{path.relative_to(project_root)}: invalid UTF-8: {error}")
        return ""


def documentation_lines(text: str):
    """Yield non-fenced lines; links shown merely as code are not documentation."""

    in_fence = False
    fence_character = ""
    fence_length = 0
    offset = 0
    for line in text.splitlines(keepends=True):
        fence = re.match(r"^[ ]{0,3}(`{3,}|~{3,})", line)
        if fence:
            marker = fence.group(1)
            if not in_fence:
                in_fence = True
                fence_character = marker[0]
                fence_length = len(marker)
            elif marker[0] == fence_character and len(marker) >= fence_length:
                in_fence = False
            offset += len(line)
            continue
        if not in_fence:
            # Inline code often demonstrates Markdown syntax and is not a link.
            visible = re.sub(r"`[^`\n]*`", "", line)
            yield visible, offset
        offset += len(line)


def destination(raw: str) -> str:
    value = raw.strip()
    if value.startswith("<"):
        closing = value.find(">", 1)
        return value[1:closing] if closing != -1 else value
    return value.split(maxsplit=1)[0] if value else ""


scheme = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
inline_link = re.compile(r"!?\[[^]\n]*\]\(([^)\n]*)\)")
reference_link = re.compile(r"^[ ]{0,3}\[[^]\n]+\]:[ \t]*(.+?)\s*$")
script_path = re.compile(r"(?<![-A-Za-z0-9_./])(\./scripts/[-A-Za-z0-9_./+@%]+)")

markdown = markdown_sources()
link_count = 0
script_reference_count = 0
seen_script_references: set[tuple[Path, int, str]] = set()

for source in markdown:
    text = readable_text(source)
    relative_source = source.relative_to(project_root)

    for line, offset in documentation_lines(text):
        candidates = [(match.group(1), match.start(1)) for match in inline_link.finditer(line)]
        definition = reference_link.match(line)
        if definition:
            candidates.append((definition.group(1), definition.start(1)))
        for raw_target, local_offset in candidates:
            target_text = destination(raw_target)
            if not target_text:
                continue
            # External URLs, protocol-relative URLs, absolute paths, and local
            # anchors are deliberately outside this offline existence check.
            if (
                target_text.startswith(("#", "/", "?"))
                or scheme.match(target_text)
            ):
                continue
            path_text = target_text.split("#", 1)[0].split("?", 1)[0]
            if not path_text:
                continue
            path_text = unquote(path_text)
            path_text = re.sub(r"\\([\\() ])", r"\1", path_text)
            resolved = (source.parent / path_text).resolve()
            try:
                resolved.relative_to(project_root)
            except ValueError:
                errors.append(
                    f"{relative_source}:{line_number(text, offset + local_offset)}: "
                    f"relative link escapes the repository: {target_text}"
                )
                continue
            link_count += 1
            if not resolved.exists():
                errors.append(
                    f"{relative_source}:{line_number(text, offset + local_offset)}: "
                    f"missing relative link target: {target_text}"
                )

    # Executable command examples normally live in fenced code blocks, so scan
    # the complete source for explicit ./scripts/... references.
    for match in script_path.finditer(text):
        documented = match.group(1).rstrip(".,;:)]}")
        location = line_number(text, match.start(1))
        identity = (source, location, documented)
        if identity in seen_script_references:
            continue
        seen_script_references.add(identity)
        script_reference_count += 1
        # A shell command beginning with ./scripts is documented relative to
        # the repository checkout, even when it appears in docs/*.md.
        resolved = (project_root / documented.removeprefix("./")).resolve()
        scripts_root = (project_root / "scripts").resolve()
        try:
            resolved.relative_to(scripts_root)
        except ValueError:
            errors.append(
                f"{relative_source}:{location}: script reference escapes scripts/: {documented}"
            )
            continue
        if not resolved.is_file() or resolved.is_symlink():
            errors.append(
                f"{relative_source}:{location}: documented script does not exist safely: {documented}"
            )
        elif not os.access(resolved, os.X_OK):
            errors.append(
                f"{relative_source}:{location}: documented script is not executable: {documented}"
            )

if not readme.is_file() or readme.is_symlink():
    errors.append("README.md: missing or unsafe project README")
    readme_text = ""
else:
    readme_text = readable_text(readme)

if not makefile.is_file() or makefile.is_symlink():
    errors.append("Makefile: missing or unsafe project Makefile")
    makefile_text = ""
else:
    makefile_text = readable_text(makefile)

declared_targets: set[str] = set()
target_declaration = re.compile(r"^([^\t#:=][^#:=]*?):(?:[^=]|$)")
for line in makefile_text.splitlines():
    declaration = target_declaration.match(line)
    if not declaration:
        continue
    for target in declaration.group(1).split():
        if target.startswith(".") or "$" in target or "%" in target:
            continue
        declared_targets.add(target)

make_reference = re.compile(
    r"(?<![-A-Za-z0-9_./])make"
    r"(?:[ \t]+(?:-[^ \t`]+|[A-Za-z_][A-Za-z0-9_]*=[^ \t`]+))*"
    r"[ \t]+([A-Za-z0-9][A-Za-z0-9_.-]*)"
)
referenced_targets: set[str] = set()
for match in make_reference.finditer(readme_text):
    target = match.group(1)
    referenced_targets.add(target)
    if target not in declared_targets:
        errors.append(
            f"README.md:{line_number(readme_text, match.start(1))}: "
            f"documented make target is not declared: {target}"
        )

if errors:
    for error in sorted(set(errors)):
        print(f"error: {error}", file=sys.stderr)
    raise SystemExit(1)

print(
    "Documentation contract passed "
    f"({len(markdown)} Markdown files, {link_count} relative links, "
    f"{script_reference_count} script references, "
    f"{len(referenced_targets)} README make targets)."
)
PY
