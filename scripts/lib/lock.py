"""Release lock contract."""

import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlparse

TARGETS = {
    'x86_64': {'target': 'x86/64', 'profile': 'generic', 'arch': 'x86_64'},
    'rpi4': {'target': 'bcm27xx/bcm2711', 'profile': 'rpi-4', 'arch': 'aarch64_cortex-a72'},
    'rpi5': {'target': 'bcm27xx/bcm2712', 'profile': 'rpi-5', 'arch': 'aarch64_cortex-a76'},
}
PRESETS = ('full', 'minimal')

SHA = re.compile(r'[0-9a-f]{64}')
COMMIT = re.compile(r'[0-9a-f]{40}')
FILENAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9._+-]*')
ATOM = re.compile(r'[A-Za-z0-9][A-Za-z0-9+._~:-]*')
PACKAGE = re.compile(r'-?[a-z0-9][a-z0-9+._-]*')


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _object(value, keys, description):
    _require(isinstance(value, dict) and set(value) == set(keys), f'invalid {description} fields')


def _record(record, assets, extra=()):
    _object(record, ('filename', 'sha256', 'bytes', *extra), 'file record')
    name, digest, size = record['filename'], record['sha256'], record['bytes']
    _require(isinstance(name, str) and FILENAME.fullmatch(name) is not None, 'unsafe asset filename')
    _require(name not in assets and name not in ('LOCK.json', 'SHA256SUMS'), f'duplicate or reserved asset filename: {name}')
    _require(isinstance(digest, str) and SHA.fullmatch(digest) is not None, f'invalid asset digest: {name}')
    _require(type(size) is int and size > 0, f'invalid asset byte count: {name}')
    assets.add(name)


def _packages(values, description):
    _require(isinstance(values, list) and all(isinstance(value, str) and PACKAGE.fullmatch(value) for value in values), f'invalid {description}')
    _require(len(set(values)) == len(values), f'duplicate {description}')
    positives = {value for value in values if not value.startswith('-')}
    negatives = {value[1:] for value in values if value.startswith('-')}
    _require(not positives & negatives, f'conflicting {description}')


def _metadata(metadata, upstream, spec):
    _require(isinstance(metadata, dict), 'invalid target metadata')
    _require(metadata.get('version_number') == upstream['version'], 'metadata version differs from upstream')
    _require(isinstance(metadata.get('version_code'), str) and ATOM.fullmatch(metadata['version_code']), 'invalid ImageBuilder source revision')
    epoch = metadata.get('source_date_epoch')
    _require(type(epoch) is int and epoch > 0, 'invalid metadata source date epoch')
    _require(metadata.get('target') == spec['target'], 'metadata target differs from target specification')
    arch = metadata.get('arch_packages', metadata.get('arch'))
    _require(arch == spec['arch'], 'metadata package architecture differs from target specification')
    kernel = metadata.get('linux_kernel', metadata.get('kernel'))
    _require(isinstance(kernel, (dict, str)) and bool(kernel), 'missing kernel metadata')
    profiles = metadata.get('profiles')
    _require(isinstance(profiles, dict) and isinstance(profiles.get(spec['profile']), dict), 'missing target device profile')


def validate_lock(lock):
    """Reject incomplete publication records and unsafe local rebuild inputs."""
    _object(lock, ('schema', 'upstream', 'recipe', 'environment', 'geometry', 'release', 'targets'), 'lock')
    _require(type(lock['schema']) is int and lock['schema'] == 1, 'unsupported lock schema')
    upstream = lock['upstream']
    _object(upstream, ('version', 'source_tag', 'source_commit', 'download_url'), 'upstream')
    version = upstream['version']
    _require(isinstance(version, str) and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version), 'upstream version must be a stable release')
    _require(upstream['source_tag'] == 'v' + version, 'source tag differs from stable release version')
    _require(isinstance(upstream['source_commit'], str) and COMMIT.fullmatch(upstream['source_commit']), 'invalid upstream source commit')
    _require(isinstance(upstream['download_url'], str), 'invalid upstream download URL')
    url = urlparse(upstream['download_url'])
    _require(url.scheme == 'https' and bool(url.netloc) and not url.username and not url.password and not url.query and not url.fragment and '..' not in url.path.split('/'), 'unsafe upstream download URL')
    _object(lock['recipe'], ('commit',), 'recipe')
    _require(isinstance(lock['recipe']['commit'], str) and COMMIT.fullmatch(lock['recipe']['commit']), 'invalid frozen recipe commit')
    assets = set()
    environment = lock['environment']
    _record(environment, assets, ('image_id', 'architecture'))
    _require(isinstance(environment['image_id'], str) and re.fullmatch(r'sha256:[0-9a-f]{64}', environment['image_id']), 'invalid Docker environment image ID')
    _require(environment['architecture'] == 'amd64', 'unsupported frozen environment architecture')
    _require(lock['geometry'] == {'rootfs_mib': 3072, 'media_bytes': 4000000000}, 'unsupported image geometry')
    _require(all(type(value) is int for value in lock['geometry'].values()), 'invalid image geometry types')
    release = lock['release']
    _object(release, ('repository', 'tag'), 'release')
    _require(isinstance(release['repository'], str) and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', release['repository']), 'unsafe release repository')
    _require(isinstance(release['tag'], str) and FILENAME.fullmatch(release['tag']), 'unsafe release tag')
    _object(lock['targets'], TARGETS, 'targets')
    for target, expected_spec in TARGETS.items():
        result = lock['targets'][target]
        _object(result, ('target', 'spec', 'metadata', 'inputs', 'presets'), 'target result')
        _require(result['target'] == target, 'target result key mismatch')
        spec = result['spec']
        _object(spec, ('target', 'profile', 'arch'), 'target specification')
        _require(spec['target'] == expected_spec['target'] and spec['profile'] == expected_spec['profile'], 'unexpected target/device specification')
        _require(isinstance(spec['arch'], str) and ATOM.fullmatch(spec['arch']), 'unsafe package architecture')
        _metadata(result['metadata'], upstream, spec)
        _record(result['inputs'], assets)
        _object(result['presets'], PRESETS, 'presets')
        for preset in PRESETS:
            built = result['presets'][preset]
            _object(built, ('images', 'manifest', 'manifest_sha256', 'metadata', 'requested_packages', 'removed_packages'), 'preset result')
            _metadata(built['metadata'], upstream, spec)
            for field in ('version_number', 'version_code', 'source_date_epoch', 'target', 'arch_packages', 'arch', 'linux_kernel', 'kernel'):
                _require(built['metadata'].get(field) == result['metadata'].get(field), f'preset {field} differs from frozen upstream profiles')
            upstream_profile = result['metadata']['profiles'][spec['profile']]
            built_profile = built['metadata']['profiles'][spec['profile']]
            for field in ('supported_devices', 'device_packages'):
                if field in upstream_profile:
                    _require(built_profile.get(field) == upstream_profile[field], f'preset device {field} differs from frozen upstream profiles')
            images = built['images']
            _require(isinstance(images, list) and len(images) == (1 if target == 'x86_64' else 2), f'incomplete image inventory: {target}/{preset}')
            for image in images:
                _record(image, assets)
                _require(image['filename'].endswith('.img.gz'), 'unexpected image extension')
                _require(image['bytes'] < lock['geometry']['media_bytes'], 'compressed image exceeds media capacity')
            described = built_profile.get('images')
            _require(isinstance(described, list), 'preset metadata has no image inventory')
            types = {'combined-efi'} if target == 'x86_64' else {'factory', 'sysupgrade'}
            matches = [entry for entry in described if isinstance(entry, dict) and entry.get('filesystem') == 'squashfs' and entry.get('type') in types]
            _require(len(matches) == len(images) and {entry['type'] for entry in matches} == types, 'preset metadata image types differ from target image inventory')
            indexed = {entry.get('name'): entry for entry in matches}
            _require(len(indexed) == len(images), 'duplicate image metadata names')
            for image in images:
                entry = indexed.get(image['filename'])
                _require(entry is not None and entry.get('sha256') == image['sha256'] and type(entry.get('size')) is int and entry['size'] == image['bytes'], 'image record disagrees with generated preset metadata')
            manifest = built['manifest']
            _require(isinstance(manifest, list) and bool(manifest), 'empty package manifest')
            names = set()
            versions = {}
            for row in manifest:
                _require(isinstance(row, str), 'invalid manifest row')
                parts = row.split(' - ')
                _require(len(parts) == 2 and all(ATOM.fullmatch(part) for part in parts), 'unsafe manifest package identity')
                _require(parts[0] not in names, 'duplicate manifest package')
                names.add(parts[0])
                versions[parts[0]] = parts[1]
            digest = hashlib.sha256(('\n'.join(manifest) + '\n').encode('utf-8')).hexdigest()
            _require(built['manifest_sha256'] == digest, 'manifest SHA-256 differs from package manifest')
            requested, removed = built['requested_packages'], built['removed_packages']
            _packages(requested, 'requested packages')
            _packages(removed, 'removed packages')
            _require(all(not item.startswith('-') and item in requested for item in removed), 'removed packages were not requested positive packages')
            for package in requested:
                if package.startswith('-'):
                    _require(package[1:] not in names, 'negatively requested package is present in manifest')
                elif package not in removed:
                    _require(package in names, 'selected requested package is missing from manifest')
    return lock

def write_lock(lock, path):
    validate_lock(lock)
    path = Path(path)
    _require(not path.is_symlink(), 'unsafe lock output symlink')
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, prefix='.' + path.name + '.', delete=False) as output:
            temporary = Path(output.name)
            json.dump(lock, output, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        temporary.chmod(0o644)
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return path

def load_lock(path):
    def pairs(items):
        result = {}
        for key, value in items:
            _require(key not in result, f'duplicate JSON key: {key}')
            result[key] = value
        return result
    def constant(value):
        raise ValueError(f'invalid JSON constant: {value}')
    path = Path(path)
    _require(not path.is_symlink() and path.is_file(), 'lock must be a regular file')
    _require(path.stat().st_size <= 64 * 1024 * 1024, 'lock file exceeds size limit')
    document = json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=pairs, parse_constant=constant)
    validate_lock(document)
    return document
