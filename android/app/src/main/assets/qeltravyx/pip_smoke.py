"""Offline pip acceptance inside the APK. Two child processes, real wheel/install/import."""
import base64
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import sysconfig
import tempfile
import uuid
import zipfile

root = Path(os.environ['QELTRAVYX_PYHOME']).parent
packages = root / 'workspace/packages'
name = 'qeltravyx_smoke_' + uuid.uuid4().hex
info = name + '-1.0.0.dist-info'
created = [packages / name, packages / info]
assert all(not p.exists() for p in created)
print(json.dumps({'executable': sys.executable, 'pid': os.getpid(), 'sys_path': sys.path,
                  'sysconfig_platform': sysconfig.get_platform(),
                  'site': __import__('site').getsitepackages()}, ensure_ascii=False), flush=True)
import ssl
print('ssl:', ssl.OPENSSL_VERSION, 'CA:', ssl.get_default_verify_paths(), flush=True)
print('TLS/downloads: não validados; instalação exclusivamente offline.', flush=True)


def run(args, cwd):
    print('python ' + repr(args), flush=True)
    child = subprocess.run([sys.executable, '-I', '-B', *args], cwd=cwd,
                           capture_output=True, text=True, timeout=20)
    print(child.stdout, end='', flush=True)
    print(child.stderr, end='', file=sys.stderr, flush=True)
    print('exitCode:', child.returncode, flush=True)
    assert child.returncode == 0


with tempfile.TemporaryDirectory(prefix='pip smoke ') as folder:
    folder = Path(folder)
    wheel = folder / (name + '-1.0.0-py3-none-any.whl')
    files = {name + '/__init__.py': b'VALUE = "offline-import-ok"\n',
             info + '/WHEEL': b'Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n',
             info + '/METADATA': ('Metadata-Version: 2.1\nName: ' + name + '\nVersion: 1.0.0\n').encode()}
    record = io.StringIO()
    writer = csv.writer(record)
    for path, data in files.items():
        writer.writerow([path, 'sha256=' + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode(), len(data)])
    writer.writerow([info + '/RECORD', '', ''])
    files[info + '/RECORD'] = record.getvalue().encode()
    with zipfile.ZipFile(wheel, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path, data in files.items():
            archive.writestr(path, data)
    try:
        run(['-m', 'pip', '--version'], folder)
        run(['-m', 'pip', 'install', str(wheel)], folder)
        # New process and a different working directory; never insert target into sys.path here.
        run(['-c', 'import importlib,os; m=importlib.import_module(' + repr(name) + '); '
             'assert m.VALUE == "offline-import-ok"; print("IMPORT OUTRO PROCESSO:", os.getpid(), m.__file__)'], root)
        run(['-m', 'pip', 'list'], root)
        print('QELTRAVYX PIP OFFLINE SMOKE COMPLETE', flush=True)
    finally:
        # Only our unpredictable UUID fixture, never an existing user package.
        for path in created:
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
