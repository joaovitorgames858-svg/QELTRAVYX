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

### Incremento Node/npm

- Commit fase 0: `b0e557b`.
- `python3 -m unittest discover -s ci/tests -v`: **3 passaram**, incluindo patch pip
  somente em cópia descartável; ZIP/hash originais inalterados.
- Primeira tentativa Flutter `--no-pub` falhou por package config ausente.
  `flutter pub get` resolveu; as **23 regressões de terminal passaram**.
- Seleção: Node **22.23.4**, fonte oficial e SHA-256 fixo em `ci/runtime/sources.json`.
  npm vem da árvore `deps/npm` da mesma fonte, sem resolver dependências na rede.
- Fontes consultadas: [Node Android](https://github.com/nodejs/node/blob/v22.23.4/BUILDING.md#android),
  [configurador](https://github.com/nodejs/node/blob/v22.23.4/android_configure.py),
  [checksums](https://nodejs.org/dist/v22.23.4/SHASUMS256.txt),
  [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile/blob/main/doc_mobile/BUILDING.md).
  Android upstream não é plataforma suportada. nodejs-mobile consultado oferece 18.20.4/libnode;
  não selecionado para esta fatia de CLI.
- Primeiro download encerrou com 10.600.367 de 51.413.508 bytes: SHA divergente e EOF xz.
  Rejeitado; retomado por HTTPS com curl. Não se alterou o hash para aceitar arquivo inválido.
- `bash ci/runtime/build_node.sh`: **bloqueado**, exit 2 esperado no host ARM64.
  Workflow manual Linux x86_64 criado; ainda NÃO executado no GitHub.
- RuntimeNpm: hash antes da extração, limites, paths canônicos e staging com rename;
  não substitui instalação diferente ou arquivos de usuário. Atualização de árvore existente
  deliberadamente bloqueada até existir migração revisada. Kotlin/Android ainda não validado.
- Smoke Node agora cobre escrita/leitura/rename/delete, argv e stdin. Smoke npm instala
  tarball próprio offline, importa módulo e testa bloqueio do lifecycle. A CLI completa
  é empacotada, mas entrada `npm` do terminal limita comandos a versão/lista/instalação
  local com `--offline --ignore-scripts`; rede/scripts ainda não têm adaptador de consentimento.
- Novo marcador de extensão preserva perfis existentes e acrescenta as funções atualizadas.
- Encontrado bloqueio herdado para instalação nova: `qpkg-vendor.zip` é referido por
  MainActivity, mas não está presente nesta worktree. Instalações existentes podem ter
  vendor persistido. Não confundir sucesso de testes host com primeiro lançamento validado.

### Evidências adicionais de implementação

- Fonte Node baixada integralmente: SHA esperado confirmado, extração segura concluída.
  `prepare_node.py` produziu npm **10.9.9**, **2148 arquivos / 12785316 bytes**,
  ZIP SHA `ba7a8333f724963973309c89402aff4e565a2f33e3a645e9ab83aef09532c0b2`.
  Payload gerado somente em `.build`; a CI o incorpora ao candidato, não ao APK estável.
- `python3 -m unittest discover -s ci/tests -v`: **17 testes passaram** (host),
  incluindo ciclos reais Python e JS, rollback, ausência de runtime, permissões,
  cancelamento, links/zip-slip, origem HTTPS e testes da infraestrutura nativa.
- `python3 ci/tests/run_kotlin_installers.py --cache <cache Gradle existente>`:
  RuntimeNpm/RuntimeQpkg **compilaram** com Kotlin 2.2.20 + Java 21; harness RuntimeNpm
  passou (hash, zip-slip, idempotência, upgrade preservado, alias da raiz, links internos).
  São stubs de Context em JVM, não substituem Android. Jansi emitiu aviso de libc.so.6;
  compilação e testes concluíram com exit 0.
- QPKG 0.10 implementa catálogo local, verify e install-local com checksum. Rede exige
  `install --allow-network`; UI explicita autorização. Redirects são bloqueados antes da conexão.
  Locks serializam mutações; arquivos e registro são publicados atomicamente individualmente;
  rollback cobre exceção/interrupção cooperativa. **Não é uma transação global de filesystem**:
  morte abrupta deixa journal e bloqueia novas mutações para revisão; recuperação automática pendente.
  Reinstall íntegro é idempotente, alteração de usuário/upgrade são recusados preservando conteúdo.
- Vendor QPKG reproduzido do pip original com hash conferido, licenças incluídas:
  229435 bytes, SHA `5e247f68495d1c744ea10e9a3920408ae45942986b2b1df5fef3cdd8d0ea5200`.
  Provisionamento novo verifica SHA/limites e staging; atualização do script salva backup.
- CORE: exemplos JavaScript integrados no canal/protocolo existente, snapshots privados,
  autorizações existentes, logs, hashes do resultado e correção determinística com backup.
  Código arbitrário/LLM permanece bloqueado para execução sem isolamento; não há sandbox nova.
- Git **2.56.0**: fonte/hash fixos do [manifesto kernel.org](https://www.kernel.org/pub/software/scm/git/sha256sums.asc),
  build NDK somente de comandos C locais; licença GPL e fonte correspondente acompanham o artefato.
  **Build e execução Android pendentes**. Clone/HTTPS não habilitado; sem curl/remote helpers.
- CI nativa manual: jobs separados Node/Git + candidato APK unsigned dependente dos dois;
  hashes verificados antes de staging, ELF Bionic/ARM64/PIE/alinhamento 16 KiB conferidos.
  Não houve build nativo nem APK local nesta sessão. Versão continua 1.0.17+43.
