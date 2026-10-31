#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || {
  echo 'BLOCKED: Git candidate requires Linux x86_64 + Android NDK, never Termux.' >&2
  exit 2
}
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to NDK 28.2.13676358}"
grep -q '28.2.13676358' "$ANDROID_NDK_HOME/source.properties"
q_work="${1:-.build/git-android}"
q_output="${2:-.build/git-bundle}"
mkdir -p "$q_work" "$q_output/jniLibs/arm64-v8a" "$q_output/licenses/git"
q_work=$(realpath "$q_work")
q_output=$(realpath "$q_output")
python3 - "$q_work" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0,'ci/runtime')
from prepare_node import MANIFEST, fetch, extract
spec=MANIFEST['git']
root='git-'+spec['version']
# Exact source-only documentation/GUI aliases; never materialize archive symlinks.
omitted={root+'/RelNotes': 'Documentation/RelNotes/2.56.0.adoc',
         root+'/subprojects/git-gui': '../git-gui', root+'/subprojects/gitk': '../gitk-git'}
extract(fetch(Path(sys.argv[1]),spec),Path(sys.argv[1]),root,omitted_links=omitted)
PY
q_version=$(python3 -c 'import json; print(json.load(open("ci/runtime/sources.json"))["git"]["version"])')
# The Git Makefile reuses SHELL_PATH for both the *Android runtime* and
# build-time recipes. Keep /system/bin/sh compiled into Git, but make GNU make
# and its source generators execute the Linux runner's /bin/sh.
# Only modify the hash-verified, disposable source in .build/.
python3 - "$q_work/git-$q_version/Makefile" <<'PY_HOST_SHELL'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
make_shell = "SHELL = $(SHELL_PATH)"
generator_shell = "$(QUIET_GEN)$(SHELL_PATH)"
if s.count(make_shell) != 1 or s.count(generator_shell) < 3:
    raise SystemExit("Git Makefile mudou: abortando em vez de aplicar patch incerto")
s = s.replace(make_shell, "SHELL = /bin/sh", 1)
s = s.replace(generator_shell, "$(QUIET_GEN)/bin/sh")
p.write_text(s)
shared = p.with_name("shared.mak")
body = shared.read_text()
# Git 2.56: version_gen is defined in shared.mak, not in Makefile.
# GIT-VERSION-FILE is -included by Makefile; if the generator silently
# fails because /system/bin/sh does not exist on Linux, make reports
# misleadingly that version-def.h has no rule for GIT-VERSION-FILE.
host_generator = '$(SHELL_PATH) "$(1)/GIT-VERSION-GEN"'
if body.count(host_generator) != 1:
    raise SystemExit("Git shared.mak mudou: abortando patch")
shared.write_text(body.replace(host_generator, '/bin/sh "$(1)/GIT-VERSION-GEN"', 1))
print("Host Linux: make, geradores e GIT-VERSION-GEN usam /bin/sh; Android SHELL_PATH preservado")
PY_HOST_SHELL
# Android Bionic does not provide POSIX pthread cancellation. Keep the
# pthread signal masking, locking and async-thread behavior; skip only the
# two unsupported cancellation-state calls in Git's atfork handling.
# Apply only to the pinned, disposable upstream source tree.
python3 - "$q_work/git-$q_version/run-command.c" <<'PY_ANDROID_PTHREAD'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
patches = [
    ('CHECK_BUG(pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &as->cs),\n\t\t"disabling cancellation");',
     '#ifndef __ANDROID__\n\tCHECK_BUG(pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &as->cs),\n\t\t"disabling cancellation");\n#endif'),
    ('CHECK_BUG(pthread_setcancelstate(as->cs, NULL),\n\t\t"re-enabling cancellation");',
     '#ifndef __ANDROID__\n\tCHECK_BUG(pthread_setcancelstate(as->cs, NULL),\n\t\t"re-enabling cancellation");\n#endif'),
]
for old, new in patches:
    if s.count(old) != 1:
        raise SystemExit("Git run-command.c mudou: abortando patch pthread Android")
    s = s.replace(old, new, 1)
p.write_text(s)
print("Android Bionic: cancelamento pthread indisponível protegido; máscaras de sinal mantidas")
PY_ANDROID_PTHREAD
q_toolchain="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
# Build only the C executable and its in-process builtins. No curl, Perl, Python,
# shell helpers or external TLS libraries; remote operations deliberately unavailable.
make -C "$q_work/git-$q_version" -j2 git \
  CC="$q_toolchain/bin/aarch64-linux-android24-clang" \
  AR="$q_toolchain/bin/llvm-ar" \
  CFLAGS='-O2 -fPIE' \
  LDFLAGS='-pie -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384' \
  NO_CURL=YesPlease NO_EXPAT=YesPlease NO_OPENSSL=YesPlease \
  NO_GETTEXT=YesPlease NO_ICONV=YesPlease NO_PERL=YesPlease NO_PYTHON=YesPlease \
  NO_TCLTK=YesPlease NO_INSTALL_HARDLINKS=YesPlease \
  CSPRNG_METHOD= HAVE_SYNC_FILE_RANGE= FSMONITOR_DAEMON_BACKEND= FSMONITOR_OS_SETTINGS= \
  ac_cv_fread_reads_directories=YesPlease ac_cv_snprintf_returns_bogus=No \
  prefix=/nonexistent/qeltravyx-git SHELL=/bin/sh SHELL_PATH=/system/bin/sh
cp "$q_work/git-$q_version/git" "$q_output/jniLibs/arm64-v8a/libqeltravyx_git.so"
cp "$q_work/git-$q_version/COPYING" "$q_output/licenses/git/"
# Distribute corresponding exact source alongside the GPL executable candidate.
cp "$q_work/git-$q_version.tar.xz" "$q_output/licenses/git/"
cp ci/runtime/sources.json ci/runtime/build_git.sh ci/runtime/prepare_node.py ci/runtime/verify_elf.py "$q_output/licenses/git/"
python3 ci/runtime/verify_elf.py "$q_output/jniLibs/arm64-v8a/libqeltravyx_git.so"
python3 - "$q_output" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1])
(root/'SHA256SUMS.json').write_text(json.dumps({p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob('*')) if p.is_file()},indent=2)+'\n')
PY
