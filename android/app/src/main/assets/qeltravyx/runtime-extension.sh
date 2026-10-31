# QELTRAVYX_RUNTIME_BASE_1_START
# Entry points are not installation evidence. No host/Termux PATH fallback.
pip() { python -m pip "$@"; }
pip3() { python3 -m pip "$@"; }
_q_runtime_native() (
  case "$1" in node|git) q_runtime_name="$1" ;; *) return 64 ;; esac
  shift
  if [ -z "${QELTRAVYX_TOOLBOX:-}" ]; then
    printf '%s\n' "$q_runtime_name: diretório nativo não configurado." >&2
    return 127
  fi
  q_runtime_libs="${QELTRAVYX_TOOLBOX%/*}"
  q_runtime_binary="$q_runtime_libs/libqeltravyx_$q_runtime_name.so"
  if [ ! -x "$q_runtime_binary" ]; then
    printf '%s\n' "$q_runtime_name: componente não empacotado neste APK." >&2
    return 127
  fi
  LD_LIBRARY_PATH="$q_runtime_libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$q_runtime_binary" "$@"
)
node() { _q_runtime_native node "$@"; }
npm() (
  q_npm_cli="$HOME/.qeltravyx/runtimes/npm/bin/npm-cli.js"
  if [ ! -f "$q_npm_cli" ]; then
    printf '%s\n' 'npm: CLI não empacotada; requer Node e a árvore completa do npm.' >&2
    return 127
  fi
  node "$q_npm_cli" "$@"
)
git() {
  GIT_EXEC_PATH="$HOME/.qeltravyx/runtimes/git/libexec/git-core" \
    _q_runtime_native git "$@"
}
# QELTRAVYX_RUNTIME_BASE_1_END
