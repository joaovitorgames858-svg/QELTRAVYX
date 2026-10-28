import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Edita somente o rascunho. O envio ao PTY fica no botão do terminal.
class CommandEditorPage extends StatefulWidget {
  const CommandEditorPage({super.key, required this.initialText});

  final String initialText;

  @override
  State<CommandEditorPage> createState() => _CommandEditorPageState();
}

class _CommandEditorPageState extends State<CommandEditorPage> {
  late final TextEditingController _editor;
  final FocusNode _editorFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _editor = TextEditingController(text: widget.initialText);
    _editor.addListener(_updateCounter);
  }

  void _updateCounter() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _editor.removeListener(_updateCounter);
    _editor.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  void _apply() => Navigator.of(context).pop(_editor.text);

  Future<void> _cancel() async {
    if (_editor.text != widget.initialText) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Descartar alterações?'),
          content: const Text(
            'As edições feitas nesta tela serão descartadas. '
            'O comando anterior continuará no terminal.',
          ),
          actions: [
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
      if (discard != true || !mounted) return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _editor.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Comando copiado.')),
    );
  }

  Future<void> _paste() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || clipboard?.text == null) return;
    final inserted = clipboard!.text!
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final old = _editor.text;
    final selection = _editor.selection;
    final start = selection.start < 0 ? old.length : selection.start;
    final end = selection.end < 0 ? old.length : selection.end;
    _editor.value = TextEditingValue(
      text: old.replaceRange(start, end, inserted),
      selection: TextSelection.collapsed(offset: start + inserted.length),
    );
    _editorFocus.requestFocus();
  }

  Future<void> _clear() async {
    if (_editor.text.isEmpty) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Limpar editor?'),
        content: const Text('O texto do editor será apagado, sem executar comandos.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Limpar'),
          ),
        ],
      ),
    );
    if (approved == true && mounted) _editor.clear();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1424),
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Voltar sem aplicar',
            icon: const Icon(Icons.arrow_back),
            onPressed: _cancel,
          ),
          title: const Text('Editor de comandos'),
          actions: [
            TextButton.icon(
              onPressed: _apply,
              icon: const Icon(Icons.check),
              label: const Text('Aplicar'),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Edite à vontade. Aplicar devolve o texto ao terminal SEM executar.',
                  style: TextStyle(color: Color(0xFF9AABC2), fontSize: 13),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: TextField(
                    controller: _editor,
                    focusNode: _editorFocus,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    autocorrect: false,
                    enableSuggestions: false,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 15,
                      color: Color(0xFFE9F1FA),
                    ),
                    decoration: InputDecoration(
                      hintText: 'Digite ou cole seu comando...',
                      hintStyle: const TextStyle(color: Color(0xFF8D9BB1)),
                      filled: true,
                      fillColor: const Color(0xFF172638),
                      contentPadding: const EdgeInsets.all(16),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${_editor.text.length} caracteres • ainda não executado',
                  style: const TextStyle(color: Color(0xFF9AABC2), fontSize: 11),
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _copy,
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('Copiar'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _paste,
                      icon: const Icon(Icons.content_paste),
                      label: const Text('Colar'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _clear,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Limpar'),
                    ),
                    TextButton(
                      onPressed: _cancel,
                      child: const Text('Cancelar'),
                    ),
                    FilledButton.icon(
                      onPressed: _apply,
                      icon: const Icon(Icons.check),
                      label: const Text('Aplicar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
