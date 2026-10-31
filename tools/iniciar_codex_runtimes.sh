#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
PROJETO="$(cd "$(dirname "$0")/.." && pwd)"
MISSAO="$PROJETO/docs/CODEX_MISSAO_RUNTIME_TOTAL.md"
test -s "$MISSAO" || { echo "ERRO: missão não encontrada"; exit 1; }
command -v proot-distro >/dev/null || { echo "ERRO: proot-distro não disponível"; exit 1; }
echo "=== PROJETO ISOLADO ==="
echo "$PROJETO"
git -C "$PROJETO" branch --show-current
df -h "$PROJETO" | tail -1
proot-distro login ubuntu -- bash -lc 'mkdir -p /root/qeltravyx_runtime_dev'
echo "=== INICIANDO CODEX NO UBUNTU ==="
proot-distro login ubuntu --bind "$PROJETO:/root/qeltravyx_runtime_dev" -- bash -lc '
  set -o pipefail
  cd /root/qeltravyx_runtime_dev || exit 1
  command -v codex || { echo "Codex CLI não encontrado no Ubuntu"; exit 1; }
  codex --version
  echo "Acesso ao ambiente Ubuntu/PROot não é sandbox forte. Atuação limitada por missão à worktree."
  codex exec --sandbox danger-full-access -c "approval_policy=\"never\"" - < docs/CODEX_MISSAO_RUNTIME_TOTAL.md 2>&1 | tee docs/CODEX_RUNTIME_EXECUCAO.log
'
