import hashlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
import zipfile

ASSETS = Path(__file__).resolve().parents[2] / 'android/app/src/main/assets/qeltravyx'
# Read the existing vendored packaging from the pinned pip payload, never install host deps.
VENDOR = tempfile.TemporaryDirectory()
with zipfile.ZipFile(ASSETS / 'python/pip-runtime.zip') as archive:
    for name in archive.namelist():
        if name.startswith('pip/_vendor/packaging/') and not name.endswith('/'):
            target = Path(VENDOR.name) / name.removeprefix('pip/_vendor/')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(name))
sys.path.insert(0, VENDOR.name)
spec = importlib.util.spec_from_file_location('qpkg', ASSETS / 'qpkg.py')
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)


def wheel(version='1.0', extra=None):
    files = {'demo/__init__.py': b'VALUE=42\n',
             f'demo-{version}.dist-info/METADATA': f'Name: demo\nVersion: {version}\n'.encode(),
             f'demo-{version}.dist-info/WHEEL': b'Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n'}
    files.update(extra or {})
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as archive:
        for name, data in files.items():
            archive.writestr(name, data)
    raw = output.getvalue()
    return raw, hashlib.sha256(raw).hexdigest()


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        q.HOME = Path(self.tmp.name).resolve()
        q.PKGS = q.HOME / 'workspace/packages'
        q.STATE = q.HOME / 'workspace/.qpkg'
        q.INDEX = q.STATE / 'installed.json'

    def local(self, version='1.0'):
        raw, sha = wheel(version)
        path = q.HOME / f'demo-{version}-py3-none-any.whl'
        path.write_bytes(raw)
        return str(path), sha

    def test_install_import_reinstall_verify_upgrade_preserves(self):
        args = self.local()
        q.install_local(*args)
        scope = {}
        exec((q.PKGS / 'demo/__init__.py').read_text(), scope)
        self.assertEqual(scope['VALUE'], 42)
        q.install_local(*args)
        q.verify_installed()
        before = q.INDEX.read_bytes()
        with self.assertRaises(q.QpkgError): q.install_local(*self.local('2.0'))
        self.assertEqual(q.INDEX.read_bytes(), before)
        (q.PKGS / 'demo/__init__.py').write_text('user data')
        with self.assertRaises(q.QpkgError): q.install_local(*args)
        with self.assertRaises(q.QpkgError): q.verify_installed()
        self.assertEqual((q.PKGS / 'demo/__init__.py').read_text(), 'user data')

    def test_bad_hash_slip_duplicate_and_limits(self):
        raw, sha = wheel()
        with self.assertRaises(q.QpkgError): q.unpack(raw, 'demo-1.0-py3-none-any.whl', '0'*64)
        for name in ('../escape.py', '/escape.py', 'demo//x.py', 'demo/./x.py', 'demo/x.so'):
            bad, digest = wheel(extra={name: b'bad'})
            with self.assertRaises(q.QpkgError): q.unpack(bad, 'demo-1.0-py3-none-any.whl', digest)
        with mock.patch.object(q, 'MAX_UNPACK', 2):
            with self.assertRaises(q.QpkgError): q.unpack(raw, 'demo-1.0-py3-none-any.whl', sha)
        with self.assertRaises(q.QpkgError): q.unpack(raw, 'demo-1.0-cp312-cp312-linux_aarch64.whl', sha)

    def test_internal_links_and_registry_paths_rejected(self):
        q.init_dirs()
        outside = q.HOME / 'outside'; outside.mkdir()
        (q.PKGS / 'demo').symlink_to(outside)
        with self.assertRaises(q.QpkgError): q.install_local(*self.local())
        for name in ('', '../bad', '/bad', 'a//b', 'a/./b'):
            with self.assertRaises(q.QpkgError): q.checked_target(name)
        self.assertEqual(list(outside.iterdir()), [])
        q.PKGS.rmdir() if not list(q.PKGS.iterdir()) else None

    def test_root_link_and_legitimate_home_alias(self):
        alias = q.HOME / 'alias'; real = q.HOME / 'real'; real.mkdir(); alias.symlink_to(real)
        # Android root aliases are normalized once, before internal path checks.
        q.HOME = alias.resolve(); q.PKGS = q.HOME/'workspace/packages'; q.STATE=q.HOME/'workspace/.qpkg'; q.INDEX=q.STATE/'installed.json'
        q.init_dirs()
        q.PKGS.rmdir(); q.PKGS.symlink_to(q.HOME)
        with self.assertRaises(q.QpkgError): q.init_dirs()

    def test_rollback_registry_failure_and_interruption(self):
        args = self.local()
        for error in (OSError('disk full'), KeyboardInterrupt()):
            with mock.patch.object(q, 'save', side_effect=error):
                with self.assertRaises(type(error)): q.install_local(*args)
            self.assertFalse((q.PKGS/'demo/__init__.py').exists())
            self.assertFalse(q.INDEX.exists())
            self.assertFalse((q.STATE/'pending.json').exists())
        (q.STATE/'pending.json').write_text('{}')
        with self.assertRaises(q.QpkgError): q.install_local(*args)

    def test_remove_failure_restores_and_success_removes_only_owned_files(self):
        q.install_local(*self.local())
        original = q.INDEX.read_bytes()
        (q.PKGS/'user.txt').write_text('preserve')
        with mock.patch.object(q, 'save', side_effect=OSError('disk full')):
            with self.assertRaises(OSError): q.main(['remove', 'demo'])
        self.assertEqual(q.INDEX.read_bytes(), original)
        q.verify_installed()
        q.main(['remove', 'demo'])
        self.assertEqual(q.registry(), {})
        self.assertEqual((q.PKGS/'user.txt').read_text(), 'preserve')

    def test_concurrent_mutation_is_blocked(self):
        q.init_dirs()
        with q.transaction_lock():
            with self.assertRaises(BlockingIOError):
                with q.transaction_lock(): pass

    def test_network_requires_consent_redirect_checked_before_connection(self):
        with mock.patch.object(q, 'https_get') as get:
            with self.assertRaises(q.QpkgError): q.main(['install', 'demo'])
            get.assert_not_called()
        for url in ('http://pypi.org/x', 'https://evil.test/x', 'https://u:p@pypi.org/x', 'https://pypi.org:444/x'):
            with self.assertRaises(q.QpkgError):
                q.SafeRedirect().redirect_request(None, None, 302, '', {}, url)


if __name__ == '__main__': unittest.main()
