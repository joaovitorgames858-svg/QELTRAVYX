# QELTRAVYX_BASH_SESSION_1_START
# Keep the PTY and its environment; replace only the initial Android shell.
qbash() {
  if [ -z "${QELTRAVYX_TOOLBOX:-}" ]; then
    printf '%s\n' 'QELTRAVYX: diretorio nativo indisponivel.' >&2
    return 127
  fi
  _q_bash="${QELTRAVYX_TOOLBOX%/*}/libqeltravyx_bash.so"
  if [ ! -x "$_q_bash" ]; then
    printf '%s\n' 'QELTRAVYX: Bash ARM64 ausente ou nao executavel.' >&2
    return 126
  fi
  if [ "$#" -eq 0 ]; then
    "$_q_bash" --noprofile --rcfile "$HOME/.qeltravyx/session.bashrc" -i
  else
    "$_q_bash" --noprofile --norc "$@"
  fi
}
case $- in
  *i*)
    if [ -z "${BASH_VERSION:-}" ] && [ -n "${QELTRAVYX_TOOLBOX:-}" ]; then
      _q_bash="${QELTRAVYX_TOOLBOX%/*}/libqeltravyx_bash.so"
      if [ -x "$_q_bash" ] && [ -r "$HOME/.qeltravyx/session.bashrc" ]; then
        exec "$_q_bash" --noprofile --rcfile "$HOME/.qeltravyx/session.bashrc" -i
      fi
      printf '%s\n' 'QELTRAVYX: sessão Bash indisponível; shell Android mantido.' >&2
    fi
    ;;
esac
# QELTRAVYX_BASH_SESSION_1_END
