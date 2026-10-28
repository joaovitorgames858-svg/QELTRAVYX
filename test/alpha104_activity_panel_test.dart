import 'package:flutter_test/flutter_test.dart';

import '../lib/agent_activity_panel.dart';
import '../lib/agent_cycle_log.dart';

void main() {
  test('resume sucessos, falhas e propostas sem armazenar codigo', () {
    final log = AgentCycleLog();
    log.record(
      project: 'teste_python',
      path: 'laboratorio095/gerado098.py',
      exitCode: 0,
      timedOut: false,
      truncated: false,
      diagnostic: 'Teste concluido',
    );
    log.record(
      project: 'teste_python',
      path: 'laboratorio095/erro099.py',
      exitCode: 1,
      timedOut: false,
      truncated: false,
      diagnostic: 'NameError',
    );
    final summary = AgentActivitySummary.from(
      entries: log.forProject('teste_python'),
      pendingFiles: 1,
    );
    expect(summary.totalTests, 2);
    expect(summary.passedTests, 1);
    expect(summary.failedTests, 1);
    expect(summary.pendingFiles, 1);
  });
}
