import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from lib import build


METADATA = {
    'version_number': '25.12.2', 'version_code': 'r1234-buildercommit',
    'source_date_epoch': 1700000000, 'target': 'x86/64',
    'arch_packages': 'x86_64', 'linux_kernel': {'version': '6.12.1'},
    'profiles': {'generic': {'id': 'generic', 'images': []}},
}
UPSTREAM = {'version': '25.12.2', 'source_tag': 'v25.12.2',
            'source_commit': 'different-source-tag-commit',
            'download_url': 'https://example.test/releases/25.12.2'}


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.recipe = self.root / 'recipe'
        (self.recipe / 'files').mkdir(parents=True)
        self.work = self.root / 'target'
        self.work.mkdir()
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        make = self.tools / 'make'
        make.write_text(f'#!{sys.executable}\n' + "import pathlib\nimport shutil\nimport sys\nargs = sys.argv[1:]\nib = pathlib.Path(args[args.index('-C') + 1])\nif 'exit 7' in (ib / 'Makefile').read_text():\n    sys.exit(7)\nvalues = dict(arg.split('=', 1) for arg in args if '=' in arg)\nout = ib / 'bin/targets/x86/64'\nout.mkdir(parents=True)\nshutil.copyfile(ib / '.config', out / 'config.buildinfo')\n(out / 'packages.manifest').write_text(values['PACKAGES'] + chr(10))\n(out / 'feeds.buildinfo').write_text(values['FILES'] + chr(10))\n")
        make.chmod(0o755)
        patch = mock.patch.dict(os.environ, {'PATH': str(self.tools) + os.pathsep + os.environ.get('PATH', '')})
        patch.start()
        self.addCleanup(patch.stop)

    def fake_available(self, ib):
        frozen = Path(ib) / '.captured-repositories'
        if not frozen.exists():
            (frozen / 'repo-1').mkdir(parents=True)
            (frozen / 'urls.json').write_text('["https://example.test/packages.adb"]')
            (frozen / 'repo-1/packages.adb').write_bytes(b'signed package index')
        return {'base'}

    def download_fixture(self, entries):
        def download(url, path, expected_sha=None, expected_bytes=None):
            name = url.rsplit('/', 1)[-1]
            payload = entries[name]
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            Path(path).write_bytes(payload)
            if expected_sha is not None:
                self.assertEqual(hashlib.sha256(payload).hexdigest(), expected_sha)
        return download

    def test_discovers_real_archive_name_without_assuming_version(self):
        archive = b'official imagebuilder'
        filename = 'immortalwrt-imagebuilder-25.12-SNAPSHOT-x86-64.Linux-x86_64.tar.zst'
        sums = f'{hashlib.sha256(archive).hexdigest()} *{filename}\n'.encode()
        entries = {'sha256sums': sums, 'profiles.json': json.dumps(METADATA).encode(), filename: archive}
        with mock.patch.object(build, 'download', side_effect=self.download_fixture(entries)):
            context = build.fetch_target_inputs(UPSTREAM, 'x86_64', self.work)
        self.assertEqual(context['archive'].name, filename)
        self.assertEqual(context['metadata']['version_code'], 'r1234-buildercommit')
        self.assertEqual(context['spec']['arch'], 'x86_64')

    def test_new_live_attempt_discards_prior_pinned_indexes(self):
        archive = b'official imagebuilder'
        filename = 'immortalwrt-imagebuilder-any.Linux-x86_64.tar.zst'
        entries = {'sha256sums': f'{hashlib.sha256(archive).hexdigest()} *{filename}\n'.encode(),
                   'profiles.json': json.dumps(METADATA).encode(), filename: archive}
        pinned = self.work / 'signed-indexes'
        pinned.mkdir()
        (pinned / 'old-index').write_text('previous failed attempt')
        with mock.patch.object(build, 'download', side_effect=self.download_fixture(entries)):
            build.fetch_target_inputs(UPSTREAM, 'x86_64', self.work)
        self.assertFalse(pinned.exists())

    def test_traversing_archive_name_is_rejected(self):
        entries = {'sha256sums': f'{"a" * 64} *../immortalwrt-imagebuilder-any.Linux-x86_64.tar.zst\n'.encode(),
                   'profiles.json': json.dumps(METADATA).encode()}
        with mock.patch.object(build, 'download', side_effect=self.download_fixture(entries)):
            with self.assertRaisesRegex(ValueError, 'ImageBuilder'):
                build.fetch_target_inputs(UPSTREAM, 'x86_64', self.work)

    def test_ambiguous_archives_are_rejected(self):
        names = ['immortalwrt-imagebuilder-a.Linux-x86_64.tar.zst',
                 'immortalwrt-imagebuilder-b.Linux-x86_64.tar.zst']
        entries = {'sha256sums': ''.join(f'{"a" * 64} *{n}\n' for n in names).encode(),
                   'profiles.json': json.dumps(METADATA).encode()}
        with mock.patch.object(build, 'download', side_effect=self.download_fixture(entries)):
            with self.assertRaisesRegex(ValueError, 'ImageBuilder'):
                build.fetch_target_inputs(UPSTREAM, 'x86_64', self.work)

    def test_metadata_target_mismatch_is_rejected(self):
        metadata = dict(METADATA, target='bcm27xx/bcm2711')
        entries = {'sha256sums': b'', 'profiles.json': json.dumps(metadata).encode()}
        with mock.patch.object(build, 'download', side_effect=self.download_fixture(entries)):
            with self.assertRaisesRegex(ValueError, 'target'):
                build.fetch_target_inputs(UPSTREAM, 'x86_64', self.work)

    def fixture_context(self, fail=False):
        source = self.root / 'ib-src'
        source.mkdir()
        (source / '.config').write_text('CONFIG_TARGET_ARCH_PACKAGES="x86_64"\nCONFIG_GRUB_IMAGES=y\nCONFIG_TARGET_ROOTFS_EXT4FS=y\n')
        (source / 'repositories').write_text('https://example.test/packages.adb\n')
        (source / 'Makefile').write_text(
            'image:\n\t' + ('exit 7\n' if fail else
            'mkdir -p bin/targets/x86/64\n\tcp .config bin/targets/x86/64/config.buildinfo\n'
            '\tprintf "%s\\n" "$(PACKAGES)" > bin/targets/x86/64/packages.manifest\n'
            '\tprintf "%s\\n" "$(FILES)" > bin/targets/x86/64/feeds.buildinfo\n'))
        archive = self.root / 'imagebuilder.tar.gz'
        with tarfile.open(archive, 'w:gz') as stream:
            stream.add(source, arcname='official-ib')
        return {'archive': archive, 'target': 'x86_64', 'metadata': copy.deepcopy(METADATA),
                'spec': {'target': 'x86/64', 'profile': 'generic', 'arch': 'x86_64'},
                'cache_dir': self.work / 'package-cache', 'work': self.work}

    def test_live_resolver_uses_signed_snapshot_after_upstream_index_changes(self):
        context = self.fixture_context()
        upstream_index = self.root / 'upstream-index.json'
        upstream_index.write_text('{"version": "new-version"}')
        def availability(ib):
            frozen = Path(ib) / '.captured-repositories'
            (frozen / 'repo-1').mkdir(parents=True)
            (frozen / 'urls.json').write_text('["https://example.test/packages.adb"]')
            (frozen / 'repo-1/packages.adb').write_text('{"version": "old-version"}')
            (Path(ib) / '.upstream-index').write_text(str(upstream_index))
            return {'base'}
        make = self.tools / 'make'
        script = make.read_text().replace('import pathlib\n', 'import pathlib\nimport hashlib, json\n')
        script = script.replace("(out / 'packages.manifest').write_text(values['PACKAGES'] + chr(10))", "if (ib / '.upstream-index').exists():\n    url = (ib / 'repositories').read_text().strip()\n    download = next(line.split('=', 1)[1] for line in (ib / '.config').read_text().splitlines() if line.startswith('CONFIG_DOWNLOAD_FOLDER='))\n    cached = pathlib.Path(json.loads(download)) / ('APKINDEX.' + hashlib.sha256(url.encode()).hexdigest()[:8] + '.tar.gz')\n    index = cached if '--cache-max-age 2147483647' in (ib / 'Makefile').read_text() and cached.exists() else pathlib.Path((ib / '.upstream-index').read_text())\n    version = json.loads(index.read_text())['version']\n    (out / 'packages.manifest').write_text('base - ' + version + chr(10))\nelse:\n    (out / 'packages.manifest').write_text(values['PACKAGES'] + chr(10))")
        make.write_text(script)
        with mock.patch.object(build, 'available_packages', side_effect=availability), \
             mock.patch.object(build, 'verify_output', return_value={}):
            build.run_imagebuilder(context, 'full', ['base'], self.work / 'artifacts/full', self.recipe)
        self.assertEqual((self.work / 'artifacts/full/packages.manifest').read_text(), 'base - old-version\n')

    def test_fresh_build_config_and_missing_package_removal(self):
        context = self.fixture_context()
        out = self.work / 'artifacts/full'
        verified = {'images': [], 'manifest': ['base - 1'], 'manifest_sha256': 'a' * 64, 'metadata': METADATA}
        with mock.patch.object(build, 'available_packages', side_effect=self.fake_available), \
             mock.patch.object(build, 'verify_output', return_value=verified):
            result = build.run_imagebuilder(context, 'full', ['base', 'missing', '-dnsmasq'], out, self.recipe)
        config = (out / 'config.buildinfo').read_text()
        self.assertIn('CONFIG_TARGET_ROOTFS_PARTSIZE=3072\n', config)
        self.assertIn('CONFIG_TARGET_KERNEL_PARTSIZE=32\n', config)
        self.assertIn('CONFIG_GRUB_EFI_IMAGES=y\n', config)
        self.assertIn('# CONFIG_GRUB_IMAGES is not set\n', config)
        self.assertIn('# CONFIG_TARGET_ROOTFS_EXT4FS is not set\n', config)
        self.assertIn(f'CONFIG_DOWNLOAD_FOLDER="{context["cache_dir"]}"\n', config)
        self.assertEqual((out / 'packages.manifest').read_text(), 'base -dnsmasq\n')
        self.assertEqual(result['requested_packages'], ['base', 'missing', '-dnsmasq'])
        self.assertEqual(result['removed_packages'], ['missing'])
        self.assertEqual((out / 'feeds.buildinfo').read_text().strip(), str(self.recipe / 'files'))

    def test_build_error_is_not_suppressed(self):
        context = self.fixture_context(fail=True)
        with mock.patch.object(build, 'available_packages', side_effect=self.fake_available):
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                build.run_imagebuilder(context, 'full', ['base'], self.work / 'artifacts/full', self.recipe)
        self.assertEqual(failure.exception.returncode, 7)

    def test_offline_uses_local_repositories_and_clears_live_cache(self):
        context = self.fixture_context()
        repositories = self.root / 'repositories'
        (repositories / 'repo-1').mkdir(parents=True)
        (repositories / 'repositories.list').write_text('repo-1\n')
        (repositories / 'repo-1/packages.adb').write_bytes(b'signed index')
        context['cache_dir'].mkdir()
        (context['cache_dir'] / 'stale-live.apk').write_bytes(b'stale')
        with mock.patch.object(build, 'available_packages', side_effect=self.fake_available), \
             mock.patch.object(build, 'verify_output', return_value={}):
            build.run_imagebuilder(context, 'full', ['base'], self.work / 'artifacts/full', self.recipe, repositories)
        ib = self.work / 'imagebuilder/official-ib'
        self.assertEqual((ib / 'repositories').read_text(), f'file://{repositories}/repo-1/packages.adb\n')
        self.assertFalse((context['cache_dir'] / 'stale-live.apk').exists())

    def test_fresh_extractions_use_same_absolute_path(self):
        context = self.fixture_context()
        with mock.patch.object(build, 'available_packages', side_effect=self.fake_available), \
             mock.patch.object(build, 'verify_output', return_value={}):
            build.run_imagebuilder(context, 'full', ['base'], self.work / 'artifacts/full', self.recipe)
            marker = self.work / 'imagebuilder/official-ib/stale'
            marker.write_text('first extraction')
            build.run_imagebuilder(context, 'minimal', ['base'], self.work / 'artifacts/minimal', self.recipe)
        self.assertFalse(marker.exists())
        self.assertTrue(marker.parent.is_dir())

    def test_exact_replay_comparison_rejects_changed_image_or_manifest(self):
        expected = {'images': [{'filename': 'image.img.gz', 'sha256': 'a' * 64, 'bytes': 3}],
                    'manifest': ['base - 1'], 'manifest_sha256': 'b' * 64}
        for field, changed in [('images', []), ('manifest', ['base - 2']), ('manifest_sha256', 'c' * 64)]:
            result = dict(expected, **{field: changed})
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'replay'):
                build.compare_replay(result, expected)

    def test_live_target_requires_external_offline_replay_before_publication(self):
        context = self.fixture_context()
        result = {'images': [{'filename': 'image.img.gz', 'sha256': 'a' * 64, 'bytes': 3}],
                  'manifest': ['base - 1'], 'manifest_sha256': 'b' * 64,
                  'metadata': METADATA, 'requested_packages': ['base'], 'removed_packages': []}
        ib = context['work'] / 'imagebuilder/official-ib'
        ib.mkdir(parents=True)
        context['imagebuilder'] = ib
        def fake_bundle(directory, archive):
            Path(archive).parent.mkdir(parents=True, exist_ok=True)
            with tarfile.open(archive, 'w:gz') as stream:
                for path in Path(directory).iterdir():
                    stream.add(path, arcname=path.name)
            return Path(archive)
        with mock.patch.object(build, 'fetch_target_inputs', return_value=context), \
             mock.patch.object(build, 'requested_packages', return_value=['base']), \
             mock.patch.object(build, 'run_imagebuilder', side_effect=[copy.deepcopy(result), copy.deepcopy(result)]), \
             mock.patch.object(build, 'capture_repositories', return_value={}), \
             mock.patch.object(build, 'make_bundle', side_effect=fake_bundle):
            target_result = build.build_target(UPSTREAM, 'x86_64', self.work, self.recipe)
        self.assertFalse(target_result['reproduced'])
        self.assertEqual(set(target_result['presets']), {'full', 'minimal'})
        self.assertTrue((self.work / 'artifacts' / target_result['inputs']['filename']).is_file())

    def test_restore_rejects_image_replay_mismatch(self):
        frozen = self.root / 'frozen-source'
        frozen.mkdir()
        (frozen / 'imagebuilder.tar.zst').write_bytes(b'frozen-imagebuilder')
        archive = self.root / 'x86_64-inputs.tar.gz'
        with tarfile.open(archive, 'w:gz') as stream:
            stream.add(frozen / 'imagebuilder.tar.zst', arcname='imagebuilder.tar.zst')
        expected = {'images': [{'filename': 'image.img.gz', 'sha256': 'a' * 64, 'bytes': 3}],
                    'manifest': ['base - 1'], 'manifest_sha256': 'b' * 64,
                    'metadata': METADATA, 'requested_packages': ['base'], 'removed_packages': []}
        target_result = {'target': 'x86_64', 'spec': {'target': 'x86/64', 'profile': 'generic', 'arch': 'x86_64'},
                         'metadata': METADATA,
                         'inputs': {'filename': archive.name, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                                    'bytes': archive.stat().st_size},
                         'presets': {'full': expected, 'minimal': expected}}
        with mock.patch.object(build, 'requested_packages', return_value=['base']), \
             mock.patch.object(build, 'run_imagebuilder', return_value=dict(expected, images=[])):
            with self.assertRaisesRegex(ValueError, 'replay'):
                build.rebuild_target({'upstream': UPSTREAM}, target_result, self.root,
                                     self.work / 'artifacts', self.recipe)

    def test_restore_rejects_bundle_hash_before_extraction(self):
        archive = self.root / 'x86_64-inputs.tar.gz'
        archive.write_bytes(b'tampered')
        target_result = {'target': 'x86_64', 'spec': {'target': 'x86/64', 'profile': 'generic', 'arch': 'x86_64'},
                         'metadata': METADATA,
                         'inputs': {'filename': archive.name, 'sha256': 'a' * 64, 'bytes': 8}, 'presets': {}}
        with self.assertRaisesRegex(ValueError, 'checksum|SHA|hash'):
            build.rebuild_target({'upstream': UPSTREAM}, target_result, self.root,
                                 self.work / 'artifacts', self.recipe)


if __name__ == '__main__':
    unittest.main()
