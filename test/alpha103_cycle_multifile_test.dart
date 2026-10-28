import 'package:flutter_test/flutter_test.dart';

import '../lib/agent_cycle_log.dart';

void main() {
  test('limite de reparos por arquivo continua apos alternar projetos', () {
    final log = AgentCycleLog();
    for (var i = 0; i < AgentCycleLog.maxRepairAttempts; i++) {
      log.repairApplied('teste_python', 'laboratorio095/erro099.py');
    }
    expect(
      log.canApplyRepair('teste_python', 'laboratorio095/erro099.py'),
      isFalse,
    );
    log.repairApplied('teste_python', 'laboratorio095/outro.py');
    log.repairApplied('outro_projeto', 'laboratorio095/erro099.py');
    expect(log.repairsFor('teste_python', 'laboratorio095/erro099.py'), 3);
    expect(
      log.canApplyRepair('teste_python', 'laboratorio095/erro099.py'),
      isFalse,
    );
    expect(log.repairsFor('teste_python', 'laboratorio095/outro.py'), 1);
  });

  test('teste aprovado libera apenas o arquivo correspondente', () {
    final log = AgentCycleLog();
    log.repairApplied('teste_python', 'a.py');
    log.repairApplied('teste_python', 'b.py');
    log.record(
      project: 'teste_python',
      path: 'b.py',
      exitCode: 0,
      timedOut: false,
      truncated: false,
      diagnostic: 'OK',
    );
    expect(log.repairsFor('teste_python', 'a.py'), 1);
    expect(log.repairsFor('teste_python', 'b.py'), 0);
    expect(log.latestFor('teste_python', 'b.py')?.passed, isTrue);
  });

  test('timeout ou saida truncada nao reiniciam ciclo', () {
    final log = AgentCycleLog();
    log.repairApplied('teste_python', 'a.py');
    log.record(
      project: 'teste_python',
      path: 'a.py',
      exitCode: 0,
      timedOut: true,
      truncated: false,
      diagnostic: 'Timeout',
    );
    log.record(
      project: 'teste_python',
      path: 'a.py',
      exitCode: 0,
      timedOut: false,
      truncated: true,
      diagnostic: 'Truncado',
    );
    expect(log.repairsFor('teste_python', 'a.py'), 1);
  });

  test('historico mantem no maximo doze entradas', () {
    final log = AgentCycleLog();
    for (var i = 0; i < 20; i++) {
      log.record(
        project: 'teste_python',
        path: 'teste$i.py',
        exitCode: 1,
        timedOut: false,
        truncated: false,
        diagnostic: 'Falhou',
      );
    }
    final entries = log.forProject('teste_python');
    expect(entries.length, 12);
    expect(entries.first.path, 'teste19.py');
    expect(entries.last.path, 'teste8.py');
  });
}
