# QELTRAVYX_RUNTIME_TOTAL_2_START
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
  # Restricted terminal entry point; full CLI tree remains bundled separately.
  # No implicit network consent and no lifecycle/script/exec commands.
  case "${1:-}" in
    --version|-v) node "$q_npm_cli" --version; return $? ;;
    ls|list) shift; [ "$#" -eq 0 ] || return 64
      node "$q_npm_cli" ls --offline --ignore-scripts --no-audit --no-fund
      return $? ;;
    install)
      shift
      if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
        printf '%s\n' 'npm install: forneça um .tgz local; rede e scripts não autorizados.' >&2
        return 64
      fi
      case "$1" in *.tgz) ;; *) return 64 ;; esac
      # Resolve the local file; reject CLI options, URLs and directories.
      q_npm_tarball=$(cd -- "$(dirname -- "$1")" && printf '%s/%s' "$PWD" "$(basename -- "$1")") || return 64
      node "$q_npm_cli" install "$q_npm_tarball" --offline --ignore-scripts --no-audit --no-fund \
        --update-notifier=false --userconfig=/dev/null --globalconfig="${q_npm_cli%/bin/npm-cli.js}/.qel-global-npmrc" --global=false --prefix="$PWD"
      return $? ;;
    *) printf '%s\n' 'npm: disponíveis --version, ls e install arquivo.tgz offline; scripts/rede exigem adaptador de consentimento.' >&2
       return 64 ;;
  esac
)
git() {
  GIT_ALLOW_PROTOCOL='' GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
  GIT_EXEC_PATH="$HOME/.qeltravyx/runtimes/git/libexec/git-core" \
    _q_runtime_native git "$@"
}
# QELTRAVYX_RUNTIME_TOTAL_2_END
