import 'package:flutter/services.dart';
import 'core_v1.dart';

/// Uses the existing native executors. core=true enables stricter native guards.
class CoreNativeTools implements CoreTools {
  static const workspace = MethodChannel('qeltravyx/workspace');
  static const agent = MethodChannel('qeltravyx/agent');

  @override
  Future<Map<String, bool>> permissions(String project) async {
    final values = await agent.invokeMapMethod<String, dynamic>('getPermissions', {'project': project});
    return {for (final key in ['read', 'write', 'tests', 'download', 'web']) key: values?[key] == true};
  }

  @override
  Future<List<String>> list(String project) async {
    final result = <String>[];
    var entriesSeen = 0;
    Future<void> visit(String folder, int depth) async {
      final entries = await workspace.invokeListMethod<dynamic>('listEntries', {'project': project, 'file': folder, 'core': true}) ?? [];
      for (final raw in entries) {
        if (++entriesSeen > 200) throw StateError('Projeto excede 200 entradas; selecione um arquivo explícito.');
        final item = Map<String, dynamic>.from(raw as Map);
        final path = folder.isEmpty ? item['name'] as String : '$folder/${item["name"]}';
        if (item['isDirectory'] == true) {
          if (depth < 4) await visit(path, depth + 1);
        } else {
          try { CoreSafety.path(path); result.add(path); }
          on FormatException { /* Sensitive/unsupported paths are not exposed. */ }
        }
      }
    }
    await visit('', 1);
    return result;
  }

  @override
  Future<String> read(String project, String path) async {
    CoreSafety.path(path);
    final text = await workspace.invokeMethod<String>('readTextFile', {'project': project, 'file': path, 'core': true});
    if (text == null) throw StateError('Leitura nativa sem resposta.');
    return text;
  }

  @override
  Future<String> apply(String project, CoreProposal proposal) async {
    final result = await agent.invokeMapMethod<String, dynamic>('applyAgentPlan', {
      'project': project, 'core': true, 'consent': true,
      'changes': [{'path': proposal.path, 'expected': proposal.before, 'content': proposal.after}],
    });
    if (result?['backupId'] is! String) throw StateError('Aplicação sem confirmação de backup.');
    return result!['backupId'] as String;
  }

  @override
  Future<Map<String, Object?>> runPython(String project, String path, String runId, String expected) async {
    final result = await agent.invokeMapMethod<String, Object?>('runAgentPython', {
      'project': project, 'file': path, 'core': true, 'consent': true, 'runId': runId, 'expected': expected,
    });
    if (result == null) throw StateError('Executor sem resposta.');
    return result;
  }

  @override
  Future<void> cancelPython(String project, String runId) => agent.invokeMethod<void>('cancelCorePython', {'project': project, 'runId': runId});

  @override
  Future<void> remember(String project, CoreAction action, CorePhase phase) => agent.invokeMethod<void>('recordCoreMemory', {
    'project': project, 'action': action.name, 'phase': phase.name,
  });

  @override
  Future<List<String>> memory(String project) async => await agent.invokeListMethod<String>('getCoreMemory', {'project': project}) ?? [];
}
