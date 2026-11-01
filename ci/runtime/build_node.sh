#!/usr/bin/env bash
# Build only on CI's Linux x86_64 host, with Android's Bionic sysroot.
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || {
  echo 'BLOCKED: requires Linux x86_64 + Android NDK; host/Termux binaries are not accepted.' >&2
  exit 2
}
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to NDK 28.2.13676358}"
grep -q '28.2.13676358' "$ANDROID_NDK_HOME/source.properties"
q_work="${1:-.build/node-android}"
q_output="${2:-.build/runtime-bundle}"
mkdir -p "$q_work" "$q_output"
q_work=$(realpath "$q_work")
q_output=$(realpath "$q_output")
python3 ci/runtime/prepare_node.py --work "$q_work" --assets "$q_output/assets/qeltravyx/npm"
q_version=$(python3 -c 'import json; print(json.load(open("ci/runtime/sources.json"))["node"]["version"])')
q_toolchain="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
export PATH="$q_toolchain/bin:$PATH"
export CC="$q_toolchain/bin/aarch64-linux-android24-clang"
export CXX="$q_toolchain/bin/aarch64-linux-android24-clang++"
export AR="$q_toolchain/bin/llvm-ar"
export CC_host=gcc CXX_host=g++ AR_host=ar
export GYP_DEFINES="target_arch=arm64 v8_target_arch=arm64 android_target_arch=arm64 host_os=linux OS=android android_ndk_path=$ANDROID_NDK_HOME"
export LDFLAGS='-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384'
(
  cd "$q_work/node-v$q_version"
  # The upstream Android patch shipped with 22.23.4 targets an older V8 header.
  # Apply a narrowly scoped, pinned equivalent: Android must not enable trap handlers.
  python3 - "$OLDPWD/ci/runtime" <<'PY_PATCH'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]); spec=json.loads((root/'sources.json').read_text())['node']
for name,sha in spec['patches'].items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest()==sha
PY_PATCH
  patch --batch --forward --fuzz=0 -p1 < "$OLDPWD/ci/runtime/node-android-traps.patch"
  # mksnapshot runs on x86_64 but includes V8_TARGET_OS_ANDROID for ARM64 output.
  # Disable Android-specific trap-handler optimization consistently in host/target.
  grep -Fq "#if defined(V8_TARGET_OS_ANDROID) || V8_OS_ANDROID" deps/v8/src/trap-handler/trap-handler.h
  # Explicit configure invocation: upstream android_configure.py discards exit status.
  ./configure --dest-cpu=arm64 --dest-os=android --openssl-no-asm --cross-compiling --with-intl=small-icu
  # Build the executable target only. The default GYP "all" also compiles
  # cctest, whose aligned_alloc() requires an Android API newer than our minSdk 24.
  # Host mksnapshot and every library required by the node target remain dependencies.
  # Use the generated Android GYP Makefile rather than the upstream default "all".
  make -j4 -C out BUILDTYPE=Release V=0 node
)
mkdir -p "$q_output/jniLibs/arm64-v8a"
cp ci/runtime/node-android-traps.patch "$q_output/assets/qeltravyx/npm/NODE-ANDROID-PATCH.diff"
cp "$q_work/node-v$q_version/out/Release/node" "$q_output/jniLibs/arm64-v8a/libqeltravyx_node.so"
if "$q_toolchain/bin/llvm-readelf" -d "$q_output/jniLibs/arm64-v8a/libqeltravyx_node.so" | grep -q libc++_shared.so; then
  cp "$q_toolchain/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$q_output/jniLibs/arm64-v8a/"
  cp "$ANDROID_NDK_HOME/NOTICE" "$q_output/assets/qeltravyx/npm/NDK-NOTICE.txt"
fi
python3 ci/runtime/verify_elf.py "$q_output/jniLibs/arm64-v8a/libqeltravyx_node.so"
python3 - "$q_output" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1])
files={p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob('*')) if p.is_file()}
(root/'SHA256SUMS.json').write_text(json.dumps(files,indent=2)+'\n')
PY
