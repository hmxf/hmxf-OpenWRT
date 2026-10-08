#!/usr/bin/env python3
"""Five operations: discover, fetch, build, lock and publish latest stable firmware."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from lib import releases
from lib.inputs import download, file_record, sha256
from lib.lock import TARGETS, PRESETS, load_lock, validate_lock, write_lock

ROOT = Path(__file__).resolve().parents[1]


def read_json(path):
    return json.loads(Path(path).read_text())


def save_json(value, path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def check_update(repository, output, force=False):
    upstream = releases.latest_stable()
    changed = force or not releases.already_published(upstream, releases.list_releases(repository))
    save_json(upstream, output)
    print(f'Stable source: {upstream["source_tag"]} ({upstream["source_commit"]}); build={changed}')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write(f'changed={str(changed).lower()}\nversion={upstream["version"]}\n')
    return changed


def fetch_inputs(upstream, target, work):
    from lib.build import fetch_target_inputs
    return fetch_target_inputs(upstream, target, work)


def build_firmware(upstream, target, work):
    from lib.build import build_target
    result = build_target(upstream, target, work, ROOT)
    save_json(result, Path(work) / 'result.json')
    return result


def create_lock(upstream, results_dir, environment, image_id, commit, repository, output):
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', image_id):
        raise ValueError('invalid frozen Docker image identity')
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('recipe must have a committed git identity')
    targets = {}
    for target in TARGETS:
        result = read_json(Path(results_dir) / target / 'result.json')
        if result.get('target') != target or result.get('reproduced') is not True:
            raise ValueError(f'{target} did not complete its offline reproduction checks')
        result.pop('reproduced')
        targets[target] = result
    lock = {'schema': 1, 'upstream': upstream, 'recipe': {'commit': commit},
            'environment': {**file_record(environment), 'image_id': image_id, 'architecture': 'amd64'},
            'geometry': {'rootfs_mib': 3072, 'media_bytes': 4000000000},
            'release': {'repository': repository, 'tag': 'pending'}, 'targets': targets}
    fingerprint = hashlib.sha256(json.dumps(lock, sort_keys=True, separators=(',', ':')).encode()).hexdigest()[:12]
    lock['release']['tag'] = f'stable-v{upstream["version"]}-{fingerprint}'
    validate_lock(lock)
    output = Path(output)
    if output.exists():
        raise ValueError(f'Release staging directory already exists: {output}')
    output.mkdir(parents=True)
    try:
        def copy_record(record, source):
            if file_record(source) != {key: record[key] for key in ('filename', 'sha256', 'bytes')}:
                raise ValueError(f'asset changed before publication: {source}')
            destination = output / record['filename']
            if destination.exists():
                raise ValueError(f'duplicate Release filename: {destination.name}')
            shutil.copyfile(source, destination)

        copy_record(lock['environment'], environment)
        for target, result in targets.items():
            artifacts = Path(results_dir) / target / 'artifacts'
            copy_record(result['inputs'], artifacts / result['inputs']['filename'])
            for preset in PRESETS:
                for record in result['presets'][preset]['images']:
                    copy_record(record, artifacts / preset / record['filename'])
        write_lock(lock, output / 'LOCK.json')
        (output / 'SHA256SUMS').write_text(''.join(
            f'{sha256(path)}  {path.name}\n' for path in sorted(output.iterdir()) if path.is_file()))
    except Exception:
        shutil.rmtree(output)
        raise
    return lock


def publish_release(lock_path):
    lock = load_lock(lock_path)
    directory = Path(lock_path).resolve().parent
    required = {'LOCK.json', 'SHA256SUMS', lock['environment']['filename']}
    records = [lock['environment']]
    for result in lock['targets'].values():
        required.add(result['inputs']['filename'])
        records.append(result['inputs'])
        for preset in result['presets'].values():
            required.update(record['filename'] for record in preset['images'])
            records.extend(preset['images'])
    if {path.name for path in directory.iterdir()} != required:
        raise ValueError('Release staging asset set differs from lock')
    # Recheck bytes before making any remote mutation.
    for record in records:
        if file_record(directory / record['filename']) != {key: record[key] for key in ('filename', 'sha256', 'bytes')}:
            raise ValueError(f'Release asset differs from lock: {record["filename"]}')
    indexed = set()
    for line in (directory / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split('  ', 1)
        if name in indexed or name == 'SHA256SUMS' or name not in required or sha256(directory / name) != digest:
            raise ValueError(f'Release checksum mismatch: {name}')
        indexed.add(name)
    if indexed != required - {'SHA256SUMS'}:
        raise ValueError('Release checksum inventory is incomplete')
    return releases.publish(lock['release']['repository'], lock, directory)


def rebuild(lock_path, output, targets=None):
    lock = load_lock(lock_path)
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    run = output / 'run'
    inputs = run / 'inputs'
    inputs.mkdir(parents=True, exist_ok=True)
    save_json(lock, run / 'LOCK.json')
    selected = targets or list(TARGETS)
    base = f'https://github.com/{lock["release"]["repository"]}/releases/download/{lock["release"]["tag"]}/'
    for record in [lock['environment']] + [lock['targets'][target]['inputs'] for target in selected]:
        download(base + record['filename'], inputs / record['filename'], record['sha256'], record['bytes'])
    environment = inputs / lock['environment']['filename']
    zstd = subprocess.Popen(['zstd', '-dc', str(environment)], stdout=subprocess.PIPE)
    try:
        subprocess.run(['docker', 'load'], stdin=zstd.stdout, check=True)
        zstd.stdout.close()
        if zstd.wait() != 0:
            raise ValueError('frozen environment decompression failed')
    finally:
        if zstd.poll() is None:
            zstd.kill()
            zstd.wait()
    subprocess.run(['docker', 'image', 'inspect', lock['environment']['image_id']], check=True,
                   stdout=subprocess.DEVNULL)
    subprocess.run(['docker', 'run', '--rm', '--network', 'none',
                    '--user', f'{os.getuid()}:{os.getgid()}',
                    '-v', f'{output}:/work', lock['environment']['image_id'],
                    '_replay', '/work/run/LOCK.json', '--targets', *selected], check=True)
    print(f'All requested images match LOCK.json: {output / "targets"}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('check')
    check.add_argument('--repository', required=True)
    check.add_argument('--output', required=True)
    check.add_argument('--force', action='store_true')
    fetch = commands.add_parser('fetch')
    build = commands.add_parser('build')
    for command in (fetch, build):
        command.add_argument('--upstream', required=True)
        command.add_argument('--target', choices=TARGETS, required=True)
        command.add_argument('--work', required=True)
    repeat = commands.add_parser('_replay-target')
    repeat.add_argument('--upstream', required=True)
    repeat.add_argument('--target', choices=TARGETS, required=True)
    repeat.add_argument('--work', required=True)
    seal = commands.add_parser('lock')
    for argument in ('upstream', 'results', 'environment', 'image-id', 'commit', 'repository', 'output'):
        seal.add_argument('--' + argument, required=True)
    publish = commands.add_parser('publish')
    publish.add_argument('lock')
    for name in ('rebuild', '_replay'):
        replay = commands.add_parser(name)
        replay.add_argument('lock')
        replay.add_argument('--targets', nargs='+', choices=TARGETS)
        if name == 'rebuild':
            replay.add_argument('--output', default='out/rebuild')
    args = parser.parse_args()
    if args.command == 'check':
        check_update(args.repository, args.output, args.force)
    elif args.command == 'fetch':
        fetch_inputs(read_json(args.upstream), args.target, Path(args.work))
    elif args.command == 'build':
        build_firmware(read_json(args.upstream), args.target, Path(args.work))
    elif args.command == '_replay-target':
        from lib.build import rebuild_target
        work = Path(args.work)
        result = read_json(work / 'result.json')
        rebuild_target({'upstream': read_json(args.upstream)}, result, work / 'artifacts',
                       work / 'artifacts', ROOT)
        result['reproduced'] = True
        save_json(result, work / 'result.json')
    elif args.command == 'lock':
        create_lock(read_json(args.upstream), args.results, args.environment,
                    args.image_id, args.commit, args.repository, args.output)
    elif args.command == 'publish':
        print(publish_release(args.lock))
    elif args.command == 'rebuild':
        rebuild(args.lock, args.output, args.targets)
    elif args.command == '_replay':
        from lib.build import rebuild_target
        lock = load_lock(args.lock)
        for target in args.targets or TARGETS:
            rebuild_target(lock, lock['targets'][target], Path('/work/run/inputs'),
                           Path('/work/targets') / target / 'artifacts', ROOT)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'ERROR: {error}')
