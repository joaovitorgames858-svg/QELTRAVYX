import 'dart:convert';

/// Plano limitado a escrita de arquivos de texto. Nunca executa comandos.
class AgentFileEdit {
  const AgentFileEdit({required this.path, required this.content});
  final String path;
  final String content;

  static final RegExp _part = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,70}$');

  static void validatePath(String path) {
    if (path.isEmpty ||
        path.length > 180 ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path.contains('..') ||
        path.contains('\u0000')) {
      throw const FormatException('Caminho de arquivo invalido.');
    }
    final components = path.split('/');
    if (components.length > 4 || components.any((c) => !_part.hasMatch(c))) {
      throw const FormatException('Nome ou profundidade de caminho invalido.');
    }
    if (!RegExp(
      r'\.(py|sh|json|txt)$',
      caseSensitive: false,
    ).hasMatch(components.last)) {
      throw const FormatException('Extensao nao permitida.');
    }
  }
}

class AgentEditPlan {
  const AgentEditPlan({required this.summary, required this.files});
  final String summary;
  final List<AgentFileEdit> files;

  static AgentEditPlan parse(String answer) {
    var body = answer.trim();
    if (body.startsWith('```')) {
      final start = body.indexOf('\n');
      final end = body.lastIndexOf('```');
      if (start < 0 || end <= start) {
        throw const FormatException('JSON da IA incompleto.');
      }
      body = body.substring(start + 1, end).trim();
    }
    final parsed = jsonDecode(body);
    if (parsed is! Map ||
        parsed['summary'] is! String ||
        parsed['files'] is! List) {
      throw const FormatException('A IA nao retornou um plano JSON valido.');
    }
    final rawFiles = parsed['files'] as List;
    if (rawFiles.isEmpty || rawFiles.length > 3) {
      throw const FormatException('O plano precisa ter de 1 a 3 arquivos.');
    }
    final seen = <String>{};
    final edits = <AgentFileEdit>[];
    for (final item in rawFiles) {
      if (item is! Map ||
          item['path'] is! String ||
          item['content'] is! String) {
        throw const FormatException('Arquivo com formato incorreto.');
      }
      final path = item['path'] as String;
      final content = item['content'] as String;
      AgentFileEdit.validatePath(path);
      if (!seen.add(path.toLowerCase())) {
        throw const FormatException('Arquivo repetido no plano.');
      }
      if (utf8.encode(content).length > 12000) {
        throw const FormatException('Arquivo proposto maior que 12 KB.');
      }
      edits.add(AgentFileEdit(path: path, content: content));
    }
    final summary = parsed['summary'] as String;
    if (summary.length > 3000) {
      throw const FormatException('Resumo excessivamente longo.');
    }
    return AgentEditPlan(summary: summary, files: edits);
  }
}
