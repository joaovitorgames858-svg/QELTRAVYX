# CODEX — MISSÃO QELTRAVYX RUNTIME TOTAL (31/10/2026)

## Objetivo
Desenvolva a próxima versão do app QELTRAVYX: Node.js + npm executáveis reais, Git nativo, gerenciamento de pacotes melhorado e CORE capaz de programar, testar e diagnosticar projetos, preservando tudo que já funciona. Trabalhe de modo autônomo e iterativo na worktree isolada deste documento, com commits e testes. Não marque como pronto o que não executou de verdade.

## Base comprovada que NÃO pode regredir
- Flutter 3.47.2, Dart 3.13.2, Android id dev.qeltravyx.qeltravyx, minSdk 24+, arm64-v8a. Versão estável 1.0.17+43.
- GitHub Actions já gera APK unsigned em Linux x86_64 com NDK 28.2.13676358, Gradle 9.3.1, Java 21. A assinatura é feita só no celular com keystore privada nunca enviada ao GitHub.
- Terminal Bash PTY com prompt verde dinâmico, teclado ao toque, colagem na tela preta, seleção com alças azuis, zoom salvo, sessões, histórico e UX V3 clean. NÃO remover.
- Python 3.14.9, ssl/sqlite3/json e pip 26.2.2 offline estão funcionando de verdade. O usuário instalou um arquivo wheel puro qelpipdemo 1.0.0 e conseguiu importar. Preservar ci/patch_pip_android_alias.py, hash e dados do app.
- Veja RuntimeBridge.kt, MainActivity.kt, RuntimePip.kt, runtime-extension.sh, lib/core_*.dart, arquivos de UX e qpkg.py; Node, npm e Git continuam AUSENTES e os stubs não podem alegar instalação.
- O telefone tem pouco espaço; não gerar dezenas de APKs, não apagar builds/backups indiscriminadamente.

## Regras de engenharia, segurança e honestidade
1. Faça inventário do repositório primeiro. Edite somente a worktree atual. Não executar git reset --hard, git clean, flutter clean, nem apagar dados/keystores/código do projeto principal em ~/QELTRAVYX_CODEX107. Commits incrementais e backups de arquivos críticos.
2. Execução Android ARM64/Bionic é obrigatória, totalmente independente do Termux; ELF Linux ARM64 glibc não funciona automaticamente no Android. Não copie Node/Git/apt do Termux para dentro do APK. Para cada binário inclua fonte confiável, versão fixa, licença e hashes; toolchain NDK no GitHub Actions ou alternativa comprovadamente compatível.
3. Os serviços instalados devem passar por testes reais no Android: Node com require('fs'), argv, stdin, leitura/escrita e código JS; npm com --version e instalação/uso de módulo puro em pasta própria, scripts pós-instalação somente com autorização; Git com init/add/commit/status/log e, se habilitado, clone HTTPS em diretório autorizado. Não simular resultados.
4. Execução segura: paths canônicos aceitando alias legítimo /data/user/0 vs /data/data mas negando links internos indevidos, proteção zip-slip, limites de tamanho, checksum, instalação atômica, rollback, logs, cancelamento, timeouts e política de downloads HTTPS com consentimento. Não usar credenciais no código, no GitHub ou nos logs.
5. Não prometer apt/pkg real sem bootstrap confiável com suporte Android. Aprimore QPKG existente para catálogo local/seguro e mostre claramente o que está disponível. Preserve os arquivos do usuário em workspace, Python packages, históricos, SharedPreferences, permissões e dados de projetos.
6. Use o canal/CORE e o agente que já existem. Preservar as permissões por projeto; criar/editar múltiplos arquivos com backup, testes e diagnósticos, jobs canceláveis, status de execução visível e mensagens de erro honestas. Não fingir acesso a LLM, à rede ou ao sistema quando indisponível.
7. NÃO enviar mudanças para main nem alterar o APK estável. Não fazer push automático; não instalar nem limpar app do usuário. Mantenha release unsigned em CI e documente assinatura local após testes.
8. Se algum componente depender de ferramentas que não existem, implemente a infraestrutura/CI e registre exatamente o bloqueio, em vez de improvisar ou alegar sucesso.

## Sequência de trabalho e critérios de aceite

FASE 0: Leia todas as peças relevantes, crie docs/RUNTIME_TOTAL_STATUS.md com tabela por função (confirmado, stub, falhando, não testado), inventário, riscos, versão, ferramenta de build e passos concretos. Adicione teste de regressão dos recursos atuais. Faça commit inicial da documentação/infra.

FASE 1: Node.js Android arm64 Bionic. Estude viabilidade de versões de Node e nodejs-mobile; escolha fontes auditáveis, proteja downloads por SHA, compile no CI se necessário. Faça integração nativa sem depender de Termux; extração segura/idempotente, status ligado ao resultado real do --version, script JS de smoke. Se só for possível entregar pipeline de compilação, registre pendência de teste no dispositivo e não declare pronto.

FASE 2: npm CLI completo para a versão Node realmente escolhida, com dependências empacotadas de forma reproduzível, instalação de pacote JS puro em área privada e política explícita sobre rede e lifecycle scripts. Sem npm "instalado" se somente Node existir.

FASE 3: Git Android arm64 Bionic real, com utilitários e bibliotecas necessários, licenças, PATH/exec corretos, testes init/add/commit/status/log. Clone somente HTTPS por permissão. Não depender de executáveis do Termux.

FASE 4: QPKG/repositório de pacotes. Melhorar descoberta/versões, integrity, processos/rollback e UX para gerenciar pip, npm e binários nativos sem chamar apt do Termux. Testar reinstall, upgrade e falhas de extração.

FASE 5: CORE agente programação ponta a ponta. Prompt único integrado, mas sem perder compositor Bash; montar plano, gerar/editar projetos dentro do workspace, rodar/testar, diagnosticar/corrigir, salvar logs de atividades e cancelar processos. Tratar capacidades inexistentes honestamente. Testar mini projeto Python e JavaScript.

FASE 6: CI/qualidade. Adicione workflows de testes e build nativo separados da release UX V3, execução dos testes Flutter relevantes, smoke no Android quando praticável; APK unsigned sem chaves privadas e guia de assinatura local. Não incrementar versionCode até haver novo APK validado; base 43.

## Execução autônoma nesta sessão
Não pare só em plano: implemente o máximo de código funcional viável com segurança. Priorize uma fatia vertical de Node ou Git compilável com testes. Execute diagnósticos e testes disponíveis; corrija erros. Registre continuamente em docs/RUNTIME_TOTAL_STATUS.md (comandos executados, saídas, limites, commits, próximos passos). Não faça push sem pedido explícito e não mexa no projeto original. Ao terminar, escreva uma conclusão objetiva distinguindo implementado de pendente; não prometa que completou recursos não testados.
