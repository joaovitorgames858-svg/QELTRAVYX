import 'package:flutter_test/flutter_test.dart';

import '../lib/agent_cycle_log.dart';

void main() {
  test('historico separa projetos e exibe ordem recente primeiro', () {
    final log = AgentCycleLog();
    log.record(
      project: 'A',
      path: 'main.py',
      exitCode: 1,
      timedOut: false,
      truncated: false,
      diagnostic: 'NameError',
    );
    log.record(
      project: 'B',
      path: 'main.py',
      exitCode: 0,
      timedOut: false,
      truncated: false,
      diagnostic: 'OK',
    );
    log.record(
      project: 'A',
      path: 'teste.py',
      exitCode: 0,
      timedOut: false,
      truncated: false,
      diagnostic: 'OK',
    );
    expect(log.forProject('A').map((e) => e.path).toList(), <String>[
      'teste.py',
      'main.py',
    ]);
    expect(log.forProject('B').length, 1);
  });

  test('limite de 12 entradas e resumo curto sem linhas', () {
    final log = AgentCycleLog();
    for (var i = 0; i < 15; i++) {
      log.record(
        project: 'P',
        path: '$i.py',
        exitCode: 0,
        timedOut: false,
        truncated: false,
        diagnostic: 'linha1\nlinha2',
      );
    }
    expect(log.forProject('P').length, 12);
    expect(log.forProject('P').first.path, '14.py');
    expect(log.forProject('P').last.path, '3.py');
    expect(log.forProject('P').first.diagnostic, 'linha1 linha2');
  });

  test('permite ate tres correcoes do mesmo arquivo', () {
    final log = AgentCycleLog();
    for (var i = 0; i < 3; i++) {
      expect(log.canApplyRepair('P', 'erro.py'), true);
      log.repairApplied('P', 'erro.py');
    }
    expect(log.canApplyRepair('P', 'erro.py'), false);
    expect(() => log.repairApplied('P', 'erro.py'), throwsStateError);
  });

  test(
    'teste falho nao reseta ciclo; teste correto do mesmo arquivo reseta',
    () {
      final log = AgentCycleLog();
      log.repairApplied('P', 'erro.py');
      log.record(
        project: 'P',
        path: 'outro.py',
        exitCode: 0,
        timedOut: false,
        truncated: false,
        diagnostic: 'OK',
      );
      expect(log.repairsFor('P', 'erro.py'), 1);
      log.record(
        project: 'P',
        path: 'erro.py',
        exitCode: 1,
        timedOut: false,
        truncated: false,
        diagnostic: 'NameError',
      );
      expect(log.repairsFor('P', 'erro.py'), 1);
      log.record(
        project: 'P',
        path: 'erro.py',
        exitCode: 0,
        timedOut: false,
        truncated: false,
        diagnostic: 'OK',
      );
      expect(log.repairsFor('P', 'erro.py'), 0);
    },
  );

  test('timeout e saida truncada nunca equivalem a sucesso', () {
    final log = AgentCycleLog();
    log.repairApplied('P', 'erro.py');
    log.record(
      project: 'P',
      path: 'erro.py',
      exitCode: 0,
      timedOut: true,
      truncated: false,
      diagnostic: 'timeout',
    );
    log.record(
      project: 'P',
      path: 'erro.py',
      exitCode: 0,
      timedOut: false,
      truncated: true,
      diagnostic: 'truncado',
    );
    expect(log.repairsFor('P', 'erro.py'), 1);
    expect(log.forProject('P').every((e) => !e.passed), true);
  });
}
