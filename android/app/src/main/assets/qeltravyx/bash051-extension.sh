# QELTRAVYX_BASH_0_5_1_START
# Override only the previous qbash helper, without changing other commands.
qbash() {
  if [ -z "${QELTRAVYX_TOOLBOX:-}" ]; then
    printf '%s\n' 'QELTRAVYX: diretorio nativo indisponivel.' >&2
    return 127
  fi
  _q_bash="${QELTRAVYX_TOOLBOX%/*}/libqeltravyx_bash.so"
  _q_rc="$HOME/.qeltravyx/bashrc"
  if [ ! -x "$_q_bash" ]; then
    printf '%s\n' 'QELTRAVYX: Bash ARM64 ausente ou nao executavel.' >&2
    return 126
  fi
  if [ "$#" -eq 0 ]; then
    if [ ! -f "$_q_rc" ]; then
      printf '%s\n' 'QELTRAVYX: configuracao Bash ausente.' >&2
      return 1
    fi
    HISTFILE="$HOME/.qeltravyx_bash_history" "$_q_bash" --noprofile --rcfile "$_q_rc" -i
  else
    "$_q_bash" --noprofile --norc "$@"
  fi
}
# QELTRAVYX_BASH_0_5_1_END
