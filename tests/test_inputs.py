import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from lib import inputs


class InputsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_filter_preserves_negative_removals(self):
        self.assertEqual(inputs.select_packages(['luci', '-wpad-basic', 'missing'], {'luci'}),
                         (['luci', '-wpad-basic'], ['missing']))

    def test_filter_rejects_conflicting_package_intent(self):
        with self.assertRaises(ValueError):
            inputs.select_packages(['luci', '-luci'], {'luci'})

    def test_preset_policy_rejects_runtime_apps_and_wrong_realtek_driver(self):
        packages = self.root / 'packages'
        packages.mkdir()
        (packages / 'base-image.txt').write_text('luci # control plane\n-wpad-basic\n')
        (packages / 'runtime-apps.txt').write_text('luci-app-passwall\n')
        (packages / 'full-drivers-common.txt').write_text('kmod-usb\n')
        (packages / 'full-drivers-x86_64.txt').write_text('kmod-r8169\n')
        self.assertEqual(inputs.requested_packages(self.root, 'x86_64', 'minimal'), ['-wpad-basic', 'luci'])
        with self.assertRaises(ValueError):
            inputs.requested_packages(self.root, 'x86_64', 'full')
        (packages / 'full-drivers-x86_64.txt').write_text('luci-app-passwall\n')
        with self.assertRaises(ValueError):
            inputs.requested_packages(self.root, 'x86_64', 'full')

    def archive(self, entries):
        path = self.root / 'fixture.tar'
        with tarfile.open(path, 'w') as archive:
            for name, kind, value in entries:
                info = tarfile.TarInfo(name)
                if kind == 'file':
                    info.size = len(value)
                    archive.addfile(info, io.BytesIO(value))
                else:
                    info.type = kind
                    info.linkname = value
                    archive.addfile(info)
        return path

    def test_extract_allows_contained_imagebuilder_symlinks(self):
        archive = self.archive([('ib/tool', 'file', b'apk'), ('ib/bin/apk', tarfile.SYMTYPE, '../tool')])
        destination = self.root / 'out'
        inputs.extract_archive(archive, destination)
        self.assertEqual((destination / 'ib/bin/apk').read_bytes(), b'apk')

    def test_extract_rejects_traversal_and_symlink_escape_before_writing(self):
        cases = [('../escape', 'file', b'x'), ('/escape', 'file', b'x'),
                 ('ib/link', tarfile.SYMTYPE, '../../escape'),
                 ('ib/link', tarfile.SYMTYPE, '/etc/passwd'),
                 ('device', tarfile.CHRTYPE, '')]
        for bad in cases:
            with self.subTest(bad=bad):
                destination = self.root / 'out'
                archive = self.archive([('good', 'file', b'good'), bad])
                with self.assertRaises(ValueError):
                    inputs.extract_archive(archive, destination)
                self.assertFalse((destination / 'good').exists())

    def test_extract_rejects_file_written_through_symlink(self):
        archive = self.archive([('ib/dir', tarfile.SYMTYPE, 'actual'), ('ib/dir/tool', 'file', b'bad')])
        with self.assertRaises(ValueError):
            inputs.extract_archive(archive, self.root / 'out')

    def test_deterministic_bundle_normalizes_time_and_retains_executable(self):
        directory = self.root / 'bundle'
        directory.mkdir()
        tool = directory / 'tool'
        tool.write_bytes(b'#!/bin/sh\n')
        tool.chmod(0o755)
        first, second = self.root / 'first.tar.gz', self.root / 'second.tar.gz'
        inputs.make_bundle(directory, first)
        os.utime(tool, (100, 100))
        inputs.make_bundle(directory, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        inputs.extract_archive(first, self.root / 'restored')
        self.assertTrue((self.root / 'restored/tool').stat().st_mode & 0o111)

    def test_download_rejects_digest_and_keeps_prior_file(self):
        source = self.root / 'source'
        source.write_bytes(b'new')
        target = self.root / 'target'
        target.write_bytes(b'old')
        with self.assertRaises(ValueError):
            inputs.download(source.as_uri(), target, expected_sha='0' * 64)
        self.assertEqual(target.read_bytes(), b'old')
        inputs.download(source.as_uri(), target, expected_sha=hashlib.sha256(b'new').hexdigest(), expected_bytes=3)
        self.assertEqual(target.read_bytes(), b'new')

    def test_download_reuses_only_authenticated_matching_cache(self):
        path = self.root / 'cached'
        path.write_bytes(b'verified bytes')
        digest = hashlib.sha256(b'verified bytes').hexdigest()
        with mock.patch.object(inputs, 'urlopen', side_effect=AssertionError('authenticated cache must avoid network')):
            self.assertEqual(inputs.download('https://invalid.example/input', path, digest, 14), path)
            self.assertEqual(path.read_bytes(), b'verified bytes')

    def test_download_refreshes_mismatched_cache_and_unhashed_metadata(self):
        source, target = self.root / 'source', self.root / 'cached'
        source.write_bytes(b'new')
        target.write_bytes(b'old')
        inputs.download(source.as_uri(), target, hashlib.sha256(b'new').hexdigest(), 3)
        self.assertEqual(target.read_bytes(), b'new')
        source.write_bytes(b'fresh metadata')
        inputs.download(source.as_uri(), target)
        self.assertEqual(target.read_bytes(), b'fresh metadata')

    def test_download_retries_transient_errors_then_validates_bytes(self):
        class Response(io.BytesIO):
            def geturl(self):
                return 'https://upstream.example/input'
        for transient in (URLError('connection reset'), HTTPError('https://upstream.example/input', 429, 'throttled', None, None), HTTPError('https://upstream.example/input', 503, 'unavailable', None, None)):
            with self.subTest(transient=transient):
                target = self.root / 'target'
                with mock.patch.object(inputs, 'urlopen', side_effect=[transient, transient, Response(b'new')]), mock.patch('time.sleep'):
                    inputs.download('https://upstream.example/input', target, hashlib.sha256(b'new').hexdigest(), 3)
                self.assertEqual(target.read_bytes(), b'new')
                target.unlink()

    def test_download_stops_after_three_failures_and_preserves_existing_bytes(self):
        target = self.root / 'target'
        target.write_bytes(b'old')
        failures = [URLError('reset')] * 3 + [AssertionError('must stop at three attempts')]
        with mock.patch.object(inputs, 'urlopen', side_effect=failures), mock.patch('time.sleep'):
            with self.assertRaises(URLError):
                inputs.download('https://upstream.example/input', target)
        self.assertEqual(target.read_bytes(), b'old')
        self.assertEqual(list(self.root.glob('.target.*')), [])

    def test_download_does_not_retry_permanent_http_or_wrong_digest(self):
        class Response(io.BytesIO):
            def geturl(self):
                return 'https://upstream.example/input'
        permanent = HTTPError('https://upstream.example/input', 404, 'missing', None, None)
        with mock.patch.object(inputs, 'urlopen', side_effect=[permanent, AssertionError('must not retry HTTP404')]):
            with self.assertRaises(HTTPError):
                inputs.download('https://upstream.example/input', self.root / 'target')
        with mock.patch.object(inputs, 'urlopen', side_effect=[Response(b'new'), AssertionError('must not retry wrong checksum')]):
            with self.assertRaises(ValueError):
                inputs.download('https://upstream.example/input', self.root / 'target', '0' * 64)

    def fixture_repository(self, packages):
        ib = self.root / 'ib'
        apk = ib / 'staging_dir/host/bin/apk'
        apk.parent.mkdir(parents=True)
        # Only the external APK decoder is substituted; capture performs actual IO.
        apk.write_text('#!/usr/bin/env python3\nimport pathlib,sys\nsys.stdout.write(pathlib.Path(sys.argv[-1]).read_text())\n')
        apk.chmod(0o755)
        repo = self.root / 'upstream'
        repo.mkdir()
        (repo / 'packages.adb').write_text(json.dumps({'packages': packages}))
        (ib / 'repositories').write_text((repo / 'packages.adb').as_uri() + '\n')
        cache = self.root / 'cache'
        cache.mkdir()
        return ib, repo, cache

    def test_capture_keeps_signed_index_and_maps_authenticated_cache_names(self):
        package = {'name': 'luci', 'version': '1-r1', 'arch': 'x86_64', 'hashes': 'abcddcba' + '1' * 56}
        dependency = {'name': 'libubus', 'version': '2-r2', 'arch': 'x86_64', 'hashes': '12345678' + '2' * 56}
        ib, repo, cache = self.fixture_repository([package, dependency])
        embedded = ib / 'packages'
        embedded.mkdir()
        for name in ('base-files', 'kernel', 'libc'):
            (embedded / (name + '-1.apk')).write_text(json.dumps({'info': {'name': name, 'version': '1', 'arch': 'x86_64'}}))
        signed_bytes = (repo / 'packages.adb').read_bytes()
        for item in (package, dependency):
            (cache / (item['name'] + '-' + item['version'] + '.' + item['hashes'][:8] + '.apk')).write_text(json.dumps({'info': item}))
        self.assertEqual(inputs.available_packages(ib), {'luci', 'libubus', 'base-files', 'kernel', 'libc'})
        (repo / 'packages.adb').write_text('upstream has changed')
        dest = self.root / 'frozen'
        inputs.capture_repositories(ib, cache, [['base-files - 1', 'kernel - 1', 'libc - 1', 'libubus - 2-r2', 'luci - 1-r1']], dest)
        self.assertEqual((dest / 'repo-1/packages.adb').read_bytes(), signed_bytes)
        self.assertEqual((dest / 'repo-1/luci-1-r1.apk').read_bytes(), (cache / 'luci-1-r1.abcddcba.apk').read_bytes())
        self.assertTrue((dest / 'repo-1/libubus-2-r2.apk').is_file())
        self.assertEqual((dest / 'repositories.list').read_text(), 'repo-1\n')

    def test_capture_fails_missing_dependency_or_mismatched_apk_identity(self):
        item = {'name': 'luci', 'version': '1-r1', 'arch': 'x86_64', 'hashes': 'abcddcba' + '1' * 56}
        ib, _, cache = self.fixture_repository([item])
        inputs.available_packages(ib)
        with self.assertRaises(ValueError):
            inputs.capture_repositories(ib, cache, [['dependency - 1']], self.root / 'missing')
        (cache / 'luci-1-r1.abcddcba.apk').write_text(json.dumps({'info': {**item, 'name': 'wrong'}}))
        with self.assertRaises(ValueError):
            inputs.capture_repositories(ib, cache, [['luci - 1-r1']], self.root / 'wrong')

    def test_missing_index_is_an_error_not_an_empty_package_set(self):
        ib, repo, _ = self.fixture_repository([])
        (repo / 'packages.adb').unlink()
        with self.assertRaises((ValueError, OSError)):
            inputs.available_packages(ib)

    def test_imagebuilder_embedded_apks_are_available_without_remote_cache(self):
        item = {'name': 'libgcc', 'version': '1-r1', 'arch': 'x86_64', 'hashes': 'abcddcba' + '1' * 56}
        ib, _, cache = self.fixture_repository([{'name': 'luci', 'version': '1', 'arch': 'x86_64', 'hashes': 'a' * 64}])
        local = ib / 'packages'
        local.mkdir()
        (local / 'libgcc-1-r1.apk').write_text(json.dumps({'info': item}))
        self.assertIn('libgcc', inputs.available_packages(ib))
        dest = self.root / 'captured'
        inputs.capture_repositories(ib, cache, [['libgcc - 1-r1']], dest)
        self.assertTrue((dest / 'repo-1/packages.adb').is_file())

    def test_extract_resolves_dotdot_after_symlink_before_accepting_target(self):
        archive = self.archive([('ib/dir', tarfile.SYMTYPE, '..'),
                                ('ib/link', tarfile.SYMTYPE, 'dir/../escape')])
        with self.assertRaises(ValueError):
            inputs.extract_archive(archive, self.root / 'out')

    def test_zstd_bundle_roundtrip(self):
        try:
            from compression import zstd
        except ImportError:
            self.skipTest('stdlib zstd unavailable')
        directory = self.root / 'bundle'
        directory.mkdir()
        (directory / 'input').write_bytes(b'frozen input')
        archive = self.root / 'bundle.tar.zst'
        inputs.make_bundle(directory, archive)
        inputs.extract_archive(archive, self.root / 'restored')
        self.assertEqual((self.root / 'restored/input').read_bytes(), b'frozen input')

    def test_capture_rejects_ambiguous_repository_variants(self):
        item = {'name': 'luci', 'version': '1-r1', 'arch': 'x86_64', 'hashes': 'a' * 64}
        ib, repo, cache = self.fixture_repository([item])
        second = self.root / 'second-repo'
        second.mkdir()
        variant = {**item, 'hashes': 'b' * 64}
        (second / 'packages.adb').write_text(json.dumps({'packages': [variant]}))
        (ib / 'repositories').write_text((repo / 'packages.adb').as_uri() + '\n' + (second / 'packages.adb').as_uri() + '\n')
        for package in (item, variant):
            (cache / ('luci-1-r1.' + package['hashes'][:8] + '.apk')).write_text(json.dumps({'info': package}))
        with self.assertRaises(ValueError):
            inputs.capture_repositories(ib, cache, [['luci - 1-r1']], self.root / 'out')
        self.assertFalse((self.root / 'out').exists())

    def test_capture_rejects_conflicting_versions_across_presets(self):
        item = {'name': 'luci', 'version': '1-r1', 'arch': 'x86_64', 'hashes': 'a' * 64}
        ib, _, cache = self.fixture_repository([item])
        with self.assertRaises(ValueError):
            inputs.capture_repositories(ib, cache, [['luci - 1-r1'], ['luci - 2-r1']], self.root / 'out')

    def test_capture_rejects_missing_builtin_version(self):
        item = {'name': 'luci', 'version': '1-r1', 'arch': 'x86_64', 'hashes': 'a' * 64}
        ib, _, cache = self.fixture_repository([item])
        (ib / 'packages').mkdir()
        (ib / 'packages/base-files-1.apk').write_text(json.dumps({'info': {'name': 'base-files', 'version': '1', 'arch': 'x86_64'}}))
        with self.assertRaises(ValueError):
            inputs.capture_repositories(ib, cache, [['base-files - nonexistent']], self.root / 'out')

    def test_extract_remaps_only_known_imagebuilder_host_tool_links(self):
        root = 'immortalwrt-imagebuilder-25.12.2-x86-64.Linux-x86_64'
        entries = [(root + '/scripts/noop.sh', 'file', b'#!/bin/sh\n'),
                   (root + '/scripts/xxdi.pl', 'file', b'#!/usr/bin/perl\n')]
        for name, target in [('getopt', '/usr/bin/getopt'), ('bash', '/usr/bin/bash'),
                             ('python3', '/usr/bin/python3.9'), ('python', '/usr/bin/python3.9'),
                             ('xxd', '/mnt/disk/openwrt-25.12/scripts/xxdi.pl'),
                             ('ldconfig', '/immortalwrt/openwrt-25.12/scripts/noop.sh')]:
            entries.append((root + '/staging_dir/host/bin/' + name, tarfile.SYMTYPE, target))
        destination = self.root / 'out'
        inputs.extract_archive(self.archive(entries), destination)
        host = destination / root / 'staging_dir/host/bin'
        self.assertEqual(os.readlink(host / 'getopt'), '/usr/bin/getopt')
        self.assertEqual(os.readlink(host / 'bash'), '/usr/bin/bash')
        self.assertEqual(os.readlink(host / 'python3'), '/usr/bin/python3')
        self.assertEqual(os.readlink(host / 'python'), '/usr/bin/python3')
        self.assertEqual((host / 'xxd').read_bytes(), b'#!/usr/bin/perl\n')
        self.assertEqual((host / 'ldconfig').read_bytes(), b'#!/bin/sh\n')

    def test_extract_rejects_unexpected_imagebuilder_host_targets(self):
        root = 'immortalwrt-imagebuilder-25.12.2-x86-64.Linux-x86_64'
        cases = [(root + '/staging_dir/host/bin/bash', '/etc/passwd'),
                 (root + '/staging_dir/host/bin/bash', '/usr/bin/python3.9'),
                 (root + '/staging_dir/host/bin/unknown', '/usr/bin/bash'),
                 (root + '/usr/bin/bash', '/usr/bin/bash'),
                 ('ib/staging_dir/host/bin/bash', '/usr/bin/bash'),
                 (root + '/staging_dir/host/bin/xxd', '/etc/xxdi.pl')]
        for name, target in cases:
            with self.subTest(name=name, target=target):
                with self.assertRaises(ValueError):
                    inputs.extract_archive(self.archive([(name, tarfile.SYMTYPE, target)]), self.root / 'out')

    def test_extract_preserves_tar_timestamps_without_following_links(self):
        archive = self.root / 'times.tar'
        with tarfile.open(archive, 'w') as output:
            directory = tarfile.TarInfo('ib')
            directory.type = tarfile.DIRTYPE
            directory.mtime = 1600000000
            output.addfile(directory)
            tool = tarfile.TarInfo('ib/tool')
            tool.size, tool.mtime, tool.mode = 3, 1600000001, 0o755
            output.addfile(tool, io.BytesIO(b'apk'))
            link = tarfile.TarInfo('ib/link')
            link.type, link.linkname, link.mtime = tarfile.SYMTYPE, 'tool', 1600000002
            output.addfile(link)
        destination = self.root / 'out'
        inputs.extract_archive(archive, destination)
        self.assertEqual((destination / 'ib').stat().st_mtime, 1600000000)
        self.assertEqual((destination / 'ib/tool').stat().st_mtime, 1600000001)
        self.assertEqual((destination / 'ib/link').lstat().st_mtime, 1600000002)


if __name__ == '__main__':
    unittest.main()
