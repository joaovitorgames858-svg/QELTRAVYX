import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'editor_cursor_position.dart';

/// QELTRAVYX_ALPHA095_MANAGER: gerenciador isolado do editor Python legado.
/// Operacoes sempre validadas novamente pelo Kotlin dentro de workspace/projects.
class QeltravyxWorkspaceManagerPage extends StatefulWidget {
  const QeltravyxWorkspaceManagerPage({super.key});

  @override
  State<QeltravyxWorkspaceManagerPage> createState() =>
      _QeltravyxWorkspaceManagerPageState();
}

class _QeltravyxWorkspaceManagerPageState
    extends State<QeltravyxWorkspaceManagerPage> {
  static const MethodChannel _channel = MethodChannel('qeltravyx/workspace');
  static const Color _green = Color(0xFF43E7AB);

  String? _project;
  String _folder = '';
  List<String> _projects = <String>[];
  List<Map<String, Object?>> _entries = <Map<String, Object?>>[];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  static String _join(String folder, String name) =>
      folder.isEmpty ? name : '$folder/$name';

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
        final data = await _channel.invokeListMethod<String>('listProjects');
        if (!mounted) return;
        setState(() => _projects = data ?? <String>[]);
      } else {
        final data = await _channel.invokeListMethod<dynamic>(
          'listEntries',
          <String, Object?>{'project': _project, 'file': _folder},
        );
        if (!mounted) return;
        setState(() {
          _entries = (data ?? <dynamic>[])
              .whereType<Map>()
              .map(
                (entry) => <String, Object?>{
                  'name': entry['name']?.toString() ?? '',
                  'isDirectory': entry['isDirectory'] == true,
                },
              )
              .where((entry) => (entry['name'] as String).isNotEmpty)
              .toList();
        });
      }
    } on PlatformException catch (error) {
      _notify(error.message ?? 'Falha ao listar arquivos');
    } catch (error) {
      _notify('Falha ao carregar: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enterProject(String project) async {
    if (_busy) return;
    setState(() {
      _project = project;
      _folder = '';
      _entries.clear();
    });
    await _refresh();
  }

  Future<void> _enterFolder(String name) async {
    if (_busy) return;
    setState(() {
      _folder = _join(_folder, name);
      _entries.clear();
    });
    await _refresh();
  }

  Future<void> _back() async {
    if (_busy) return;
    if (_folder.isNotEmpty) {
      setState(() {
        final i = _folder.lastIndexOf('/');
        _folder = i < 0 ? '' : _folder.substring(0, i);
      });
    } else if (_project != null) {
      setState(() => _project = null);
    } else {
      Navigator.of(context).pop();
      return;
    }
    await _refresh();
  }

  Future<String?> _askName(String title, String hint, String initial) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: hint,
            helperText: 'Letras, numeros, ponto, _ e -; sem barras.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    return result;
  }

  Future<bool> _mutate(String method, Map<String, Object?> args) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod<void>(method, args);
      return mounted;
    } on PlatformException catch (error) {
      _notify(error.message ?? 'Operacao nao permitida');
      return false;
    } catch (error) {
      _notify('Falha: $error');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createFolder() async {
    if (_project == null || _busy) return;
    final name = await _askName('Criar pasta', 'Nome da pasta', 'scripts');
    if (name == null || name.isEmpty || !mounted) return;
    final ok = await _mutate('createFolder', <String, Object?>{
      'project': _project,
      'file': _join(_folder, name),
    });
    if (ok) {
      _notify('Pasta criada: $name');
      await _refresh();
    }
  }

  Future<void> _createFile() async {
    if (_project == null || _busy) return;
    final name = await _askName('Criar arquivo', 'Arquivo de texto', 'novo.py');
    if (name == null || name.isEmpty || !mounted) return;
    final ok = await _mutate('createTextFile', <String, Object?>{
      'project': _project,
      'file': _join(_folder, name),
    });
    if (ok) {
      _notify('Arquivo criado: $name');
      await _refresh();
    }
  }

  Future<void> _rename(String name) async {
    if (_project == null || _busy) return;
    final next = await _askName('Renomear', 'Novo nome', name);
    if (next == null || next.isEmpty || next == name || !mounted) return;
    final ok = await _mutate('renameEntry', <String, Object?>{
      'project': _project,
      'file': _join(_folder, name),
      'newName': next,
    });
    if (ok) {
      _notify('Renomeado para $next');
      await _refresh();
    }
  }

  Future<void> _delete(String name, bool isDirectory) async {
    if (_project == null || _busy) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isDirectory ? 'Excluir pasta?' : 'Excluir arquivo?'),
        content: Text(
          'Excluir "$name"? A operacao nao pode ser desfeita. '
          'Por seguranca, somente pastas vazias podem ser excluidas.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final ok = await _mutate('deleteEntry', <String, Object?>{
      'project': _project,
      'file': _join(_folder, name),
    });
    if (ok) {
      _notify('Excluido: $name');
      await _refresh();
    }
  }

  Future<void> _edit(String name) async {
    if (_project == null || _busy) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => QeltravyxTextFileEditorPage(
          project: _project!,
          file: _join(_folder, name),
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final location = _project == null
        ? 'workspace / projects'
        : 'workspace / projects / $_project${_folder.isEmpty ? '' : ' / $_folder'}';
    return PopScope(
      canPop: _project == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1424),
        appBar: AppBar(
          leading: IconButton(
            onPressed: _busy ? null : _back,
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Voltar',
          ),
          title: Text(_project ?? 'Gerenciar arquivos'),
          actions: <Widget>[
            if (_project != null) ...<Widget>[
              IconButton(
                onPressed: _busy ? null : _createFolder,
                tooltip: 'Nova pasta',
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
              IconButton(
                onPressed: _busy ? null : _createFile,
                tooltip: 'Novo arquivo',
                icon: const Icon(Icons.note_add_outlined),
              ),
            ],
            IconButton(
              onPressed: _busy ? null : _refresh,
              tooltip: 'Atualizar',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: <Widget>[
            if (_busy) const LinearProgressIndicator(color: _green),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.folder_open_outlined, color: _green),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      location,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFF9AABC2)),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _project == null
                  ? _projects.isEmpty
                        ? const Center(
                            child: Text('Nenhum projeto encontrado.'),
                          )
                        : ListView.builder(
                            itemCount: _projects.length,
                            itemBuilder: (context, index) => ListTile(
                              leading: const Icon(
                                Icons.folder_outlined,
                                color: _green,
                              ),
                              title: Text(_projects[index]),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: _busy
                                  ? null
                                  : () => _enterProject(_projects[index]),
                            ),
                          )
                  : _entries.isEmpty
                  ? const Center(
                      child: Text(
                        'Pasta vazia. Crie uma pasta ou arquivo acima.',
                      ),
                    )
                  : ListView.builder(
                      itemCount: _entries.length,
                      itemBuilder: (context, index) {
                        final item = _entries[index];
                        final name = item['name'] as String;
                        final folder = item['isDirectory'] == true;
                        return ListTile(
                          leading: Icon(
                            folder
                                ? Icons.folder_outlined
                                : Icons.description_outlined,
                            color: _green,
                          ),
                          title: Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: _busy
                              ? null
                              : () => folder ? _enterFolder(name) : _edit(name),
                          trailing: PopupMenuButton<String>(
                            tooltip: 'Opcoes do item',
                            onSelected: (action) {
                              if (action == 'rename') _rename(name);
                              if (action == 'delete') _delete(name, folder);
                            },
                            itemBuilder: (_) => const <PopupMenuEntry<String>>[
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('Renomear'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Excluir'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Editor em texto puro, sem executar scripts ao salvar.
class QeltravyxTextFileEditorPage extends StatefulWidget {
  const QeltravyxTextFileEditorPage({
    super.key,
    required this.project,
    required this.file,
  });

  final String project;
  final String file;

  @override
  State<QeltravyxTextFileEditorPage> createState() =>
      _QeltravyxTextFileEditorPageState();
}

class _QeltravyxTextFileEditorPageState
    extends State<QeltravyxTextFileEditorPage> {
  static const MethodChannel _channel = MethodChannel('qeltravyx/workspace');
  static const Color _green = Color(0xFF43E7AB);
  final TextEditingController _editor = TextEditingController();
  bool _busy = true;
  bool _loaded = false;
  bool _dirty = false;
  String _saved = '';
  int _currentLine = 1;
  int _currentColumn = 1;
  int _totalLines = 1;

  @override
  void initState() {
    super.initState();
    _editor.addListener(_updateEditorState);
    _load();
  }

  // Indicador atualizado ao editar e ao mover o cursor; nunca executa codigo.
  void _updateEditorState() {
    if (!mounted || !_loaded) return;
    final position = calculateEditorCursorPosition(
      _editor.text,
      _editor.selection.baseOffset,
    );
    final dirty = _editor.text != _saved;
    if (dirty != _dirty ||
        position.line != _currentLine ||
        position.column != _currentColumn ||
        position.totalLines != _totalLines) {
      setState(() {
        _dirty = dirty;
        _currentLine = position.line;
        _currentColumn = position.column;
        _totalLines = position.totalLines;
      });
    }
  }

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _load() async {
    try {
      final data = await _channel.invokeMethod<String>(
        'readTextFile',
        <String, Object?>{'project': widget.project, 'file': widget.file},
      );
      if (!mounted) return;
      _saved = data ?? '';
      _editor.text = _saved;
      final position = calculateEditorCursorPosition(
        _saved,
        _editor.selection.baseOffset,
      );
      setState(() {
        _loaded = true;
        _dirty = false;
        _currentLine = position.line;
        _currentColumn = position.column;
        _totalLines = position.totalLines;
      });
    } on PlatformException catch (error) {
      _notify(error.message ?? 'Falha ao abrir arquivo');
    } catch (error) {
      _notify('Falha ao abrir: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || !_loaded) return;
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod<void>('saveTextFile', <String, Object?>{
        'project': widget.project,
        'file': widget.file,
        'text': _editor.text,
      });
      if (!mounted) return;
      _saved = _editor.text;
      setState(() => _dirty = false);
      _notify('Arquivo salvo.');
    } on PlatformException catch (error) {
      _notify(error.message ?? 'Falha ao salvar arquivo');
    } catch (error) {
      _notify('Falha ao salvar: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _editor.text));
    _notify('Conteudo copiado.');
  }

  Future<void> _attemptLeave() async {
    if (_busy) return;
    if (!_dirty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Alteracoes nao salvas'),
        content: const Text('Deseja sair e descartar suas alteracoes?'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Continuar editando'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.file.split('/').last;
    return PopScope(
      canPop: !_dirty && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _attemptLeave();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1424),
        appBar: AppBar(
          leading: IconButton(
            onPressed: _busy ? null : _attemptLeave,
            icon: const Icon(Icons.arrow_back),
          ),
          title: Text(
            '$name${_dirty ? ' *' : ''}',
            overflow: TextOverflow.ellipsis,
          ),
          actions: <Widget>[
            IconButton(
              onPressed: _loaded && !_busy ? _copy : null,
              icon: const Icon(Icons.copy_outlined),
              tooltip: 'Copiar texto',
            ),
            IconButton(
              onPressed: _loaded && !_busy ? _save : null,
              icon: const Icon(Icons.save_outlined),
              tooltip: 'Salvar arquivo',
            ),
          ],
        ),
        // Barra fora da coluna rolavel; SafeArea evita sobreposicao com Android 16.
        bottomNavigationBar: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(12, 6, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _loaded
                          ? (_dirty ? '● Alterações não salvas' : 'Salvo')
                          : 'Arquivo não carregado',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: _dirty
                            ? const Color(0xFFFFC778)
                            : const Color(0xFF9AABC2),
                      ),
                    ),
                  ),
                  Text(
                    'Ln $_currentLine, Col $_currentColumn  •  $_totalLines linhas',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF9AABC2),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _loaded && !_busy ? _save : null,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Salvar arquivo'),
                ),
              ),
            ],
          ),
        ),
        body: Column(
          children: <Widget>[
            if (_busy) const LinearProgressIndicator(color: _green),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                'workspace / projects / ${widget.project} / ${widget.file}\n'
                'Texto UTF-8 ate 256 KB. Salvar nao executa o arquivo.',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9AABC2)),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: TextField(
                  controller: _editor,
                  enabled: _loaded && !_busy,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
                  decoration: InputDecoration(
                    alignLabelWithHint: true,
                    hintText: 'Conteudo do arquivo...',
                    filled: true,
                    fillColor: const Color(0xFF172638),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
