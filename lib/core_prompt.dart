import 'dart:async';

import 'package:flutter/material.dart';

import 'core_native_tools.dart';
import 'core_v1.dart';
import 'core_v2.dart';

/// One integrated task field; project scope and consent stay on the terminal.
class CorePrompt extends StatefulWidget {
  const CorePrompt({
    super.key,
    this.engine,
    this.onOutput,
    this.focusNode,
    this.onSubmitted,
  });
  final FocusNode? focusNode;
  final VoidCallback? onSubmitted;
  final CoreEngine? engine;
  final ValueChanged<String>? onOutput;
  @override
  State<CorePrompt> createState() => _CorePromptState();
}

class _CorePromptState extends State<CorePrompt> {
  late final CoreEngine _engine;
  final _text = TextEditingController();
  String? _project;
  bool _selecting = false;
  String _lastProgress = '';

  // QELTRAVYX_ACTIVITY_V1
  DateTime? _busyStartedAt;
  Timer? _busyTicker;

  String get _elapsedLabel {
    final elapsed = _busyStartedAt == null
        ? Duration.zero
        : DateTime.now().difference(_busyStartedAt!);

    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');

    return '$minutes:$seconds';
  }

  @override
  void initState() {
    super.initState();
    _engine = widget.engine ?? CoreV2Engine();
    _engine.onChanged = () {
      if (!mounted) return;

      if (_engine.busy && _busyStartedAt == null) {
        _busyStartedAt = DateTime.now();

        _busyTicker?.cancel();
        _busyTicker = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted && _engine.busy) {
            setState(() {});
          }
        });
      } else if (!_engine.busy && _busyStartedAt != null) {
        _busyTicker?.cancel();
        _busyTicker = null;
        _busyStartedAt = null;
      }

      setState(() {});

      if (_engine.busy && _engine.status != _lastProgress) {
        _lastProgress = _engine.status;
        widget.onOutput?.call(_engine.status);
      }
    };
  }

  @override
  void dispose() {
    _engine.onChanged = null;
    _busyTicker?.cancel();
    _engine.cancel();
    _text.dispose();
    super.dispose();
  }

  Future<bool> _approve(String title, String preview) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(child: SelectableText(preview)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Confirmar'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _selectProject() async {
    if (_engine.busy || _selecting) return;
    setState(() => _selecting = true);
    try {
      final projects =
          await CoreNativeTools.workspace.invokeListMethod<String>(
            'listProjects',
          ) ??
          [];
      if (!mounted) return;
      if (projects.isEmpty)
        throw StateError(
          'Crie um projeto em Arquivos e configurações → Projetos.',
        );
      final selected = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Projeto do CORE'),
          children: [
            for (final name in projects)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, name),
                child: Text(name),
              ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      final permissions = await _engine.tools.permissions(selected);
      if (!mounted) return;
      var read = permissions['read'] == true;
      var write = permissions['write'] == true;
      var tests = permissions['tests'] == true;
      var web = permissions['web'] == true;
      final saved = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text('Autorizar $selected'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CheckboxListTile(
                    title: const Text('Ler arquivos'),
                    value: read,
                    onChanged: (v) => update(() => read = v!),
                  ),
                  CheckboxListTile(
                    title: const Text('Autorizar edições com backup'),
                    value: write,
                    onChanged: (v) => update(() => write = v!),
                  ),
                  CheckboxListTile(
                    title: const Text('Permitir testes Python'),
                    value: tests,
                    onChanged: (v) => update(() => tests = v!),
                  ),
                  CheckboxListTile(
                    title: const Text('Pesquisar páginas públicas'),
                    value: web,
                    onChanged: (v) => update(() => web = v!),
                  ),
                  const Text(
                    'Leitura, edições com backup e pesquisa autorizadas persistem neste projeto. Execuções e restaurações exigem aprovação específica. Desmarque para revogar.',
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Salvar'),
              ),
            ],
          ),
        ),
      );
      if (saved != true || !mounted) return;
      await CoreNativeTools.agent.invokeMethod<void>('savePermissions', {
        'project': selected,
        'read': read,
        'write': write,
        'tests': tests,
        'web': web,
        'download': permissions['download'] == true,
      });
      if (mounted) setState(() => _project = selected);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(CoreSafety.display(error.toString()))),
        );
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  Future<void> _submit() async {
    if (_engine.busy || _text.text.trim().isEmpty) return;
    if (_project == null) await _selectProject();
    if (!mounted || _project == null) return;
    final request = _text.text;
    _text.clear();
    widget.onSubmitted?.call();
    await _engine.submit(_project!, request, _approve);
    if (!mounted) return;
    widget.onOutput?.call('${_engine.status}\n${_engine.output}');
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 36,
          child: Row(
            children: [
              Flexible(
                child: TextButton(
                  onPressed: _engine.busy || _selecting ? null : _selectProject,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF65DFA5),
                    textStyle: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: Text(
                    _project ?? 'Selecionar projeto',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (_engine.busy) ...[
                // QELTRAVYX_ACTIVITY_PULSE_V2
                // Alterna com o contador existente; sem animacao infinita.
                Icon(
                  _busyStartedAt != null &&
                          DateTime.now()
                              .difference(_busyStartedAt!)
                              .inSeconds
                              .isEven
                      ? Icons.hourglass_top
                      : Icons.hourglass_bottom,
                  size: 17,
                  color: const Color(0xFFFFCC66),
                  semanticLabel: 'Tarefa em processamento',
                ),
                const SizedBox(width: 5),
                Text(
                  _elapsedLabel,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFFFCC66),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  _engine.status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: _engine.busy
                        ? const Color(0xFFFFCC66)
                        : _engine.phase == CorePhase.failed
                        ? const Color(0xFFFF7777)
                        : const Color(0xFF9AAABE),
                  ),
                ),
              ),
              if (_engine.canCancel)
                IconButton(
                  tooltip: 'Cancelar tarefa',
                  onPressed: _engine.cancel,
                  icon: const Icon(Icons.close, size: 18),
                ),
              if (!_engine.busy && _engine.output.isNotEmpty)
                IconButton(
                  tooltip: 'Ver resultado',
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(_engine.status),
                      content: SingleChildScrollView(
                        child: SelectableText(_engine.output),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Fechar'),
                        ),
                      ],
                    ),
                  ),
                  icon: const Icon(Icons.receipt_long, size: 18),
                ),
            ],
          ),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('core-prompt'),
                controller: _text,
                focusNode: widget.focusNode,
                enabled: !_selecting,
                readOnly: _engine.busy,
                autofocus: false,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: 'Peça uma tarefa em português…',
                ),
              ),
            ),
            IconButton.filled(
              tooltip: 'Enviar tarefa',
              onPressed: _engine.busy || _selecting ? null : _submit,
              icon: const Icon(Icons.arrow_upward),
            ),
          ],
        ),
      ],
    ),
  );
}
