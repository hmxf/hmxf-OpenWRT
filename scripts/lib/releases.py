"""Stable source discovery and atomic GitHub Release publication."""

import json
import os
import re
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

API = 'https://api.github.com'
UPSTREAM = 'immortalwrt/immortalwrt'
DOWNLOADS = 'https://downloads.immortalwrt.org'


def request(url, data=None, method=None, headers=None):
    headers = {'User-Agent': 'stable-firmware-builder', **(headers or {})}
    if url.startswith(API + '/') or url.startswith('https://uploads.github.com/'):
        token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
        if token:
            headers['Authorization'] = f'Bearer {token}'
        headers['X-GitHub-Api-Version'] = '2022-11-28'
    for attempt in range(3):
        try:
            with urlopen(Request(url, data=data, method=method, headers=headers), timeout=120) as response:
                return response.read()
        except HTTPError as error:
            if error.code not in (429, 500, 502, 503, 504) or attempt == 2:
                raise
        except URLError:
            if attempt == 2:
                raise
        time.sleep(2 ** attempt)


def api(path, data=None, method=None):
    payload = None if data is None else json.dumps(data).encode()
    raw = request(API + path, payload, method,
                  {'Accept': 'application/vnd.github+json', 'Content-Type': 'application/json'})
    return json.loads(raw) if raw else None


def stable_versions(html):
    versions = set(re.findall(r'href=[\"\'](\d+\.\d+\.\d+)/[\"\']', html))
    if not versions:
        raise ValueError('upstream directory contains no stable release')
    return sorted(versions, key=lambda version: tuple(map(int, version.split('.'))))


def source_commit(version):
    obj = api(f'/repos/{UPSTREAM}/git/ref/tags/v{version}')['object']
    for _ in range(5):
        if obj['type'] == 'commit' and re.fullmatch(r'[0-9a-f]{40}', obj['sha']):
            return obj['sha']
        if obj['type'] != 'tag':
            break
        obj = api(f'/repos/{UPSTREAM}/git/tags/{obj["sha"]}')['object']
    raise ValueError(f'upstream stable tag v{version} does not resolve to a commit')


def source_marker(upstream):
    return f'<!-- source:{upstream["version"]}@{upstream["source_commit"]} -->'


def already_published(upstream, release_list):
    return any(not item.get('draft') and not item.get('prerelease')
               and source_marker(upstream) in (item.get('body') or '')
               and any(asset['name'] == 'LOCK.json' for asset in item.get('assets', []))
               for item in release_list)


def list_releases(repository):
    items = []
    for page in range(1, 101):
        batch = api(f'/repos/{repository}/releases?per_page=100&page={page}')
        items.extend(batch)
        if len(batch) < 100:
            return items
    raise ValueError('too many releases to check safely')


def latest_stable():
    version = stable_versions(request(DOWNLOADS + '/releases/').decode())[-1]
    return {'version': version, 'source_tag': f'v{version}',
            'source_commit': source_commit(version),
            'download_url': f'{DOWNLOADS}/releases/{version}'}


def publish(repository, lock, directory):
    """Keep incomplete uploads as drafts; expose a complete Release in one operation."""
    from .inputs import file_record

    directory = Path(directory)
    files = sorted(path for path in directory.iterdir() if path.is_file())
    expected = {path.name: file_record(path) for path in files}
    tag = lock['release']['tag']
    old = next((item for item in list_releases(repository) if item['tag_name'] == tag), None)
    if old and not old['draft']:
        raise ValueError(f'Release {tag} is already published; refusing to replace it')
    removed = [f'- {target}/{preset}: {", ".join(result["removed_packages"])}'
               for target, target_result in lock['targets'].items()
               for preset, result in target_result['presets'].items() if result['removed_packages']]
    body = (f'{source_marker(lock["upstream"])}\n\n'
            'Six firmware builds passed image, package and offline reproducibility checks. '
            'Use LOCK.json with rebuild.sh to reproduce these images.\n\n'
            + ('Packages absent upstream:\n' + '\n'.join(removed) if removed else ''))
    release = old or api(f'/repos/{repository}/releases', {
        'tag_name': tag, 'target_commitish': lock['recipe']['commit'],
        'name': f'ImmortalWrt {lock["upstream"]["version"]}',
        'body': body, 'draft': True, 'prerelease': False,
    }, 'POST')
    for asset in release.get('assets', []):
        api(f'/repos/{repository}/releases/assets/{asset["id"]}', method='DELETE')
    upload_url = release['upload_url'].split('{')[0]
    for path in files:
        # The compressed environment/inputs are small enough for the Release asset limit.
        uploaded = json.loads(request(upload_url + '?name=' + quote(path.name),
                                     path.read_bytes(), 'POST',
                                     {'Content-Type': 'application/octet-stream'}))
        record = expected[path.name]
        if uploaded['size'] != record['bytes'] or uploaded.get('digest') != 'sha256:' + record['sha256']:
            raise ValueError(f'GitHub asset digest mismatch: {path.name}')
    actual = api(f'/repos/{repository}/releases/{release["id"]}')
    if {a['name'] for a in actual['assets']} != set(expected):
        raise ValueError('Release upload inventory mismatch')
    return api(f'/repos/{repository}/releases/{release["id"]}',
               {'draft': False, 'body': body, 'make_latest': 'true'}, 'PATCH')['html_url']
