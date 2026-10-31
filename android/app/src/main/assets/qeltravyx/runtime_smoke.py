"""Executed only by the APK's explicit Python diagnostic action."""
import json
import pathlib
import resource
import sys
import time

started = time.monotonic()
assert pathlib.Path('relative.txt').read_text() == 'relative-ok'
assert sys.argv[1:] == ['argumento ç']
assert input() == 'entrada-ok'
assert json.loads('{"ok":true}')['ok'] is True
print('QELTRAVYX PYTHON OK', flush=True)
print('STDERR OK', file=sys.stderr, flush=True)
try:
    import sqlite3
    with sqlite3.connect(':memory:') as db:
        assert db.execute('select 42').fetchone()[0] == 42
    print('sqlite3: OK')
except ImportError:
    print('sqlite3: Não disponível')
print(json.dumps({'python': sys.version, 'executable': sys.executable,
                  'duration_ms': (time.monotonic() - started) * 1000,
                  'max_rss_kib': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}))
# Android/Bionic only: no external Termux executable or workspace program.
import os
import subprocess
print('pid:', os.getpid())
child = subprocess.run(['/system/bin/sh', '-c', 'printf subprocess-ok'],
                       capture_output=True, text=True, timeout=2)
assert child.returncode == 0 and child.stdout == 'subprocess-ok'
print('subprocess /system/bin/sh: OK')
error = subprocess.run([sys.executable, '-I', '-c', 'raise ValueError("expected-smoke-error")'],
                       capture_output=True, text=True, timeout=2)
assert error.returncode != 0 and 'expected-smoke-error' in error.stderr
print('exception/exit/stderr: OK', error.returncode)
sleeper = subprocess.Popen([sys.executable, '-I', '-c', 'import time; time.sleep(30)'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    try:
        sleeper.communicate(timeout=0.2)
        raise AssertionError('Expected timeout')
    except subprocess.TimeoutExpired:
        sleeper.terminate()
        sleeper.communicate(timeout=2)
        assert sleeper.returncode != 0
        print('timeout/cancel: OK', sleeper.returncode)
finally:
    if sleeper.poll() is None:
        sleeper.kill()
        sleeper.communicate()
print('QELTRAVYX PYTHON SMOKE COMPLETE', flush=True)
