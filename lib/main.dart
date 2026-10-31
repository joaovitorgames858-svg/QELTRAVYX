import 'dart:async';

import 'core_prompt.dart';
import 'core_v1.dart';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

import 'command_editor_page.dart';
import 'command_history_page.dart';
import 'terminal_copy.dart';
import 'script_command.dart';
import 'runtime_status_panel.dart';

import 'dart:convert';

import 'terminal_selection_overlay.dart';
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
          'PTY Android: GNU Bash (sem root)\n'
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
  final viewKey = GlobalKey<TerminalViewState>();
  final scrollController = ScrollController();
}

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage>
    with WidgetsBindingObserver {
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
  final FocusNode _coreFocus = FocusNode();
  final Object _inputRegion = Object();
  bool _typing = false;
  bool _imeWasVisible = false;
  int _typingRequest = 0;
  bool _sending = false;
  PointerEvent? _dismissedInputEvent;
  PointerEvent? _terminalTapEvent;

  void _beginTyping() {
    if (_pinchKeyboardGuard || (_shellMode && _active?.connected != true)) {
      return;
    }
    _active?.controller.clearSelection();
    final request = ++_typingRequest;
    setState(() => _typing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_typing || request != _typingRequest) return;
      final focus = _shellMode ? _focus : _coreFocus;
      focus.requestFocus();
      // Let EditableText attach its input connection after the layout/focus
      // change. Explicit show also handles an already focused, hidden IME.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _typing && request == _typingRequest && focus.hasFocus) {
          SystemChannels.textInput
              .invokeMethod<void>('TextInput.show')
              .catchError((Object _) {});
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  void _endTyping() {
    _typingRequest++;
    if (!_typing) return;
    setState(() => _typing = false);
    _focus.unfocus();
    _coreFocus.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  void _inputTapOutside(PointerDownEvent event) {
    if (!_typing || ModalRoute.of(context)?.isCurrent != true) return;
    _dismissedInputEvent = event.original ?? event;
    _endTyping();
  }

  @override
  void didChangeMetrics() {
    final visible = View.of(context).viewInsets.bottom > 0;
    if (_imeWasVisible &&
        !visible &&
        ModalRoute.of(context)?.isCurrent == true) {
      _endTyping();
    }
    _imeWasVisible = visible;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _endTyping();
  }

  final List<ShellTab> _tabs = [];
  final List<String> _history = [];
  StreamSubscription<dynamic>? _subscription;

  final Map<int, String> _pendingOutput = {};
  int? _activeId;
  bool _creating = false;
  String _appVersion = '1.0.8';
  bool _shellMode = false;
  final _corePromptKey = GlobalKey();
  // QELTRAVYX_ALPHA092_ZOOM: ajuste somente visual; PTY nativo preservado.
  double _terminalFontSize = 15.0;
  double? _zoomBaseFontSize;

  // QELTRAVYX_PINCH_ZOOM_V1
  final Map<int, Offset> _zoomPointers = <int, Offset>{};
  double? _zoomStartDistance;

  // QELTRAVYX_PINCH_KEYBOARD_FIX_V1
  bool _pinchKeyboardGuard = false;
  bool _selectionHandleDragging = false;
  bool _terminalMultiTouch = false;
  bool _terminalMenuOpen = false;

  void _hideImeDuringPinch() {
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  void _zoomPointerDown(PointerDownEvent event) {
    if (_selectionHandleDragging) return;
    _zoomPointers[event.pointer] = event.localPosition;

    if (_zoomPointers.length == 2) {
      final points = _zoomPointers.values.toList();
      _zoomStartDistance = (points[0] - points[1]).distance;
      _zoomBaseFontSize = _terminalFontSize;
      _pinchKeyboardGuard = true;
      _hideImeDuringPinch();
    } else if (_zoomPointers.length > 2) {
      _zoomStartDistance = null;
      _zoomBaseFontSize = null;
    }
  }

  void _zoomPointerMove(PointerMoveEvent event) {
    if (!_zoomPointers.containsKey(event.pointer)) return;

    _zoomPointers[event.pointer] = event.localPosition;

    if (_zoomPointers.length != 2 ||
        _zoomStartDistance == null ||
        _zoomStartDistance! < 12 ||
        _zoomBaseFontSize == null) {
      return;
    }

    final points = _zoomPointers.values.toList();
    final distance = (points[0] - points[1]).distance;

    final next = (_zoomBaseFontSize! * distance / _zoomStartDistance!)
        .clamp(10.0, 24.0)
        .toDouble();

    if (mounted && (next - _terminalFontSize).abs() >= 0.2) {
      setState(() => _terminalFontSize = next);
    }
  }

  void _zoomPointerFinish(PointerEvent event) {
    _zoomPointers.remove(event.pointer);
    _zoomStartDistance = null;
    _zoomBaseFontSize = null;

    if (_pinchKeyboardGuard) {
      // O terminal pode solicitar foco ao terminar o toque.
      // Oculta novamente apos o processamento do gesto.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _hideImeDuringPinch();
        }
      });

      if (_zoomPointers.isEmpty) {
        _pinchKeyboardGuard = false;
      }
    }
  }

  ShellTab? get _active {
    for (final t in _tabs) {
      if (t.id == _activeId) return t;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _qObservedZoom = _terminalFontSize.toDouble();
    _qRestoreZoom();
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
      tab.terminal.write(
        '\x1b[1;36mQELTRAVYX\x1b[0m ALPHA $_appVersion | PTY Android\r\n',
      );
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
    _endTyping();
    final previous = _active;
    if (previous != null) previous.draft = _command.text;
    setState(() {
      _activeId = tab.id;
      _selectionHandleDragging = false;
    });
    _zoomPointers.clear();
    _zoomStartDistance = null;
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
    final next = (_terminalFontSize + delta).clamp(10.0, 24.0).toDouble();
    if (next == _terminalFontSize) return;
    setState(() => _terminalFontSize = next);
  }

  Future<void> _haptic(Future<void> Function() feedback) async {
    try {
      await feedback();
    } catch (_) {
      // Unsupported/disabled haptics must never affect input or session state.
    }
  }

  Future<bool> _sendRaw(ShellTab tab, String data) async {
    if (!tab.connected || data.isEmpty) return false;
    try {
      await _shell.invokeMethod<void>('sendInput', {
        'sessionId': tab.id,
        'data': data,
      });
      return true;
    } catch (error) {
      tab.terminal.write('\r\n[Erro de escrita: $error]\r\n');
      return false;
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
    _beginTyping();
  }

  Future<void> _send([String? preset]) async {
    if (_sending) return;
    _sending = true;
    try {
      await _sendCommand(preset);
    } finally {
      _sending = false;
    }
  }

  Future<void> _sendCommand(String? preset) async {
    final tab = _active;
    if (tab == null || !tab.connected) return;
    // Preserva as quebras de linha de comandos colados do Termux.
    final original = preset ?? _command.text;
    final command = original
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trimRight();
    if (command.trim().isEmpty) {
      if (preset == null && await _sendRaw(tab, '\r')) {
        unawaited(_haptic(HapticFeedback.lightImpact));
        if (mounted && tab.id == _activeId) _endTyping();
      }
      return;
    }

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
      if (approved != true ||
          !mounted ||
          !tab.connected ||
          tab.id != _activeId) {
        return;
      }
    }

    try {
      await _shell.invokeMethod<void>('sendCommand', {
        'sessionId': tab.id,
        'command': command,
      });
      unawaited(_haptic(HapticFeedback.lightImpact));
      if (mounted &&
          preset == null &&
          tab.id == _activeId &&
          _command.text == original) {
        _command.clear();
        tab.draft = '';
      }
      if (_history.isEmpty || _history.last != command) _history.add(command);
      if (_history.length > 100) _history.removeAt(0);
      tab.historyCursor = -1;
      if (mounted && tab.id == _activeId) _endTyping();
    } on PlatformException catch (e) {
      tab.terminal.write('\r\n[Falha no envio] ${e.message}\r\n');
    } catch (e) {
      tab.terminal.write('\r\n[Falha] $e\r\n');
    }
  }

  bool _qCtrlNext = false;
  bool _qAltNext = false;

  void _qExtraKey(String key) {
    final tab = _active;
    if (tab == null || !tab.connected) return;

    const sequences = <String, String>{
      'ESC': '\x1b',
      '/': '/',
      '-': '-',
      'HOME': '\x1b[H',
      'END': '\x1b[F',
      'PGUP': '\x1b[5~',
      'PGDN': '\x1b[6~',
      'TAB': '\t',
      '↑': '\x1b[A',
      '↓': '\x1b[B',
      '←': '\x1b[D',
      '→': '\x1b[C',
    };

    const ctrlSequences = <String, String>{
      '/': '\x1f',
      '-': '\x1f',
      'HOME': '\x1b[1;5H',
      'END': '\x1b[1;5F',
      'PGUP': '\x1b[5;5~',
      'PGDN': '\x1b[6;5~',
      '↑': '\x1b[1;5A',
      '↓': '\x1b[1;5B',
      '←': '\x1b[1;5D',
      '→': '\x1b[1;5C',
    };

    String? sequence = sequences[key];
    if (sequence == null) return;

    if (_qCtrlNext) {
      sequence = ctrlSequences[key] ?? sequence;
    }
    if (_qAltNext) {
      sequence = '\x1b$sequence';
    }

    if (_qCtrlNext || _qAltNext) {
      setState(() {
        _qCtrlNext = false;
        _qAltNext = false;
      });
    }

    _sendRaw(tab, sequence);
  }

  Future<void> _qTerminalMenu(Offset globalPosition) async {
    if (!mounted ||
        _terminalMenuOpen ||
        _selectionHandleDragging ||
        _terminalMultiTouch ||
        _pinchKeyboardGuard) {
      return;
    }
    final tab = _active;
    if (tab == null) return;

    final selection = tab.controller.selection;
    final selectedText = selection == null
        ? ''
        : tab.terminal.buffer.getText(selection);

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final local = overlay.globalToLocal(globalPosition);

    _terminalMenuOpen = true;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(local.dx, local.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (selectedText.isNotEmpty)
          const PopupMenuItem(
            value: 'selection',
            child: Text('Copiar seleção'),
          ),
        const PopupMenuItem(value: 'paste', child: Text('Colar')),
        const PopupMenuItem(value: 'type', child: Text('Digitar comando')),
        const PopupMenuItem(value: 'all', child: Text('Copiar saída inteira')),
      ],
    );
    _terminalMenuOpen = false;

    if (!mounted || _active?.id != tab.id) return;

    if (action == 'selection' && selectedText.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: selectedText));
    } else if (action == 'all') {
      await Clipboard.setData(
        ClipboardData(text: qeltravyxCopyTerminalText(tab.terminal)),
      );
    } else if (action == 'paste') {
      await _qPasteTerminal(tab.id);
    } else if (action == 'type') {
      if (!_shellMode) {
        _endTyping();
        setState(() => _shellMode = true);
      }
      _beginTyping();
    }
  }

  Future<void> _qPasteTerminal(int sessionId) async {
    if (_active?.id != sessionId || _active?.connected != true) {
      return;
    }

    final clip = await _readClipboard();
    if (!mounted || _active?.id != sessionId || _active?.connected != true) {
      return;
    }

    final value = (clip?.text ?? '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');

    if (value.isEmpty) return;

    if (value.contains('\n') ||
        RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(value)) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Revisar colagem antes de executar?'),
          content: const Text(
            'Esse conteúdo tem quebras de linha ou controles. '
            'Abra no campo de comandos para revisar; controles serão removidos. '
            'Nada será enviado até você executar.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Revisar'),
            ),
          ],
        ),
      );
      if (approved != true ||
          !mounted ||
          _activeId != sessionId ||
          _active?.connected != true) {
        return;
      }
      final review = value.replaceAll(
        RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'),
        '',
      );
      if (review.isEmpty) return;
      _insertClipboard(review);
      return;
    }

    final tab = _active;
    if (!mounted || tab == null || tab.id != sessionId || !tab.connected) {
      return;
    }

    if (await _sendRaw(tab, value)) {
      unawaited(_haptic(HapticFeedback.lightImpact));
    }
  }

  Future<void> _pasteClipboard() async {
    final tab = _active;
    if (tab?.connected != true) return;
    final clip = await _readClipboard();
    if (!mounted ||
        _active != tab ||
        tab!.connected != true ||
        clip?.text == null) {
      return;
    }
    final inserted = clip!.text!
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    if (inserted.isEmpty) return;
    _insertClipboard(inserted);
  }

  Future<ClipboardData?> _readClipboard() async {
    try {
      return await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      if (mounted) _message('Não foi possível ler a área de transferência.');
      return null;
    }
  }

  void _insertClipboard(String inserted) {
    if (!_shellMode) {
      _endTyping();
      setState(() => _shellMode = true);
    }
    final oldText = _command.text;
    final range = _command.selection;
    final start = range.start < 0 ? oldText.length : range.start;
    final end = range.end < 0 ? oldText.length : range.end;
    _command.value = TextEditingValue(
      text: oldText.replaceRange(start, end, inserted),
      selection: TextSelection.collapsed(offset: start + inserted.length),
    );
    _active?.draft = _command.text;
    _beginTyping();
    unawaited(_haptic(HapticFeedback.lightImpact));
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
    _beginTyping();
  }

  Future<void> _restart() async {
    final tab = _active;
    if (tab == null) return;
    setState(() => tab.connected = false);
    tab.terminal.write('\r\n--- Reiniciando o PTY ---\r\n');
    tab.controller.clearSelection();
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      tab.controller.dispose();
      tab.scrollController.dispose();
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
    await _runSavedScript(scriptPath);
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
    await _runSavedScript(scriptPath);
  }

  Future<void> _runSavedScript(String path) async {
    final tab = _active;
    if (tab == null || !tab.connected) return;
    final runtime = path.endsWith('.py')
        ? 'python'
        : path.endsWith('.js')
        ? 'node'
        : null;
    if (runtime == null) {
      _message('Selecione um arquivo .py ou .js');
      return;
    }
    try {
      final rows = await RuntimeStatusPanel.channel.invokeListMethod<dynamic>(
        'inspect',
      );
      final found = rows?.where((row) => row['name'] == runtime).firstOrNull;
      if (found == null || found['status'] != 'Instalado') {
        _message(
          '$runtime: ${found?['status'] ?? 'Não disponível'} • ${found?['reason'] ?? 'inspeção sem resposta'}',
        );
        return;
      }
    } catch (error) {
      _message('Não foi possível verificar $runtime: $error');
      return;
    }
    if (!mounted || _activeId != tab.id) return;
    final arguments = TextEditingController(text: '[]');
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Executar com $runtime'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(path, maxLines: 3),
            const Text(
              'Argumentos como lista JSON, exemplo: ["nome", "dois espaços"]. Use CTRL+C no terminal para interromper.',
            ),
            TextField(
              controller: arguments,
              decoration: const InputDecoration(labelText: 'Argumentos'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, arguments.text),
            child: const Text('Executar'),
          ),
        ],
      ),
    );
    // The route can still animate with its TextField attached for one frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => arguments.dispose());
    if (raw == null || !mounted || _activeId != tab.id || !tab.connected)
      return;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! List || parsed.any((e) => e is! String))
        throw const FormatException('Use uma lista de textos');
      setState(() => _shellMode = true);
      await _send(scriptCommand(path, parsed.cast<String>()));
    } catch (error) {
      _message('Argumentos inválidos: $error');
    }
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
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _shellMode = true);
    _setInput(selection.command);
    current.draft = selection.command;
    current.historyCursor = -1;
    _beginTyping();
    if (selection.openEditor) await _editCommandExpanded();
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    _command.dispose();
    _scroll.dispose();
    _focus.dispose();
    _coreFocus.dispose();
    for (final tab in _tabs) {
      tab.controller.dispose();
      tab.scrollController.dispose();
    }
    super.dispose();
  }

  void _menuAction(String action) {
    final tab = _active;
    switch (action) {
      case 'mode':
        _endTyping();
        FocusManager.instance.primaryFocus?.unfocus();
        setState(() => _shellMode = !_shellMode);
      case 'files':
        _openFilesExplorer();
      case 'projects':
        _openWorkspace();
      case 'history':
        _showHistory();
      case 'packages':
        _openPackages();
      case 'legacy':
        _openAgentIa();
      case 'restart':
        _restart();
      case 'smaller':
        _changeTerminalFontSize(-1);
        _qSaveZoom();
      case 'larger':
        _changeTerminalFontSize(1);
        _qSaveZoom();
      case 'copy':
        if (tab != null) {
          Clipboard.setData(
            ClipboardData(text: qeltravyxCopyTerminalText(tab.terminal)),
          );
          _message('Saída copiada.');
        }
      case 'clear':
        if (tab != null) {
          tab.terminal.write('\x1b[2J\x1b[H');
          setState(() => tab.log = '');
        }
    }
  }

  // QELTRAVYX_CLEAN_DRAWER_ZOOM_2026_V2
  static const String _qZoomPreference = 'qeltravyx_zoom_persistente';
  bool _qZoomEditedByUser = false;
  double? _qZoomLastSaved;
  double? _qObservedZoom;

  Future<void> _qRestoreZoom() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final stored = preferences.getDouble(_qZoomPreference);
      if (!mounted ||
          _qZoomEditedByUser ||
          stored == null ||
          !stored.isFinite) {
        return;
      }
      final zoom = stored.clamp(6.0, 72.0).toDouble();
      setState(() {
        _terminalFontSize = zoom;
      });
      _qZoomLastSaved = zoom;
      _qObservedZoom = zoom;
    } catch (_) {
      // If preferences cannot be loaded, keep the existing font size.
    }
  }

  Future<void> _qSaveZoom() async {
    _qZoomEditedByUser = true;
    final value = _terminalFontSize.toDouble();
    _qObservedZoom = value;
    if (_qZoomLastSaved == value) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      if (await preferences.setDouble(_qZoomPreference, value)) {
        _qZoomLastSaved = value;
      }
    } catch (_) {
      // Do not interrupt terminal operation if saving fails.
    }
  }

  void _qMaybeSaveZoom() {
    if (_qObservedZoom != _terminalFontSize.toDouble()) {
      _qSaveZoom();
    }
  }

  Widget _qDrawerEntry(String title, IconData icon, String action) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(title),
      onTap: () {
        Navigator.of(context).pop();
        _menuAction(action);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tab = _active;
    return PopScope(
      canPop: !_typing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _endTyping();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        drawerEnableOpenDragGesture: !_selectionHandleDragging,
        drawerEdgeDragWidth: 40,
        drawer: Drawer(
          backgroundColor: const Color(0xFF101010),
          child: SafeArea(
            child: ListView(
              children: [
                const ListTile(
                  title: Text(
                    'QELTRAVYX',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  subtitle: Text('Sessões e ferramentas'),
                ),
                const Divider(),
                for (final session in _tabs)
                  ListTile(
                    leading: Icon(
                      Icons.terminal,
                      color: session.connected ? green : Colors.orange,
                    ),
                    title: Text(session.title),
                    selected: session.id == _activeId,
                    onTap: () {
                      Navigator.of(context).pop();
                      _selectTab(session);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('Nova sessão'),
                  enabled: _tabs.length < 4 && !_creating,
                  onTap: () {
                    Navigator.of(context).pop();
                    _createTab();
                  },
                ),
                const Divider(),
                _qDrawerEntry('Alternar Bash / CORE', Icons.swap_horiz, 'mode'),
                _qDrawerEntry('Arquivos', Icons.folder_open, 'files'),
                _qDrawerEntry(
                  'Projetos',
                  Icons.folder_copy_outlined,
                  'projects',
                ),
                _qDrawerEntry('Histórico', Icons.history, 'history'),
                _qDrawerEntry('Pacotes', Icons.apps, 'packages'),
                _qDrawerEntry(
                  'Agente legado',
                  Icons.smart_toy_outlined,
                  'legacy',
                ),
                const Divider(),
                _qDrawerEntry('Copiar saída', Icons.copy, 'copy'),
                _qDrawerEntry('Limpar tela', Icons.cleaning_services, 'clear'),
                _qDrawerEntry('Reiniciar Shell', Icons.restart_alt, 'restart'),
                _qDrawerEntry('Aumentar fonte', Icons.zoom_in, 'larger'),
                _qDrawerEntry('Diminuir fonte', Icons.zoom_out, 'smaller'),
              ],
            ),
          ),
        ),
        appBar: AppBar(
          backgroundColor: const Color(0xFF101010),
          toolbarHeight: 46,
          titleSpacing: 0,
          title: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                const Text(
                  'QELTRAVYX',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _shellMode ? 'BASH' : 'CORE V2',
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
          ),
          actions: [
            IconButton(
              tooltip: _typing
                  ? 'Ocultar digitação'
                  : 'Digitar comando ou tarefa',
              onPressed: _typing ? _endTyping : _beginTyping,
              icon: Icon(_typing ? Icons.keyboard_hide : Icons.keyboard),
            ),
            PopupMenuButton<String>(
              tooltip: 'Arquivos e configurações',
              icon: const Icon(Icons.more_vert),
              onSelected: _menuAction,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'mode',
                  child: Text(
                    _shellMode
                        ? 'Modo tarefa • CORE local'
                        : 'Modo comando • Bash',
                  ),
                ),
                const PopupMenuItem(value: 'files', child: Text('Arquivos')),
                const PopupMenuItem(value: 'projects', child: Text('Projetos')),
                const PopupMenuItem(
                  value: 'history',
                  child: Text('Histórico salvo'),
                ),
                const PopupMenuItem(value: 'copy', child: Text('Copiar saída')),
                const PopupMenuItem(value: 'clear', child: Text('Limpar tela')),
                const PopupMenuItem(
                  value: 'restart',
                  child: Text('Reiniciar shell'),
                ),
                const PopupMenuItem(value: 'packages', child: Text('Pacotes')),
                const PopupMenuItem(
                  value: 'legacy',
                  child: Text('Avançado • agente cloud legado'),
                ),
                const PopupMenuItem(
                  value: 'smaller',
                  child: Text('Diminuir fonte'),
                ),
                const PopupMenuItem(
                  value: 'larger',
                  child: Text('Aumentar fonte'),
                ),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Container(
                color: const Color(0xFF101010),
                height: 38,
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
              Expanded(
                child: Container(
                  color: const Color(0xFF090909),
                  padding: const EdgeInsets.all(4),
                  child: tab == null
                      ? const Center(child: CircularProgressIndicator())
                      : Listener(
                          behavior: HitTestBehavior.translucent,
                          onPointerDown: (event) {
                            if (_zoomPointers.isEmpty) {
                              _terminalMultiTouch = false;
                            }
                            _terminalTapEvent = event.original ?? event;
                            _zoomPointerDown(event);
                            if (_zoomPointers.length > 1) {
                              _terminalMultiTouch = true;
                            }
                          },
                          onPointerMove: _zoomPointerMove,
                          onPointerUp: (event) {
                            _zoomPointerFinish(event);
                            _qMaybeSaveZoom();
                          },
                          onPointerCancel: (event) {
                            _zoomPointerFinish(event);
                            _qMaybeSaveZoom();
                          },
                          child: TerminalSelectionOverlay(
                            key: ValueKey('selection-${tab.id}'),
                            terminal: tab.terminal,
                            controller: tab.controller,
                            viewKey: tab.viewKey,
                            scrollController: tab.scrollController,
                            onPaste: () => _qPasteTerminal(tab.id),
                            onBlankLongPress: _qTerminalMenu,
                            onLongPress: () =>
                                unawaited(_haptic(HapticFeedback.vibrate)),
                            onHandleDrag: (dragging) {
                              setState(
                                () => _selectionHandleDragging = dragging,
                              );
                              _zoomPointers.clear();
                              _zoomStartDistance = null;
                            },
                            child: TerminalView(
                              tab.terminal,
                              key: tab.viewKey,
                              scrollController: tab.scrollController,
                              controller: tab.controller,
                              autoResize: true,
                              textStyle: TerminalStyle(
                                fontSize: _terminalFontSize,
                              ),
                              autofocus: false,
                              hardwareKeyboardOnly: true,
                              onPaste: () => _qPasteTerminal(tab.id),
                              onTapUp: (details, cell) {
                                if (identical(
                                      _dismissedInputEvent,
                                      _terminalTapEvent,
                                    ) ||
                                    _terminalMultiTouch ||
                                    _pinchKeyboardGuard ||
                                    _selectionHandleDragging ||
                                    _terminalMenuOpen ||
                                    tab.controller.selection != null) {
                                  return;
                                }
                                if (!terminalHasTextAt(
                                  tab.viewKey.currentState!,
                                  details.globalPosition,
                                )) {
                                  _beginTyping();
                                }
                              },
                              onSecondaryTapUp: (details, _) {
                                _qTerminalMenu(details.globalPosition);
                              },
                            ),
                          ),
                        ),
                ),
              ),
              // QELTRAVYX_TERMUX_KEYS_V1
              // Input and extra keys share one outside-tap region.
              if (_shellMode && _typing)
                TapRegion(
                  groupId: _inputRegion,
                  onTapOutside: _inputTapOutside,
                  child: Container(
                    color: const Color(0xFF101010),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: 5,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            _key('ESC', () => _qExtraKey('ESC')),
                            _key('/', () => _qExtraKey('/')),
                            _key('-', () => _qExtraKey('-')),
                            _key('HOME', () => _qExtraKey('HOME')),
                            _key('↑', () => _qExtraKey('↑')),
                            _key('END', () => _qExtraKey('END')),
                            _key('PGUP', () => _qExtraKey('PGUP')),
                          ],
                        ),
                        Row(
                          children: [
                            _key('TAB', () => _qExtraKey('TAB')),
                            _key('CTRL', () {
                              setState(() => _qCtrlNext = !_qCtrlNext);
                            }, active: _qCtrlNext),
                            _key('ALT', () {
                              setState(() => _qAltNext = !_qAltNext);
                            }, active: _qAltNext),
                            _key('←', () => _qExtraKey('←')),
                            _key('↓', () => _qExtraKey('↓')),
                            _key('→', () => _qExtraKey('→')),
                            _key('PGDN', () => _qExtraKey('PGDN')),
                          ],
                        ),
                        Row(
                          children: [
                            _key('COLAR', _pasteClipboard),
                            _key('HIST', _showHistory),
                            _key('H↑', () => _navigateHistory(true)),
                            _key('H↓', () => _navigateHistory(false)),
                            _key('A−', () {
                              _changeTerminalFontSize(-1);
                              _qSaveZoom();
                            }),
                            _key('A+', () {
                              _changeTerminalFontSize(1);
                              _qSaveZoom();
                            }),
                            _key('CTRL+C', () {
                              if (tab != null) _sendRaw(tab, '\x03');
                            }),
                            _key('TAB campo', _insertTab),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              // Keep CORE mounted across modes so in-flight work and scope survive.
              Offstage(
                key: const ValueKey('core-composer'),
                offstage: _shellMode || !_typing,
                child: TapRegion(
                  enabled: !_shellMode && _typing,
                  groupId: _inputRegion,
                  onTapOutside: _inputTapOutside,
                  child: CorePrompt(
                    key: _corePromptKey,
                    focusNode: _coreFocus,
                    onSubmitted: _endTyping,
                    onOutput: (output) {
                      final current = _active;
                      if (current != null) {
                        final safe = CoreSafety.display(output)
                            .replaceAll('\n', '\r\n');
                        // QELTRAVYX_CORE_TEXT_NORMAL_V2
                        current.terminal.write('\r\n[CORE V2] $safe\r\n');
                      }
                    },
                  ),
                ),
              ),
              if (_shellMode && _typing)
                TapRegion(
                  groupId: _inputRegion,
                  onTapOutside: _inputTapOutside,
                  child: Container(
                    color: const Color(0xFF101010),
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
                            key: const ValueKey('shell-command'),
                            controller: _command,
                            focusNode: _focus,
                            enabled: tab?.connected == true,
                            // O modo multiline impede que o teclado una comandos
                            // colados, como "cd /system" e "pwd".
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.send,
                            onEditingComplete: () {},
                            onSubmitted: (_) => _send(),
                            minLines: 1,
                            maxLines: 3,
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
                          onPressed: tab?.connected == true
                              ? () => _send()
                              : null,
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
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _key(String title, VoidCallback onTap, {bool active = false}) {
    return Expanded(
      child: SizedBox(
        height: 39,
        child: TextButton(
          onPressed: _active?.connected == true ? onTap : null,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: Colors.white,
            backgroundColor: active
                ? const Color(0xFF276F64)
                : Colors.transparent,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              title,
              maxLines: 1,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ),
      ),
    );
  }
}
