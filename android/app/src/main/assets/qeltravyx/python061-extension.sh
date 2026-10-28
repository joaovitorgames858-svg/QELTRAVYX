# QELTRAVYX_PYTHON_0_6_1_START
# Fix Android dlopen dependency lookup. Keeps user profile and existing Python setup.
qpython() {
  if [ -z "${QELTRAVYX_TOOLBOX:-}" ]; then
    printf '%s\n' 'Python: biblioteca nativa nao configurada.' >&2
    return 127
  fi
  _q_pylibs="${QELTRAVYX_TOOLBOX%/*}"
  _q_pyexe="$_q_pylibs/libqeltravyx_python.so"
  _q_pyhome="$HOME/python-runtime-3.14.9"
  if [ ! -x "$_q_pyexe" ]; then
    printf '%s\n' 'Python: executavel ARM64 nao localizado no APK.' >&2
    return 127
  fi
  if [ ! -f "$_q_pyhome/.qeltravyx_ready" ]; then
    printf '%s\n' 'Python: runtime nao preparado. Reinicie o aplicativo.' >&2
    return 1
  fi
  LD_LIBRARY_PATH="$_q_pylibs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  QELTRAVYX_PYHOME="$_q_pyhome" "$_q_pyexe" "$@"
}
python() { qpython "$@"; }
python3() { qpython "$@"; }
# QELTRAVYX_PYTHON_0_6_1_END
