import 'dart:convert';

import 'agent_edit_plan.dart';
import 'agent_error_diagnostic.dart';

const corePythonTemplate = '''def main():
    print("Olá, QELTRAVYX!")


if __name__ == "__main__":
    main()
''';

enum CoreAction { list, createPython, read, verifyPython, repairBom, diagnostics, unsupported }
enum CorePhase { idle, understanding, planning, inspecting, approval, applying, verifying, completed, failed, cancelled }

class CorePlan {
  const CorePlan(this.action, {this.path});
  final CoreAction action;
  final String? path;
}

/// Replaceable interpretation boundary. V1 is a finite grammar, not a model.
abstract interface class CoreInterpreter {
  CorePlan interpret(String request);
}

class PortugueseCoreInterpreter implements CoreInterpreter {
  @override
  CorePlan interpret(String request) {
    if (request.length > 500) return const CorePlan(CoreAction.unsupported);
    var text = request.trim().toLowerCase();
    const accents = {'á':'a', 'à':'a', 'ã':'a', 'â':'a', 'é':'e', 'ê':'e', 'í':'i', 'ó':'o', 'ô':'o', 'õ':'o', 'ú':'u', 'ç':'c'};
    accents.forEach((from, to) => text = text.replaceAll(from, to));
    if (RegExp(r'^(listar|liste|mostrar|mostre) (os )?arquivos( do projeto)?$').hasMatch(text)) {
      return const CorePlan(CoreAction.list);
    }
    if (RegExp(r'^(diagnostico(s)?|mostrar diagnosticos|mostre diagnosticos|memoria)$').hasMatch(text)) {
      return const CorePlan(CoreAction.diagnostics);
    }
    final grammars = <CoreAction, String>{
      CoreAction.createPython: r'^(?:criar|crie) (?:um )?(?:arquivo )?python de exemplo(?: (.+))?$',
      CoreAction.read: r'^(?:ler|leia) (?:o arquivo |arquivo )?(.+)$',
      CoreAction.verifyPython: r'^(?:verificar|verifique|testar|teste) (?:o arquivo |arquivo )?(?:python )?(.+)$',
      CoreAction.repairBom: r'^(?:reparar|repare|corrigir|corrija) (?:o arquivo |arquivo )?(.+)$',
    };
    for (final grammar in grammars.entries) {
      final match = RegExp(grammar.value).firstMatch(text);
      if (match == null) continue;
      // Capture the original spelling of the path (case-sensitive filesystem).
      final normalizedPath = match.group(1);
      var path = normalizedPath == null ? 'exemplo.py' : request.trim().substring(request.trim().length - normalizedPath.length);
      if (path.startsWith('"') && path.endsWith('"')) path = path.substring(1, path.length - 1);
      CoreSafety.path(path, python: grammar.key != CoreAction.read);
      return CorePlan(grammar.key, path: path);
    }
    return const CorePlan(CoreAction.unsupported);
  }
}

class CoreSafety {
  static void project(String name) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$').hasMatch(name)) {
      throw const FormatException('Projeto inválido.');
    }
  }

  static void path(String path, {bool python = false}) {
    AgentFileEdit.validatePath(path);
    if (RegExp(r'(secret|credential|token|password|senha|api[_-]?key|service.account|\.env)', caseSensitive: false).hasMatch(path)) {
      throw const FormatException('Arquivo potencialmente sensível bloqueado no CORE.');
    }
    if (python && !path.toLowerCase().endsWith('.py')) {
      throw const FormatException('Selecione um arquivo .py.');
    }
  }

  static String display(String text) {
    // Hide entire sensitive lines, including ordinary assignment/JSON formats.
    final redacted = text.replaceAll(RegExp(r'-----BEGIN[^\n]*PRIVATE KEY-----[\s\S]*?(?:-----END[^\n]*PRIVATE KEY-----|$)', caseSensitive: false), '[CHAVE PRIVADA OCULTADA]');
    final safe = redacted.split('\n').map((line) => RegExp(
      r'(secret|credential|token|password|senha|api[_-]?key|sk-[\w-]{12,}|bearer\s|PRIVATE KEY)',
      caseSensitive: false,
    ).hasMatch(line) ? '[CONTEÚDO SENSÍVEL OCULTADO]' : line).join('\n');
    return safe.replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]'), '');
  }

  static void content(String text) {
    if (utf8.encode(text).length > 12000) throw const FormatException('CORE limitado a 12 KB por arquivo.');
    if (display(text) != text.replaceAll('\r', '')) {
      throw const FormatException('Conteúdo sensível ou de controle: leitura/execução bloqueada no CORE.');
    }
  }
}

class CoreProposal {
  const CoreProposal(this.path, this.before, this.after);
  final String path;
  final String? before;
  final String after;
  String get preview => '$path\nANTES:\n${before ?? "(arquivo novo)"}\nDEPOIS:\n$after';
}

abstract interface class CoreTools {
  Future<Map<String, bool>> permissions(String project);
  Future<List<String>> list(String project);
  Future<String> read(String project, String path);
  Future<String> apply(String project, CoreProposal proposal);
  Future<Map<String, Object?>> runPython(String project, String path, String runId, String expected);
  Future<void> cancelPython(String project, String runId);
  Future<void> remember(String project, CoreAction action, CorePhase phase);
  Future<List<String>> memory(String project);
}

typedef CoreApproval = Future<bool> Function(String title, String preview);

class CoreEngine {
  CoreEngine(this.tools, {CoreInterpreter? interpreter, this.persistentWrites = false}) : interpreter = interpreter ?? PortugueseCoreInterpreter();
  final CoreTools tools;
  final bool persistentWrites;
  final CoreInterpreter interpreter;
  void Function()? onChanged;
  CorePhase phase = CorePhase.idle;
  String status = 'CORE V1 • local • tarefas estruturadas';
  String output = '';
  bool busy = false;
  bool _cancelled = false;
  String? _project;
  String? _runId;
  bool get canCancel => busy && const {
    CorePhase.understanding, CorePhase.planning, CorePhase.inspecting,
    CorePhase.approval, CorePhase.verifying,
  }.contains(phase);

  void _set(CorePhase value, String message) {
    phase = value;
    status = message;
    onChanged?.call();
  }

  Future<void> cancel() async {
    if (!canCancel) return;
    _cancelled = true;
    status = 'Cancelamento solicitado…';
    onChanged?.call();
    if (_runId != null && _project != null) {
      try { await tools.cancelPython(_project!, _runId!); }
      catch (_) { status = 'Cancelamento solicitado; executor limitado a 8 s.'; onChanged?.call(); }
    }
  }

  void _checkpoint() {
    if (_cancelled) throw const _CoreCancelled();
  }

  Future<void> _permission(String project, String kind) async {
    final allowed = await tools.permissions(project);
    _checkpoint();
    if (allowed['read'] != true || (kind != 'read' && allowed[kind] != true)) {
      throw StateError('Autorize leitura${kind == "read" ? "" : " e $kind"} neste projeto.');
    }
  }

  Future<void> submit(String project, String request, CoreApproval approve) async {
    if (busy) return;
    busy = true;
    _cancelled = false;
    _project = project;
    output = '';
    var action = CoreAction.unsupported;
    try {
      _set(CorePhase.understanding, 'Entendendo pedido…');
      CoreSafety.project(project);
      final plan = interpreter.interpret(request);
      action = plan.action;
      _set(CorePhase.planning, 'Planejando ação local…');
      if (action == CoreAction.unsupported) {
        output = 'Pedido ainda não suportado. Exemplos: listar arquivos; criar python de exemplo exemplo.py; ler exemplo.py; verificar exemplo.py; reparar exemplo.py; diagnósticos.';
      } else {
        await _permission(project, 'read');
        _set(CorePhase.inspecting, 'Inspecionando projeto autorizado…');
        if (action == CoreAction.diagnostics) {
          output = 'CORE V1 determinístico, sem rede ou modelo neural.\nPython usa o UID do app e não possui sandbox confiável.\nMemória: últimas 40 operações (sem conteúdo).\n${(await tools.memory(project)).join("\n")}';
        } else if (action == CoreAction.list) {
          final files = await tools.list(project);
          output = files.isEmpty ? 'Nenhum arquivo textual permitido.' : files.join('\n');
        } else {
          final path = plan.path!;
          CoreSafety.path(path, python: action != CoreAction.read);
          if (action == CoreAction.createPython) {
            final files = await tools.list(project);
            _checkpoint();
            if (files.contains(path)) throw StateError('Arquivo já existe; escolha outro nome.');
            await _apply(project, CoreProposal(path, null, corePythonTemplate), approve);
          } else {
            final source = await tools.read(project, path);
            _checkpoint();
            CoreSafety.content(source);
            if (action == CoreAction.read) {
              output = '$path\n$source';
            } else if (action == CoreAction.repairBom) {
              if (!source.startsWith('\uFEFF')) {
                output = 'Nenhum reparo determinístico seguro disponível. V1 só remove BOM UTF-8 inicial de Python, sem alterar a lógica.';
              } else {
                final header = source.split('\n').take(2).join('\n');
                final encoding = RegExp(r'coding[:=]\s*([-\w.]+)').firstMatch(header)?.group(1)?.toLowerCase().replaceAll('_', '-');
                if (encoding != null && encoding != 'utf-8' && encoding != 'utf8') {
                  throw StateError('Reparo recusado: declaração de codificação incompatível com UTF-8.');
                }
                await _apply(project, CoreProposal(path, source, source.substring(1)), approve);
              }
            } else {
              await _permission(project, 'tests');
              _set(CorePhase.approval, 'Aguardando consentimento para esta execução…');
              final accepted = await approve('Executar Python?', '$path\nSem sandbox confiável: o script pode acessar dados e rede com o UID do aplicativo. Limite: 8 segundos.\n\n$source');
              _checkpoint();
              if (!accepted) throw const _CoreCancelled();
              await _permission(project, 'tests');
              _runId = DateTime.now().microsecondsSinceEpoch.toString();
              _set(CorePhase.verifying, 'Executando Python local…');
              _checkpoint();
              final result = await tools.runPython(project, path, _runId!, source);
              _checkpoint();
              final code = result['exitCode'];
              final diagnostic = AgentErrorDiagnostic.summary(CoreSafety.display(result['output'] as String? ?? ''));
              output = 'Python: código $code${result["timedOut"] == true ? " • tempo esgotado" : ""}${result["truncated"] == true ? " • saída truncada" : ""}\n${CoreSafety.display(result["output"] as String? ?? "")}';
              if (code != 0 || result['timedOut'] == true || result['cancelled'] == true) {
                output += '\nDiagnóstico: $diagnostic';
                throw StateError('Verificação Python falhou; nenhuma correção foi aplicada.');
              }
            }
          }
        }
      }
      _checkpoint();
      _set(CorePhase.completed, action == CoreAction.unsupported ? 'Pedido não suportado' : 'Concluído');
    } on _CoreCancelled {
      _set(CorePhase.cancelled, 'Cancelado; nenhuma etapa seguinte será executada.');
    } catch (error) {
      final message = CoreSafety.display(error.toString());
      output = '$output\n$message'.trim();
      _set(CorePhase.failed, 'Falha • consulte o resultado');
    } finally {
      _runId = null;
      try { CoreSafety.project(project); await tools.remember(project, action, phase); }
      catch (_) { output = '$output\nMemória local indisponível; resultado não persistido.'; }
      busy = false;
      onChanged?.call();
    }
  }

  Future<void> _apply(String project, CoreProposal proposal, CoreApproval approve) async {
    await _permission(project, 'write');
    CoreSafety.content(proposal.after);
    if (!persistentWrites) {
      _set(CorePhase.approval, 'Proposta pronta • revise antes de aplicar');
      final accepted = await approve('Aplicar com backup?', proposal.preview);
      _checkpoint();
      if (!accepted) throw const _CoreCancelled();
    }
    await _permission(project, 'write');
    _set(CorePhase.applying, 'Aplicando com backup e proteção de conflito…');
    final backup = await tools.apply(project, proposal);
    // A dispatched write is atomic at the native boundary and cannot be undone by cancel.
    output = 'Aplicado: ${proposal.path}\nBackup: $backup';
    _set(CorePhase.verifying, 'Verificando conteúdo salvo…');
    await _permission(project, 'read');
    final actual = await tools.read(project, proposal.path);
    if (actual != proposal.after) throw StateError('Conteúdo salvo diverge da proposta; consulte o backup.');
    output += '\nConteúdo conferido. Para executar, envie: verificar ${proposal.path}';
  }
}

class _CoreCancelled implements Exception { const _CoreCancelled(); }
