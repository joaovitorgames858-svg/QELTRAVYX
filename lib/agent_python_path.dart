import 'agent_edit_plan.dart';

/// Verificacao de entrada no Flutter; Android revalida antes de executar.
class AgentPythonPath {
  static String validate(String value) {
    final path = value.trim();
    AgentFileEdit.validatePath(path);
    if (!path.toLowerCase().endsWith('.py')) {
      throw const FormatException('Selecione um arquivo Python .py.');
    }
    return path;
  }
}
