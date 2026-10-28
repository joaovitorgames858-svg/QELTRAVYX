import 'package:flutter_test/flutter_test.dart';

import '../lib/agent_edit_plan.dart';

void main() {
  test('aceita proposta de arquivo Python', () {
    final plan = AgentEditPlan.parse(
      '{"summary":"Criar script","files":[{"path":"src/main.py","content":"print(42)\\n"}]}',
    );
    expect(plan.files.single.path, 'src/main.py');
    expect(plan.summary, 'Criar script');
  });
  test('aceita JSON delimitado em bloco', () {
    final plan = AgentEditPlan.parse(
      '```json\n{"summary":"ok","files":[{"path":"app.json","content":"{}"}]}\n```',
    );
    expect(plan.files.single.path, 'app.json');
  });
  test('bloqueia traversal e arquivos executaveis', () {
    for (final p in [
      '../config.json',
      '/tmp/t.py',
      'data/../../app.py',
      'run.apk',
      'foo\\bar.py',
      'my.env',
    ]) {
      expect(() => AgentFileEdit.validatePath(p), throwsFormatException);
    }
  });
  test('bloqueia mais de tres arquivos', () {
    final files = List.generate(
      4,
      (n) => '{"path":"f$n.py","content":""}',
    ).join(',');
    expect(
      () => AgentEditPlan.parse('{"summary":"ok","files":[$files]}'),
      throwsFormatException,
    );
  });
  test('bloqueia JSON nao estruturado', () {
    expect(
      () => AgentEditPlan.parse('aqui esta seu codigo'),
      throwsFormatException,
    );
  });
}
