"""Host regressions: preserve packaged baseline; never claim Android execution."""
import hashlib
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / 'android/app/src/main/assets/qeltravyx'


class BaselineTests(unittest.TestCase):
    def test_pip_integrity_and_alias_patch_in_disposable_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            target = base / 'android/app/src/main/assets/qeltravyx/python'
            target.mkdir(parents=True)
            for name in ('pip-runtime.zip', 'pip-runtime.sha256'):
                (target / name).write_bytes((ASSETS / 'python' / name).read_bytes())
            expected = (target / 'pip-runtime.sha256').read_text().strip()
            self.assertEqual(hashlib.sha256((target / 'pip-runtime.zip').read_bytes()).hexdigest(), expected)
            subprocess.run(['python3', str(ROOT / 'ci/patch_pip_android_alias.py')], cwd=base, check=True)
            with zipfile.ZipFile(target / 'pip-runtime.zip') as archive:
                policy = archive.read('pip/_qeltravyx.py').decode()
                self.assertIn('/data/user/0/dev.qeltravyx.qeltravyx/files', policy)
                self.assertIn('/data/data/dev.qeltravyx.qeltravyx/files', policy)
                compile(policy, 'pip/_qeltravyx.py', 'exec')

    def test_missing_native_runtimes_do_not_use_host_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ('node', 'git', 'npm'):
                result = subprocess.run(['bash', '-c', 'source "$1"; "$2" --version',
                                         'test', str(ASSETS / 'runtime-extension.sh'), name],
                                        env={'HOME': tmp, 'PATH': '/usr/bin:/bin'}, capture_output=True)
                self.assertEqual(result.returncode, 127, result.stdout + result.stderr)

    def test_python_stdlib_is_valid_zip(self):
        with zipfile.ZipFile(ASSETS / 'python/stdlib.zip') as archive:
            self.assertIsNone(archive.testzip())
            self.assertIn('python3.14/encodings/__init__.py', archive.namelist())


if __name__ == '__main__':
    unittest.main()
