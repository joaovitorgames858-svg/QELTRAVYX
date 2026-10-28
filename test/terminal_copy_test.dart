import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';
import 'package:qeltravyx/terminal_copy.dart';

void main() {
  test('copiar terminal omite escapes ANSI', () {
    final terminal = Terminal(maxLines: 100);
    terminal.write('\x1b[32mQELTRAVYX_OK\x1b[0m\r\n');
    final texto = qeltravyxCopyTerminalText(terminal);
    expect(texto, contains('QELTRAVYX_OK'));
    expect(texto, isNot(contains('\x1b')));
    expect(texto, isNot(contains('\x08')));
  });
}
