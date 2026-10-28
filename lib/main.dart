import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

import 'command_editor_page.dart';
import 'command_history_page.dart';
import 'terminal_copy.dart';
import 'workspace_editor.dart';
import 'agent_ia_page.dart'; // QELTRAVYX_ALPHA097_AGENT
import 'file_explorer_page.dart';
import 'packages_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const QeltravyxApp());
}

class QeltravyxApp extends StatelessWidget {
  const QeltravyxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QELTRAVYX',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A101B),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF43E7AB),
          brightness: Brightness.dark,
        ),
      ),
      home: const TerminalPage(),
    );
  }
}

class ShellTab {
  ShellTab(this.id, this.title, String version)
    : log =
          'QELTRAVYX ALPHA $version\n'
          'PTY Android: /system/bin/sh (sem root)\n'
          'Terminal interativo com suporte ANSI.\n\n';

  final int id;
  final String title;
  String log;
  String draft = '';
  String savedDraft = '';
  int historyCursor = -1;
  bool connected = true;
  final Terminal terminal = Terminal(maxLines: 5000);
  final TerminalController controller = TerminalController();
}

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  static const MethodChannel _shell = MethodChannel('qeltravyx/shell');
  static const MethodChannel _versionChannel = MethodChannel(
    'qeltravyx/version',
  );
  static const EventChannel _events = EventChannel('qeltravyx/output');

  static const green = Color(0xFF43E7AB);
  static const muted = Color(0xFF97A7BA);

  final TextEditingController _command = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  final List<ShellTab> _tabs = [];
  final List<String> _history = [];
  StreamSubscription<dynamic>? _subscription;

  final Map<int, String> _pendingOutput = {};
  int? _activeId;
  bool _creating = false;
  String _appVersion = '0.9.4';
  // QELTRAVYX_ALPHA092_ZOOM: ajuste somente visual; PTY nativo preservado.
  double _terminalFontSize = 14.0;

  ShellTab? get _active {
    for (final t in _tabs) {
      if (t.id == _activeId) return t;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _subscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error) {
        final t = _active;
        if (t != null) _append(t, '\n[Erro no canal] $error\n');
      },
    );
    _initialize();
  }

  // QELTRAVYX_ALPHA094_HISTORY: usa a versão real do APK instalado.
  Future<void> _loadAppVersion() async {
    try {
      final version = await _versionChannel.invokeMethod<String>('getVersion');
      if (!mounted || version == null || version.isEmpty) return;
      setState(() => _appVersion = version);
    } catch (_) {
      // Fallback local: terminal continua utilizável se canal estiver indisponível.
    }
  }

  Future<void> _initialize() async {
    await _loadAppVersion();
    try {
      final commands = await _shell.invokeListMethod<String>('getHistory');
      if (!mounted) return;
      _history.addAll(commands ?? const <String>[]);
    } catch (_) {
      // O terminal continua funcionando mesmo sem histórico salvo.
    }
    // The 73 MB standard library is extracted only once, outside the UI thread.
    // Keep Android/Bash terminal accessible if Python preparation fails.
    try {
      await _shell.invokeMethod<void>('preparePythonRuntime');
    } on PlatformException catch (e) {
      _message('Python ainda não preparado: ${e.message}');
    }
    if (mounted) await _createTab();
  }

  Future<void> _createTab() async {
    if (_creating || _tabs.length >= 4) return;
    setState(() => _creating = true);
    try {
      final id = await _shell.invokeMethod<int>('createSession');
      if (!mounted || id == null) return;
      final tab = ShellTab(id, 'Shell $id', _appVersion);
      setState(() {
        _tabs.add(tab);
      });
      _selectTab(tab);
      tab.terminal.onOutput = (data) => _sendRaw(tab, data);
      tab.terminal.onResize = (w, h, pw, ph) {
        if (w > 0 && h > 0 && tab.connected) {
          _shell
              .invokeMethod<void>('resizeSession', {
                'sessionId': tab.id,
                'rows': h,
                'cols': w,
              })
              .catchError((Object _) {});
        }
      };
      tab.terminal.write('QELTRAVYX ALPHA $_appVersion | PTY Android\r\n');
      if (_pendingOutput.containsKey(id)) {
        tab.terminal.write(_pendingOutput.remove(id)!);
      }
      _append(tab, '[Sessão $id conectada]\n');
    } on PlatformException catch (e) {
      _message('Não foi possível abrir a sessão: ${e.message}');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _onEvent(dynamic event) {
    if (!mounted || event is! Map) return;
    final id = event['sessionId'];
    if (id is! int) return;
    ShellTab? tab;
    for (final t in _tabs) {
      if (t.id == id) tab = t;
    }
    if (tab == null) {
      if (event['type'] == 'output') {
        _pendingOutput[id] =
            (_pendingOutput[id] ?? '') + (event['data'] ?? '').toString();
      }
      return;
    }
    if (event['type'] == 'output') {
      final data = (event['data'] ?? '').toString();
      tab.terminal.write(data);
      tab.log += data;
      if (tab.log.length > 55000)
        tab.log = tab.log.substring(tab.log.length - 42000);
    } else if (event['type'] == 'exit') {
      setState(() => tab!.connected = false);
      tab.terminal.write('\r\n[Sessão encerrada. Reinicie a aba.]\r\n');
    }
  }

  void _append(ShellTab tab, String value) {
    if (!mounted) return;
    setState(() {
      tab.log += value;
      if (tab.log.length > 55000) {
        tab.log =
            '… [saída anterior reduzida]\n' +
            tab.log.substring(tab.log.length - 42000);
      }
    });
    if (tab.id == _activeId) _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _selectTab(ShellTab tab) {
    final previous = _active;
    if (previous != null) previous.draft = _command.text;
    setState(() => _activeId = tab.id);
    _setInput(tab.draft);
    _scrollToBottom();
  }

  void _setInput(String text) {
    _command.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _changeTerminalFontSize(double delta) {
    final next = (_terminalFontSize + delta).clamp(10.0, 20.0).toDouble();
    if (next == _terminalFontSize) return;
    setState(() => _terminalFontSize = next);
  }

  Future<void> _sendRaw(ShellTab tab, String data) async {
    if (!tab.connected || data.isEmpty) return;
    try {
      await _shell.invokeMethod<void>('sendInput', {
        'sessionId': tab.id,
        'data': data,
      });
    } catch (error) {
      tab.terminal.write('\r\n[Erro de escrita: $error]\r\n');
    }
  }

  // QELTRAVYX_ALPHA_093_COMMAND_EDITOR: preparar sem enviar ao PTY.
  Future<void> _editCommandExpanded() async {
    final tab = _active;
    if (tab == null || !tab.connected) return;
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => CommandEditorPage(initialText: _command.text),
      ),
    );
    if (!mounted || result == null || _activeId != tab.id || !tab.connected) {
      return;
    }
    _setInput(result);
    tab.draft = result;
  }

  Future<void> _send([String? preset]) async {
    final tab = _active;
    if (tab == null || !tab.connected) return;
    // Preserva as quebras de linha de comandos colados do Termux.
    final original = preset ?? _command.text;
    final command = original
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trimRight();
    if (command.trim().isEmpty) return;

    if (command.contains('\n')) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Executar ${command.split('\n').length} linhas?'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                command.length > 1800
                    ? '${command.substring(0, 1800)}\n… (prévia abreviada)'
                    : command,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Executar'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted || !tab.connected) return;
    }

    if (preset == null && tab.id == _activeId) {
      // Se o usuário alterou o campo enquanto via a prévia, não o apaga.
      if (_command.text == original) {
        _command.clear();
        tab.draft = '';
      }
    }

    try {
      await _shell.invokeMethod<void>('sendCommand', {
        'sessionId': tab.id,
        'command': command,
      });
      if (_history.isEmpty || _history.last != command) _history.add(command);
      if (_history.length > 100) _history.removeAt(0);
      tab.historyCursor = -1;
    } on PlatformException catch (e) {
      tab.terminal.write('\r\n[Falha no envio] ${e.message}\r\n');
    } catch (e) {
      tab.terminal.write('\r\n[Falha] $e\r\n');
    }
  }

  Future<void> _pasteClipboard() async {
    if (_active?.connected != true) return;
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || clip?.text == null) return;
    final inserted = clip!.text!
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final oldText = _command.text;
    final range = _command.selection;
    final start = range.start < 0 ? oldText.length : range.start;
    final end = range.end < 0 ? oldText.length : range.end;
    _command.value = TextEditingValue(
      text: oldText.replaceRange(start, end, inserted),
      selection: TextSelection.collapsed(offset: start + inserted.length),
    );
    _focus.requestFocus();
  }

  void _navigateHistory(bool up) {
    final tab = _active;
    if (tab == null || _history.isEmpty) return;
    if (tab.historyCursor == -1) {
      if (!up) return;
      tab.savedDraft = _command.text;
      tab.historyCursor = _history.length - 1;
    } else if (up) {
      if (tab.historyCursor > 0) tab.historyCursor--;
    } else {
      if (tab.historyCursor < _history.length - 1) {
        tab.historyCursor++;
      } else {
        tab.historyCursor = -1;
        _setInput(tab.savedDraft);
        return;
      }
    }
    _setInput(_history[tab.historyCursor]);
  }

  void _insertTab() {
    if (_active?.connected != true) return;
    final text = _command.text;
    final selection = _command.selection;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? text.length : selection.end;
    _command.value = TextEditingValue(
      text: text.replaceRange(start, end, '\t'),
      selection: TextSelection.collapsed(offset: start + 1),
    );
    _focus.requestFocus();
  }

  Future<void> _restart() async {
    final tab = _active;
    if (tab == null) return;
    setState(() => tab.connected = false);
    tab.terminal.write('\r\n--- Reiniciando o PTY ---\r\n');
    try {
      await _shell.invokeMethod<void>('restartSession', {'sessionId': tab.id});
      if (!mounted) return;
      setState(() => tab.connected = true);
      tab.terminal.write('\r\n[Novo PTY conectado]\r\n');
    } on PlatformException catch (e) {
      tab.terminal.write('\r\n[Erro ao reiniciar] ${e.message}\r\n');
    }
  }

  Future<void> _closeTab(ShellTab tab) async {
    try {
      await _shell.invokeMethod<void>('stopSession', {'sessionId': tab.id});
    } catch (_) {
      // Mesmo sem resposta, retira a aba da interface.
    }
    if (!mounted) return;
    final wasActive = _activeId == tab.id;
    setState(() {
      _tabs.remove(tab);
      _pendingOutput.remove(tab.id);
      if (wasActive) _activeId = null;
    });
    if (wasActive && _tabs.isNotEmpty) _selectTab(_tabs.last);
    if (_tabs.isEmpty) await _createTab();
  }

  // QELTRAVYX_WORKSPACE_ALPHA07: return to existing shell to run saved script.
  // QELTRAVYX_ALPHA095_EXPLORER: listagem e leitura sem alterar o motor PTY.
  Future<void> _openFilesExplorer() async {
    final scriptPath = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const QeltravyxFileExplorerPage(),
      ),
    );
    if (!mounted || scriptPath == null) return;
    final tab = _active;
    if (tab == null || !tab.connected) {
      _message('Abra uma sessao ativa para executar o script.');
      return;
    }
    final safe = scriptPath.replaceAll("'", r"'\''");
    await _send("python '$safe'");
  }

  // QELTRAVYX_ALPHA097_AGENT: UI de configuracao, sem IA em execucao.
  Future<void> _openAgentIa() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const QeltravyxAgentPage()),
    );
  }

  Future<void> _openWorkspace() async {
    final scriptPath = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QeltravyxWorkspacePage()),
    );
    if (!mounted || scriptPath == null) return;
    final tab = _active;
    if (tab == null || !tab.connected) {
      _message('Abra uma sessão de terminal para executar o script.');
      return;
    }
    // Kotlin validates the path and filenames; keep shell quoting defensive.
    final safe = scriptPath.replaceAll("'", "'\\''");
    await _send("python '$safe'");
  }

  // QELTRAVYX_PACKAGES_UI_ALPHA09: qpkg commands run in existing PTY.
  Future<void> _openPackages() async {
    final command = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QeltravyxPackagesPage()),
    );
    if (!mounted || command == null) return;
    if (_active?.connected != true) {
      _message('Abra uma sessão ativa para utilizar o QPKG.');
      return;
    }
    await _send(command);
  }

  // QELTRAVYX_ALPHA094_HISTORY: recuperar, buscar, copiar ou editar.
  Future<void> _showHistory() async {
    // QELTRAVYX_HISTORY_SYNC: Android é a fonte do histórico salvo.
    try {
      final saved = await _shell.invokeListMethod<String>('getHistory');
      if (!mounted) return;
      if (saved != null) {
        setState(() {
          _history
            ..clear()
            ..addAll(saved);
        });
      }
    } catch (error) {
      _message('Falha ao sincronizar histórico: $error');
    }

    if (_history.isEmpty) {
      _message('Ainda não há comandos no histórico.');
      return;
    }
    final current = _active;
    final selection = await Navigator.of(context)
        .push<QeltravyxHistorySelection>(
          MaterialPageRoute<QeltravyxHistorySelection>(
            builder: (_) => QeltravyxHistoryPage(
              commands: _history,
              onClear: () async {
                try {
                  await _shell.invokeMethod<void>('clearHistory');
                  if (!mounted) return false;
                  setState(() => _history.clear());
                  for (final t in _tabs) {
                    t.historyCursor = -1;
                    t.savedDraft = '';
                  }
                  return true;
                } catch (error) {
                  _message('Falha ao limpar histórico: $error');
                  return false;
                }
              },
            ),
          ),
        );
    if (!mounted ||
        selection == null ||
        current == null ||
        current.id != _activeId ||
        !current.connected)
      return;
    _setInput(selection.command);
    current.draft = selection.command;
    current.historyCursor = -1;
    if (selection.openEditor) await _editCommandExpanded();
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _command.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tab = _active;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: const Color(0xFF10192A),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'QELTRAVYX',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
            Text(
              'ADVANCED TERMINAL • ALPHA $_appVersion',
              style: TextStyle(fontSize: 9, letterSpacing: 1, color: muted),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _showHistory,
            tooltip: 'Histórico salvo',
            icon: const Icon(Icons.history, size: 20),
          ),
          IconButton(
            onPressed: tab == null
                ? null
                : () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: qeltravyxCopyTerminalText(tab.terminal),
                      ),
                    );
                    _message('Saída copiada.');
                  },
            tooltip: 'Copiar saída',
            icon: const Icon(Icons.copy_outlined, size: 20),
          ),
          IconButton(
            onPressed: tab == null
                ? null
                : () {
                    tab.terminal.write('\x1b[2J\x1b[H');
                    setState(() => tab.log = '');
                  },
            tooltip: 'Limpar tela',
            icon: const Icon(Icons.delete_sweep_outlined, size: 23),
          ),
          IconButton(
            onPressed: tab == null ? null : _restart,
            tooltip: 'Reiniciar shell atual',
            icon: const Icon(Icons.refresh, size: 23),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: const Color(0xFF10192A),
              height: 51,
              child: Row(
                children: [
                  Expanded(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _tabs.length,
                      itemBuilder: (context, index) {
                        final t = _tabs[index];
                        final selected = t.id == _activeId;
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 5,
                          ),
                          child: Material(
                            color: selected
                                ? const Color(0xFF1F3740)
                                : const Color(0xFF192638),
                            borderRadius: BorderRadius.circular(8),
                            child: Row(
                              children: [
                                InkWell(
                                  onTap: () => _selectTab(t),
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      6,
                                      4,
                                      6,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.circle,
                                          size: 8,
                                          color: t.connected
                                              ? green
                                              : Colors.orange,
                                        ),
                                        const SizedBox(width: 7),
                                        Text(
                                          t.title,
                                          style: TextStyle(
                                            color: selected
                                                ? Colors.white
                                                : muted,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => _closeTab(t),
                                  tooltip: 'Fechar ${t.title}',
                                  icon: const Icon(Icons.close, size: 15),
                                  visualDensity: VisualDensity.compact,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  IconButton(
                    onPressed: (_tabs.length >= 4 || _creating)
                        ? null
                        : _createTab,
                    tooltip: 'Nova sessão (máximo 4)',
                    icon: const Icon(Icons.add_circle_outline, color: green),
                  ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: const Color(0xFF10192A),
              child: Row(
                children: [
                  Icon(
                    Icons.circle,
                    size: 10,
                    color: tab?.connected == true ? green : Colors.orangeAccent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tab?.connected == true
                          ? 'PTY ANDROID CONECTADO'
                          : 'PTY DESCONECTADO',
                      style: const TextStyle(
                        color: muted,
                        fontSize: 11,
                        letterSpacing: .7,
                      ),
                    ),
                  ),
                  const Text(
                    'SEM ROOT',
                    style: TextStyle(color: green, fontSize: 10),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                color: const Color(0xFF060C14),
                padding: const EdgeInsets.all(4),
                child: tab == null
                    ? const Center(child: CircularProgressIndicator())
                    : TerminalView(
                        tab.terminal,
                        key: ValueKey('terminal-${tab.id}'),
                        controller: tab.controller,
                        autoResize: true,
                        textStyle: TerminalStyle(fontSize: _terminalFontSize),
                        autofocus: false,
                      ),
              ),
            ),
            Container(
              color: const Color(0xFF10192A),
              height: 47,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                children: [
                  _key('PROJETOS', _openWorkspace),
                  _key('ARQUIVOS', _openFilesExplorer),
                  _key('AGENT IA', _openAgentIa),
                  _key('PACOTES', _openPackages),
                  _key('HIST', _showHistory),
                  _key('H↑', () => _navigateHistory(true)),
                  _key('H↓', () => _navigateHistory(false)),
                  _key('A−', () => _changeTerminalFontSize(-1)),
                  _key('A+', () => _changeTerminalFontSize(1)),
                  _key('ESC', () {
                    if (tab != null) _sendRaw(tab, '\x1b');
                  }),
                  _key('CTRL+C', () {
                    if (tab != null) _sendRaw(tab, '\x03');
                  }),
                  _key('↑', () {
                    if (tab != null) _sendRaw(tab, '\x1b[A');
                  }),
                  _key('↓', () {
                    if (tab != null) _sendRaw(tab, '\x1b[B');
                  }),
                  _key('←', () {
                    if (tab != null) _sendRaw(tab, '\x1b[D');
                  }),
                  _key('→', () {
                    if (tab != null) _sendRaw(tab, '\x1b[C');
                  }),
                  _key('TAB', () {
                    if (tab != null) _sendRaw(tab, '\t');
                  }),
                  _key('COLAR', _pasteClipboard),
                  for (final c in [
                    'qhelp',
                    'qdoctor',
                    'qinfo',
                    'qprojects',
                    'pwd',
                    'ls',
                    'id',
                    'uname -a',
                    'date',
                  ])
                    _key(c, () => _send(c)),
                ],
              ),
            ),
            Container(
              color: const Color(0xFF10192A),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  const Text(
                    '\$ ',
                    style: TextStyle(
                      color: green,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      fontSize: 19,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _command,
                      focusNode: _focus,
                      enabled: tab?.connected == true,
                      // O modo multiline impede que o teclado una comandos
                      // colados, como "cd /system" e "pwd".
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      minLines: 1,
                      maxLines: 8,
                      textAlignVertical: TextAlignVertical.top,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Digite um comando...',
                        hintStyle: const TextStyle(color: muted),
                        filled: true,
                        fillColor: const Color(0xFF172638),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(9),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: tab?.connected == true
                        ? _editCommandExpanded
                        : null,
                    tooltip: 'Ampliar editor de comandos',
                    icon: const Icon(Icons.open_in_full, size: 20),
                    color: green,
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    onPressed: tab?.connected == true ? () => _send() : null,
                    tooltip: 'Executar comando',
                    style: IconButton.styleFrom(
                      backgroundColor: green,
                      foregroundColor: const Color(0xFF071710),
                    ),
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _key(String title, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        label: Text(title, style: const TextStyle(fontSize: 12)),
        onPressed: _active?.connected == true ? onTap : null,
        side: const BorderSide(color: Color(0xFF355062)),
        backgroundColor: const Color(0xFF1A2C3A),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
