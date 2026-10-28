import 'package:xterm2/xterm.dart';

/// Exporta o texto processado pelo emulador, e nao o fluxo bruto do PTY.
/// O buffer principal inclui o historico de rolagem, sem sequencias ANSI.
String qeltravyxCopyTerminalText(Terminal terminal) {
  return terminal.mainBuffer.getText().trimRight();
}
