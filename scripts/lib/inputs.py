"""Download, validate and freeze ImageBuilder inputs without live replay access."""
from __future__ import annotations

import gzip
import hashlib
from http.client import IncompleteRead
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import urlopen

ATOM = re.compile(r'[A-Za-z0-9][A-Za-z0-9+._~:-]*')
PACKAGE = re.compile(r'-?[a-z0-9][a-z0-9+._-]*')
SHA = re.compile(r'[0-9a-f]{64}')
# These links are supplied by official ImageBuilders, and resolve only to tools
# in the frozen build environment. Everything outside this mapping is rejected.
HOST_TOOLS = {
    'getopt': '/usr/bin/getopt', 'perl': '/usr/bin/perl', 'diff': '/usr/bin/diff',
    'git': '/usr/bin/git', 'file': '/usr/bin/file', 'unzip': '/usr/bin/unzip',
    'rsync': '/usr/bin/rsync', 'bash': '/usr/bin/bash', 'grep': '/usr/bin/grep',
    'gzip': '/usr/bin/gzip', 'g++': '/usr/bin/g++', 'egrep': '/usr/bin/egrep',
    'which': '/usr/bin/which', 'awk': '/usr/bin/gawk', 'gcc': '/usr/bin/cc',
    'wget': '/usr/bin/wget', 'mkisofs': '/usr/bin/genisoimage',
    'python': '/usr/bin/python3.9', 'python3': '/usr/bin/python3.9',
}


def _regular(path):
    path = Path(path)
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f'not a regular file: {path}')
    return path


def sha256(path):
    digest = hashlib.sha256()
    with _regular(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path):
    path = _regular(path)
    return {'filename': path.name, 'sha256': sha256(path), 'bytes': path.stat().st_size}


def download(url, path, expected_sha=None, expected_bytes=None):
    """Validate into a sibling temporary file before replacing the destination."""
    path = Path(path)
    if urlparse(str(url)).scheme not in ('https', 'file'):
        raise ValueError(f'unsupported download URL: {url}')
    if expected_sha is not None and not SHA.fullmatch(expected_sha):
        raise ValueError('invalid expected SHA-256')
    if expected_bytes is not None and (type(expected_bytes) is not int or expected_bytes <= 0):
        raise ValueError('invalid expected byte count')
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError(f'unsafe download destination: {path}')
    if path.exists():
        _regular(path)
        size = path.stat().st_size
        if expected_sha is not None and size > 0 and (expected_bytes is None or size == expected_bytes) and sha256(path) == expected_sha:
            return path
    temporary = None
    try:
        for attempt in range(3):
            try:
                with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.' + path.name + '.', delete=False) as output:
                    temporary = Path(output.name)
                    with urlopen(str(url), timeout=120) as source:
                        if urlparse(source.geturl()).scheme not in ('https', 'file'):
                            raise ValueError('download redirected to an unsafe protocol')
                        shutil.copyfileobj(source, output, length=1024 * 1024)
                break
            except (URLError, ConnectionError, TimeoutError, IncompleteRead) as error:
                retryable = urlparse(str(url)).scheme == 'https' and (
                    not isinstance(error, HTTPError) or error.code == 429 or 500 <= error.code < 600)
                if isinstance(error, HTTPError):
                    error.close()
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
                    temporary = None
                if not retryable or attempt == 2:
                    raise
                time.sleep(attempt + 1)
        size = temporary.stat().st_size
        if size <= 0 or expected_bytes is not None and size != expected_bytes:
            raise ValueError(f'download byte count mismatch: {url}')
        if expected_sha is not None and sha256(temporary) != expected_sha:
            raise ValueError(f'download SHA-256 mismatch: {url}')
        temporary.chmod(0o644)
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return path


def _json(payload):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError(f'duplicate JSON key: {key}')
            result[key] = value
        return result
    def constant(value):
        raise ValueError(f'invalid JSON constant: {value}')
    return json.loads(payload, object_pairs_hook=pairs, parse_constant=constant)


def _relative(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or '\\' in name or '..' in path.parts:
        raise ValueError(f'unsafe archive path: {name}')
    return path


def _link_target(name, target, symbolic):
    if not target or target.startswith('/') or '\\' in target:
        raise ValueError(f'unsafe archive link: {name} -> {target}')
    parts = list(PurePosixPath(name).parent.parts) if symbolic else []
    for part in PurePosixPath(target).parts:
        if part == '..':
            if not parts:
                raise ValueError(f'archive link leaves destination: {name} -> {target}')
            parts.pop()
        elif part != '.':
            parts.append(part)
    return PurePosixPath(*parts)


def _host_link(name, target):
    parts = name.parts
    if len(parts) != 5 or not re.fullmatch(r'immortalwrt-imagebuilder-[A-Za-z0-9+._-]+\.Linux-x86_64', parts[0]) or parts[1:4] != ('staging_dir', 'host', 'bin'):
        raise ValueError(f'absolute link outside ImageBuilder host tools: {name}')
    tool = parts[4]
    if tool in HOST_TOOLS and target == HOST_TOOLS[tool]:
        return '/usr/bin/python3' if tool in ('python', 'python3') else target
    embedded = {'xxd': 'xxdi.pl', 'ldconfig': 'noop.sh'}
    if tool in embedded and re.fullmatch(r'/(?:immortalwrt|mnt/disk)/openwrt-[0-9]+\.[0-9]+/scripts/' + re.escape(embedded[tool]), target):
        return '../../../scripts/' + embedded[tool]
    raise ValueError(f'unexpected ImageBuilder host link: {name} -> {target}')


def _extract_tar(archive, destination):
    entries, links, external = {}, {}, set()
    for member in archive.getmembers():
        name = _relative(member.name)
        if str(name) == '.' and member.isdir():
            continue
        if name in entries:
            if entries[name].isdir() and member.isdir():
                continue
            raise ValueError(f'duplicate archive path: {name}')
        if not (member.isdir() or member.isfile() or member.issym() or member.islnk()):
            raise ValueError(f'archive contains a special file: {name}')
        entries[name] = member
        if member.issym() or member.islnk():
            if member.issym() and member.linkname.startswith('/'):
                member.linkname = _host_link(name, member.linkname)
                if member.linkname.startswith('/'):
                    external.add(name)
                    continue
            links[name] = _link_target(name, member.linkname, member.issym())
    def resolve(path, active=frozenset()):
        resolved = []
        for index, part in enumerate(path.parts):
            if part == '..':
                if not resolved:
                    raise ValueError('archive link resolves outside destination')
                resolved.pop()
                continue
            resolved.append(part)
            prefix = PurePosixPath(*resolved)
            if prefix in external:
                raise ValueError(f'archive link indirectly resolves to external host tool: {prefix}')
            if prefix in links:
                if prefix in active:
                    raise ValueError(f'cyclic archive link: {prefix}')
                member = entries[prefix]
                base = prefix.parent if member.issym() else PurePosixPath('.')
                raw_target = base / member.linkname / PurePosixPath(*path.parts[index + 1:])
                return resolve(raw_target, active | {prefix})
        return PurePosixPath(*resolved)
    for name, member in entries.items():
        for parent in name.parents:
            if parent in links or parent in external:
                raise ValueError(f'archive writes through a link: {name}')
            if parent in entries and not entries[parent].isdir():
                raise ValueError(f'archive parent is not a directory: {name}')
        if name in links:
            resolved = resolve(name)
            if member.issym() and member.name.endswith(('/host/bin/xxd', '/host/bin/ldconfig')) and (resolved not in entries or not entries[resolved].isfile()):
                raise ValueError(f'ImageBuilder host script is missing: {name}')
            if member.islnk() and (resolved not in entries or not entries[resolved].isfile()):
                raise ValueError(f'archive hard link has no regular target: {name}')
    destination = Path(destination)
    if destination.is_symlink() or destination.exists() and (not destination.is_dir() or any(destination.iterdir())):
        raise ValueError(f'archive destination must be an empty real directory: {destination}')
    destination.mkdir(parents=True, exist_ok=True)
    for name, member in sorted(entries.items(), key=lambda item: (len(item[0].parts), str(item[0]))):
        path = destination / str(name)
        if member.isdir():
            path.mkdir(parents=True, exist_ok=True)
            path.chmod(0o755)
        elif member.isfile():
            path.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source, path.open('xb') as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
            path.chmod(0o755 if member.mode & 0o111 else 0o644)
    for name, member in entries.items():
        path = destination / str(name)
        if member.islnk():
            path.parent.mkdir(parents=True, exist_ok=True)
            os.link(destination / str(resolve(name)), path)
        elif member.issym():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to(member.linkname)
    # Preserve ImageBuilder source/tool times for make's dependency checks.
    # Restore directories last, after all child creation has finished.
    for name, member in sorted(entries.items(), key=lambda item: len(item[0].parts), reverse=True):
        os.utime(destination / str(name), (member.mtime, member.mtime), follow_symlinks=False)


def extract_archive(archive, dest):
    archive = _regular(archive)
    if archive.name.endswith('.zst'):
        with tempfile.TemporaryDirectory() as temporary:
            raw = Path(temporary) / 'archive.tar'
            with raw.open('wb') as output:
                try:
                    from compression import zstd
                except ImportError:
                    subprocess.run(['zstd', '-q', '-d', '-c', str(archive)], stdout=output, check=True)
                else:
                    with zstd.open(archive, 'rb') as source:
                        shutil.copyfileobj(source, output, length=1024 * 1024)
            with tarfile.open(raw, 'r:') as handle:
                _extract_tar(handle, dest)
    else:
        with tarfile.open(archive, 'r:*') as handle:
            _extract_tar(handle, dest)
    return Path(dest)


def make_bundle(directory, archive):
    """Build a deterministic archive, with executable bits preserved."""
    directory, archive = Path(directory), Path(archive)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f'unsafe bundle directory: {directory}')
    archive.parent.mkdir(parents=True, exist_ok=True)
    if archive.resolve().is_relative_to(directory.resolve()) or archive.is_symlink():
        raise ValueError('bundle output must be outside its input tree')
    with tempfile.TemporaryDirectory(dir=archive.parent) as temporary:
        raw = Path(temporary) / 'bundle.tar'
        with tarfile.open(raw, 'w', format=tarfile.GNU_FORMAT) as output:
            for path in sorted(directory.rglob('*')):
                name = path.relative_to(directory).as_posix()
                info = output.gettarinfo(str(path), arcname=name)
                if not (info.isdir() or info.isfile() or info.issym()):
                    raise ValueError(f'unsupported bundle entry: {path}')
                if info.issym() and not path.resolve().is_relative_to(directory.resolve()):
                    raise ValueError(f'bundle symlink leaves its tree: {path}')
                info.uid = info.gid = info.mtime = 0
                info.uname = info.gname = ''
                info.mode = 0o755 if info.isdir() or info.mode & 0o111 else 0o644
                if info.isfile():
                    with path.open('rb') as source:
                        output.addfile(info, source)
                else:
                    output.addfile(info)
        compressed = Path(temporary) / 'output'
        if archive.name.endswith(('.gz', '.tgz')):
            with raw.open('rb') as source, compressed.open('wb') as output:
                with gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0, compresslevel=9) as encoder:
                    shutil.copyfileobj(source, encoder, length=1024 * 1024)
        elif archive.name.endswith('.zst'):
            with raw.open('rb') as source, compressed.open('wb') as output:
                try:
                    from compression import zstd
                except ImportError:
                    subprocess.run(['zstd', '-q', '-19', '-T1', '-c', str(raw)], stdout=output, check=True)
                else:
                    with zstd.open(output, 'wb', level=19) as encoder:
                        shutil.copyfileobj(source, encoder, length=1024 * 1024)
        elif archive.name.endswith('.tar'):
            shutil.copyfile(raw, compressed)
        else:
            raise ValueError(f'unsupported bundle compression: {archive}')
        compressed.chmod(0o644)
        os.replace(compressed, archive)
    return file_record(archive)


def _intent(requested):
    seen = set()
    for package in requested:
        if not isinstance(package, str) or not PACKAGE.fullmatch(package):
            raise ValueError(f'unsafe requested package: {package!r}')
        opposite = package[1:] if package.startswith('-') else '-' + package
        if package in seen or opposite in seen:
            raise ValueError(f'duplicate or conflicting requested package: {package}')
        seen.add(package)


def _package_list(path):
    result = []
    for line in _regular(path).read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if line:
            result.extend(line.split())
    _intent(result)
    return result


def requested_packages(recipe_root, target, preset):
    from .lock import TARGETS, PRESETS
    if target not in TARGETS or preset not in PRESETS:
        raise ValueError(f'unknown target/preset: {target}/{preset}')
    root = Path(recipe_root) / 'packages'
    packages = _package_list(root / 'base-image.txt')
    if preset == 'full':
        packages += _package_list(root / 'full-drivers-common.txt')
        packages += _package_list(root / f'full-drivers-{target}.txt')
    _intent(packages)
    positive = {package for package in packages if not package.startswith('-')}
    runtime = set(_package_list(root / 'runtime-apps.txt'))
    if positive & runtime:
        raise ValueError(f'runtime applications leaked into preset: {sorted(positive & runtime)}')
    forbidden = {'kmod-r8169', 'kmod-usb-net-rtl8152'} if target == 'x86_64' else {
        'kmod-r8101', 'kmod-r8168', 'kmod-r8125', 'kmod-r8126', 'kmod-r8127',
        'kmod-usb-net-rtl8152-vendor', 'kmod-hinic'}
    if positive & forbidden:
        raise ValueError(f'{target} driver policy conflict: {sorted(positive & forbidden)}')
    return sorted(packages)


def select_packages(requested, available):
    requested = list(requested)
    _intent(requested)
    selected, removed = [], []
    for package in requested:
        (selected if package.startswith('-') or package in available else removed).append(package)
    return selected, removed


def _repositories(imagebuilder):
    imagebuilder = Path(imagebuilder)
    configured = imagebuilder / 'repositories'
    if not configured.exists():
        configured = imagebuilder / 'repositories.conf'
    result = []
    for line in _regular(configured).read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        if len(line.split()) != 1:
            raise ValueError(f'unsupported repository configuration: {line}')
        parsed = urlparse(line)
        if not parsed.scheme:
            path = imagebuilder / line
            if path.is_dir():
                path /= 'packages.adb'
            line = path.resolve().as_uri()
        elif parsed.scheme not in ('https', 'file'):
            raise ValueError(f'unsupported repository URL: {line}')
        elif not parsed.path.endswith('.adb'):
            line = line.rstrip('/') + '/packages.adb'
        if line in result:
            raise ValueError(f'duplicate repository URL: {line}')
        result.append(line)
    if not result:
        raise ValueError('ImageBuilder has no package repositories')
    return result


def _decode(imagebuilder, path):
    tool = _regular(Path(imagebuilder) / 'staging_dir/host/bin/apk')
    result = subprocess.run([str(tool), 'adbdump', '--format', 'json', '--', str(_regular(path))],
                            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    document = _json(result.stdout)
    if not isinstance(document, dict):
        raise ValueError(f'APK metadata is not an object: {path}')
    return document


def _index_packages(imagebuilder, path):
    document = _decode(imagebuilder, path)
    packages = document.get('packages')
    if not isinstance(packages, list) or not packages:
        raise ValueError(f'package index has no package metadata: {path}')
    seen = set()
    for item in packages:
        if not isinstance(item, dict) or any(not isinstance(item.get(key), str) or not ATOM.fullmatch(item[key]) for key in ('name', 'version', 'arch')):
            raise ValueError(f'unsafe package index metadata: {path}')
        if not isinstance(item.get('hashes'), str) or not SHA.fullmatch(item['hashes']):
            raise ValueError(f'unsafe package index hash: {path}')
        identity = item['name'], item['version'], item['arch']
        if identity in seen:
            raise ValueError(f'duplicate repository package: {identity}')
        seen.add(identity)
    return packages


def _frozen_indexes(imagebuilder):
    imagebuilder = Path(imagebuilder)
    urls = _repositories(imagebuilder)
    frozen = imagebuilder / '.captured-repositories'
    identity = frozen / 'urls.json'
    identities = []
    for url in urls:
        parsed = urlparse(url)
        local = Path(parsed.path)
        if parsed.scheme == 'file' and local.is_relative_to(imagebuilder.resolve()):
            identities.append('imagebuilder:' + local.relative_to(imagebuilder.resolve()).as_posix())
        else:
            identities.append(url)
    if identity.exists():
        if _json(_regular(identity).read_text()) != identities:
            raise ValueError('frozen package indexes disagree with configured repositories')
    else:
        if frozen.exists() and any(frozen.iterdir()):
            raise ValueError('incomplete frozen repository capture')
        frozen.mkdir(parents=True, exist_ok=True)
        for number, url in enumerate(urls, 1):
            download(url, frozen / f'repo-{number}/packages.adb')
        identity.write_text(json.dumps(identities) + '\n')
    return [(f'repo-{number}', frozen / f'repo-{number}/packages.adb') for number in range(1, len(urls) + 1)]


def available_packages(imagebuilder):
    remote = {item['name'] for _, path in _frozen_indexes(imagebuilder) for item in _index_packages(imagebuilder, path)}
    return remote | {info['name'] for _, info in _local_apks(imagebuilder)}


def _local_apks(imagebuilder):
    """ImageBuilder Makefile adds packages/ independently of repositories text."""
    local = Path(imagebuilder) / 'packages'
    if local.is_symlink():
        raise ValueError('unsafe ImageBuilder embedded packages directory')
    result = []
    for path in sorted(local.glob('*.apk')):
        info = _decode(imagebuilder, path).get('info')
        if not isinstance(info, dict) or any(not isinstance(info.get(key), str) or not ATOM.fullmatch(info[key]) for key in ('name', 'version', 'arch')):
            raise ValueError(f'unsafe embedded APK metadata: {path}')
        result.append((path, info))
    return result


def _manifest_identities(manifests):
    required = {}
    for manifest in manifests:
        rows = _regular(manifest).read_text().splitlines() if isinstance(manifest, (str, Path)) else list(manifest)
        seen = set()
        for row in rows:
            parts = row.split(' - ')
            if len(parts) != 2 or any(not ATOM.fullmatch(part) for part in parts):
                raise ValueError(f'unsafe manifest row: {row!r}')
            name, version = parts
            if name in seen or name in required and required[name] != version:
                raise ValueError(f'duplicate or conflicting manifest package: {name}')
            seen.add(name)
            required[name] = version
    if not required:
        raise ValueError('package manifests are empty')
    return required


def capture_repositories(imagebuilder, cache_dir, manifests, dest):
    """Preserve signed indexes and all resolved dependency APKs under canonical names."""
    imagebuilder, cache_dir, dest = Path(imagebuilder), Path(cache_dir), Path(dest)
    if cache_dir.is_symlink() or not cache_dir.is_dir():
        raise ValueError(f'unsafe APK cache directory: {cache_dir}')
    if dest.exists() and (dest.is_symlink() or not dest.is_dir() or any(dest.iterdir())):
        raise ValueError('repository capture destination must be empty')
    indexes = _frozen_indexes(imagebuilder)
    candidates = {}
    for repository, index in indexes:
        for item in _index_packages(imagebuilder, index):
            candidates.setdefault((item['name'], item['version']), []).append((repository, item))
    required = _manifest_identities(manifests)
    embedded = {(info['name'], info['version']) for _, info in _local_apks(imagebuilder)}
    selected = []
    for name, version in sorted(required.items()):
        matches = []
        for repository, item in candidates.get((name, version), []):
            filename = f"{name}-{version}.{item['hashes'][:8]}.apk"
            cached = cache_dir / filename
            if cached.exists() or cached.is_symlink():
                _regular(cached)
                document = _decode(imagebuilder, cached)
                info = document.get('info')
                if not isinstance(info, dict) or any(info.get(key) != item[key] for key in ('name', 'version', 'arch')):
                    raise ValueError(f'cached APK identity disagrees with signed index: {cached}')
                if info.get('hashes') is not None and info['hashes'] != item['hashes']:
                    raise ValueError(f'cached APK hash disagrees with signed index: {cached}')
                matches.append((repository, item, cached))
        if len({item['hashes'] for _, item, _ in matches}) > 1:
            raise ValueError(f'ambiguous cached variants for package: {name} {version}')
        if not matches:
            if (name, version) in embedded:
                continue
            raise ValueError(f'manifest dependency has no exact indexed cache APK: {name} {version}')
        repository, item, cached = matches[0]
        selected.append((repository, f'{name}-{version}.apk', cached))
    dest.mkdir(parents=True, exist_ok=True)
    for repository, index in indexes:
        (dest / repository).mkdir()
        shutil.copyfile(_regular(index), dest / repository / 'packages.adb')
    for repository, filename, cached in selected:
        shutil.copyfile(cached, dest / repository / filename)
    (dest / 'repositories.list').write_text(''.join(repository + '\n' for repository, _ in indexes))
    return {'path': dest, 'repositories': [repository for repository, _ in indexes],
            'packages': [f'{repository}/{filename}' for repository, filename, _ in selected]}
