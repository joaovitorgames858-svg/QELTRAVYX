/// Posicao do cursor no editor UTF-8, considerando que TextField usa offsets
/// UTF-16 para selecao. Contagem de coluna e feita na mesma unidade.
class EditorCursorPosition {
  const EditorCursorPosition({
    required this.line,
    required this.column,
    required this.totalLines,
  });

  final int line;
  final int column;
  final int totalLines;
}

EditorCursorPosition calculateEditorCursorPosition(String text, int offset) {
  final safeOffset = offset.clamp(0, text.length);
  var line = 1;
  var totalLines = 1;
  var lastBreak = -1;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 10) {
      totalLines++;
      if (i < safeOffset) {
        line++;
        lastBreak = i;
      }
    }
  }
  return EditorCursorPosition(
    line: line,
    column: safeOffset - lastBreak,
    totalLines: totalLines,
  );
}
