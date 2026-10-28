# QELTRAVYX — Alpha 0.1

Protótipo executável de terminal Android feito com Flutter (interface) e Kotlin (shell).

## Instalação no Termux

1. Instale/descompacte o arquivo ZIP em um diretório de sua escolha (ex.: ~/qeltravyx_kit).
2. Execute `bash ~/qeltravyx_kit/instalar.sh`.
3. Compile com:
   ```sh
   cd ~/QELTRAVYX
   flutter build apk --release --target-platform android-arm64
   cp build/app/outputs/flutter-apk/app-release.apk /sdcard/Download/QELTRAVYX-ALPHA-01.apk
   ```

## Testes básicos

Tente `pwd`, `id`, `ls`, `uname -a`, `date`, `echo QELTRAVYX`.
Tente `cd /system && pwd` e depois `pwd` em comando separado: a sessão shell mantém o diretório.

## Limitações reais (intencionais na Alpha 0.1)

- Shell de sistema: `/system/bin/sh`, **não** é o Bash do Termux.
- Comandos `pkg`, `apt`, `python`, `node`, `codex`, etc. não estarão disponíveis a menos que já façam parte do ambiente da própria aplicação — não presumir que existam.
- Saída em texto simples; escape ANSI, `vim`, `nano`, `top` e aplicações interativas ainda não têm emulação de terminal / PTY.
- Sem root e sem acesso às pastas privadas de outros apps.
- Reiniciar o shell encerra o processo principal; subprocessos criados por ele podem sobreviver, por ainda não haver gerenciamento completo de grupo de processos.
- Executar comandos perigosos (por exemplo `rm`) pode apagar dados acessíveis à própria aplicação. O usuário controla o shell.
- Sem serviço persistente: sessões podem terminar se o Android encerrar o aplicativo.
- O aplicativo não se conecta ao Termux instalado nem compartilha seus pacotes.
- A versão local release é para teste; publicação exige revisão de assinatura, privacidade, permissões e política da loja.

## Próximo desenvolvimento

1. Terminal real com PTY e controle de sinais, emulação ANSI, teclado com Ctrl/Esc/Tab.
2. Histórico persistente, várias sessões, SSH, gerenciador de arquivos.
3. Bootstrap Linux adequado ao identificador próprio, pacotes e ambiente Linux.
4. Integração com IA por API autorizada, chaves protegidas e confirmação de operações destrutivas.

## Referências técnicas

- https://github.com/termux/termux-app/wiki/Termux-Libraries
- https://github.com/termux/termux-app#forking
- https://developer.android.com/about/versions/10/behavior-changes-10
