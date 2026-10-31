#!/usr/bin/env python3
"""Optional JVM validation with existing Gradle cache, without downloading a toolchain."""
import argparse
from pathlib import Path
import subprocess

parser=argparse.ArgumentParser()
parser.add_argument('--cache',type=Path,required=True,help='Gradle modules-2/files-2.1')
parser.add_argument('--output',type=Path,default=Path('.build/kotlin-runtime'))
args=parser.parse_args()
def jar(group,name,version):
    matches=list((args.cache/group/name/version).glob('*/*.jar'))
    if len(matches)!=1: raise SystemExit('Missing pinned compiler dependency: '+name+' '+version)
    return str(matches[0])
compiler=[jar('org.jetbrains.kotlin','kotlin-compiler-embeddable','2.2.20'),
          jar('org.jetbrains.kotlin','kotlin-stdlib','2.2.20'),
          jar('org.jetbrains.kotlin','kotlin-reflect','2.2.21'),
          jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.8.0'),
          jar('org.jetbrains','annotations','13.0')]
args.output.mkdir(parents=True,exist_ok=True)
source=Path('android/app/src/main/kotlin/dev/qeltravyx/qeltravyx')
files=[source/'RuntimeNpm.kt',source/'RuntimeQpkg.kt',*Path('ci/tests/kotlin').glob('*.kt')]
subprocess.run(['java','-cp',':'.join(compiler),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
    '-no-stdlib','-no-reflect','-classpath',':'.join(compiler[1:]),'-d',str(args.output),*[str(p) for p in files]],check=True)
subprocess.run(['java','-cp',str(args.output)+':'+compiler[1], 'dev.qeltravyx.qeltravyx.RuntimeInstallerTestKt'],check=True)
