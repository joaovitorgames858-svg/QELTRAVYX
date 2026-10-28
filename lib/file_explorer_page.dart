import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'workspace_editor.dart';
import 'workspace_manager_page.dart';

/// Explorador de leitura limitado ao workspace privado do QELTRAVYX.
/// Usa somente os metodos nativos ja existentes: listProjects, listFiles, readFile.
/// Criacao/edicao continuam a cargo do editor atual, sem alterar seu comportamento.
class QeltravyxFileExplorerPage extends StatefulWidget {
  const QeltravyxFileExplorerPage({super.key});

  @override
  State<QeltravyxFileExplorerPage> createState() =>
      _QeltravyxFileExplorerPageState();
}

class _QeltravyxFileExplorerPageState extends State<QeltravyxFileExplorerPage> {
  static const _channel = MethodChannel('qeltravyx/workspace');
  static const _green = Color(0xFF43E7AB);

  List<String> _projects = <String>[];
  List<String> _files = <String>[];
  String? _project;
  String? _file;
  String? _preview;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_project == null) {
        final items = await _channel.invokeListMethod<String>('listProjects');
        if (!mounted) return;
        setState(() => _projects = items ?? <String>[]);
      } else {
        final items = await _channel.invokeListMethod<String>(
          'listFiles',
          <String, Object?>{'project': _project},
        );
        if (!mounted) return;
        setState(() => _files = items ?? <String>[]);
      }
    } on PlatformException catch (error) {
      _notify(error.message ?? 'Falha ao listar arquivos');
    } catch (error) {
      _notify('Falha ao carregar: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openProject(String project) async {
    if (_busy) return;
    setState(() {
      _project = project;
      _file = null;
      _preview = null;
      _files = <String>[];
    });
    await _refresh();
  }

  Future<void> _openFile(String file) async {
    if (_busy || _project == null) return;
    setState(() => _busy = true);
    try {
      final contents = await _channel.invokeMethod<String>(
        'readFile',
        <String, Object?>{'project': _project, 'file': file},
      );
      if (!mounted || contents == null) return;
      setState(() {
        _file = file;
        _preview = contents;
      });
    } on PlatformException catch (error) {
      _notify(error.message ?? 'Falha ao ler arquivo');
    } catch (error) {
      _notify('Falha ao visualizar arquivo: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openEditor() async {
    if (_busy) return;
    final script = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const QeltravyxWorkspacePage()),
    );
    if (!mounted) return;
    if (script != null) {
      // Encaminha o pedido explicito de Executar ao terminal principal.
      Navigator.of(context).pop(script);
      return;
    }
    // Arquivos podem ter sido criados/editados no editor.
    setState(() {
      _project = null;
      _file = null;
      _preview = null;
    });
    await _refresh();
  }

  void _back() {
    if (_file != null) {
      setState(() {
        _file = null;
        _preview = null;
      });
    } else if (_project != null) {
      setState(() {
        _project = null;
        _files = <String>[];
      });
      _refresh();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _file ?? _project ?? 'Arquivos dos projetos';
    return PopScope(
      canPop: _project == null && _file == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1424),
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Voltar',
            onPressed: _back,
          ),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: <Widget>[
            IconButton(
              tooltip: 'Gerenciar arquivos e pastas',
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: _busy
                  ? null
                  : () async {
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const QeltravyxWorkspaceManagerPage(),
                        ),
                      );
                      if (!mounted) return;
                      setState(() {
                        _project = null;
                        _file = null;
                        _preview = null;
                      });
                      await _refresh();
                    },
            ),
            IconButton(
              tooltip: 'Atualizar arquivos',
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: <Widget>[
            if (_busy) const LinearProgressIndicator(color: _green),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.folder_open_outlined, color: _green),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _project == null
                          ? 'workspace / projects'
                          : _file == null
                          ? 'workspace / projects / $_project'
                          : 'workspace / projects / $_project / $_file',
                      maxLines: 2,
                      style: const TextStyle(color: Color(0xFF9AABC2)),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _content()),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _openEditor,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Abrir editor de projetos'),
                      ),
                    ),
                    if (_preview != null) ...<Widget>[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Copiar conteudo do arquivo',
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: _preview!),
                          );
                          _notify('Conteudo copiado.');
                        },
                        icon: const Icon(Icons.copy_outlined, color: _green),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    if (_file != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          _preview ?? '',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
      );
    }

    final names = _project == null ? _projects : _files;
    if (!_busy && names.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            _project == null
                ? 'Nenhum projeto encontrado. Crie um no editor de projetos.'
                : 'Nenhum arquivo encontrado neste projeto.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF9AABC2)),
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: names.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final name = names[index];
        final isProject = _project == null;
        return ListTile(
          leading: Icon(
            isProject ? Icons.folder_outlined : Icons.description_outlined,
            color: _green,
          ),
          title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy
              ? null
              : () => isProject ? _openProject(name) : _openFile(name),
        );
      },
    );
  }
}
