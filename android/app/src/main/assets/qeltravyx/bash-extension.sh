# QELTRAVYX_BASH_0_5_START
# Added to the user's shell profile only once. Does not replace user settings.
qbash() {
  if [ -z "${QELTRAVYX_TOOLBOX:-}" ]; then
    printf '%s\n' 'QELTRAVYX: diretorio nativo indisponivel.' >&2
    return 127
  fi
  _q_bash="${QELTRAVYX_TOOLBOX%/*}/libqeltravyx_bash.so"
  if [ ! -x "$_q_bash" ]; then
    printf '%s\n' 'QELTRAVYX: Bash ARM64 ausente ou nao executavel.' >&2
    printf 'Caminho: %s\n' "$_q_bash" >&2
    return 126
  fi
  if [ "$#" -eq 0 ]; then
    "$_q_bash" --noprofile --norc -i
  else
    "$_q_bash" --noprofile --norc "$@"
  fi
}
qbashhelp() {
  printf '%s\n' 'qbash      Abre Bash interativo' \
    "qbash -c 'echo teste'  Executa um comando no Bash" \
    'exit       Volta ao shell Android'
}
# QELTRAVYX_BASH_0_5_END
