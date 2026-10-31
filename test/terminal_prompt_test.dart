import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

void main() {
  test('real Bash PTY prompt renders green path, neutral dollar and correct cursor', () {
    // Captured from the shipped rc using test/runtime/test_bash_prompt.py.
    // That suite also checks the capture against a newly spawned real Bash PTY.
    final prompt = File('test/fixtures/terminal_prompt_ux_v3.ansi')
        .readAsStringSync();
    final terminal = Terminal()
      ..resize(40, 5)
      ..write(prompt);
    final line = terminal.buffer.lines[0];
    expect(terminal.buffer.getText(), startsWith('~ \$ '));
    expect(line.getForeground(0) & CellColor.valueMask, 2); // ANSI green
    expect(line.getAttributes(0) & CellAttr.bold, CellAttr.bold);
    expect(line.getForeground(2), 0); // SGR reset before $
    expect(line.getAttributes(2) & CellAttr.bold, 0);
    expect(terminal.buffer.cursorX, 4);
    terminal.write('pwd\r\n');
    expect(terminal.buffer.getText(), startsWith('~ \$ pwd\n'));
  });
}
