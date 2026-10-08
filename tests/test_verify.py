"""Artifact verifier behavior, using real SquashFS files at the image offset."""
import copy
import gzip
import hashlib
import importlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
try:
    verify = importlib.import_module('lib.verify')
except ModuleNotFoundError:
    verify = None

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('mksquashfs') and shutil.which('unsquashfs'), 'SquashFS tools required')
class VerifyOutputTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(verify, 'verification module is missing')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.recipe = self.work / 'recipe'
        shutil.copytree(ROOT / 'files', self.recipe / 'files')
        (self.recipe / 'packages').mkdir()
        (self.recipe / 'packages/runtime-apps.txt').write_text('runtime-only\n')
        self.out = self.work / 'out'
        self.out.mkdir()
        self.fs = self.work / 'fs'
        shutil.copytree(self.recipe / 'files', self.fs)
        for name in ['lib/libustream-ssl.so', 'usr/sbin/uhttpd', 'www/cgi-bin/luci']:
            path = self.fs / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'runtime-content')
        self.metadata = {
            'version_number': '29.1.0', 'version_code': 'r41001-123456789abc',
            'source_date_epoch': 1800000000, 'target': 'x86/64',
            'arch_packages': 'x86_64',
            'linux_kernel': {'version': '6.12.20', 'release': '1', 'vermagic': 'a' * 32},
            'profiles': {'generic': {'supported_devices': ['x86,generic'], 'images': []}},
        }
        self.image_name = 'arbitrary-next-major-full-squashfs-combined-efi.img.gz'
        self.manifest_path = self.out / 'unversioned.manifest'
        self.manifest_path.write_text('base-files - 1\nuhttpd - 2\n')
        self.repack()
        self.structure = mock.patch.object(verify, '_verify_structure', return_value=None)
        self.structure.start()
        self.addCleanup(self.structure.stop)

    def repack(self):
        sq = self.work / 'root.squashfs'
        subprocess.run(['mksquashfs', str(self.fs), str(sq), '-noappend', '-processors', '1', '-quiet'], check=True, stdout=subprocess.DEVNULL)
        raw = self.work / 'raw.img'
        with raw.open('wb') as stream:
            stream.seek(66048 * 512)
            stream.write(sq.read_bytes())
        image = self.out / self.image_name
        with raw.open('rb') as src, image.open('wb') as dst:
            with gzip.GzipFile(filename='', mode='wb', fileobj=dst, mtime=0) as zipped:
                shutil.copyfileobj(src, zipped)
        digest = hashlib.sha256(image.read_bytes()).hexdigest()
        self.metadata['profiles']['generic']['images'] = [{
            'name': self.image_name, 'type': 'combined-efi', 'filesystem': 'squashfs',
            'size': image.stat().st_size, 'sha256': digest,
        }]
        self.save_metadata()

    def save_metadata(self):
        (self.out / 'profiles.json').write_text(json.dumps(self.metadata))

    def run_verify(self, expected=None, smoke=False):
        return verify.verify_output(self.out, 'x86_64', copy.deepcopy(self.metadata), ['uhttpd'], self.recipe, expected_result=expected, smoke=smoke)

    def test_discovers_current_image_name_from_profiles(self):
        result = self.run_verify()
        self.assertEqual([self.image_name], [item['filename'] for item in result['images']])
        self.assertEqual(['base-files - 1', 'uhttpd - 2'], result['manifest'])
        self.assertEqual(hashlib.sha256(self.manifest_path.read_bytes()).hexdigest(), result['manifest_sha256'])
        self.assertEqual(self.metadata, result['metadata'])

    def test_rejects_each_wrong_build_identity(self):
        expected = copy.deepcopy(self.metadata)
        for field, bad in [('version_number', '29.1.1'), ('version_code', 'r1-abcdef0'), ('source_date_epoch', 1), ('target', 'x86/32'), ('arch_packages', 'arm')]:
            with self.subTest(field=field):
                self.metadata[field] = bad
                self.save_metadata()
                with self.assertRaises(ValueError):
                    verify.verify_output(self.out, 'x86_64', expected, ['uhttpd'], self.recipe, smoke=False)
                self.metadata = copy.deepcopy(expected)
        self.metadata['linux_kernel']['vermagic'] = 'b' * 32
        self.save_metadata()
        with self.assertRaises(ValueError):
            verify.verify_output(self.out, 'x86_64', expected, ['uhttpd'], self.recipe, smoke=False)

    def test_rejects_wrong_device_profile(self):
        expected = copy.deepcopy(self.metadata)
        self.metadata['profiles']['generic']['supported_devices'] = ['different-device']
        self.save_metadata()
        with self.assertRaises(ValueError):
            verify.verify_output(self.out, 'x86_64', expected, ['uhttpd'], self.recipe, smoke=False)

    def test_rejects_wrong_image_digest_and_size(self):
        for field, bad in [('sha256', '0' * 64), ('size', 1)]:
            with self.subTest(field=field):
                old = self.metadata['profiles']['generic']['images'][0][field]
                self.metadata['profiles']['generic']['images'][0][field] = bad
                self.save_metadata()
                with self.assertRaises(ValueError):
                    self.run_verify()
                self.metadata['profiles']['generic']['images'][0][field] = old

    def test_rejects_unsafe_and_duplicate_metadata_names(self):
        for name in ['../escape.img.gz', '/absolute.img.gz']:
            with self.subTest(name=name):
                self.metadata['profiles']['generic']['images'][0]['name'] = name
                self.save_metadata()
                with self.assertRaises(ValueError):
                    self.run_verify()
        self.metadata['profiles']['generic']['images'][0]['name'] = self.image_name
        self.metadata['profiles']['generic']['images'] *= 2
        self.save_metadata()
        with self.assertRaises(ValueError):
            self.run_verify()

    def test_rejects_extra_or_symlinked_image(self):
        extra = self.out / 'stale-squashfs-combined-efi.img.gz'
        extra.write_bytes(b'stale')
        with self.assertRaises(ValueError):
            self.run_verify()
        extra.unlink()
        image = self.out / self.image_name
        original = self.work / 'original.gz'
        image.rename(original)
        image.symlink_to(original)
        with self.assertRaises(ValueError):
            self.run_verify()

    def test_manifest_requires_requested_packages_and_excludes_removals(self):
        self.manifest_path.write_text('base-files - 1\n')
        with self.assertRaises(ValueError):
            self.run_verify()
        self.manifest_path.write_text('base-files - 1\nuhttpd - 2\nremoved - 1\n')
        with self.assertRaises(ValueError):
            verify.verify_output(self.out, 'x86_64', self.metadata, ['uhttpd', '-removed'], self.recipe, smoke=False)

    def test_rejects_ambiguous_and_duplicate_package_manifest(self):
        self.manifest_path.write_text('uhttpd - 2\nuhttpd - 3\n')
        with self.assertRaises(ValueError):
            self.run_verify()
        self.manifest_path.write_text('uhttpd - 2\n')
        (self.out / 'other.manifest').write_text('uhttpd - 2\n')
        with self.assertRaises(ValueError):
            self.run_verify()

    def test_rejects_noncanonical_manifest_bytes(self):
        for data in [b'uhttpd - 2', b'uhttpd - 2\r\n']:
            with self.subTest(data=data):
                self.manifest_path.write_bytes(data)
                with self.assertRaises(ValueError):
                    self.run_verify()

    def test_rejects_runtime_apps_in_manifest(self):
        self.manifest_path.write_text('uhttpd - 2\nruntime-only - 1\n')
        with self.assertRaises(ValueError):
            self.run_verify()

    def test_rejects_actual_missing_runtime_file(self):
        (self.fs / 'lib/libustream-ssl.so').unlink()
        self.repack()
        with self.assertRaises(ValueError):
            self.run_verify()

    def test_rejects_actual_changed_overlay_file(self):
        (self.fs / 'etc/config/attendedsysupgrade').write_text('wrong server\n')
        self.repack()
        with self.assertRaises(ValueError):
            self.run_verify()

    def test_checks_every_recipe_overlay_file(self):
        (self.recipe / 'files/etc/new-setting').write_text('new setting\n')
        with self.assertRaises(ValueError):
            self.run_verify()

    def test_replay_requires_exact_manifest_bytes(self):
        expected = self.run_verify()
        self.manifest_path.write_text('uhttpd - 2\nbase-files - 1\n')
        with self.assertRaises(ValueError):
            self.run_verify(expected=expected)

    def test_replay_requires_exact_image_digest(self):
        expected = self.run_verify()
        (self.fs / 'new-file').write_text('different but valid filesystem\n')
        self.repack()
        with self.assertRaises(ValueError):
            self.run_verify(expected=expected)

    def test_real_structure_failure_is_fatal(self):
        self.structure.stop()
        with self.assertRaises(ValueError):
            self.run_verify()

    def test_x86_smoke_failure_is_fatal(self):
        scripts = self.recipe / 'scripts/verify'
        scripts.mkdir(parents=True)
        (scripts / 'smoke-test-x86-uefi.sh').write_text('#!/bin/sh\nexit 9\n')
        with self.assertRaises(ValueError):
            self.run_verify(smoke=True)


class SmokeScriptTests(unittest.TestCase):
    def test_runs_without_legacy_common_library(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / 'smoke.sh'
            shutil.copyfile(ROOT / 'scripts/verify/smoke-test-x86-uefi.sh', script)
            proc = subprocess.run(['bash', str(script), str(Path(tmp) / 'missing')], text=True, capture_output=True)
            self.assertNotEqual(0, proc.returncode)
            self.assertIn('missing artifact directory', proc.stderr)
            self.assertNotIn('common.sh', proc.stderr)


if __name__ == '__main__':
    unittest.main()
