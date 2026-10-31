import 'dart:async';

import 'package:flutter/services.dart';

import 'core_native_tools.dart';
import 'core_v1.dart';

/// Host adapter for the bundled, tested Python task engine. V1 remains available
/// for its explicit, individually approved Python runner and BOM repair.
class CoreV2Engine extends CoreEngine {
  CoreV2Engine({CoreTools? tools})
    : super(tools ?? CoreNativeTools(), persistentWrites: true) {
    status = 'CORE V2 • planos locais • modelos externos opcionais';
  }
  static const channel = MethodChannel('qeltravyx/core-v2');
  static const progress = EventChannel('qeltravyx/core-v2-progress');
  String? _activeProject;
  String? _activeRun;
  bool _v2Cancelled = false;
  Map<String, dynamic>? diagnostic;
  Map<String, dynamic>? persistenceDiagnostic;

  @override
  bool get canCancel => _activeRun != null || super.canCancel;

  @override
  Future<void> cancel() async {
    if (_activeRun == null) return super.cancel();
    _v2Cancelled = true;
    status = 'Cancelamento solicitado…';
    onChanged?.call();
    try {
      await channel.invokeMethod<void>('cancelCoreV2', {
        'project': _activeProject,
        'runId': _activeRun,
      });
    } catch (_) {
      status = 'Cancelamento solicitado; aguardando limite do executor.';
      onChanged?.call();
    }
  }

  @override
  Future<void> submit(
    String project,
    String request,
    CoreApproval approve,
  ) async {
    if (busy) return;
    diagnostic = null;
    persistenceDiagnostic = null;
    // Preserve explicitly supported V1 commands. All compound/unknown requests
    // go through V2, which reports unsupported requests without claiming success.
    CorePlan legacy;
    try {
      legacy = interpreter.interpret(request);
    } on FormatException {
      legacy = const CorePlan(CoreAction.unsupported);
    }
    if (const {
      CoreAction.createPython,
      CoreAction.verifyPython,
      CoreAction.repairBom,
    }.contains(legacy.action)) {
      return super.submit(project, request, approve);
    }
    busy = true;
    output = '';
    _v2Cancelled = false;
    _activeProject = project;
    _activeRun = DateTime.now().microsecondsSinceEpoch.toString();
    phase = CorePhase.planning;
    status = 'Planejando tarefa…';
    onChanged?.call();
    StreamSubscription<dynamic>? subscription;
    try {
      CoreSafety.project(project);
      subscription = progress.receiveBroadcastStream().listen(
        (dynamic raw) {
          final event = Map<String, dynamic>.from(raw as Map);
          if (event['project'] != project ||
              event['runId'] != _activeRun ||
              _v2Cancelled)
            return;
          status = CoreSafety.display(event['message'] as String? ?? '');
          phase = _phase(event['phase'] as String? ?? '');
          onChanged?.call();
        },
        onError: (Object _) {
          /* Final result still arrives on the method channel. */
        },
      );
      Future<Map<String, dynamic>> run(bool approved) async {
        final result = await channel.invokeMapMethod<String, dynamic>(
          'runCoreV2',
          {
            'project': project,
            'runId': _activeRun,
            'request': request,
            'approved': approved,
          },
        );
        if (result == null) throw StateError('CORE V2 sem resposta.');
        return result;
      }

      var result = await run(false);
      if (result['phase'] == 'approval' && !_v2Cancelled) {
        phase = CorePhase.approval;
        status = 'Aguardando aprovação específica';
        onChanged?.call();
        final accepted = await approve(
          'Autorizar operação?',
          CoreSafety.display(result['output'] as String? ?? ''),
        );
        if (accepted && !_v2Cancelled) {
          result = await run(true);
        } else {
          await cancel();
        }
      }
      diagnostic = _diagnostic(result['diagnostic']);
      persistenceDiagnostic = _diagnostic(result['persistence_diagnostic']);
      if (_v2Cancelled) {
        if (diagnostic?['code'] == 'approval_required') {
          diagnostic = Map<String, dynamic>.unmodifiable({
            ...?diagnostic,
            'code': 'cancelled',
            'message': 'Aprovação recusada ou cancelada',
          });
        }
        phase = CorePhase.cancelled;
        status = 'Cancelado; consulte o estado e os backups.';
        output = CoreSafety.display(result['output'] as String? ?? '');
      } else {
        phase = _phase(result['phase'] as String? ?? 'failed');
        output = CoreSafety.display(result['output'] as String? ?? '');
        status = switch (result['phase']) {
          'completed' => 'Concluído',
          'awaiting_model' => 'AGUARDANDO MODELO • arquivos preservados',
          'planned' => 'Plano salvo • implementação pendente',
          'awaiting_tests' => 'Arquivos conferidos • testes pendentes',
          'unsupported' => 'Pedido não suportado',
          'cancelled' => 'Cancelado',
          _ => 'Falha • consulte o resultado',
        };
      }
    } catch (error) {
      phase = _v2Cancelled ? CorePhase.cancelled : CorePhase.failed;
      status = _v2Cancelled
          ? 'Cancelado; consulte o estado e os backups.'
          : 'CORE V2 indisponível • consulte o resultado';
      output = CoreSafety.display(error.toString());
    } finally {
      // Detach progress immediately, but do not gate the final result on the
      // broadcast subscription's cleanup Future (which may use another zone).
      // EventChannel reports platform teardown errors through FlutterError.
      unawaited(subscription?.cancel());
      _activeRun = null;
      _activeProject = null;
      busy = false;
      onChanged?.call();
    }
  }

  Map<String, dynamic>? _diagnostic(dynamic value) {
    if (value is! Map) return null;
    return Map<String, dynamic>.unmodifiable(
      value.map((dynamic key, dynamic item) => MapEntry(key.toString(), item)),
    );
  }

  CorePhase _phase(String value) => switch (value) {
    'planning' || 'planned' => CorePhase.planning,
    'applying' || 'correcting' => CorePhase.applying,
    'observing' => CorePhase.inspecting,
    'verifying' || 'awaiting_tests' || 'awaiting_model' => CorePhase.verifying,
    'approval' => CorePhase.approval,
    'completed' => CorePhase.completed,
    'cancelled' => CorePhase.cancelled,
    _ => CorePhase.failed,
  };
}
