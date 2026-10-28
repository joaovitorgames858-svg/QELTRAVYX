/// Historico de execucoes locais nesta abertura do AGENT IA.
/// Nunca armazena credenciais, codigo-fonte ou traceback completo.
class AgentCycleEntry {
  final String project;
  final String path;
  final int exitCode;
  final bool timedOut;
  final bool truncated;
  final String diagnostic;
  final DateTime timestamp;

  const AgentCycleEntry({
    required this.project,
    required this.path,
    required this.exitCode,
    required this.timedOut,
    required this.truncated,
    required this.diagnostic,
    required this.timestamp,
  });

  bool get passed => !timedOut && !truncated && exitCode == 0;

  String get resultLabel => timedOut
      ? 'Tempo esgotado'
      : truncated
      ? 'Saida truncada'
      : passed
      ? 'OK (0)'
      : 'Falhou ($exitCode)';
}

// QELTRAVYX_CICLO103_V1: controles independentes por projeto e arquivo.
class AgentCycleLog {
  static const maxEntries = 12;
  static const maxRepairAttempts = 3;

  final List<AgentCycleEntry> _entries = <AgentCycleEntry>[];
  final Map<String, int> _repairsByFile = <String, int>{};

  String _key(String project, String path) => '$project::$path';

  List<AgentCycleEntry> forProject(String? project) =>
      List<AgentCycleEntry>.unmodifiable(
        _entries.where((entry) => entry.project == project).toList().reversed,
      );

  int repairsFor(String project, String path) =>
      _repairsByFile[_key(project, path)] ?? 0;

  bool canApplyRepair(String project, String path) =>
      repairsFor(project, path) < maxRepairAttempts;

  /// Registrar somente quando a gravacao com backup for confirmada pelo Android.
  void repairApplied(String project, String path) {
    if (!canApplyRepair(project, path)) {
      throw StateError('Limite de tres reparos por ciclo atingido.');
    }
    final key = _key(project, path);
    _repairsByFile[key] = repairsFor(project, path) + 1;
  }

  /// Retorna o teste mais recente de um arquivo, sem armazenar codigo ou token.
  AgentCycleEntry? latestFor(String project, String path) {
    for (final entry in _entries.reversed) {
      if (entry.project == project && entry.path == path) return entry;
    }
    return null;
  }

  void record({
    required String project,
    required String path,
    required int exitCode,
    required bool timedOut,
    required bool truncated,
    required String diagnostic,
    DateTime? now,
  }) {
    final safeDiagnostic = diagnostic.replaceAll(RegExp(r'[\r\n\t]+'), ' ');
    _entries.add(
      AgentCycleEntry(
        project: project,
        path: path,
        exitCode: exitCode,
        timedOut: timedOut,
        truncated: truncated,
        diagnostic: safeDiagnostic.length > 180
            ? safeDiagnostic.substring(0, 180)
            : safeDiagnostic,
        timestamp: now ?? DateTime.now(),
      ),
    );
    if (_entries.length > maxEntries) _entries.removeAt(0);

    // So zera o contador do arquivo testado quando ele conclui com sucesso.
    // Um teste aprovado em outro arquivo nao libera reparos bloqueados.
    if (exitCode == 0 && !timedOut && !truncated) {
      _repairsByFile.remove(_key(project, path));
    }
  }
}
