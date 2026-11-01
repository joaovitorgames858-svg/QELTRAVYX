# QELTRAVYX_GIT_LOCAL_FIX_1_START
# Git 2.56 local-only runs without Termux 'less', non-bundled git-maintenance
# helpers, or templates installed in the NDK's nonexistent build prefix.
# Keep user Git identity / config and allow an explicit GIT_PAGER override.
git() {
  GIT_ALLOW_PROTOCOL='' GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
  GIT_PAGER="${GIT_PAGER:-cat}" \
  GIT_EXEC_PATH="$HOME/.qeltravyx/runtimes/git/libexec/git-core" \
    _q_runtime_native git \
      -c init.templateDir= \
      -c maintenance.auto=false \
      -c gc.auto=0 \
      "$@"
}
# QELTRAVYX_GIT_LOCAL_FIX_1_END
