#!/usr/bin/env python3
"""Verify CI outputs before copying into a disposable checkout. No arbitrary paths."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
from verify_elf import verify


def stage(bundle):
    sums=json.loads((bundle/'SHA256SUMS.json').read_text())
    allowed={'jniLibs/arm64-v8a/libqeltravyx_node.so','jniLibs/arm64-v8a/libqeltravyx_git.so',
             'jniLibs/arm64-v8a/libc++_shared.so'}
    for name,expected in sums.items():
        parts=name.split('/')
        if any(p in ('','..','.') for p in parts) or '\\' in name:
            raise ValueError('Unsafe bundle path')
        path=bundle/name
        if path.is_symlink() or path.resolve()!=bundle.resolve().joinpath(*parts):
            raise ValueError('Bundle symlink')
        if hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
            raise ValueError('Bundle hash mismatch: '+name)
    # Validate every candidate before making any changes.
    selected=[]
    for name in sums:
        if name in allowed or name.startswith('assets/qeltravyx/npm/'):
            src=bundle/name
            dst=Path('android/app/src/main')/name
            if dst.exists(): raise ValueError('Refusing to overwrite '+str(dst))
            if name.endswith(('libqeltravyx_node.so','libqeltravyx_git.so')): verify(src)
            selected.append((src,dst))
        elif not name.startswith('licenses/git/'):
            raise ValueError('Unexpected bundle entry: '+name)
    if not selected: raise ValueError('No payload in bundle')
    for src,dst in selected:
        dst.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(src,dst)
    # GPL corresponding source and COPYING are distributed with CI's separate Git bundle.
    if (bundle/'licenses/git/COPYING').is_file():
        dst=Path('android/app/src/main/assets/qeltravyx/licenses/GIT-COPYING.txt')
        dst.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(bundle/'licenses/git/COPYING',dst)


if __name__=='__main__':
    for arg in sys.argv[1:]: stage(Path(arg))
