# Validar o candidato sem confundir com a versão estável

## Build autorizado, ainda não executado nesta sessão

Os workflows novos são separados de `qeltravyx-ux-v3.yml`. Não há push automático.
Após revisão e envio explícito da branch, executar manualmente **Runtime total - Android Bionic Node candidate**.
A CI baixa fontes fixas/SHA-256, compila Node e Git com NDK 28.2.13676358/Linux x86_64,
valida ELF e reúne **um** APK unsigned. Se qualquer build falhar, guardar o log; não
substituir o binário por Linux glibc ou Termux. Node Android upstream não é suportado
oficialmente; os comandos de build ainda exigem validação nesse runner.

- Node 22.23.4 e npm 10.9.9: `ci/runtime/sources.json`.
- Git 2.56.0: comandos locais, sem transporte remoto. Clone HTTPS permanece indisponível.
- Bibliotecas executáveis ficam em `jniLibs/arm64-v8a` para extração pelo PackageManager.
  npm é somente dados JS; instalador verifica ZIP antes de staging/rename.
- Licenças Node/npm são incluídas; Git COPYING e fonte correspondente estão no artefato Git.
  Ao redistribuir Git, distribuir também esse pacote de fontes/licença e scripts de build.
- A validação ELF exige linker64/ARM64/PIE/alinhamento 16 KiB para os candidatos novos.
  Isso não certifica compatibilidade 16 KiB de todas as bibliotecas herdadas do APK.
- `versionCode` permanece **43** até um APK novo ser validado e uma mudança de versão ser autorizada.

## Assinatura somente local

Nenhuma chave é usada ou solicitada pelo CI. No telefone/ambiente local autorizado,
com Android Build Tools disponíveis, confira o SHA do artefato e então:

```sh
zipalign -P 16 -f -v 4 QELTRAVYX-runtime-candidate-unsigned.apk QELTRAVYX-runtime-aligned.apk
apksigner sign --ks /caminho/local/keystore-privada.jks --out QELTRAVYX-runtime-signed.apk QELTRAVYX-runtime-aligned.apk
apksigner verify --verbose --print-certs QELTRAVYX-runtime-signed.apk
```

A senha é solicitada localmente pelo apksigner; não colocar em comando, log ou Git.
Usar a identidade de assinatura do app instalado para uma atualização que preserve dados.
Não instalar, desinstalar ou limpar dados automaticamente. Manter o APK estável e backups existentes.
Esses comandos são instruções, **não foram executados** nesta sessão.

## Aceite no Android, em sessão autorizada

1. Registrar modelo/API/ABI, versão/assinatura do APK e hashes dos artefatos.
2. Conferir regressão manual: prompt verde/cwd, teclado por toque, colagem/seleção/alças,
   zoom salvo, sessões, histórico e compositor Bash alternando com CORE.
3. Em **Runtimes e pacotes**, inspecionar versões; salvar saída e exitCode de cada smoke.
   Node deve ler argv/stdin e criar/ler/renomear/remover arquivo. npm deve instalar/importar
   fixture local em cache privado e mostrar lifecycle bloqueado. Git deve init/add/commit,
   status limpo e log com a mensagem esperada. `--version` sozinho não é o aceite.
4. Repetir Python ssl/sqlite/json e pip offline/import, incluindo wheel puro do usuário.
   Não remover pacotes já existentes. O ZIP/hash pip do repositório permanece preservado;
   o patch de alias é aplicado apenas no checkout descartável de CI.
5. Criar projeto de teste próprio via UI; conceder permissões por projeto. No CORE:
   `criar projeto python`, depois `testar projeto python` com aprovação da execução;
   repetir com `criar projeto javascript` e `testar projeto javascript`.
   Conferir logs, backups, hashes e cancelamento/revogação. Código diferente dos templates
   não entra no ciclo automático: não existe isolamento Android para código arbitrário.
6. QPKG: `qpkg catalog`, `qpkg install-local ARQUIVO.whl SHA256`, `qpkg verify`,
   reinstall íntegro e checksum inválido. Upgrade é recusado preservando arquivos.
   `qpkg install --allow-network NOME` é consentimento para PyPI/HTTPS; UI explicita isso.
7. Se houver `.qpkg/pending.json`, suspender mutações e revisar arquivos/registro.
   Rollback por exceção é testado; recuperação após morte abrupta ainda é manual.

Nenhum desses passos de dispositivo deve ser marcado como aprovado sem saída real.
Runtimes do host e testes JVM/Flutter não validam SELinux, linker, exec no APK ou ABI do telefone.

## Comandos de desenvolvimento já disponíveis

```sh
python3 -m unittest discover -s ci/tests -v
flutter pub get
flutter test --no-pub
# Requer cache Kotlin compatível; somente testes JVM com Context de fixture:
python3 ci/tests/run_kotlin_installers.py --cache CAMINHO/modules-2/files-2.1
# Apenas Linux x86_64 com NDK configurado:
bash ci/runtime/build_node.sh
bash ci/runtime/build_git.sh
```

npm completo é empacotado, mas o comando de terminal limita operações a `--version`, `ls`
e `install ARQUIVO.tgz` offline com lifecycle desativado. Scripts, rede npm e ferramentas
nativas compiladas via npm exigem trabalho adicional. Não há apt/pkg/Termux integrado.
