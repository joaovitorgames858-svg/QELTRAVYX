import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ASSET = Path(__file__).resolve().parents[2]/'android/app/src/main/assets/qeltravyx/core_v2.py'
spec = importlib.util.spec_from_file_location('core_runtime', ASSET)
core = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = core
spec.loader.exec_module(core)


class CoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)/'project'; self.root.mkdir()
        self.grants = dict(read=True, write=True, tests=True, web=False)
        self.store = core.Store(self.root, Path(self.tmp.name)/'metadata', self.grants)

    def run_task(self, request, approved=False):
        return core.Engine(self.store).execute(request, approved=approved)

    def test_python_create_test_diagnose_correct_backup(self):
        self.assertEqual(self.run_task('criar projeto python')['phase'], 'awaiting_tests')
        self.assertEqual(self.run_task('testar projeto python')['phase'], 'approval')
        (self.root/'calculator.py').write_text(core.PYTHON_BUG)
        result = self.run_task('testar projeto python', True)
        self.assertEqual(result['phase'], 'completed', result)
        self.assertIn('Correções: 1', result['output'])
        self.assertEqual((self.root/'calculator.py').read_text(), core.PYTHON_SOURCE)
        self.assertTrue(list(self.store.meta.glob('backup_*')))

    @unittest.skipUnless(shutil.which('node'), 'No host Node for fixture test; not Android evidence')
    def test_javascript_create_test_correct_and_save_evidence(self):
        self.assertEqual(self.run_task('criar projeto javascript')['phase'], 'awaiting_tests')
        self.assertEqual(self.run_task('testar projeto javascript')['phase'], 'approval')
        (self.root/'calculator.js').write_text(core.JAVASCRIPT_BUG)
        with mock.patch.object(core.Engine, 'node_binary', return_value=shutil.which('node')):
            result = self.run_task('testar projeto javascript', True)
        self.assertEqual(result['phase'], 'completed', result)
        self.assertIn('Correções: 1', result['output'])
        report = self.store.load('verification.json')
        self.assertEqual(report['exitCode'], 0)
        self.assertEqual(report['files']['calculator.js'], core.digest(core.JAVASCRIPT_SOURCE))

    def test_missing_runtime_untrusted_code_permissions_and_cancel(self):
        self.run_task('criar projeto javascript')
        with mock.patch.dict(core.os.environ, {}, clear=True):
            result = self.run_task('testar projeto javascript', True)
        self.assertEqual(result['phase'], 'failed')
        self.assertIn('nenhum fallback', result['output'])
        (self.root/'calculator.js').write_text('require("fs").writeFileSync("bad", "bad")')
        with mock.patch.object(core.Engine, 'node_binary', return_value='/never-run'), mock.patch.object(core.subprocess, 'Popen') as process:
            self.assertEqual(self.run_task('testar projeto javascript', True)['phase'], 'failed')
            process.assert_not_called()
        self.grants['write'] = False
        self.assertEqual(self.run_task('criar projeto python')['phase'], 'failed')
        self.assertFalse((self.root/'calculator.py').exists())
        result = core.Engine(self.store, cancel=lambda: True).execute('criar projeto python')
        self.assertEqual(result['phase'], 'cancelled')


if __name__ == '__main__': unittest.main()
