# QELTRAVYX_QPKG_0_8_START
# QELTRAVYX package manager (only pure Python wheels; no native package builds).
qpkg() {
  if [ ! -f "$HOME/.qeltravyx/qpkg.py" ]; then
    printf '%s\n' 'qpkg: inicialização incompleta; reinicie o QELTRAVYX.' >&2
    return 1
  fi
  python "$HOME/.qeltravyx/qpkg.py" "$@"
}
# QELTRAVYX_QPKG_0_8_END
