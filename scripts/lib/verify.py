"""Verify generated firmware identity, boot layout, and embedded filesystem."""
from __future__ import annotations

import copy
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from .lock import TARGETS

ROOTFS_MIB = 3072
MEDIA_BYTES = 4_000_000_000
_SAFE_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9+._-]*\Z')
_SHA256 = re.compile(r'[0-9a-f]{64}\Z')
_PACKAGE = re.compile(r'[A-Za-z0-9][A-Za-z0-9+._-]*\Z')


def _regular(path: Path) -> None:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f'missing or unsafe regular file: {path}')


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _unique_json(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate JSON key: {key}')
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValueError(f'invalid JSON constant: {value}')


def canonical_metadata(metadata):
    """Upstream builds image lists from unsorted directory iteration."""
    metadata = copy.deepcopy(metadata)
    if isinstance(metadata, dict) and isinstance(metadata.get('profiles'), dict):
        for profile in metadata['profiles'].values():
            if isinstance(profile, dict) and isinstance(profile.get('images'), list):
                images = profile['images']
                if all(isinstance(image, dict) and isinstance(image.get('name'), str) for image in images):
                    images.sort(key=lambda image: image['name'])
    return metadata


def _load_metadata(path: Path) -> dict:
    _regular(path)
    try:
        metadata = json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=_unique_json,
                              parse_constant=_invalid_constant)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f'invalid profiles.json: {exc}') from exc
    if not isinstance(metadata, dict):
        raise ValueError('profiles.json must be an object')
    return canonical_metadata(metadata)


def _check_metadata(metadata: dict, expected: dict, target: str) -> dict:
    spec = TARGETS[target]
    for field in ('version_number', 'version_code', 'source_date_epoch', 'target', 'arch_packages', 'linux_kernel'):
        if field not in expected or field not in metadata or metadata[field] != expected[field]:
            raise ValueError(f'profiles.json {field} mismatch')
    if metadata['target'] != spec['target']:
        raise ValueError('profiles.json target does not match selected device')
    if not isinstance(metadata['source_date_epoch'], int) or isinstance(metadata['source_date_epoch'], bool):
        raise ValueError('profiles.json source_date_epoch must be an integer')
    if not isinstance(metadata['arch_packages'], str) or not metadata['arch_packages']:
        raise ValueError('profiles.json package architecture is missing')
    kernel = metadata['linux_kernel']
    if not isinstance(kernel, dict) or not all(isinstance(kernel.get(k), str) and kernel[k] for k in ('version', 'release', 'vermagic')):
        raise ValueError('profiles.json kernel identity is incomplete')
    profiles = metadata.get('profiles')
    expected_profiles = expected.get('profiles')
    profile_key = spec['profile']
    if not isinstance(profiles, dict) or not isinstance(expected_profiles, dict):
        raise ValueError('profiles.json device profiles are missing')
    profile = profiles.get(profile_key)
    upstream_profile = expected_profiles.get(profile_key)
    if not isinstance(profile, dict) or not isinstance(upstream_profile, dict):
        raise ValueError(f'profiles.json is missing device profile {profile_key}')
    for field in ('supported_devices', 'device_packages'):
        if field in upstream_profile and profile.get(field) != upstream_profile[field]:
            raise ValueError(f'profiles.json device {field} mismatch')
    return profile


def _images(output: Path, profile: dict, target: str) -> list[dict]:
    entries = profile.get('images')
    if not isinstance(entries, list) or not entries:
        raise ValueError('profiles.json image list is missing')
    seen = set()
    selected = {}
    expected_types = {'combined-efi'} if target == 'x86_64' else {'factory', 'sysupgrade'}
    described_gzip = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError('invalid profiles.json image entry')
        name = entry.get('name')
        if not isinstance(name, str) or not _SAFE_NAME.fullmatch(name) or name in seen:
            raise ValueError(f'unsafe or duplicate profiles.json image name: {name!r}')
        seen.add(name)
        path = output / name
        _regular(path)
        size = path.stat().st_size
        sha = _sha256(path)
        if type(entry.get('size')) is not int or entry['size'] != size or size <= 0 or size >= MEDIA_BYTES:
            raise ValueError(f'image size mismatch or exceeds media limit: {name}')
        if not isinstance(entry.get('sha256'), str) or not _SHA256.fullmatch(entry['sha256']) or entry['sha256'] != sha:
            raise ValueError(f'image SHA-256 mismatch: {name}')
        if name.endswith('.img.gz'):
            described_gzip.add(name)
        image_type = entry.get('type')
        if entry.get('filesystem') == 'squashfs' and image_type in expected_types:
            if image_type in selected or not name.endswith(f'-squashfs-{image_type}.img.gz'):
                raise ValueError(f'ambiguous or unsupported SquashFS image: {name}')
            selected[image_type] = {'filename': name, 'sha256': sha, 'bytes': size}
    actual_gzip = {path.name for path in output.glob('*.img.gz')}
    if actual_gzip != described_gzip:
        raise ValueError('actual image filenames differ from profiles.json')
    if set(selected) != expected_types:
        raise ValueError(f'wrong SquashFS image types for {target}')
    return [selected[key] for key in sorted(selected)]


def _manifest(output: Path, requested: list[str], recipe_root: Path) -> tuple[list[str], str]:
    manifests = list(output.glob('*.manifest'))
    if len(manifests) != 1:
        raise ValueError('expected exactly one package manifest')
    path = manifests[0]
    _regular(path)
    try:
        data = path.read_bytes()
        text = data.decode('utf-8')
        if not data.endswith(b'\n') or b'\r' in data:
            raise ValueError('package manifest must use canonical LF line endings')
        lines = text.splitlines()
    except (OSError, UnicodeError) as exc:
        raise ValueError(f'invalid package manifest: {exc}') from exc
    packages = set()
    if not lines:
        raise ValueError('empty package manifest')
    for line in lines:
        fields = line.split()
        if len(fields) != 3 or fields[1] != '-' or not _PACKAGE.fullmatch(fields[0]) or fields[0] in packages:
            raise ValueError(f'invalid or duplicate package manifest entry: {line!r}')
        packages.add(fields[0])
    for package in requested:
        removed = package.startswith('-')
        name = package[1:] if removed else package
        if not _PACKAGE.fullmatch(name):
            raise ValueError(f'invalid requested package: {package!r}')
        if (not removed and name not in packages) or (removed and name in packages):
            raise ValueError(f'package manifest does not match requested package: {package}')
    runtime_file = recipe_root / 'packages/runtime-apps.txt'
    _regular(runtime_file)
    for line in runtime_file.read_text(encoding='utf-8').splitlines():
        name = line.split('#', 1)[0].strip()
        if name and name in packages:
            raise ValueError(f'runtime application was unexpectedly embedded: {name}')
    return lines, _sha256(path)


def _run(command: list[str], *, binary: bool = False):
    try:
        result = subprocess.run(command, capture_output=True, check=True, text=not binary)
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, 'stderr', '') or str(exc)
        if isinstance(detail, bytes):
            detail = detail.decode('utf-8', errors='replace')
        raise ValueError(f'verification command failed ({command[0]}): {detail}') from exc
    return result.stdout


def _verify_structure(images: list[Path], target: str, metadata: dict, recipe_root: Path) -> None:
    script = Path(__file__).resolve().parents[1] / 'verify/verify-image-structure.py'
    _regular(script)
    _run([sys.executable, str(script), '--expected-version', metadata['version_number'],
          '--expected-revision', metadata['version_code'], target, str(ROOTFS_MIB), str(MEDIA_BYTES),
          *map(str, images)])


def _verify_filesystem(image: Path, target: str, recipe_root: Path) -> None:
    offset = (66048 if target == 'x86_64' else 147456) * 512
    with tempfile.TemporaryDirectory(prefix='firmware-verify-') as directory:
        raw = Path(directory) / 'firmware.img'
        size = 0
        try:
            with gzip.open(image, 'rb') as compressed, raw.open('wb') as stream:
                for chunk in iter(lambda: compressed.read(4 * 1024 * 1024), b''):
                    size += len(chunk)
                    if size >= MEDIA_BYTES:
                        raise ValueError('uncompressed image exceeds media limit')
                    if chunk.count(0) == len(chunk):
                        stream.seek(len(chunk), 1)
                    else:
                        stream.write(chunk)
                stream.truncate(size)
        except (OSError, EOFError) as exc:
            raise ValueError(f'invalid compressed filesystem image: {exc}') from exc
        _run(['unsquashfs', '-stat', '-offset', str(offset), str(raw)])

        def read_file(name: str) -> bytes:
            data = _run(['unsquashfs', '-cat', '-offset', str(offset), str(raw), name], binary=True)
            if not data:
                raise ValueError(f'root filesystem file is empty: {name}')
            return data

        overlay = recipe_root / 'files'
        if not overlay.is_dir() or overlay.is_symlink():
            raise ValueError('recipe overlay directory is missing or unsafe')
        for source in sorted(overlay.rglob('*')):
            if source.is_symlink():
                raise ValueError(f'unsupported symlink in recipe overlay: {source}')
            if source.is_file():
                name = source.relative_to(overlay).as_posix()
                data = _run(['unsquashfs', '-cat', '-offset', str(offset), str(raw), name], binary=True)
                if data != source.read_bytes():
                    raise ValueError(f'embedded overlay differs from recipe: {name}')
        uhttpd = read_file('etc/config/uhttpd')
        if not re.search(rb'^\s+list listen_https\s+0[.]0[.]0[.]0:443\s*$', uhttpd, re.M):
            raise ValueError('embedded uhttpd does not listen on HTTPS')
        if not re.search(rb'^\s+option redirect_https\s+1\s*$', uhttpd, re.M):
            raise ValueError('embedded uhttpd does not redirect HTTP to HTTPS')
        for name in ('lib/libustream-ssl.so', 'usr/sbin/uhttpd', 'www/cgi-bin/luci'):
            read_file(name)


def verify_output(output_dir, target, expected_metadata, requested_packages, recipe_root,
                  expected_result=None, smoke=True) -> dict:
    """Verify generated output and optionally require byte-identical frozen replay.

    ``expected_metadata`` is the unchanged upstream profiles.json. Image hashes
    are taken from generated profiles.json because custom images differ from
    the upstream default images. ``expected_result`` is a prior verified result.
    """
    output, recipe = Path(output_dir), Path(recipe_root)
    if target not in TARGETS:
        raise ValueError(f'unknown firmware target: {target}')
    if not output.is_dir() or output.is_symlink():
        raise ValueError(f'missing or unsafe output directory: {output}')
    metadata = _load_metadata(output / 'profiles.json')
    profile = _check_metadata(metadata, expected_metadata, target)
    records = _images(output, profile, target)
    lines, digest = _manifest(output, requested_packages, recipe)
    result = {'images': records, 'manifest': lines, 'manifest_sha256': digest, 'metadata': metadata}
    if expected_result is not None:
        for field in ('images', 'manifest', 'manifest_sha256', 'metadata'):
            expected = expected_result.get(field)
            if field == 'metadata':
                expected = canonical_metadata(expected)
            if result[field] != expected:
                raise ValueError(f'offline replay {field} mismatch')
    images = [output / record['filename'] for record in records]
    _verify_structure(images, target, metadata, recipe)
    geometry_image = images[0]  # sorted types put factory before sysupgrade
    _verify_filesystem(geometry_image, target, recipe)
    if smoke and target == 'x86_64':
        script = recipe / 'scripts/verify/smoke-test-x86-uefi.sh'
        _regular(script)
        _run(['bash', str(script), str(output)])
    return result
