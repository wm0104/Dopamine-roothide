#!/usr/bin/env python3
"""Validate both frozen Latest assets before updating the two bundled DEBs."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

BRANCH = 'custom-package-managers'
SOURCES = (
    ('wm0104/irisin', 'wiki.qaq.irisin', 'Application/Dopamine/Resources/irisin.deb'),
    ('wm0104/Sileo-roothide', 'org.coolstar.sileo', 'Application/Dopamine/Resources/sileo.deb'),
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(*args, destination=None):
    try:
        result = subprocess.run(args, stdout=destination or subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=300, check=True)
    except (subprocess.SubprocessError, OSError):
        # Do not relay tool diagnostics which might contain credentials.
        raise RuntimeError(f'{args[0]} operation failed or timed out') from None
    return '' if destination else result.stdout.decode().strip()


def git(*args):
    return command('git', *args)


def api(endpoint):
    return json.loads(command('gh', 'api', '--method', 'GET', endpoint))


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def remote_sha():
    refs = git('ls-remote', '--exit-code', 'origin', f'refs/heads/{BRANCH}').splitlines()
    require(len(refs) == 1, 'target remote ref is not unique')
    return refs[0].split()[0]


def freeze(source, package, target):
    require(api(f'repos/{source}').get('private') is False, 'source repository is not public')
    release = api(f'repos/{source}/releases/latest')
    require(release.get('draft') is False and release.get('prerelease') is False,
            'Latest release is draft or prerelease')
    require(type(release.get('id')) is int and release['id'] > 0
            and isinstance(release.get('tag_name'), str) and release['tag_name'], 'invalid release identity')
    pattern = re.compile(re.escape(package) + r'_([0-9][A-Za-z0-9.+:~\-]*)_iphoneos-arm64e\.deb')
    candidates = [a for a in release.get('assets', []) if pattern.fullmatch(a.get('name', ''))]
    require(len(candidates) == 1, 'expected exactly one matching DEB asset')
    asset = candidates[0]
    require(type(asset.get('id')) is int and asset['id'] > 0, 'invalid asset ID')
    require(asset.get('state') == 'uploaded', 'asset upload is not complete')
    require(type(asset.get('size')) is int and asset['size'] > 0, 'invalid asset size')
    require(re.fullmatch(r'sha256:[0-9a-fA-F]{64}', asset.get('digest') or ''), 'missing valid SHA-256 digest')
    return dict(source=source, package=package, target=target, release_id=release['id'],
                tag=release['tag_name'], asset_id=asset['id'], name=asset['name'],
                size=asset['size'], digest=asset['digest'][7:].lower(),
                version=pattern.fullmatch(asset['name']).group(1))


def validate(item, path):
    require(path.stat().st_size == item['size'], 'download size mismatch')
    require(sha256(path) == item['digest'], 'download SHA-256 mismatch')
    fields = {name: command('dpkg-deb', '--field', str(path), name)
              for name in ('Package', 'Architecture', 'Version')}
    require(fields['Package'] == item['package'], 'unexpected Package')
    require(fields['Architecture'] == 'iphoneos-arm64e', 'unexpected Architecture')
    require(fields['Version'] and fields['Version'] == item['version'], 'Version does not match asset filename')
    # Fully parse the data archive without installing or executing maintainer scripts.
    command('dpkg-deb', '--contents', str(path))


def summary(base, updated, frozen, status):
    path = os.environ.get('GITHUB_STEP_SUMMARY')
    if path:
        with open(path, 'a') as stream:
            stream.write(f'## Package sync: {status}\n\nBase SHA: `{base}`\n\nUpdated SHA: `{updated or "not pushed"}`\n\n')
            for item in frozen:
                # JSON escaping prevents untrusted release text creating extra log lines.
                stream.write(f'- `{json.dumps(item, ensure_ascii=True)}`\n')


def sync():
    base, updated, frozen = '', '', []
    try:
        require(not git('status', '--porcelain', '--untracked-files=all'), 'working tree must be clean')
        base = git('rev-parse', 'HEAD')
        require(base == remote_sha(), 'remote advanced since checkout')
        for source, package, target in SOURCES:
            frozen.append(freeze(source, package, target))
        with tempfile.TemporaryDirectory(prefix='package-sync-') as directory:
            downloads = []
            for index, item in enumerate(frozen):
                download = Path(directory) / f'{index}.deb'
                with download.open('wb') as output:
                    command('gh', 'api', '--method', 'GET',
                            f'repos/{item["source"]}/releases/assets/{item["asset_id"]}',
                            '-H', 'Accept: application/octet-stream', '--allow-escape-sequences', destination=output)
                validate(item, download)
                downloads.append((item, download))
            changed = []
            for item, download in downloads:
                target = Path(item['target'])
                require(target.is_file() and not target.is_symlink(), 'target must be a regular bundled file')
                if sha256(target) != item['digest']:
                    changed.append((download, target))
            require(base == remote_sha(), 'remote advanced during validation')
            require(git('rev-parse', 'HEAD') == base and not git('status', '--porcelain', '--untracked-files=all'),
                    'local repository changed during validation')
            if not changed:
                updated = base
                summary(base, updated, frozen, 'no change')
                write_outputs(False, base)
                emit_markers(base, updated, False, frozen)
                return
            for download, target in changed:
                shutil.copyfile(download, target)
            # A single explicit add; unchanged paths do not enter the index diff.
            git('add', '--', *(item['target'] for item in frozen))
            staged = git('diff', '--cached', '--name-only', '-z').split('\0')
            require(set(filter(None, staged)) == {str(target) for _, target in changed}, 'unexpected staged paths')
            require(git('rev-parse', 'HEAD') == base, 'HEAD moved before commit')
            git('-c', 'user.name=Codex', '-c', 'user.email=codex@openai.com',
                'commit', '-m', '更新内置包管理器')
            candidate = git('rev-parse', 'HEAD')
            require(git('rev-list', '--parents', '-n', '1', candidate).split() == [candidate, base],
                    'commit does not have the initial base as its sole parent')
            require(remote_sha() == base, 'remote advanced before push')
            git('push', 'origin', f'{candidate}:refs/heads/{BRANCH}')
            updated = candidate
            summary(base, updated, frozen, 'updated')
            write_outputs(True, updated)
            emit_markers(base, updated, True, frozen)
    except Exception:
        summary(base, updated, frozen, 'failed')
        raise


def emit_markers(base, updated, changed, frozen):
    print(f'PACKAGE_SYNC_BASE_SHA={base}', flush=True)
    print(f'PACKAGE_SYNC_SHA={updated}', flush=True)
    print(f'PACKAGE_SYNC_CHANGED={str(changed).lower()}', flush=True)
    for item in frozen:
        metadata = {key: item[key] for key in ('release_id', 'tag', 'asset_id', 'name', 'size', 'package', 'version')}
        metadata.update(repo=item['source'], sha256=item['digest'], architecture='iphoneos-arm64e')
        print('PACKAGE_SYNC_ASSET=' + json.dumps(metadata, ensure_ascii=True), flush=True)


def write_outputs(changed, sha):
    path = os.environ.get('GITHUB_OUTPUT')
    if path:
        with open(path, 'a') as stream:
            stream.write(f'changed={str(changed).lower()}\nbuild_sha={sha}\n')


if __name__ == '__main__':
    try:
        sync()
    except Exception as error:
        # Only our own bounded diagnostics; never echo gh responses or environment.
        message = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(f'PACKAGE_SYNC_FAILED {message}', file=sys.stderr)
        sys.exit(1)
