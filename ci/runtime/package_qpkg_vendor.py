#!/usr/bin/env python3
"""Reproduce QPKG's missing vendor asset from the existing hash-verified pip bundle."""
import hashlib
from pathlib import Path
import zipfile


def build(assets):
    source = assets / 'python/pip-runtime.zip'
    expected = (assets / 'python/pip-runtime.sha256').read_text().strip()
    if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
        raise ValueError('pip integrity mismatch; refusing vendor extraction')
    target = assets / 'qpkg-vendor.zip'
    with zipfile.ZipFile(source) as src, zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED) as dst:
        for name in sorted(src.namelist()):
            if name.endswith('/'):
                continue
            if name.startswith('pip/_vendor/packaging/'):
                out = 'vendor/' + name.removeprefix('pip/_vendor/')
            elif name == 'pip/_vendor/certifi/cacert.pem':
                out = 'vendor/cacert.pem'
            elif name == 'pip/_vendor/certifi/LICENSE':
                out = 'vendor/CERTIFI-LICENSE.txt'
            else:
                continue
            info = zipfile.ZipInfo(out, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            dst.writestr(info, src.read(name))
    sha = hashlib.sha256(target.read_bytes()).hexdigest()
    (assets / 'qpkg-vendor.sha256').write_text(sha+'\n')
    print('QPKG vendor from verified pip:', target.stat().st_size, 'bytes;', sha)


if __name__ == '__main__':
    build(Path('android/app/src/main/assets/qeltravyx'))
