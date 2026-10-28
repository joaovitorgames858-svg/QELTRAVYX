import 'package:flutter/material.dart';

import 'agent_cycle_log.dart';

/// Estado de orientacao visual. Nunca executa arquivos ou consultas de rede.
enum AgentWorkflowPhase {
  chooseProject,
  preparePrompt,
  working,
  reviewProposal,
  testCode,
  repairError,
  completed,
}

class AgentWorkflowStatus {
  final AgentWorkflowPhase phase;
  final String title;
  final String detail;

  const AgentWorkflowStatus(this.phase, this.title, this.detail);

  static AgentWorkflowStatus evaluate({
    required String? project,
    required List<AgentCycleEntry> tests,
    required int proposalCount,
    required bool waitingRetest,
    required bool busy,
  }) {
    if (project == null) {
      return const AgentWorkflowStatus(
        AgentWorkflowPhase.chooseProject,
        'Selecionar projeto',
        'Escolha um projeto e confira as permissoes salvas.',
      );
    }
    if (busy) {
      return const AgentWorkflowStatus(
        AgentWorkflowPhase.working,
        'Operacao em andamento',
        'Acompanhe o resultado antes de iniciar outra operacao.',
      );
    }
    if (proposalCount > 0) {
      return const AgentWorkflowStatus(
        AgentWorkflowPhase.reviewProposal,
        'Revisar alteracoes propostas',
        'Abra a previa e, somente apos conferir, aplique com backup.',
      );
    }
    final latest = tests.isEmpty ? null : tests.first;
    if (waitingRetest && (latest == null || !latest.passed)) {
      return const AgentWorkflowStatus(
        AgentWorkflowPhase.testCode,
        'Retestar codigo corrigido',
        'Revise o script salvo e confirme a execucao manual do Python.',
      );
    }
    if (latest != null && !latest.passed) {
      return const AgentWorkflowStatus(
        AgentWorkflowPhase.repairError,
        'Corrigir erro detectado',
        'Use Preparar correcao para obter uma proposta restrita ao arquivo.',
      );
    }
    if (latest != null && latest.passed) {
      return const AgentWorkflowStatus(
        AgentWorkflowPhase.completed,
        'Ultimo teste aprovado',
        'O teste terminou com sucesso. Voce pode iniciar outra tarefa.',
      );
    }
    return const AgentWorkflowStatus(
      AgentWorkflowPhase.preparePrompt,
      'Descrever a tarefa',
      'Informe um prompt, escolha Gerar / editar codigo e revise a proposta.',
    );
  }
}

class AgentWorkflowPanel extends StatelessWidget {
  final String? project;
  final List<AgentCycleEntry> tests;
  final int proposalCount;
  final bool waitingRetest;
  final bool busy;

  const AgentWorkflowPanel({
    super.key,
    required this.project,
    required this.tests,
    required this.proposalCount,
    required this.waitingRetest,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    final status = AgentWorkflowStatus.evaluate(
      project: project,
      tests: tests,
      proposalCount: proposalCount,
      waitingRetest: waitingRetest,
      busy: busy,
    );
    return Card(
      color: const Color(0xFF152630),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Row(
              children: <Widget>[
                Icon(Icons.route_outlined, color: Color(0xFF92DFC0)),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Fluxo guiado · AGENT IA',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              status.title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              status.detail,
              style: const TextStyle(color: Color(0xFFB7C8D9), fontSize: 12),
            ),
            const SizedBox(height: 8),
            const Text(
              'Proposta → Revisao → Backup → Teste → Correcao → Reteste',
              style: TextStyle(color: Color(0xFF92DFC0), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
