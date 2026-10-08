import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import sys
import subprocess
from unittest.mock import MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from lib import releases
import firmware
from lib.inputs import file_record
from lib.lock import load_lock
from test_lock import complete_lock


class DiscoveryTests(unittest.TestCase):
    def test_version_boundaries_and_prerelease_filter(self):
        html = '<a href="1.1.9/">x</a><a href="1.2.0/">x</a><a href="10.0.0-rc1/">x</a><a href="2.0.0/">x</a>'
        self.assertEqual(releases.stable_versions(html), ['1.1.9', '1.2.0', '2.0.0'])

    def test_annotated_tag_is_peeled_separately(self):
        responses = [{'object': {'type': 'tag', 'sha': 'a' * 40}},
                     {'object': {'type': 'commit', 'sha': 'b' * 40}}]
        with patch.object(releases, 'api', side_effect=responses):
            self.assertEqual(releases.source_commit('25.12.2'), 'b' * 40)

    def test_published_source_skips_but_draft_does_not(self):
        upstream = {'version': '1.2.0', 'source_commit': 'a' * 40}
        release = {'draft': False, 'prerelease': False,
                   'body': releases.source_marker(upstream),
                   'assets': [{'name': 'LOCK.json'}]}
        self.assertTrue(releases.already_published(upstream, [release]))
        release['draft'] = True
        self.assertFalse(releases.already_published(upstream, [release]))

    def test_no_stable_version_is_an_error(self):
        with self.assertRaises(ValueError):
            releases.stable_versions('<a href="SNAPSHOT/">SNAPSHOT</a>')


class PublicationTests(unittest.TestCase):
    def fixture(self, root):
        document = complete_lock()
        environment = root / document['environment']['filename']
        environment.write_bytes(b'frozen build environment')
        document['environment'].update(file_record(environment))
        results = root / 'targets'
        for target, result in document['targets'].items():
            artifacts = results / target / 'artifacts'
            artifacts.mkdir(parents=True)
            path = artifacts / result['inputs']['filename']
            path.write_bytes(('frozen ' + target).encode())
            result['inputs'].update(file_record(path))
            for preset, built in result['presets'].items():
                (artifacts / preset).mkdir()
                for record in built['images']:
                    image = artifacts / preset / record['filename']
                    image.write_bytes(record['filename'].encode())
                    record.update(file_record(image))
                    for entry in built['metadata']['profiles'][result['spec']['profile']]['images']:
                        if entry['name'] == image.name:
                            entry.update(size=record['bytes'], sha256=record['sha256'])
            result['reproduced'] = True
            firmware.save_json(result, results / target / 'result.json')
        return document, environment, results

    def seal(self, document, environment, results, output):
        return firmware.create_lock(document['upstream'], results, environment,
                                    document['environment']['image_id'], document['recipe']['commit'],
                                    document['release']['repository'], output)

    def test_six_successful_results_produce_one_complete_release(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            document, environment, results = self.fixture(root)
            sealed = self.seal(document, environment, results, root / 'release')
            self.assertEqual(len(list((root / 'release').iterdir())), 16)
            self.assertEqual(load_lock(root / 'release/LOCK.json'), sealed)

    def test_failed_or_incomplete_replay_never_writes_lock(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            document, environment, results = self.fixture(root)
            result_path = results / 'rpi5/result.json'
            result = firmware.read_json(result_path)
            result['reproduced'] = False
            firmware.save_json(result, result_path)
            with self.assertRaises(ValueError):
                self.seal(document, environment, results, root / 'release')
            self.assertFalse((root / 'release').exists())

    def test_corruption_before_staging_does_not_leave_a_lock(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            document, environment, results = self.fixture(root)
            record = document['targets']['rpi4']['presets']['full']['images'][0]
            (results / 'rpi4/artifacts/full' / record['filename']).write_bytes(b'corrupted')
            with self.assertRaises(ValueError):
                self.seal(document, environment, results, root / 'release')
            self.assertFalse((root / 'release/LOCK.json').exists())

    def test_corruption_before_publish_never_mutates_release(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            document, environment, results = self.fixture(root)
            self.seal(document, environment, results, root / 'release')
            (root / 'release/SHA256SUMS').write_text('')
            with patch.object(releases, 'publish') as publish:
                with self.assertRaises(ValueError):
                    firmware.publish_release(root / 'release/LOCK.json')
                publish.assert_not_called()

    def test_failed_upload_keeps_release_draft(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'image.img.gz').write_bytes(b'firmware')
            document = complete_lock()
            draft = {'id': 1, 'assets': [], 'upload_url': 'https://uploads.github.com/test{?name}'}
            with patch.object(releases, 'list_releases', return_value=[]), \
                    patch.object(releases, 'api', return_value=draft) as api, \
                    patch.object(releases, 'request', return_value=b'{"size":8,"digest":"sha256:wrong"}'):
                with self.assertRaises(ValueError):
                    releases.publish(document['release']['repository'], document, root)
                self.assertTrue(api.call_args.args[1]['draft'])
                self.assertEqual(api.call_count, 1)


class EnvironmentTests(unittest.TestCase):
    def test_loaded_runtime_identity_can_differ_from_historical_identity(self):
        document = complete_lock()
        runtime_id = 'sha256:' + 'e' * 64
        decompressor = MagicMock()
        decompressor.wait.return_value = 0
        decompressor.poll.return_value = 0
        loaded = subprocess.CompletedProcess([], 0, stdout='Loaded image: firmware-build:latest\n')
        inspection = json.dumps([{'Id': runtime_id, 'Architecture': 'amd64', 'Os': 'linux'}]).encode()
        with tempfile.TemporaryDirectory() as temp, \
                patch.object(firmware, 'load_lock', return_value=document), \
                patch.object(firmware, 'download'), \
                patch.object(firmware.subprocess, 'Popen', return_value=decompressor), \
                patch.object(firmware.subprocess, 'check_output', return_value=inspection) as inspect, \
                patch.object(firmware.subprocess, 'run', return_value=loaded) as run:
            firmware.rebuild('/unused/LOCK.json', temp, ['x86_64'])
            self.assertIn('firmware-build:latest', inspect.call_args.args[0])
            command = run.call_args.args[0]
            self.assertIn(runtime_id, command)
            self.assertNotIn(document['environment']['image_id'], command)
            self.assertIn('--pull=never', command)
            self.assertIn('none', command)

    def test_load_rejects_missing_or_ambiguous_reference_and_wrong_platform(self):
        valid = {'Id': 'sha256:' + 'e' * 64, 'Architecture': 'amd64', 'Os': 'linux'}
        cases = [('', valid), ('Loaded image: one\nLoaded image: two\n', valid),
                 ('Loaded image: one\n', dict(valid, Architecture='arm64')),
                 ('Loaded image: one\n', dict(valid, Os='windows'))]
        for stdout, image in cases:
            with self.subTest(stdout=stdout, image=image):
                decompressor = MagicMock()
                decompressor.wait.return_value = 0
                decompressor.poll.return_value = 0
                with patch.object(firmware.subprocess, 'Popen', return_value=decompressor), \
                        patch.object(firmware.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=stdout)), \
                        patch.object(firmware.subprocess, 'check_output', return_value=json.dumps([image]).encode()):
                    with self.assertRaises(ValueError):
                        firmware.load_environment(Path('/unused/archive.tar.zst'))


if __name__ == '__main__':
    unittest.main()
