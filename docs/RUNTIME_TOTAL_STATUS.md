# RUNTIME TOTAL — diário verificável (31/10/2026)

## Escopo e base

Worktree `/root/qeltravyx_runtime_dev`, branch `runtime-total-dev`, início `ee17042`.
Base preservada: **1.0.17+43**, Flutter 3.47.2 / Dart 3.13.2,
`dev.qeltravyx.qeltravyx`, ARM64, Android API 24+.
Não houve push, instalação do app, alteração de main, assinatura ou limpeza do projeto original.
Backups locais dos arquivos críticos em `backups/runtime-total-20261031/` (ignorados pelo Git).

## Inventário inicial

| Função | Estado comprovado inicial | Evidência / limite |
| --- | --- | --- |
| Bash PTY / UX V3 | confirmado pelo usuário; regressão local em execução | `MainActivity.kt`, `android/native`, `lib/terminal_*`, 4 suites Flutter |
| Python 3.14.9 / ssl / sqlite / json | confirmado pelo usuário | executável e libs em `jniLibs/arm64-v8a`, stdlib.zip; não revalidado no app nesta sessão |
| pip 26.2.2 offline | confirmado pelo usuário | RuntimePip, patch de alias Android e ZIP/hash preservados |
| Node | stub de entrada; não instalado | nenhuma `libqeltravyx_node.so`; não usar Node do host como evidência Android |
| npm | stub de entrada; não instalado | nenhuma árvore CLI empacotada; smoke existente só verifica versão |
| Git | stub de entrada; não instalado | nenhuma `libqeltravyx_git.so`; smoke local existe, não executado no app |
| QPKG | implementação de wheels Python; não testado nesta sessão | download PyPI/hash, rollback parcial; catálogo local ausente |
| CORE | implementação Python V3, protocolo/canal V2 | permissões por projeto, backups, cancelamento, logs, validação estática; execução de exemplo Python restrita; JS sem ciclo pronto |
| LLM | opcional; não confirmado | endpoint local configurável, indisponibilidade deve continuar explícita |
| apt/pkg | não disponível | sem bootstrap Android; não será anunciado como instalado |
| CI UX V3 | confirmado pelo usuário | Linux x86_64, NDK 28.2.13676358, Java 21, Gradle 9.3.1; unsigned no CI |

Arquivos inspecionados: RuntimeBridge, RuntimePip, CorePolicy, CoreV2Bridge,
MainActivity (canais/preparação), runtime-extension, qpkg, core_v2.py,
lib/core_*.dart, runtime_status_panel, packages_page, pubspec, workflow UX V3.
Não há AGENTS.md na worktree.

## Ambiente e bloqueios observados

- `uname -m`: aarch64 (PRoot no telefone); Python host 3.12.3, Node host v18.19.1.
- `flutter --version`: Flutter 3.47.2, Dart 3.13.2, disponível pelo host.
- `adb devices`: falhou ao iniciar daemon (`proot ... tcp:5037 not found`); nenhum dispositivo autenticado nesta sessão.
- NDK Linux x86_64 não executa nativamente aqui. Não copiar executáveis Termux.
- Disco: cerca de 12 GiB livres de 229 GiB. Evitar builds grandes locais/APKs repetidos.
- Ferramenta cloud `environment_status` e `/etc/codex/network-policy.json` ausentes; nenhuma credencial inspecionada.

## Riscos e direção

1. Android exige ELF Bionic, interpreter `/system/bin/linker64`; um ELF glibc não atende.
2. Node upstream oferece android-configure mas declara Android não suportado; nodejs-mobile
   fornece libnode, exigindo launcher separado. Seleção/pinning após conferir fontes oficiais.
3. QPKG resolve paths antes de checar links e só valida destino HTTPS depois do redirect.
4. Código de projeto no mesmo UID não é sandbox. CORE não deve liberar execução arbitrária
   alegando isolamento; preservar exemplos auditados/permissões.
5. `--version` prova apenas inicialização. Aceite exige I/O, pacote npm e commit Git reais no APK.

## Sequência e registro

- Fase 0: inventário, backups, regressões de integridade pip/stdlib e ausência honesta de runtimes.
- Próximo: fatia nativa reproduzível e separada da release; pins, hashes, licença, validação ELF,
  smoke Android e integração de dados npm. Não incrementar versionCode.
- Depois: endurecer QPKG, estender CORE com exemplo JS limitado, CI e guia de assinatura local.

Comandos iniciais: `git status --short` (limpo), `git log -5 --oneline`, `git worktree list`,
`rg --files`, leitura dos arquivos listados, `df -h .`, versões e ADB acima.
Resultados adicionais e commits serão acrescentados conforme executados.
