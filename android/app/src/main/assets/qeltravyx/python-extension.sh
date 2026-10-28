# QELTRAVYX_PYTHON_0_6_START
# Official CPython 3.14 Android embeddable distribution, no dependency on Termux.
qpython() {
  if [ -z "${QELTRAVYX_TOOLBOX:-}" ]; then
    printf '%s\n' 'Python: diretório nativo não configurado.' >&2
    return 127
  fi
  _q_pyexe="${QELTRAVYX_TOOLBOX%/*}/libqeltravyx_python.so"
  _q_pyhome="$HOME/python-runtime-3.14.9"
  if [ ! -x "$_q_pyexe" ]; then
    printf '%s\n' 'Python: executável ARM64 não localizado no APK.' >&2
    return 127
  fi
  if [ ! -f "$_q_pyhome/.qeltravyx_ready" ]; then
    printf '%s\n' 'Python: arquivos ainda não preparados. Reinicie o aplicativo.' >&2
    return 1
  fi
  QELTRAVYX_PYHOME="$_q_pyhome" "$_q_pyexe" "$@"
}
python() { qpython "$@"; }
python3() { qpython "$@"; }
# QELTRAVYX_PYTHON_0_6_END
