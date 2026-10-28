# QELTRAVYX 0.4 — initialization for Android /system/bin/sh (mksh).
# User-editable file: ~/.qeltravyx/profile.sh (never overwritten after creation).
QELTRAVYX_WORKSPACE=${QELTRAVYX_WORKSPACE:-"$HOME/workspace"}

qhelp() {
  printf '%s\n' \
    'QELTRAVYX 0.4 — comandos integrados:' \
    '  qhelp         Lista os comandos do QELTRAVYX' \
    '  qinfo         Informacoes da ferramenta ARM64 empacotada' \
    '  qdoctor       Diagnostico do ambiente independente' \
    '  qprojects     Abre a pasta de projetos do QELTRAVYX' \
    '  qworkspace    Abre o espaco de trabalho' \
    '  qnative help  Executa o utilitario ARM64 do APK' \
    'O shell atual e /system/bin/sh (Android), nao Ubuntu ou Bash.'
}

qnative() {
  if [ -n "${QELTRAVYX_TOOLBOX:-}" ] && [ -x "$QELTRAVYX_TOOLBOX" ]; then
    "$QELTRAVYX_TOOLBOX" "$@"
  else
    printf '%s\n' 'QELTRAVYX: utilitario ARM64 nao esta executavel neste Android.' >&2
    printf 'Caminho esperado: %s\n' "${QELTRAVYX_TOOLBOX:-nao configurado}" >&2
    return 126
  fi
}

qdoctor() { qnative doctor; }
qinfo() { qnative info; }
qprojects() { cd "$QELTRAVYX_WORKSPACE/projects"; }
qworkspace() { cd "$QELTRAVYX_WORKSPACE"; }

# APT/PKG, Python, Bash, Node e Codex ainda nao fazem parte desta versao.
