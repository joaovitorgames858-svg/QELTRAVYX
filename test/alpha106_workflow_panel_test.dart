import 'package:flutter_test/flutter_test.dart';

import '../lib/agent_cycle_log.dart';
import '../lib/agent_workflow_panel.dart';

AgentCycleEntry entry(int exitCode) => AgentCycleEntry(
  project: 'teste_python',
  path: 'erro_pro105.py',
  exitCode: exitCode,
  timedOut: false,
  truncated: false,
  diagnostic: exitCode == 0 ? 'Teste concluido' : 'NameError',
  timestamp: DateTime(2026, 10, 27),
);

AgentWorkflowPhase phase({
  String? project = 'teste_python',
  List<AgentCycleEntry> tests = const [],
  int proposalCount = 0,
  bool waitingRetest = false,
  bool busy = false,
}) => AgentWorkflowStatus.evaluate(
  project: project,
  tests: tests,
  proposalCount: proposalCount,
  waitingRetest: waitingRetest,
  busy: busy,
).phase;

void main() {
  test('sem projeto indica selecao', () {
    expect(phase(project: null), AgentWorkflowPhase.chooseProject);
  });
  test('nova sessao indica prompt', () {
    expect(phase(), AgentWorkflowPhase.preparePrompt);
  });
  test('proposta pendente exige revisao antes do teste', () {
    expect(
      phase(tests: [entry(1)], proposalCount: 1),
      AgentWorkflowPhase.reviewProposal,
    );
  });
  test('depois de aplicar codigo, solicita reteste', () {
    expect(
      phase(tests: [entry(1)], waitingRetest: true),
      AgentWorkflowPhase.testCode,
    );
  });
  test('erro indica correcao', () {
    expect(phase(tests: [entry(1)]), AgentWorkflowPhase.repairError);
  });
  test('sucesso indica conclusao mesmo apos reteste', () {
    expect(
      phase(tests: [entry(0)], waitingRetest: true),
      AgentWorkflowPhase.completed,
    );
  });
  test('operacao ocupa painel sem autorizar execucao', () {
    expect(phase(busy: true), AgentWorkflowPhase.working);
  });
}
