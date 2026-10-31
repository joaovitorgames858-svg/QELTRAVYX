import importlib.util
import io
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'ci/runtime'/f'{name}.py')
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result

prepare = module('prepare_node')
elf = module('verify_elf')


class NativeTests(unittest.TestCase):
    def test_source_paths_and_symlinks_rejected(self):
        for name, link in [('node-v22.23.4/../escape', False), ('node-v22.23.4/link', True)]:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); archive = root/'bad.tar'
                with tarfile.open(archive, 'w') as tar:
                    item = tarfile.TarInfo(name)
                    if link: item.type = tarfile.SYMTYPE; item.linkname = '/tmp'
                    tar.addfile(item)
                with self.assertRaises(ValueError): prepare.extract(archive, root)
                self.assertFalse((root/'node-v22.23.4').exists())

    def test_elf_rejects_host_and_missing_interpreter(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'fake'
            path.write_bytes(b'not elf')
            with self.assertRaises(ValueError): elf.verify(path)
            header = bytearray(256); header[:7] = b'\x7fELF\x02\x01\x01'
            struct.pack_into('<HH', header, 16, 3, 183)
            struct.pack_into('<Q', header, 24, 0x1000)
            path.write_bytes(header)
            with self.assertRaises(ValueError): elf.verify(path)

    @unittest.skipUnless(shutil.which('node'), 'Host Node unavailable')
    def test_node_smoke_real_host_io(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(['node', str(ROOT/'android/app/src/main/assets/qeltravyx/node_smoke.js'), 'argumento ç'],
                                    input='entrada-ok\n', text=True, cwd=tmp, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('QELTRAVYX NODE OK', result.stdout)
            self.assertFalse((Path(tmp)/'node-renamed.txt').exists())

    def test_reproducible_complete_npm_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); source=root/'source'; npm=source/'deps/npm'; npm.mkdir(parents=True)
            (source/'LICENSE').write_text('license')
            (npm/'package.json').write_text('{"version":"1.2.3"}')
            nested=npm/'node_modules/example'; nested.mkdir(parents=True)
            (nested/'index.js').write_text('module.exports=42;')
            prepare.package_npm(source,root/'one'); prepare.package_npm(source,root/'two')
            self.assertEqual((root/'one/npm-runtime.zip').read_bytes(),(root/'two/npm-runtime.zip').read_bytes())


if __name__ == '__main__': unittest.main()
