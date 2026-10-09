"""Fresh ImageBuilder builds and exact replay from frozen target inputs."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from .inputs import (available_packages, capture_repositories, download,
                     extract_archive, file_record, make_bundle,
                     requested_packages, select_packages, sha256)
from .lock import PRESETS, TARGETS
from .verify import canonical_metadata, verify_output


_ARCHIVE = re.compile(r'immortalwrt-imagebuilder-[A-Za-z0-9+._-]+\.Linux-x86_64\.tar\.zst')
_SAFE_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9+._-]*')


def _metadata_spec(upstream, target, metadata):
    spec = dict(TARGETS[target])
    if metadata.get('version_number') != upstream['version']:
        raise ValueError('upstream metadata version does not match stable release')
    if metadata.get('target') != spec['target']:
        raise ValueError('upstream metadata target mismatch')
    if spec['profile'] not in metadata.get('profiles', {}):
        raise ValueError('upstream metadata is missing the selected device profile')
    arch = metadata.get('arch_packages', metadata.get('arch'))
    if not isinstance(arch, str) or not re.fullmatch(r'[A-Za-z0-9_+-]+', arch):
        raise ValueError('upstream metadata has no valid package architecture')
    spec['arch'] = arch
    if not isinstance(metadata.get('version_code'), str) or not metadata['version_code']:
        raise ValueError('upstream metadata has no ImageBuilder revision')
    epoch = metadata.get('source_date_epoch')
    if isinstance(epoch, bool) or not isinstance(epoch, int) or epoch <= 0:
        raise ValueError('upstream metadata has no source date epoch')
    return spec


def fetch_target_inputs(upstream, target, work):
    """Discover the actual archive from sha256sums; retain official profiles."""
    work = Path(work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    pinned = work / 'signed-indexes'
    if pinned.exists() or pinned.is_symlink():
        _reset_directory(pinned, work)
        pinned.rmdir()
    inputs = work / 'downloads'
    inputs.mkdir(exist_ok=True)
    base = upstream['download_url'].rstrip('/') + '/targets/' + TARGETS[target]['target']
    profiles = inputs / 'profiles.json'
    sums = inputs / 'sha256sums'
    download(base + '/profiles.json', profiles)
    metadata = json.loads(profiles.read_text())
    spec = _metadata_spec(upstream, target, metadata)
    download(base + '/sha256sums', sums)
    candidates = []
    seen = set()
    for line in sums.read_text().splitlines():
        match = re.fullmatch(r'([0-9a-fA-F]{64}) [ *](.+)', line)
        if match is None:
            raise ValueError('malformed upstream checksum list')
        digest, filename = match.groups()
        if filename in seen:
            raise ValueError('duplicate filename in upstream checksum list')
        seen.add(filename)
        if 'imagebuilder' in filename.lower():
            if not _ARCHIVE.fullmatch(filename):
                raise ValueError('unsupported or unsafe ImageBuilder archive filename')
            candidates.append((filename, digest.lower()))
    if len(candidates) != 1:
        raise ValueError('expected exactly one ImageBuilder archive in sha256sums')
    filename, digest = candidates[0]
    archive = inputs / filename
    download(base + '/' + filename, archive, expected_sha=digest)
    return {'archive': archive, 'metadata': metadata, 'spec': spec,
            'target': target, 'cache_dir': work / 'package-cache', 'work': work}


def _reset_directory(path, work):
    path = Path(path)
    work = Path(work).resolve()
    if path.is_symlink() or path.resolve() == work or not path.resolve().is_relative_to(work):
        raise ValueError(f'unsafe build working directory: {path}')
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True)


def _fresh_imagebuilder(context):
    work = Path(context['work']).resolve()
    directory = work / 'imagebuilder'
    _reset_directory(directory, work)
    extract_archive(context['archive'], directory)
    children = list(directory.iterdir())
    if len(children) != 1 or not children[0].is_dir() or children[0].is_symlink():
        raise ValueError('unexpected ImageBuilder archive layout')
    ib = children[0]
    if not (ib / 'Makefile').is_file() or not (ib / '.config').is_file():
        raise ValueError('ImageBuilder lacks Makefile or configuration')
    config = (ib / '.config').read_text()
    arch = re.findall(r'^CONFIG_TARGET_ARCH_PACKAGES="([^"\n]+)"$', config, re.MULTILINE)
    if arch != [context['spec']['arch']]:
        raise ValueError('ImageBuilder package architecture disagrees with official metadata')
    context['imagebuilder'] = ib
    return ib


def _configure(ib, context):
    options = {
        'CONFIG_DOWNLOAD_FOLDER': json.dumps(str(Path(context['cache_dir']).resolve())),
        'CONFIG_TARGET_ROOTFS_PARTSIZE': '3072',
        'CONFIG_TARGET_ROOTFS_SQUASHFS': 'y',
        'CONFIG_TARGET_ROOTFS_EXT4FS': 'n',
        'CONFIG_TARGET_ROOTFS_TARGZ': 'n',
        'CONFIG_TARGET_KERNEL_PARTSIZE': '32' if context['target'] == 'x86_64' else '64',
    }
    if context['target'] == 'x86_64':
        options.update({'CONFIG_TARGET_IMAGES_GZIP': 'y', 'CONFIG_GRUB_EFI_IMAGES': 'y'})
        for symbol in ('CONFIG_GRUB_IMAGES', 'CONFIG_ISO_IMAGES', 'CONFIG_QCOW2_IMAGES',
                       'CONFIG_VDI_IMAGES', 'CONFIG_VHDX_IMAGES', 'CONFIG_VMDK_IMAGES'):
            options[symbol] = 'n'
    path = ib / '.config'
    lines = path.read_text().splitlines()
    lines = [line for line in lines if not any(
        line.startswith(symbol + '=') or line == f'# {symbol} is not set' for symbol in options)]
    for symbol, value in options.items():
        lines.append(f'# {symbol} is not set' if value == 'n' else f'{symbol}={value}')
    path.write_text('\n'.join(lines) + '\n')


def _local_repositories(ib, repositories):
    repositories = Path(repositories).resolve()
    names = (repositories / 'repositories.list').read_text().splitlines()
    if not names or names != [f'repo-{number}' for number in range(1, len(names) + 1)]:
        raise ValueError('frozen repositories must be contiguous repo-N entries')
    lines = []
    for name in names:
        index = repositories / name / 'packages.adb'
        if index.is_symlink() or not index.is_file() or not index.stat().st_size:
            raise ValueError('frozen repository has no signed package index')
        lines.append('file://' + str(index))
    (ib / 'repositories').write_text('\n'.join(lines) + '\n')


def _pin_live_indexes(ib, cache):
    """Seed APK3's URL-derived index cache and prevent index autoupdates.

    APK3 hashes the index URL, not the package contents, for this cache name.
    Its cache loader accepts signed ADB bytes despite the legacy .tar.gz suffix.
    Keeping the original repository URL lets APK fetch only selected package
    bytes remotely while resolving against the immutable signed snapshot.
    """
    frozen = ib / '.captured-repositories'
    urls = json.loads((frozen / 'urls.json').read_text())
    pinned = []
    seen = set()
    for number, url in enumerate(urls, 1):
        if not isinstance(url, str):
            raise ValueError('invalid frozen repository URL identity')
        if url.startswith('imagebuilder:') or url.startswith('file://'):
            continue
        if not url.startswith('https://'):
            raise ValueError('unsupported live repository URL identity')
        name = 'APKINDEX.' + hashlib.sha256(url.encode()).hexdigest()[:8] + '.tar.gz'
        if name in seen:
            raise ValueError('APK repository index cache name collision')
        seen.add(name)
        original = frozen / f'repo-{number}/packages.adb'
        destination = cache / name
        if destination.is_symlink():
            raise ValueError('unsafe APK index cache symlink')
        digest = sha256(original)
        shutil.copyfile(original, destination)
        os.utime(destination, None)
        pinned.append((destination, digest))
    # Applies to every nested make's APK invocation without replacing upstream
    # root/architecture/key options. Fresh extraction removes this on each run.
    with (ib / 'Makefile').open('a') as stream:
        stream.write('\n# Resolve against the frozen signed APK index cache.\n'
                     'override APK += --cache-max-age 2147483647\n')
    return pinned


def run_imagebuilder(context, preset, packages, out, recipe_root, repositories=None):
    """Build once in a fresh tree, filter only missing positive requests, verify."""
    if preset not in PRESETS:
        raise ValueError('unknown preset')
    recipe_root = Path(recipe_root).resolve()
    work = Path(context['work']).resolve()
    out = Path(out).resolve()
    if out == work or not out.is_relative_to(work):
        raise ValueError('artifacts must be below the target working directory')
    ib = _fresh_imagebuilder(context)
    cache = Path(context['cache_dir']).resolve()
    if repositories is not None:
        # Even the live cache must not conceal an incomplete frozen closure.
        _reset_directory(cache, work)
        _local_repositories(ib, repositories)
    else:
        cache.mkdir(parents=True, exist_ok=True)
        pinned = work / 'signed-indexes'
        if pinned.exists():
            shutil.copytree(pinned, ib / '.captured-repositories')
    available = available_packages(ib)
    if repositories is None and not (work / 'signed-indexes').exists() and (ib / '.captured-repositories').exists():
        shutil.copytree(ib / '.captured-repositories', work / 'signed-indexes')
    selected, removed = select_packages(packages, available)
    _configure(ib, context)
    pinned_indexes = _pin_live_indexes(ib, cache) if repositories is None else []
    env = os.environ.copy()
    env.update({'LC_ALL': 'C', 'TZ': 'UTC',
                'SOURCE_DATE_EPOCH': str(context['metadata']['source_date_epoch'])})
    subprocess.run(['make', '-C', str(ib), 'image',
                    'PROFILE=' + context['spec']['profile'],
                    'PACKAGES=' + ' '.join(selected), 'FILES=' + str(recipe_root / 'files'),
                    'ROOTFS_PARTSIZE=3072', 'EXTRA_IMAGE_NAME=' + preset],
                   env=env, check=True)
    for path, digest in pinned_indexes:
        if sha256(path) != digest:
            raise ValueError('live APK resolution changed a frozen signed package index')
    generated = ib / 'bin/targets' / context['spec']['target']
    if not generated.is_dir():
        raise ValueError('ImageBuilder emitted no target output directory')
    staged = out.parent / ('.' + out.name + '.pending')
    _reset_directory(staged, work)
    for path in generated.iterdir():
        if path.is_symlink():
            raise ValueError('ImageBuilder output contains a symbolic link')
        if path.is_file():
            shutil.copy2(path, staged / path.name)
    result = dict(verify_output(staged, context['target'], context['metadata'], selected,
                                recipe_root, expected_result=context.get('expected_results', {}).get(preset),
                                smoke=True))
    result.update({'requested_packages': list(packages), 'removed_packages': removed})
    if out.exists():
        _reset_directory(out, work)
        out.rmdir()
    staged.rename(out)
    return result


def compare_replay(actual, expected):
    """Fail on any image-byte or exact package-manifest disagreement."""
    for key in ('images', 'manifest', 'manifest_sha256', 'metadata'):
        if key not in expected:
            continue
        left, right = actual.get(key), expected[key]
        if key == 'metadata':
            left, right = canonical_metadata(left), canonical_metadata(right)
        if left != right:
            raise ValueError(f'offline replay differs in {key}')


def build_target(upstream, target, work, recipe_root):
    context = fetch_target_inputs(upstream, target, work)
    work = context['work']
    live = {}
    for preset in PRESETS:
        packages = requested_packages(recipe_root, target, preset)
        live[preset] = run_imagebuilder(context, preset, packages, work / 'artifacts' / preset, recipe_root)
    bundle = work / 'frozen'
    _reset_directory(bundle, work)
    shutil.copyfile(context['archive'], bundle / 'imagebuilder.tar.zst')
    capture_repositories(context['imagebuilder'], context['cache_dir'],
                         [live[preset]['manifest'] for preset in PRESETS], bundle / 'repositories')
    archive = work / 'artifacts' / (target + '-inputs.tar.gz')
    make_bundle(bundle, archive)
    return {'target': target, 'spec': context['spec'], 'metadata': context['metadata'],
            'inputs': file_record(archive), 'presets': live, 'reproduced': False}


def rebuild_target(lock, target_result, inputs_dir, out, recipe_root):
    """Rebuild using only the authenticated Release bundle and frozen recipe."""
    record = target_result['inputs']
    filename = record['filename']
    if not _SAFE_NAME.fullmatch(filename) or Path(filename).name != filename:
        raise ValueError('unsafe frozen input filename')
    archive = Path(inputs_dir) / filename
    if archive.is_symlink() or not archive.is_file():
        raise ValueError('missing frozen input bundle')
    if archive.stat().st_size != record['bytes'] or sha256(archive) != record['sha256']:
        raise ValueError('frozen input bundle checksum/hash mismatch')
    out = Path(out).resolve()
    work = out.parent
    work.mkdir(parents=True, exist_ok=True)
    frozen = work / 'replay-inputs'
    _reset_directory(frozen, work)
    extract_archive(archive, frozen)
    spec = _metadata_spec(lock['upstream'], target_result['target'], target_result['metadata'])
    if spec != target_result['spec']:
        raise ValueError('frozen target spec disagrees with metadata')
    context = {'archive': frozen / 'imagebuilder.tar.zst', 'metadata': target_result['metadata'],
               'target': target_result['target'], 'spec': spec,
               'cache_dir': work / 'package-cache', 'work': work,
               'expected_results': target_result['presets']}
    for preset in PRESETS:
        expected = target_result['presets'][preset]
        requested = requested_packages(recipe_root, context['target'], preset)
        if requested != expected['requested_packages']:
            raise ValueError('frozen recipe package intent differs from release lock')
        result = run_imagebuilder(context, preset, requested, out / preset, recipe_root, frozen / 'repositories')
        compare_replay(result, expected)
        if result['removed_packages'] != expected['removed_packages']:
            raise ValueError('offline replay removed package set differs')
