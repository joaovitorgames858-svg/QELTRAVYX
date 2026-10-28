import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Seleciona um .py existente, sempre por caminhos relativos ao projeto.
/// A validacao final do caminho e feita pelo gerenciador nativo Android.
Future<String?> showAgentPythonPicker({
  required BuildContext context,
  required String project,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _AgentPythonPicker(project: project),
  );
}

class _AgentPythonPicker extends StatefulWidget {
  final String project;
  const _AgentPythonPicker({required this.project});

  @override
  State<_AgentPythonPicker> createState() => _AgentPythonPickerState();
}

class _PickerEntry {
  final String name;
  final bool isDirectory;
  const _PickerEntry(this.name, this.isDirectory);
}

class _AgentPythonPickerState extends State<_AgentPythonPicker> {
  static const MethodChannel _workspace = MethodChannel('qeltravyx/workspace');
  String _folder = '';
  late Future<List<_PickerEntry>> _items;

  @override
  void initState() {
    super.initState();
    _items = _read('');
  }

  Future<List<_PickerEntry>> _read(String folder) async {
    final raw =
        await _workspace.invokeListMethod<dynamic>(
          'listEntries',
          <String, Object?>{'project': widget.project, 'file': folder},
        ) ??
        <dynamic>[];
    final result = <_PickerEntry>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final data = Map<String, dynamic>.from(item);
      final name = data['name'];
      final directory = data['isDirectory'] == true;
      if (name is! String ||
          name.isEmpty ||
          name == '.' ||
          name == '..' ||
          name.contains('/') ||
          name.contains('\\')) {
        continue;
      }
      if (directory || name.toLowerCase().endsWith('.py')) {
        result.add(_PickerEntry(name, directory));
      }
    }
    result.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return result;
  }

  void _navigate(String folder) {
    setState(() {
      _folder = folder;
      _items = _read(folder);
    });
  }

  void _goUp() {
    if (_folder.isEmpty) return;
    final slash = _folder.lastIndexOf('/');
    _navigate(slash < 0 ? '' : _folder.substring(0, slash));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Selecionar script Python'),
      content: SizedBox(
        width: double.maxFinite,
        height: 390,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '${widget.project}/${_folder.isEmpty ? '' : _folder}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            TextButton.icon(
              onPressed: _folder.isEmpty ? null : _goUp,
              icon: const Icon(Icons.arrow_upward),
              label: const Text('Pasta anterior'),
            ),
            const Divider(),
            Expanded(
              child: FutureBuilder<List<_PickerEntry>>(
                future: _items,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        const Text('Nao foi possivel listar esta pasta.'),
                        TextButton(
                          onPressed: () => _navigate(_folder),
                          child: const Text('Tentar novamente'),
                        ),
                      ],
                    );
                  }
                  final items = snapshot.data ?? <_PickerEntry>[];
                  if (items.isEmpty) {
                    return const Center(
                      child: Text('Nenhum script .py nesta pasta.'),
                    );
                  }
                  return ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final entry = items[index];
                      final path = _folder.isEmpty
                          ? entry.name
                          : '$_folder/${entry.name}';
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          entry.isDirectory
                              ? Icons.folder_outlined
                              : Icons.code_outlined,
                        ),
                        title: Text(entry.name),
                        onTap: entry.isDirectory
                            ? () => _navigate(path)
                            : () => Navigator.of(context).pop(path),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
