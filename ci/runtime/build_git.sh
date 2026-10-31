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
q_toolchain="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
# Build only the C executable and its in-process builtins. No curl, Perl, Python,
# shell helpers or external TLS libraries; remote operations deliberately unavailable.
make -C "$q_work/git-$q_version" -j2 git \
  CC="$q_toolchain/bin/aarch64-linux-android24-clang" \
  AR="$q_toolchain/bin/llvm-ar" \
  CFLAGS='-O2 -fPIE -D__ANDROID_API__=24' \
  LDFLAGS='-pie -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384' \
  NO_CURL=YesPlease NO_EXPAT=YesPlease NO_OPENSSL=YesPlease \
  NO_GETTEXT=YesPlease NO_ICONV=YesPlease NO_PERL=YesPlease NO_PYTHON=YesPlease \
  NO_TCLTK=YesPlease NO_INSTALL_HARDLINKS=YesPlease \
  CSPRNG_METHOD= HAVE_SYNC_FILE_RANGE= FSMONITOR_DAEMON_BACKEND= FSMONITOR_OS_SETTINGS= \
  ac_cv_fread_reads_directories=YesPlease ac_cv_snprintf_returns_bogus=No \
  prefix=/nonexistent/qeltravyx-git SHELL_PATH=/system/bin/sh
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
