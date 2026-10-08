import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from lib import lock


def complete_lock():
    def record(name):
        return {'filename': name, 'sha256': 'a' * 64, 'bytes': 1}
    document = {
        'schema': 1,
        'upstream': {'version': '25.12.0', 'source_tag': 'v25.12.0', 'source_commit': 'b' * 40,
                     'download_url': 'https://downloads.immortalwrt.org/releases/25.12.0'},
        'recipe': {'commit': 'c' * 40},
        'environment': {**record('build-environment.tar.gz'), 'image_id': 'sha256:' + 'd' * 64, 'architecture': 'amd64'},
        'geometry': {'rootfs_mib': 3072, 'media_bytes': 4000000000},
        'release': {'repository': 'hmxf/hmxf-OpenWRT', 'tag': 'stable-25.12.0-bbbbbbbb'},
        'targets': {},
    }
    for target, spec in lock.TARGETS.items():
        metadata = {'version_number': '25.12.0', 'version_code': 'r123-abcd', 'source_date_epoch': 1750000000,
                    'target': spec['target'], 'arch_packages': spec['arch'], 'linux_kernel': {'version': '6.6.1'},
                    'profiles': {spec['profile']: {'images': []}}}
        presets = {}
        for preset in lock.PRESETS:
            images = [record(target + '-' + preset + '-efi.img.gz')] if target == 'x86_64' else [record(target + '-' + preset + '-' + kind + '.img.gz') for kind in ('factory', 'sysupgrade')]
            presets[preset] = {'images': images, 'manifest': ['luci - 1-r1'],
                              'manifest_sha256': hashlib.sha256(b'luci - 1-r1\n').hexdigest(),
                              'metadata': copy.deepcopy(metadata), 'requested_packages': ['luci', 'missing'],
                              'removed_packages': ['missing']}
            presets[preset]['metadata']['profiles'][spec['profile']]['images'] = [
                {'name': image['filename'], 'sha256': image['sha256'], 'size': image['bytes'],
                 'filesystem': 'squashfs', 'type': 'combined-efi' if target == 'x86_64' else ('factory' if 'factory' in image['filename'] else 'sysupgrade')}
                for image in images]
        document['targets'][target] = {'target': target, 'spec': copy.deepcopy(spec), 'metadata': metadata,
                                       'inputs': record(target + '-inputs.tar.gz'), 'presets': presets}
    return document


class LockTests(unittest.TestCase):
    def test_accepts_all_six_verified_results_and_preserves_revision_distinction(self):
        document = complete_lock()
        lock.validate_lock(document)
        self.assertNotEqual(document['upstream']['source_commit'], document['targets']['x86_64']['metadata']['version_code'])

    def test_preset_metadata_can_have_custom_images_but_cannot_lie_about_image_hash(self):
        document = complete_lock()
        lock.validate_lock(document)
        self.assertNotEqual(document['targets']['x86_64']['metadata']['profiles'],
                            document['targets']['x86_64']['presets']['full']['metadata']['profiles'])
        document['targets']['x86_64']['presets']['full']['metadata']['profiles']['generic']['images'][0]['sha256'] = 'b' * 64
        with self.assertRaises(ValueError):
            lock.validate_lock(document)

    def test_rejects_missing_preset_and_incomplete_image_inventory(self):
        document = complete_lock()
        del document['targets']['rpi4']['presets']['minimal']
        with self.assertRaises(ValueError):
            lock.validate_lock(document)
        document = complete_lock()
        document['targets']['rpi5']['presets']['full']['images'].pop()
        with self.assertRaises(ValueError):
            lock.validate_lock(document)

    def test_rejects_unsafe_records_and_global_asset_collisions(self):
        for field, value in [('filename', '../escape'), ('filename', 'unsafe name.tar'), ('bytes', True), ('bytes', 0), ('sha256', 'A' * 64)]:
            with self.subTest(field=field, value=value):
                document = complete_lock()
                document['environment'][field] = value
                with self.assertRaises(ValueError):
                    lock.validate_lock(document)
        document = complete_lock()
        document['targets']['rpi4']['inputs']['filename'] = document['targets']['x86_64']['inputs']['filename']
        with self.assertRaises(ValueError):
            lock.validate_lock(document)

    def test_rejects_manifest_tampering_removal_lies_and_metadata_mismatch(self):
        for mutation in ('manifest', 'removed', 'metadata'):
            with self.subTest(mutation=mutation):
                document = complete_lock()
                result = document['targets']['rpi4']['presets']['full']
                if mutation == 'manifest':
                    result['manifest'] = ['luci - 2-r1']
                elif mutation == 'removed':
                    result['removed_packages'] = ['unrequested']
                else:
                    result['metadata']['version_code'] = 'wrong'
                with self.assertRaises(ValueError):
                    lock.validate_lock(document)

    def test_write_validates_before_replacing_existing_lock_and_load_rejects_duplicates(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'LOCK.json'
            document = complete_lock()
            lock.write_lock(document, path)
            self.assertEqual(lock.load_lock(path), document)
            original = path.read_bytes()
            document['targets'].pop('x86_64')
            with self.assertRaises(ValueError):
                lock.write_lock(document, path)
            self.assertEqual(path.read_bytes(), original)
            path.write_text('{"schema":1,"schema":1}')
            with self.assertRaises(ValueError):
                lock.load_lock(path)


if __name__ == '__main__':
    unittest.main()
