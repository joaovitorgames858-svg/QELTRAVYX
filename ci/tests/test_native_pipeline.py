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

    @unittest.skipUnless((ROOT/'.build/runtime-sources/node-v22.23.4/deps/npm/bin/npm-cli.js').is_file() and shutil.which('node'),
                         'Pinned npm source not prepared; run prepare_node.py first')
    def test_pinned_npm_installs_fixture_offline_without_lifecycle(self):
        assets=ROOT/'android/app/src/main/assets/qeltravyx'
        cli=ROOT/'.build/runtime-sources/node-v22.23.4/deps/npm/bin/npm-cli.js'
        with tempfile.TemporaryDirectory() as tmp:
            shutil.copy2(assets/'qel-js-demo-1.0.0.tgz', Path(tmp)/'qel-js-demo-1.0.0.tgz')
            result=subprocess.run(['node',str(assets/'npm_smoke.js'),str(cli)],cwd=tmp,capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('QELTRAVYX NPM OK',result.stdout)
            # Exercise the actual Bash entry point with an explicitly supplied host fixture.
            home=Path(tmp)/'home'; runtimes=home/'.qeltravyx/runtimes'; runtimes.mkdir(parents=True)
            (runtimes/'npm').symlink_to(cli.parent.parent)
            native=Path(tmp)/'native'; native.mkdir()
            (native/'libqeltravyx_node.so').symlink_to(shutil.which('node'))
            project=home/'workspace/demo'; project.mkdir(parents=True)
            shutil.copy2(assets/'qel-js-demo-1.0.0.tgz',project/'demo.tgz')
            env={'HOME':str(home),'PATH':'/usr/bin:/bin','QELTRAVYX_TOOLBOX':str(native/'toolbox')}
            result=subprocess.run(['bash','-c','source "$1"; npm install ./demo.tgz',
                'smoke',str(assets/'runtime-extension.sh')],cwd=project,env=env,capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertTrue((project/'node_modules/qel-js-demo/index.js').is_file())
            for command in ['npm install remote-package', 'npm run postinstall', 'npm exec echo']:
                blocked=subprocess.run(['bash','-c','source "$1"; '+command,'smoke',str(assets/'runtime-extension.sh')],
                                       cwd=project,env=env,capture_output=True,text=True,timeout=5)
                self.assertEqual(blocked.returncode,64,blocked.stdout+blocked.stderr)

    def test_reproducible_complete_npm_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); source=root/'source'; npm=source/'deps/npm'; npm.mkdir(parents=True)
            (source/'LICENSE').write_text('license')
            (npm/'package.json').write_text('{"version":"10.9.9"}')
            nested=npm/'node_modules/example'; nested.mkdir(parents=True)
            (nested/'index.js').write_text('module.exports=42;')
            prepare.package_npm(source,root/'one'); prepare.package_npm(source,root/'two')
            self.assertEqual((root/'one/npm-runtime.zip').read_bytes(),(root/'two/npm-runtime.zip').read_bytes())


if __name__ == '__main__': unittest.main()
