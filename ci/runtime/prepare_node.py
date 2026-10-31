#!/usr/bin/env python3
"""Fetch pinned source and package its complete npm tree, without npm install."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
MANIFEST = json.loads((HERE / 'sources.json').read_text())
MAX_SOURCE = 128 * 1024 * 1024
MAX_TREE = 1024 * 1024 * 1024


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fetch(destination, spec=None):
    spec = spec or MANIFEST['node']
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / spec['url'].rsplit('/', 1)[1]
    if archive.exists() and digest(archive) == spec['sha256']:
        return archive
    fd, name = tempfile.mkstemp(prefix='download-', dir=destination)
    try:
        with os.fdopen(fd, 'wb') as output, urllib.request.urlopen(spec['url'], timeout=30) as response:
            if response.url != spec['url']:
                raise ValueError('Unexpected source origin')
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_SOURCE:
                    raise ValueError('Source exceeds size limit')
                output.write(chunk)
        if digest(Path(name)) != spec['sha256']:
            raise ValueError('Source SHA-256 mismatch')
        os.replace(name, archive)
    finally:
        Path(name).unlink(missing_ok=True)
    return archive


def extract(archive, destination, root=None):
    """Private fresh staging only; reject links/special paths before any writes."""
    root = root or 'node-v' + MANIFEST['node']['version']
    target = destination / root
    if target.exists():
        raise ValueError('Source tree already exists; use a new build directory')
    with tempfile.TemporaryDirectory(prefix='source-', dir=destination) as tmp:
        staging = Path(tmp)
        with tarfile.open(archive) as tar:
            members = tar.getmembers()
            total = 0
            seen = set()
            for item in members:
                parts = item.name.rstrip('/').split('/')
                if (parts[0] != root or any(p in ('', '.', '..') for p in parts)
                        or '\\' in item.name or not (item.isdir() or item.isfile())
                        or item.name in seen):
                    raise ValueError('Unsafe source entry: ' + item.name)
                seen.add(item.name)
                total += item.size
                if total > MAX_TREE or len(seen) > 100000:
                    raise ValueError('Source extraction limit')
            tar.extractall(staging, members=members, filter='data')
        os.replace(staging / root, target)
    return target


def package_npm(source, destination):
    npm = source / 'deps/npm'
    version = json.loads((npm / 'package.json').read_text())['version']
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / 'npm-runtime.zip'
    count, total = 0, 0
    with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for file in sorted(npm.rglob('*')):
            if file.is_symlink():
                raise ValueError('Unexpected npm symlink')
            if not file.is_file():
                continue
            # Complete vendored dependency tree and licenses; deterministic ZIP metadata.
            name = file.relative_to(npm).as_posix()
            count += 1
            total += file.stat().st_size
            if count > 10000 or total > 64 * 1024 * 1024:
                raise ValueError('npm payload exceeds installer bounds')
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, file.read_bytes())
    checksum = digest(target)
    (destination / 'npm-runtime.sha256').write_text(checksum + '\n')
    (destination / 'npm-version.txt').write_text(version + '\n')
    shutil.copyfile(source / 'LICENSE', destination / 'NODE-LICENSE.txt')
    (destination / 'provenance.json').write_text(json.dumps({
        **MANIFEST, 'npm_version': version, 'npm_sha256': checksum,
        'npm_files': count, 'npm_unpacked_bytes': total,
        'android_execution': 'NOT TESTED'
    }, indent=2) + '\n')
    print(f'npm {version}: {count} files, {total} bytes, SHA-256 {checksum}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--assets', type=Path, required=True)
    args = parser.parse_args()
    source = extract(fetch(args.work), args.work)
    package_npm(source, args.assets)
    print(source)
