import 'package:flutter/material.dart';

import 'agent_cycle_log.dart';

/// Resumo de atividades da sessao atual. Nao persiste codigo nem credenciais.
class AgentActivitySummary {
  final int totalTests;
  final int passedTests;
  final int failedTests;
  final int pendingFiles;

  const AgentActivitySummary({
    required this.totalTests,
    required this.passedTests,
    required this.failedTests,
    required this.pendingFiles,
  });

  factory AgentActivitySummary.from({
    required List<AgentCycleEntry> entries,
    required int pendingFiles,
  }) {
    final passed = entries.where((e) => e.passed).length;
    return AgentActivitySummary(
      totalTests: entries.length,
      passedTests: passed,
      failedTests: entries.length - passed,
      pendingFiles: pendingFiles,
    );
  }
}

/// Painel somente de leitura. Mantem as operacoes existentes inalteradas.
class AgentActivityPanel extends StatelessWidget {
  final String? project;
  final List<AgentCycleEntry> entries;
  final List<String> pendingFiles;
  final String lastStatus;

  const AgentActivityPanel({
    super.key,
    required this.project,
    required this.entries,
    required this.pendingFiles,
    required this.lastStatus,
  });

  @override
  Widget build(BuildContext context) {
    final summary = AgentActivitySummary.from(
      entries: entries,
      pendingFiles: pendingFiles.length,
    );
    final backupMatch = RegExp(r'Backup:\s*([A-Za-z0-9_-]+)')
        .firstMatch(lastStatus);
    final lastTest = entries.isEmpty ? null : entries.first;

    return Card(
      color: const Color(0xFF15272D),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Row(
              children: <Widget>[
                Icon(
                  Icons.dashboard_customize_outlined,
                  color: Color(0xFF92DFC0),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Painel de atividades IA',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              project == null
                  ? 'Selecione um projeto para acompanhar as atividades.'
                  : 'Projeto: $project • dados desta sessao',
              style: const TextStyle(color: Color(0xFFB7C8D9)),
            ),
            if (project != null) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: <Widget>[
                  Chip(label: Text('Testes: ${summary.totalTests}')),
                  Chip(label: Text('OK: ${summary.passedTests}')),
                  Chip(label: Text('Falhas: ${summary.failedTests}')),
                  Chip(label: Text('Em revisao: ${summary.pendingFiles}')),
                ],
              ),
              if (lastTest != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  'Ultimo teste: ${lastTest.path} — ${lastTest.resultLabel}',
                  style: const TextStyle(color: Color(0xFFB7C8D9)),
                ),
              ],
              if (pendingFiles.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  'Proposta pendente: ${pendingFiles.join(', ')}',
                  style: const TextStyle(color: Color(0xFFB7C8D9)),
                ),
              ],
              if (backupMatch != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  'Backup informado nesta sessao: ${backupMatch.group(1)}',
                  style: const TextStyle(color: Color(0xFFB7C8D9)),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
