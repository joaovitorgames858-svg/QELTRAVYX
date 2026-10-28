import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent_llm_client.dart';
import 'agent_edit_plan.dart';
import 'agent_python_path.dart';
import 'agent_error_diagnostic.dart';
import 'agent_cycle_log.dart';
import 'agent_activity_panel.dart';
import 'agent_pro_hub.dart';
import 'agent_workflow_panel.dart';
import 'agent_python_picker.dart';

/// Alpha 0.9.7: base de interface e autorização do futuro AGENT IA.
/// Não conecta a modelo, não baixa arquivos e não executa comandos nesta etapa.
class QeltravyxAgentPage extends StatefulWidget {
  const QeltravyxAgentPage({super.key});

  @override
  State<QeltravyxAgentPage> createState() => _QeltravyxAgentPageState();
}

class _QeltravyxAgentPageState extends State<QeltravyxAgentPage> {
  static const _workspace = MethodChannel('qeltravyx/workspace');
  static const _agent = MethodChannel('qeltravyx/agent');
  static const _mint = Color(0xFF43E7AB);

  final GlobalKey _proposalSectionKey = GlobalKey();
  final _prompt = TextEditingController();
  final _scriptToRun = TextEditingController(
    text: 'laboratorio095/gerado098.py',
  );
  bool _runningTest = false;
  String _testStatus = 'Execucao manual disponivel para scripts revisados.';
  String _testOutput = '';
  // QELTRAVYX_ALPHA101_CYCLE: historico apenas nesta abertura da tela.
  final AgentCycleLog _cycleLog = AgentCycleLog();
  String? _postApplyPath;
  String? _postApplyProject;
  String? _lastFailedScript;
  String? _lastFailedProject;
  String? _repairTarget;
  String? _repairProject;
  String _repairPrompt = '';
  final List<Map<String, Object?>> _stagedWrites = <Map<String, Object?>>[];
  String? _stagedProject;
  String _stagedPrompt = '';
  String _stagedSummary = '';
  final _apiKey = TextEditingController();
  final _model = TextEditingController(text: 'gpt-6-luna');
  bool _runningAi = false;
  String _aiAnswer = '';
  String _aiStatus = 'Aguardando prompt e chave de API.';
  String? _sourceApprovalProject;
  List<String> _projects = <String>[];
  String? _project;
  bool _loading = false;
  bool _read = false;
  bool _write = false;
  bool _downloads = false;
  bool _tests = false;
  bool _changed = false;
  String _message = 'Selecione um projeto para definir as permissões.';

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  @override
  void dispose() {
    _prompt.dispose();
    _scriptToRun.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _loadProjects() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final names = await _workspace.invokeListMethod<String>('listProjects');
      if (!mounted) return;
      setState(() {
        _projects = names ?? <String>[];
        _message = _projects.isEmpty
            ? 'Crie um projeto em PROJETOS antes de configurar o agente.'
            : 'Selecione um projeto. Nenhum arquivo será alterado.';
      });
    } on PlatformException catch (error) {
      if (mounted)
        setState(() => _message = error.message ?? 'Falha ao listar projetos.');
    } catch (error) {
      if (mounted)
        setState(() => _message = 'Falha ao listar projetos: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectProject(String? name) async {
    _sourceApprovalProject = null;
    _stagedWrites.clear();
    _stagedProject = null;
    if (name == null || _loading) return;
    setState(() {
      _loading = true;
      _project = name;
      _read = false;
      _write = false;
      _downloads = false;
      _tests = false;
      _changed = false;
      _message = 'Carregando permissões do projeto...';
    });
    try {
      final saved = await _agent.invokeMapMethod<String, dynamic>(
        'getPermissions',
        <String, Object?>{'project': name},
      );
      if (!mounted || _project != name) return;
      setState(() {
        _read = saved?['read'] == true;
        _write = saved?['write'] == true;
        _downloads = saved?['download'] == true;
        _tests = saved?['tests'] == true;
        _message = 'Permissões carregadas para $name.';
      });
    } on PlatformException catch (error) {
      if (mounted)
        setState(
          () => _message = error.message ?? 'Falha ao carregar permissões.',
        );
    } catch (error) {
      if (mounted)
        setState(() => _message = 'Falha ao carregar permissões: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _savePermissions() async {
    final project = _project;
    if (project == null || _loading) return;
    setState(() => _loading = true);
    try {
      await _agent.invokeMethod<void>('savePermissions', <String, Object?>{
        'project': project,
        'read': _read,
        'write': _write,
        'download': _downloads,
        'tests': _tests,
      });
      if (!mounted) return;
      setState(() {
        _changed = false;
        _message =
            'Autorização de $project salva no Android. Você pode revogá-la.';
      });
    } on PlatformException catch (error) {
      if (mounted)
        setState(
          () => _message = error.message ?? 'Falha ao salvar permissões.',
        );
    } catch (error) {
      if (mounted)
        setState(() => _message = 'Falha ao salvar permissões: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revokePermissions() async {
    final project = _project;
    if (project == null || _loading) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Revogar permissões?'),
        content: Text(
          'Todas as autorizações do projeto $project serão desativadas.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Revogar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _loading = true);
    try {
      await _agent.invokeMethod<void>('revokePermissions', <String, Object?>{
        'project': project,
      });
      if (!mounted) return;
      setState(() {
        _read = false;
        _write = false;
        _downloads = false;
        _tests = false;
        _changed = false;
        _message = 'Permissões do projeto $project revogadas.';
      });
    } on PlatformException catch (error) {
      if (mounted)
        setState(() => _message = error.message ?? 'Falha ao revogar.');
    } catch (error) {
      if (mounted) setState(() => _message = 'Falha ao revogar: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // QELTRAVYX_AGENT097_LLM: analise real por IA, sem execucao nem escrita.
  Future<void> _executeWithAi() async {
    final project = _project;
    final promptText = _prompt.text.trim();
    if (_runningAi || _loading) return;
    if (project == null || promptText.isEmpty) {
      setState(() => _aiStatus = 'Selecione um projeto e escreva um prompt.');
      return;
    }
    if (_changed) {
      setState(
        () => _aiStatus =
            'Salve as alteracoes de permissao antes de consultar a IA.',
      );
      return;
    }
    if (_apiKey.text.trim().isEmpty) {
      setState(() => _aiStatus = 'Informe sua chave da API OpenAI.');
      return;
    }
    setState(() {
      _runningAi = true;
      _aiStatus = 'Verificando autorizacao e lendo o projeto...';
      _aiAnswer = '';
    });
    try {
      // Nunca confiar somente nas chaves visuais; ler a permissao nativa salva.
      final permissions = await _agent.invokeMapMethod<String, dynamic>(
        'getPermissions',
        <String, Object?>{'project': project},
      );
      if (!mounted || _project != project) return;
      final allowedRead = permissions?['read'] == true;
      if (!allowedRead) {
        setState(
          () => _aiStatus =
              'Autorize e salve a leitura do projeto antes de executar.',
        );
        return;
      }
      final names =
          await _workspace.invokeListMethod<String>(
            'listFiles',
            <String, Object?>{'project': project},
          ) ??
          <String>[];
      if (!mounted || _project != project) return;
      final pieces = <String>[];
      var totalCharacters = 0;
      final included = <String>[];
      // Somente scripts .py na raiz: limite explicito desta etapa.
      for (final filename in names.where((n) => n.endsWith('.py')).take(8)) {
        if (totalCharacters >= 48000) break;
        final body = await _workspace.invokeMethod<String>(
          'readFile',
          <String, Object?>{'project': project, 'file': filename},
        );
        if (body == null) continue;
        final remaining = 48000 - totalCharacters;
        final maxPart = remaining < 12000 ? remaining : 12000;
        final sample = body.length > maxPart
            ? '${body.substring(0, maxPart)}\n[ARQUIVO TRUNCADO]'
            : body;
        pieces.add('ARQUIVO: $filename\n$sample');
        included.add(filename);
        totalCharacters += sample.length;
      }
      if (!mounted || _project != project) return;
      if (_sourceApprovalProject != project) {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('Enviar codigo a OpenAI?'),
            content: Text(
              'O projeto "$project" enviara trechos dos arquivos '
              '${included.isEmpty ? '(nenhum .py encontrado)' : included.join(', ')} '
              'a api.openai.com para analise. Nao inclua senhas ou tokens nos '
              'scripts. Esta permissao de transmissao vale somente nesta '
              'abertura da tela. Nenhum arquivo sera modificado.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('Enviar para analise'),
              ),
            ],
          ),
        );
        if (accepted != true || !mounted || _project != project) return;
        _sourceApprovalProject = project;
      }
      setState(() => _aiStatus = 'Consultando o modelo pela internet...');
      final answer = await QeltravyxAgentLlmClient.ask(
        apiKey: _apiKey.text,
        model: _model.text,
        project: project,
        prompt: promptText,
        sourceContext: pieces.join('\n\n---\n\n'),
      );
      if (!mounted || _project != project) return;
      setState(() {
        _aiAnswer = answer;
        _aiStatus =
            'Analise concluida. Arquivos lidos: '
            '${included.isEmpty ? 'nenhum' : included.join(', ')}. '
            'Nenhuma modificacao executada.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _aiStatus = 'Nao foi possivel consultar a IA: $error');
    } finally {
      if (mounted) setState(() => _runningAi = false);
    }
  }

  // QELTRAVYX_ALPHA098_AGENT_EDIT: propositura/previa antes de qualquer escrita.
  Future<void> _proposeAgentEdits({String? promptOverride}) async {
    final project = _project;
    final promptText = (promptOverride ?? _prompt.text).trim();
    if (_runningAi || _loading) return;
    if (project == null ||
        promptText.isEmpty ||
        _apiKey.text.trim().isEmpty ||
        _changed) {
      setState(
        () => _aiStatus = 'Selecione projeto, salve autorizacoes, informe chave API e prompt.',
      );
      return;
    }
    setState(() {
      _runningAi = true;
      _stagedWrites.clear();
      _stagedProject = null;
      _aiStatus = 'Lendo os arquivos para propor alteracoes...';
    });
    try {
      final permissions = await _agent.invokeMapMethod<String, dynamic>(
        'getPermissions',
        <String, Object?>{'project': project},
      );
      if (permissions?['read'] != true) {
        throw StateError('Autorize a leitura no projeto e salve a permissao.');
      }
      final present = <String, String>{};
      final folders = <String>{''};
      final pieces = <String>[];
      var bytes = 0;
      Future<void> visit(String folder, int depth) async {
        if (depth > 3 || present.length >= 12 || bytes >= 24000) return;
        final entries = await _workspace.invokeMethod<List<dynamic>>(
          'listEntries',
          <String, Object?>{'project': project, 'file': folder},
        );
        for (final entry in entries ?? <dynamic>[]) {
          if (entry is! Map || entry['name'] is! String) continue;
          final name = entry['name'] as String;
          if (name.startsWith('.')) continue;
          final path = folder.isEmpty ? name : '$folder/$name';
          if (entry['isDirectory'] == true) {
            if (depth < 3 && path.split('/').length <= 3) {
              folders.add(path);
              await visit(path, depth + 1);
            }
          } else if (present.length < 12 && bytes < 24000) {
            try {
              AgentFileEdit.validatePath(path);
              final contents = await _workspace.invokeMethod<String>(
                'readTextFile',
                <String, Object?>{'project': project, 'file': path},
              );
              if (contents == null) continue;
              final budget = 24000 - bytes;
              if (contents.length > 8000 || contents.length > budget) continue;
              present[path] = contents;
              pieces.add('ARQUIVO: $path\n$contents');
              bytes += contents.length;
            } on PlatformException {
              // Arquivos indisponiveis nao sao enviados a IA.
            } on FormatException {
              // Apenas os formatos permitidos pelo gerenciador.
            }
          }
        }
      }

      await visit('', 0);
      if (!mounted || _project != project) return;
      if (_sourceApprovalProject != project) {
        final consent = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('Enviar codigo do projeto?'),
            content: Text(
              'A IA recebera ate ${present.length} arquivos de texto de $project '
              '(incluindo subpastas). Confira antes se nao ha senhas, '
              'tokens ou dados privados. A proposta NAO sera aplicada '
              'sem que voce toque no botao Aplicar. Permitir nesta sessao?',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('Enviar para IA'),
              ),
            ],
          ),
        );
        if (consent != true || !mounted || _project != project) return;
        _sourceApprovalProject = project;
      }
      setState(() => _aiStatus = 'Pedindo plano de codigo a IA...');
      final response = await QeltravyxAgentLlmClient.ask(
        apiKey: _apiKey.text,
        model: _model.text,
        project: project,
        prompt:
            'Proponha ate 3 arquivos para esta tarefa. $promptText\n\n'
            'Responda SOMENTE JSON valido no formato exato: '
            '{"summary":"explicacao curta","files":['
            '{"path":"arquivo.py","content":"codigo completo"}]}. '
            'Nao use markdown. Nao inclua exclusoes, comandos ou scripts fora '
            'de .py, .sh, .json, .txt. Pasta pai deve existir. '
            'Use codigo completo, preserve conteudo relevante e nao '
            'inventar resultados de testes.',
        sourceContext:
            'PASTAS EXISTENTES: ${folders.join(', ')}\n\n'
            '${pieces.join('\n\n---\n\n')}',
      );
      final plan = AgentEditPlan.parse(response);
      // Uma correcao de erro so pode alterar o arquivo que falhou.
      final repairOnly =
          _repairProject == project && _repairPrompt == promptText
          ? _repairTarget
          : null;
      if (repairOnly != null &&
          (plan.files.length != 1 ||
              plan.files.single.path != repairOnly ||
              !present.containsKey(repairOnly))) {
        throw FormatException(
          'Correcao rejeitada: so pode modificar $repairOnly, ja lido.',
        );
      }
      final proposed = <Map<String, Object?>>[];
      for (final edit in plan.files) {
        final slash = edit.path.lastIndexOf('/');
        final parent = slash < 0 ? '' : edit.path.substring(0, slash);
        if (!folders.contains(parent)) {
          throw FormatException('Pasta pai inexistente: $parent');
        }
        // Apenas arquivos inteiros presentes no snapshot sao editaveis.
        // Novo arquivo: expected=null. Se existir mas ficou fora dos limites
        // de leitura, a validacao nativa impedira sobrescrita acidental.
        proposed.add(<String, Object?>{
          'path': edit.path,
          'content': edit.content,
          'expected': present[edit.path],
        });
      }
      if (!mounted || _project != project) return;
      setState(() {
        _stagedWrites
          ..clear()
          ..addAll(proposed);
        _stagedProject = project;
        _stagedPrompt = promptText;
        _stagedSummary = plan.summary;
        _aiStatus = 'Plano pronto. Confira os arquivos antes de aplicar.';
      });
    } catch (error) {
      if (mounted)
        setState(() => _aiStatus = 'Falha ao preparar plano: $error');
    } finally {
      if (mounted) setState(() => _runningAi = false);
    }
  }

  Future<void> _applyAgentEdits() async {
    final project = _project;
    final repairPath =
        _repairProject == project &&
            _repairTarget != null &&
            _repairPrompt == _stagedPrompt &&
            _stagedWrites.length == 1 &&
            _stagedWrites.first['path'] == _repairTarget
        ? _repairTarget
        : null;
    if (project != null &&
        repairPath != null &&
        !_cycleLog.canApplyRepair(project, repairPath)) {
      setState(
        () => _aiStatus =
            'Limite de 3 reparos aplicados neste ciclo. Revise manualmente.',
      );
      return;
    }
    if (_runningAi ||
        _loading ||
        project == null ||
        _stagedProject != project ||
        _stagedWrites.isEmpty)
      return;
    if (_changed || _prompt.text.trim() != _stagedPrompt) {
      setState(
        () => _aiStatus = 'Prompt ou permissoes mudaram. Gere um novo plano.',
      );
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Aplicar alteracoes da IA?'),
        content: Text(
          'O projeto $project recebera ${_stagedWrites.length} arquivo(s). '
          'O Android verificara a autorizacao de escrita, rejeitara '
          'arquivos modificados desde a previa e fara backup dos originais. '
          'Nenhum comando sera executado.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Aplicar arquivos'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted || project != _project) return;
    setState(() => _runningAi = true);
    try {
      final outcome = await _agent.invokeMapMethod<String, dynamic>(
        'applyAgentPlan',
        <String, Object?>{'project': project, 'changes': _stagedWrites},
      );
      if (!mounted || _project != project) return;
      if (repairPath != null) {
        // So registrar APOS sucesso da gravacao nativa com backup.
        _cycleLog.repairApplied(project!, repairPath);
        _postApplyProject = project;
        _postApplyPath = repairPath;
        _scriptToRun.text = repairPath;
      }
      setState(() {
        _aiStatus =
            'Arquivos aplicados. Backup: ${outcome?['backupId']}. '
            'Nenhum comando executado.';
        _stagedWrites.clear();
        _stagedProject = null;
      });
    } catch (error) {
      if (mounted) setState(() => _aiStatus = 'Nenhum lote concluido: $error');
    } finally {
      if (mounted) setState(() => _runningAi = false);
    }
  }

  // QELTRAVYX_ALPHA100_REPAIR: prepara proposta restrita ao arquivo que falhou.
  Future<void> _proposePythonRepair() async {
    final project = _project;
    final script = _lastFailedScript;
    if (project == null ||
        script == null ||
        project != _lastFailedProject ||
        _runningAi ||
        _runningTest ||
        _loading) {
      return;
    }
    if (!_cycleLog.canApplyRepair(project, script)) {
      setState(
        () => _aiStatus = 'Tres correcoes aplicadas neste ciclo. Verifique o codigo manualmente.',
      );
      return;
    }
    if (_changed) {
      setState(
        () => _aiStatus =
            'Salve as autorizacoes do projeto antes de propor a correcao.',
      );
      return;
    }
    String repairPrompt;
    try {
      repairPrompt = AgentErrorDiagnostic.buildRepairPrompt(
        path: script,
        errorOutput: _testOutput,
      );
    } on FormatException catch (error) {
      setState(() => _aiStatus = 'Diagnostico indisponivel: ${error.message}');
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Enviar erro Python para IA?'),
        content: SingleChildScrollView(
          child: Text(
            'Arquivo: $script\n\n'
            'A IA recebera o traceback abaixo e podera receber trechos '
            'dos arquivos autorizados do projeto. Verifique que nao '
            'existem tokens, senhas ou dados privados nesta saida. '
            'Somente uma proposta para ESTE arquivo sera aceita; '
            'a aplicacao continuara exigindo previa e backup.\n\n'
            '${AgentErrorDiagnostic.summary(_testOutput)}',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Preparar correcao'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted || _project != project) return;
    // A correcao usa um prompt interno, sem tomar o campo de texto do usuario.
    // O teclado atual deve sair de foco antes de consultar a IA.
    FocusManager.instance.primaryFocus?.unfocus();
    if (_apiKey.text.trim().isEmpty) {
      setState(
        () => _aiStatus =
            'Informe sua chave API e toque novamente em Preparar correcao.',
      );
      return;
    }
    setState(() {
      _repairTarget = script;
      _repairProject = project;
      _repairPrompt = repairPrompt;
      _aiStatus = 'Preparando correcao de $script...';
    });
    await _proposeAgentEdits(promptOverride: repairPrompt);
    // A previa gerada aparece diretamente, evitando procura pela tela longa.
    if (mounted && _project == project && _stagedWrites.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final destination = _proposalSectionKey.currentContext;
        if (!mounted || destination == null) return;
        Scrollable.ensureVisible(
          destination,
          duration: const Duration(milliseconds: 350),
          alignment: 0.15,
        );
      });
    }
  }

  // QELTRAVYX_ALPHA099_PYTHON_TEST: execucao manual, com consentimento expresso.
  Future<void> _runPythonTest() async {
    final project = _project;
    if (_runningAi || _runningTest || _loading) return;
    if (project == null || _changed) {
      setState(
        () => _testStatus =
            'Selecione um projeto e salve as autorizacoes antes do teste.',
      );
      return;
    }
    String script;
    try {
      script = AgentPythonPath.validate(_scriptToRun.text);
    } on FormatException catch (error) {
      setState(() => _testStatus = error.message);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Executar codigo Python?'),
        content: Text(
          'O arquivo $script sera executado no processo Python do aplicativo '
          '(limite de 8 segundos e saida de 12 KB). '
          'ATENCAO: isso NAO e um sandbox. O codigo executado compartilha '
          'as permissoes do aplicativo e pode modificar seus dados internos '
          'ou acessar a internet. Execute somente scripts confiaveis e '
          'revisados. Continuar?',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Executar este teste'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _project != project) return;
    setState(() {
      _runningTest = true;
      _lastFailedScript = null;
      _lastFailedProject = null;
      _testOutput = '';
      _testStatus = 'Executando Python localmente...';
    });
    try {
      final result = await _agent.invokeMapMethod<String, dynamic>(
        'runAgentPython',
        <String, Object?>{'project': project, 'file': script},
      );
      if (!mounted || _project != project) return;
      setState(() {
        _testOutput = (result?['output'] ?? '').toString();
        final exitCode = result?['exitCode'];
        final failed =
            exitCode is int &&
            exitCode != 0 &&
            result?['timedOut'] != true &&
            result?['truncated'] != true &&
            AgentErrorDiagnostic.hasPythonError(_testOutput);
        _lastFailedScript = failed ? script : null;
        _lastFailedProject = failed ? project : null;
        _testStatus = (result?['timedOut'] == true)
            ? 'Tempo limite de 8 segundos. Processo interrompido.'
            : 'Python encerrou com codigo ${result?['exitCode']}.';
        if (result?['truncated'] == true) {
          _testStatus += ' Saida truncada em 12 KB.';
        }
      });
      final code = result?['exitCode'];
      final outputSummary = AgentErrorDiagnostic.hasPythonError(_testOutput)
          ? AgentErrorDiagnostic.summary(_testOutput)
          : result?['timedOut'] == true
          ? 'Tempo limite'
          : result?['truncated'] == true
          ? 'Saida truncada'
          : code == 0
          ? 'Teste concluido'
          : 'Teste encerrado sem traceback';
      _cycleLog.record(
        project: project,
        path: script,
        exitCode: code is int ? code : -1,
        timedOut: result?['timedOut'] == true,
        truncated: result?['truncated'] == true,
        diagnostic: outputSummary,
      );
      if (_postApplyProject == project &&
          _postApplyPath == script &&
          code == 0 &&
          result?['timedOut'] != true &&
          result?['truncated'] != true) {
        _postApplyProject = null;
        _postApplyPath = null;
      }
    } catch (error) {
      if (mounted)
        setState(() => _testStatus = 'Falha no teste Python: $error');
    } finally {
      if (mounted) setState(() => _runningTest = false);
    }
  }

  void _copyPrompt() {
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) return;
    Clipboard.setData(ClipboardData(text: prompt));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Prompt copiado. Nenhuma tarefa foi executada.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1424),
      appBar: AppBar(
        title: const Text('QELTRAVYX AGENT IA'),
        actions: [
          IconButton(
            tooltip: 'Atualizar projetos',
            onPressed: _loading ? null : _loadProjects,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'AGENT IA PRO • Alpha 1.0.5',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
                color: _mint,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Selecione um projeto e defina suas autorizacoes. '
              'O agente pode analisar codigo e propor arquivos para revisao, '
              'aplicados somente com backup e confirmacao. '
              'Testes Python exigem confirmacao manual e nao estao isolados. '
              'Downloads automaticos ainda nao foram implementados.',
            ),
            const SizedBox(height: 20),
            const Text(
              'Projeto autorizado',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            DropdownButton<String>(
              value: _project,
              isExpanded: true,
              hint: const Text('Selecione um projeto'),
              items: _projects
                  .map(
                    (p) => DropdownMenuItem<String>(value: p, child: Text(p)),
                  )
                  .toList(),
              onChanged: _loading ? null : _selectProject,
            ),
            const SizedBox(height: 12),
            const Text(
              'Permissões persistentes deste projeto',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SwitchListTile(
              title: const Text('Ler arquivos do projeto'),
              value: _read,
              onChanged: _project == null || _loading
                  ? null
                  : (v) => setState(() {
                      _read = v;
                      _changed = true;
                    }),
              activeColor: _mint,
            ),
            SwitchListTile(
              title: const Text('Criar e modificar arquivos'),
              value: _write,
              onChanged: _project == null || _loading
                  ? null
                  : (v) => setState(() {
                      _write = v;
                      _changed = true;
                    }),
              activeColor: _mint,
            ),
            SwitchListTile(
              title: const Text('Baixar dependências de fontes confiáveis'),
              subtitle: const Text(
                'Downloads automáticos serão implementados em etapa futura.',
              ),
              value: _downloads,
              onChanged: _project == null || _loading
                  ? null
                  : (v) => setState(() {
                      _downloads = v;
                      _changed = true;
                    }),
              activeColor: _mint,
            ),
            SwitchListTile(
              title: const Text('Executar testes do projeto'),
              value: _tests,
              onChanged: _project == null || _loading
                  ? null
                  : (v) => setState(() {
                      _tests = v;
                      _changed = true;
                    }),
              activeColor: _mint,
            ),
            const Text(
              'Estas preferências não liberam acesso irrestrito ao celular. '
              'O futuro executor deverá verificar cada permissão e proteger ações destrutivas.',
              style: TextStyle(fontSize: 12, color: Color(0xFF9AABC2)),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _project == null || _loading ? null : _savePermissions,
              icon: const Icon(Icons.verified_user_outlined),
              label: Text(
                _changed
                    ? 'Salvar alterações de autorização'
                    : 'Salvar autorização uma vez',
              ),
            ),
            OutlinedButton.icon(
              onPressed: _project == null || _loading
                  ? null
                  : _revokePermissions,
              icon: const Icon(Icons.lock_reset),
              label: const Text('Revogar autorização do projeto'),
            ),
            if (_loading) const LinearProgressIndicator(),
            Text(_message, style: const TextStyle(color: Color(0xFF9AABC2))),
            const Divider(height: 36),
            // QELTRAVYX_ALPHA104_ACTIVITY: resumo somente de leitura.
            AgentActivityPanel(
              project: _project,
              entries: _cycleLog.forProject(_project),
              pendingFiles: _stagedWrites
                  .map((item) => item['path']?.toString() ?? '')
                  .where((path) => path.isNotEmpty)
                  .toList(),
              lastStatus: _aiStatus,
            ),
            const SizedBox(height: 14),
            // QELTRAVYX_ALPHA105_UI: atalhos reutilizam metodos existentes.
            // Alpha 1.0.6: estado guiado sem executar automaticamente.
            AgentWorkflowPanel(
              project: _project,
              tests: _cycleLog.forProject(_project),
              proposalCount: _stagedWrites.length,
              waitingRetest:
                  _postApplyProject == _project && _postApplyPath != null,
              busy: _runningAi || _runningTest,
            ),
            const SizedBox(height: 8),
            AgentProHub(
              project: _project,
              busy: _runningAi || _runningTest || _loading || _changed,
              canPrepareRepair:
                  _lastFailedScript != null &&
                  _lastFailedProject == _project &&
                  AgentErrorDiagnostic.hasPythonError(_testOutput),
              onGenerate: () {
                _proposeAgentEdits();
              },
              onPrepareRepair: () {
                _proposePythonRepair();
              },
              onRunTest: () {
                _runPythonTest();
              },
            ),
            const SizedBox(height: 14),
            const Text(
              'Prompt de programação',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _prompt,
              keyboardType: TextInputType.multiline,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Ex.: analise este projeto, crie testes e corrija os erros.',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _copyPrompt,
              icon: const Icon(Icons.copy),
              label: const Text('Copiar prompt (sem executar)'),
            ),
            // QELTRAVYX_AGENT097_LLM: configuracao mantida so nesta tela.
            const SizedBox(height: 14),
            const Text(
              'Conectar a IA (OpenAI API)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKey,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Chave API (somente nesta sessao)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _model,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Modelo da API',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _runningAi ? null : _executeWithAi,
              icon: const Icon(Icons.smart_toy_outlined),
              label: const Text('Executar com IA (analisar projeto)'),
            ),
            if (_runningAi) const LinearProgressIndicator(),
            // QELTRAVYX_ALPHA099_PYTHON_TEST: rodar somente apos toque do usuario.
            const SizedBox(height: 20),
            const Text(
              'Testar script Python local',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _scriptToRun,
              decoration: const InputDecoration(
                labelText: 'Arquivo .py relativo ao projeto',
                hintText: 'laboratorio095/gerado098.py',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            // QELTRAVYX_ALPHA104_PICKER: navegador seguro de .py.
            OutlinedButton.icon(
              onPressed:
                  _runningAi || _runningTest || _loading || _project == null
                  ? null
                  : () async {
                      final project = _project;
                      if (project == null) return;
                      final picked = await showAgentPythonPicker(
                        context: context,
                        project: project,
                      );
                      if (!mounted || _project != project || picked == null)
                        return;
                      setState(() {
                        _scriptToRun.text = picked;
                        _testOutput = '';
                        _lastFailedScript = null;
                        _lastFailedProject = null;
                        _testStatus =
                            'Script selecionado: $picked. Revise antes de executar.';
                      });
                    },
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Escolher script Python do projeto'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _runningAi || _runningTest || _loading
                  ? null
                  : _runPythonTest,
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Executar teste Python (local)'),
            ),
            if (_runningTest) const LinearProgressIndicator(),
            Text(_testStatus, style: const TextStyle(color: Color(0xFF9AABC2))),
            if (_testOutput.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              const Text(
                'Saida / erros do programa',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SelectableText(_testOutput),
            ],

            // QELTRAVYX_ALPHA100_REPAIR: diagnostico local e proposta opcional.
            if (_lastFailedScript != null &&
                _lastFailedProject == _project &&
                AgentErrorDiagnostic.hasPythonError(_testOutput)) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                'Diagnostico: ${AgentErrorDiagnostic.summary(_testOutput)}',
                style: const TextStyle(color: Color(0xFF9AABC2)),
              ),
              FilledButton.icon(
                onPressed: _runningAi || _runningTest || _loading
                    ? null
                    : _proposePythonRepair,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('IA: propor correcao deste erro (previa)'),
              ),
            ],
            // QELTRAVYX_ALPHA101_CYCLE: reteste exige novo toque e consentimento.
            if (_postApplyProject == _project &&
                _postApplyPath != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                'Correcao salva com backup: ${_postApplyPath!}. '
                'Revise o codigo antes de testar.',
                style: const TextStyle(color: Color(0xFF9AABC2)),
              ),
              FilledButton.icon(
                onPressed: _runningAi || _runningTest || _loading
                    ? null
                    : () {
                        _scriptToRun.text = _postApplyPath!;
                        _runPythonTest(); // MANTEM a confirmacao manual existente.
                      },
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Testar codigo corrigido (confirmar)'),
              ),
            ],
            if (_cycleLog.forProject(_project).isNotEmpty) ...<Widget>[
              const SizedBox(height: 14),
              const Text(
                'Historico de testes desta sessao',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Text(
                'Ultimos testes; sem codigo nem credenciais salvos.',
                style: TextStyle(color: Color(0xFF9AABC2)),
              ),
              for (final entry in _cycleLog.forProject(_project).take(8))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '${entry.path}: ${entry.resultLabel} - '
                    '${entry.diagnostic}',
                    style: const TextStyle(color: Color(0xFFB7C8D9)),
                  ),
                ),
            ],
            // QELTRAVYX_ALPHA098_AGENT_EDIT: previa e aplicacao de codigo.
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _runningAi ? null : _proposeAgentEdits,
              icon: const Icon(Icons.edit_note),
              label: const Text('IA: propor arquivos (previa)'),
            ),
            if (_stagedWrites.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                key: _proposalSectionKey,
                'Alteracoes propostas',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SelectableText(_stagedSummary),
              for (final change in _stagedWrites)
                Card(
                  child: ListTile(
                    title: Text(change['path'] as String),
                    subtitle: Text(
                      'Codigo completo: '
                      '${(change['content'] as String).length} caracteres; '
                      '${change['expected'] == null ? 'criar' : 'substituir'}',
                    ),
                    trailing: IconButton(
                      tooltip: 'Visualizar codigo proposto',
                      icon: const Icon(Icons.visibility_outlined),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (dialog) => AlertDialog(
                          title: Text(change['path'] as String),
                          content: SizedBox(
                            width: double.maxFinite,
                            child: SingleChildScrollView(
                              child: SelectableText(
                                change['content'] as String,
                              ),
                            ),
                          ),
                          actions: <Widget>[
                            TextButton(
                              onPressed: () => Navigator.pop(dialog),
                              child: const Text('Fechar'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              FilledButton.icon(
                onPressed: _runningAi ? null : _applyAgentEdits,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Aplicar arquivos com backup'),
              ),
              OutlinedButton.icon(
                onPressed: _runningAi
                    ? null
                    : () => setState(() {
                        _stagedWrites.clear();
                        _stagedProject = null;
                      }),
                icon: const Icon(Icons.close),
                label: const Text('Descartar proposta'),
              ),
            ],

            const SizedBox(height: 8),
            Text(_aiStatus, style: const TextStyle(color: Color(0xFF9AABC2))),
            if (_aiAnswer.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'Resposta da IA',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SelectableText(_aiAnswer),
              OutlinedButton.icon(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: _aiAnswer)),
                icon: const Icon(Icons.copy),
                label: const Text('Copiar resposta'),
              ),
            ],

            const SizedBox(height: 16),
            const Text(
              'Seguranca: revise propostas antes de salvar; use somente scripts confiaveis. '
              'O executor Python ainda nao possui isolamento completo.',
              style: TextStyle(color: Color(0xFF9AABC2)),
            ),
          ],
        ),
      ),
    );
  }
}
