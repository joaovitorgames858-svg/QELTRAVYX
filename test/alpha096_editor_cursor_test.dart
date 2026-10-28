import 'package:flutter_test/flutter_test.dart';

import '../lib/editor_cursor_position.dart';

void main() {
  test('arquivo vazio fica na linha e coluna 1', () {
    final p = calculateEditorCursorPosition('', 0);
    expect(p.line, 1);
    expect(p.column, 1);
    expect(p.totalLines, 1);
  });

  test('cursor acompanha quebras e calcula coluna', () {
    final p = calculateEditorCursorPosition('abc\ndef\ng', 6);
    expect(p.line, 2);
    expect(p.column, 3);
    expect(p.totalLines, 3);
  });

  test('cursor negativo e alem do texto sao limitados', () {
    final a = calculateEditorCursorPosition('a\nb', -1);
    final b = calculateEditorCursorPosition('a\nb', 100);
    expect(a.line, 1);
    expect(a.column, 1);
    expect(b.line, 2);
    expect(b.column, 2);
  });
}
