import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Alpha 0.7: project and Python file editor in the app's private workspace.
/// Returns an absolute .py path to the terminal when Run is pressed.
class QeltravyxWorkspacePage extends StatefulWidget {
  const QeltravyxWorkspacePage({super.key});

  @override
  State<QeltravyxWorkspacePage> createState() => _QeltravyxWorkspacePageState();
}

class _QeltravyxWorkspacePageState extends State<QeltravyxWorkspacePage> {
  static const _channel = MethodChannel('qeltravyx/workspace');
  static const _green = Color(0xFF43E7AB);
  final _editor = TextEditingController();
  final _focus = FocusNode();
  List<String> _projects = [];
  List<String> _files = [];
  String? _project;
  String? _file;
  bool _dirty = false;
  bool _busy = false;
  String _state = 'Carregando projetos...';

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  @override
  void dispose() {
    _editor.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<T?> _invoke<T>(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      _notify(e.message ?? 'Falha ao acessar o workspace');
    } catch (e) {
      _notify('Falha: $e');
    }
    return null;
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadProjects() async {
    setState(() => _busy = true);
    try {
      final data = await _channel.invokeListMethod<String>('listProjects');
      if (!mounted) return;
      setState(() {
        _projects = data ?? [];
        _state = _projects.isEmpty ? 'Nenhum projeto. Crie o primeiro no botão +.' : '';
      });
    } catch (e) {
      _notify('Não foi possível listar projetos: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openProject(String name) async {
    if (_busy) return;
    setState(() { _project = name; _file = null; _busy = true; });
    try {
      final data = await _channel.invokeListMethod<String>(
        'listFiles', {'project': name});
      if (!mounted) return;
      setState(() { _files = data ?? []; });
    } catch (e) {
      _notify('Erro ao abrir projeto: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openFile(String name) async {
    if (_busy || _project == null) return;
    setState(() => _busy = true);
    try {
      final data = await _channel.invokeMethod<String>('readFile',
        {'project': _project, 'file': name});
      if (!mounted || data == null) return;
      _editor.text = data;
      setState(() { _file = name; _dirty = false; });
    } catch (e) {
      _notify('Falha ao ler arquivo: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askName(String title, String hint, String initial) async {
    final c = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: hint,
            helperText: 'Use letras, números, _ e -; arquivos terminam em .py'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()),
            child: const Text('Confirmar')),
        ],
      ),
    );
    // TextField no longer needs its controller once the dialog has been disposed.
    WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
    return value;
  }

  Future<void> _newProject() async {
    final name = await _askName('Novo projeto', 'Nome do projeto', 'meu_projeto');
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod<void>('createProject', {'project': name});
      if (!mounted) return;
      await _loadProjects();
      if (mounted) await _openProject(name);
    } on PlatformException catch (e) {
      _notify(e.message ?? 'Não foi possível criar projeto');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newFile() async {
    if (_project == null) return;
    final name = await _askName('Novo script Python', 'Arquivo .py', 'main.py');
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod<void>('createFile',
        {'project': _project, 'file': name});
      if (!mounted) return;
      setState(() => _busy = false);
      await _openProject(_project!);
      await _openFile(name);
    } on PlatformException catch (e) {
      _notify(e.message ?? 'Não foi possível criar script');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _save() async {
    if (_file == null || _project == null) return false;
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod<void>('saveFile', {
        'project': _project,
        'file': _file,
        'text': _editor.text,
      });
      if (!mounted) return false;
      setState(() => _dirty = false);
      _notify('Arquivo salvo: $_file');
      return true;
    } on PlatformException catch (e) {
      _notify(e.message ?? 'Falha ao salvar');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run() async {
    if (_busy || _file == null || _project == null) return;
    if (!await _save() || !mounted) return;
    final path = await _invoke<String>('filePath',
      {'project': _project, 'file': _file});
    if (path != null && mounted) Navigator.pop(context, path);
  }

  Future<void> _renameFile() async {
    if (_file == null || _project == null || _busy) return;
    if (_dirty && !await _save()) return;
    if (!mounted) return;
    final previous = _file!;
    final name = await _askName('Renomear arquivo', 'Novo nome', previous);
    if (name == null || name.isEmpty || name == previous || !mounted) return;
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod<void>('renameFile', {
        'project': _project, 'file': previous, 'newName': name});
      if (!mounted) return;
      setState(() { _file = name; _files = [..._files.where((e) => e != previous), name]..sort(); });
    } on PlatformException catch (e) {
      _notify(e.message ?? 'Falha ao renomear');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteFile(String filename) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir script?'),
        content: Text('Excluir "$filename" permanentemente? Não há lixeira.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
            child: const Text('Excluir')),
        ],
      ),
    );
    if (yes != true || !mounted || _project == null) return;
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod<void>('deleteFile',
        {'project': _project, 'file': filename});
      if (!mounted) return;
      setState(() {
        _files.remove(filename);
        if (_file == filename) { _file = null; _dirty = false; _editor.clear(); }
      });
    } on PlatformException catch (e) {
      _notify(e.message ?? 'Falha ao excluir');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final shouldDiscard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Alterações não salvas'),
        content: const Text('Deseja descartar as alterações deste arquivo?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Continuar editando')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
            child: const Text('Descartar')),
        ],
      ),
    );
    return shouldDiscard == true;
  }

  Future<void> _back() async {
    if (_file != null) {
      if (!await _confirmDiscard() || !mounted) return;
      setState(() { _file = null; _dirty = false; });
    } else if (_project != null) {
      setState(() { _project = null; _files = []; });
    } else {
      Navigator.pop(context);
    }
  }

  void _insertIndent() {
    final text = _editor.text;
    final range = _editor.selection;
    final start = range.start < 0 ? text.length : range.start;
    final end = range.end < 0 ? text.length : range.end;
    _editor.value = TextEditingValue(
      text: text.replaceRange(start, end, '    '),
      selection: TextSelection.collapsed(offset: start + 4),
    );
    setState(() => _dirty = true);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final title = _file ?? _project ?? 'Projetos Python';
    return PopScope(
      canPop: _project == null && _file == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF10192A),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _back),
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const Text('QELTRAVYX • WORKSPACE 0.7',
              style: TextStyle(fontSize: 10, color: Color(0xFF97A7BA))),
          ]),
          actions: [
            if (_file != null) ...[
              IconButton(tooltip: 'Renomear', onPressed: _busy ? null : _renameFile,
                icon: const Icon(Icons.drive_file_rename_outline)),
              IconButton(tooltip: 'Salvar', onPressed: _busy ? null : _save,
                icon: Icon(Icons.save_outlined, color: _dirty ? _green : null)),
              IconButton(tooltip: 'Executar no terminal', onPressed: _busy ? null : _run,
                icon: const Icon(Icons.play_arrow, color: _green)),
            ] else
              IconButton(tooltip: 'Novo',
                onPressed: _busy ? null : (_project == null ? _newProject : _newFile),
                icon: const Icon(Icons.add_circle_outline, color: _green)),
          ],
        ),
        body: SafeArea(child: _busy && _file == null
          ? const Center(child: CircularProgressIndicator())
          : _file != null ? _editorView()
          : _project != null ? _fileList()
          : _projectList()),
      ),
    );
  }

  Widget _projectList() {
    if (_projects.isEmpty) return Center(child: Padding(
      padding: const EdgeInsets.all(24), child: Text(_state,
        textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF97A7BA)))));
    return ListView.builder(
      itemCount: _projects.length,
      itemBuilder: (context, i) => ListTile(
        leading: const Icon(Icons.folder_outlined, color: _green),
        title: Text(_projects[i]),
        subtitle: const Text('Projeto local • pasta privada'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openProject(_projects[i]),
      ),
    );
  }

  Widget _fileList() {
    if (_files.isEmpty) return const Center(child: Padding(
      padding: EdgeInsets.all(24),
      child: Text('Projeto vazio. Toque em + para criar um arquivo .py.',
        textAlign: TextAlign.center)));
    return ListView.builder(
      itemCount: _files.length,
      itemBuilder: (context, i) => ListTile(
        leading: const Icon(Icons.code, color: _green),
        title: Text(_files[i], style: const TextStyle(fontFamily: 'monospace')),
        subtitle: const Text('Arquivo Python'),
        onTap: () => _openFile(_files[i]),
        trailing: IconButton(
          tooltip: 'Excluir arquivo',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _deleteFile(_files[i]),
        ),
      ),
    );
  }

  Widget _editorView() {
    final lineCount = _editor.text.split("\n").length;
    return Column(children: [
      Container(
        color: const Color(0xFF142235),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(children: [
          Text(_dirty ? '● Não salvo' : '✓ Salvo',
            style: TextStyle(fontSize: 12, color: _dirty ? Colors.amber : _green)),
          const Spacer(),
          Text('$lineCount linhas',
            style: const TextStyle(fontSize: 12, color: Color(0xFF97A7BA))),
          TextButton(onPressed: _insertIndent, child: const Text('TAB +4')),
        ]),
      ),
      Expanded(child: Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _editor,
          focusNode: _focus,
          keyboardType: TextInputType.multiline,
          maxLines: null, minLines: null, expands: true,
          autocorrect: false, enableSuggestions: false,
          textAlignVertical: TextAlignVertical.top,
          onChanged: (_) { if (!_dirty) setState(() => _dirty = true); },
          style: const TextStyle(fontFamily: 'monospace', fontSize: 14,
            height: 1.5, color: Color(0xFFE4EBF4)),
          decoration: InputDecoration(
            hintText: '# Escreva seu código Python aqui...',
            contentPadding: const EdgeInsets.all(14),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      )),
      Container(
        padding: const EdgeInsets.fromLTRB(12, 5, 12, 10),
        color: const Color(0xFF10192A),
        child: Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined), label: const Text('Salvar'))),
          const SizedBox(width: 12),
          Expanded(child: FilledButton.icon(
            onPressed: _busy ? null : _run,
            style: FilledButton.styleFrom(backgroundColor: _green,
              foregroundColor: const Color(0xFF071710)),
            icon: const Icon(Icons.play_arrow), label: const Text('Executar'))),
        ]),
      ),
    ]);
  }
}
