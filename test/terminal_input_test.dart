import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qeltravyx/main.dart';
import 'package:qeltravyx/core_prompt.dart';
import 'package:qeltravyx/terminal_selection_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

void main() {
  final sent = <MethodCall>[];
  final haptics = <String>[];
  bool failSend = false;
  bool failHaptic = false;
  Completer<void>? pendingSend;
  var session = 0;
  String clipboard = '';
  Completer<String>? pendingClipboard;
  setUp(() {
    session = 0;
    sent.clear();
    haptics.clear();
    failSend = false;
    failHaptic = false;
    pendingSend = null;
    clipboard = '';
    pendingClipboard = null;
    SharedPreferences.setMockInitialValues({
      'qeltravyx_zoom_persistente': 19.0,
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String? ?? 'vibrate');
        if (failHaptic) throw PlatformException(code: 'UNAVAILABLE');
      }
      if (call.method == 'Clipboard.getData') {
        return {
          'text': pendingClipboard == null
              ? clipboard
              : await pendingClipboard!.future,
        };
      }
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('qeltravyx/shell'), (
      call,
    ) async {
      sent.add(call);
      if (call.method == 'createSession') return ++session;
      if (call.method == 'getHistory') return ['echo salvo'];
      if (call.method == 'sendInput' || call.method == 'sendCommand') {
        if (failSend) throw PlatformException(code: 'PTY_WRITE_ERROR');
        if (pendingSend != null) await pendingSend!.future;
      }
      return null;
    });
    for (final channel in ['qeltravyx/output', 'qeltravyx/version']) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (_) async => null,
      );
    }
  });

  Future<void> start(WidgetTester tester) async {
    await tester.pumpWidget(const QeltravyxApp());
    await tester.pumpAndSettle();
  }

  Future<void> bash(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Arquivos e configurações'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Modo comando • Bash'));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Digitar comando ou tarefa'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
  }

  final input = find.byKey(const ValueKey('shell-command'));

  testWidgets(
    'hidden by default; CORE stays mounted and preserves draft across modes',
    (tester) async {
      await start(tester);
      expect(find.byType(TextField), findsNothing);
      final coreState = tester.state(
        find.byType(CorePrompt, skipOffstage: false),
      );
      await open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('core-prompt')),
        'rascunho CORE',
      );
      await bash(tester);
      expect(find.byType(TextField), findsNothing);
      expect(
        tester.state(find.byType(CorePrompt, skipOffstage: false)),
        same(coreState),
      );
      await tester.tap(find.byTooltip('Arquivos e configurações'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Modo tarefa • CORE local'));
      await tester.pumpAndSettle();
      await open(tester);
      expect(find.text('rascunho CORE'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'short tap opens typing and IME; outside tap hides once; send preserves channel',
    (tester) async {
      await start(tester);
      await bash(tester);
      final terminal = find.byType(TerminalView);
      expect(tester.widget<TerminalView>(terminal).textStyle.fontSize, 19);
      await tester.tap(terminal);
      await tester.pumpAndSettle();
      expect(find.text('Colar'), findsNothing);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(input, findsOneWidget);
      for (final key in [
        'ESC',
        '/',
        '-',
        'HOME',
        '↑',
        'END',
        'PGUP',
        'TAB',
        'CTRL',
        'ALT',
        '←',
        '↓',
        '→',
        'PGDN',
        'COLAR',
        'HIST',
        'H↑',
        'H↓',
        'A−',
        'A+',
        'CTRL+C',
        'TAB campo',
      ]) {
        expect(find.text(key), findsOneWidget);
      }
      await tester.enterText(input, 'echo preservado');
      await tester.tap(find.text('CTRL+C'));
      await tester.pumpAndSettle();
      expect(input, findsOneWidget);
      expect(
        sent.any(
          (c) =>
              c.method == 'sendInput' && (c.arguments as Map)['data'] == '\x03',
        ),
        isTrue,
      );
      await tester.tap(terminal);
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      expect(find.text('ESC'), findsNothing);
      await open(tester);
      expect(find.text('echo preservado'), findsOneWidget);
      await tester.tap(find.byTooltip('Executar comando'));
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      expect(sent.where((c) => c.method == 'sendCommand').single.arguments, {
        'sessionId': 1,
        'command': 'echo preservado',
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'mouse can reopen after outside dismissal; pinch retains hidden input and saves zoom',
    (tester) async {
      await start(tester);
      await bash(tester);
      final terminal = find.byType(TerminalView);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(terminal));
      for (var i = 0; i < 3; i++) {
        await mouse.down(tester.getCenter(terminal));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(find.text('Colar'), findsNothing);
        expect(input, i.isEven ? findsOneWidget : findsNothing);
      }
      await tester.tap(find.byTooltip('Ocultar digitação'));
      await tester.pumpAndSettle();
      final center = tester.getCenter(terminal);
      final first = await tester.startGesture(
        center - const Offset(40, 0),
        pointer: 11,
      );
      final second = await tester.startGesture(
        center + const Offset(40, 0),
        pointer: 12,
      );
      await first.moveTo(center - const Offset(50, 0));
      await second.moveTo(center + const Offset(50, 0));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      expect(find.text('Colar'), findsNothing);
      final font = tester.widget<TerminalView>(terminal).textStyle.fontSize;
      expect(font, greaterThan(19));
      expect(
        (await SharedPreferences.getInstance()).getDouble(
          'qeltravyx_zoom_persistente',
        ),
        font,
      );
      // Even two stationary fingers must not resolve into a paste menu when
      // the first finger lifts (before the second pointer is released).
      final touch1 = await tester.startGesture(
        center - const Offset(40, 0),
        pointer: 21,
      );
      final touch2 = await tester.startGesture(
        center + const Offset(40, 0),
        pointer: 22,
      );
      await touch1.up();
      await tester.pump();
      expect(find.text('Colar'), findsNothing);
      await touch2.up();
      await tester.pumpAndSettle();
      expect(find.text('Colar'), findsNothing);
      await tester.tap(terminal);
      await tester.pumpAndSettle();
      expect(input, findsOneWidget);
      expect(tester.testTextInput.isVisible, isTrue);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'IME close, back, drawer and session switch hide input and retain saved zoom',
    (tester) async {
      await start(tester);
      await bash(tester);
      await open(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pumpAndSettle();
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      await open(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      await open(tester);
      await tester.enterText(input, 'sessao um');
      await tester.tap(find.byTooltip('Nova sessão (máximo 4)'));
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      await tester.tap(find.text('Shell 1'));
      await tester.pumpAndSettle();
      await open(tester);
      expect(find.text('sessao um'), findsOneWidget);
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.text('Sessões e ferramentas'), findsOneWidget);
      expect(input, findsNothing);
      expect(
        (await SharedPreferences.getInstance()).getDouble(
          'qeltravyx_zoom_persistente',
        ),
        19,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  Future<void> pasteMenu(WidgetTester tester) async {
    await tester.longPress(find.byType(TerminalView));
    await tester.pumpAndSettle();
    expect(find.text('Colar'), findsOneWidget);
    await tester.tap(find.text('Colar'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'black surface pastes a large command into PTY without Enter or composer',
    (tester) async {
      await start(tester);
      await bash(tester);
      clipboard = 'printf "%s" "${List.filled(30000, 'ação😀').join()}"';
      await tester.longPress(find.byType(TerminalView));
      await tester.pumpAndSettle();
      expect(
        sent.where((c) => c.method == 'sendInput' || c.method == 'sendCommand'),
        isEmpty,
      );
      expect(input, findsNothing);
      await tester.tap(find.text('Colar'));
      await tester.pumpAndSettle();
      expect(sent.where((c) => c.method == 'sendInput').single.arguments, {
        'sessionId': 1,
        'data': clipboard,
      });
      expect(sent.where((c) => c.method == 'sendCommand'), isEmpty);
      expect(input, findsNothing);
      await open(tester);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'multiline and control pastes require review; nothing reaches PTY',
    (tester) async {
      await start(tester);
      await bash(tester);
      for (final value in [
        'echo um\r\necho dois\r',
        'echo fim\n',
        '\x03echo controle',
      ]) {
        clipboard = value;
        sent.clear();
        await pasteMenu(tester);
        expect(find.text('Revisar colagem antes de executar?'), findsOneWidget);
        expect(sent.where((c) => c.method == 'sendInput'), isEmpty);
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();
        expect(sent.where((c) => c.method == 'sendInput'), isEmpty);
        await pasteMenu(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Revisar'));
        await tester.pumpAndSettle();
        expect(sent.where((c) => c.method == 'sendInput'), isEmpty);
        expect(sent.where((c) => c.method == 'sendCommand'), isEmpty);
        expect(
          tester.widget<TextField>(input).controller!.text,
          value
              .replaceAll('\r\n', '\n')
              .replaceAll('\r', '\n')
              .replaceAll('\x03', ''),
        );
        await tester.enterText(input, '');
        await tester.tap(find.byTooltip('Ocultar digitação'));
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'paste is bound to its session, including asynchronous clipboard reads',
    (tester) async {
      await start(tester);
      await bash(tester);
      await tester.tap(find.byTooltip('Nova sessão (máximo 4)'));
      await tester.pumpAndSettle();
      clipboard = 'echo segunda';
      await pasteMenu(tester);
      expect(sent.where((c) => c.method == 'sendInput').single.arguments, {
        'sessionId': 2,
        'data': clipboard,
      });
      sent.clear();
      pendingClipboard = Completer<String>();
      await pasteMenu(tester);
      await tester.tap(find.text('Shell 1'));
      await tester.pumpAndSettle();
      pendingClipboard!.complete('não enviar para outra sessão');
      await tester.pumpAndSettle();
      expect(sent.where((c) => c.method == 'sendInput'), isEmpty);
      pendingClipboard = null;
      clipboard = 'echo primeira';
      await pasteMenu(tester);
      expect(sent.where((c) => c.method == 'sendInput').single.arguments, {
        'sessionId': 1,
        'data': clipboard,
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'selection handles, cancellation, pinch and drawer do not open paste',
    (tester) async {
      await start(tester);
      await bash(tester);
      final terminalFinder = find.byType(TerminalView);
      final view = tester.widget<TerminalView>(terminalFinder);
      view.terminal.write('alpha beta\r\ngamma delta\r\n');
      final selection = TerminalSelection(view.terminal, view.controller!);
      selection.select(const CellOffset(0, 0), const CellOffset(10, 1));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('selection-end')),
        const Offset(30, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Colar'), findsNothing);
      expect(selection.range, isNotNull);
      final center = tester.getCenter(terminalFinder);
      final touch1 = await tester.startGesture(
        center - const Offset(40, 0),
        pointer: 41,
      );
      final touch2 = await tester.startGesture(
        center + const Offset(40, 0),
        pointer: 42,
      );
      await touch1.up();
      await touch2.up();
      await tester.pumpAndSettle();
      expect(selection.range, isNotNull);
      expect(find.text('Colar'), findsNothing);
      final first = await tester.startGesture(
        center - const Offset(40, 0),
        pointer: 31,
      );
      final second = await tester.startGesture(
        center + const Offset(40, 0),
        pointer: 32,
      );
      await first.moveBy(const Offset(-20, 0));
      await second.moveBy(const Offset(20, 0));
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(selection.range, isNotNull);
      expect(find.text('Colar'), findsNothing);
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(selection.range, isNull);
      expect(find.byKey(const ValueKey('selection-start')), findsNothing);
      expect(find.text('Colar'), findsNothing);
      clipboard = 'echo após seleção';
      await pasteMenu(tester);
      expect(sent.where((c) => c.method == 'sendInput').single.arguments, {
        'sessionId': 1,
        'data': clipboard,
      });
      await tester.dragFrom(Offset(1, center.dy), const Offset(320, 0));
      await tester.pumpAndSettle();
      expect(find.text('Sessões e ferramentas'), findsOneWidget);
      expect(find.text('Colar'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'COLAR button retains composer editing and terminal keyboard paste uses PTY',
    (tester) async {
      await start(tester);
      await bash(tester);
      await open(tester);
      clipboard = 'echo rascunho';
      await tester.tap(find.text('COLAR'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, clipboard);
      expect(
        sent.where((c) => c.method == 'sendInput' || c.method == 'sendCommand'),
        isEmpty,
      );
      await tester.tap(find.byTooltip('Ocultar digitação'));
      await tester.pumpAndSettle();
      clipboard = 'echo teclado';
      await tester.widget<TerminalView>(find.byType(TerminalView)).onPaste!();
      await tester.pumpAndSettle();
      expect(sent.where((c) => c.method == 'sendInput').single.arguments, {
        'sessionId': 1,
        'data': clipboard,
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'one haptic per recognized hold and actual paste; no success on empty, cancel or failure',
    (tester) async {
      await start(tester);
      await bash(tester);
      final terminal = find.byType(TerminalView);
      clipboard = 'echo não executar';
      final hold = await tester.startGesture(tester.getCenter(terminal));
      await tester.pump(const Duration(seconds: 2));
      expect(haptics, ['vibrate']);
      expect(input, findsNothing);
      expect(tester.testTextInput.isVisible, isFalse);
      await hold.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Colar'));
      await tester.pumpAndSettle();
      expect(haptics, ['vibrate', 'HapticFeedbackType.lightImpact']);
      expect(sent.where((c) => c.method == 'sendCommand'), isEmpty);
      haptics.clear();
      clipboard = '';
      await pasteMenu(tester);
      expect(haptics, ['vibrate']);
      haptics.clear();
      await tester.longPress(terminal);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(haptics, ['vibrate']);
      haptics.clear();
      clipboard = 'echo falha';
      failSend = true;
      await pasteMenu(tester);
      expect(haptics, ['vibrate']);
      await open(tester);
      haptics.clear();
      clipboard = '';
      await tester.tap(find.text('COLAR'));
      await tester.pumpAndSettle();
      expect(haptics, isEmpty);
      clipboard = 'echo campo';
      await tester.tap(find.text('COLAR'));
      await tester.pumpAndSettle();
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Enter is sent once, haptic waits for native acceptance, failures preserve draft',
    (tester) async {
      await start(tester);
      await bash(tester);
      await open(tester);
      await tester.enterText(input, 'echo enviado');
      pendingSend = Completer<void>();
      final submit = tester.widget<TextField>(input).onSubmitted!;
      submit('echo enviado');
      submit('echo enviado');
      await tester.pump();
      expect(sent.where((c) => c.method == 'sendCommand'), hasLength(1));
      expect(haptics, isEmpty);
      pendingSend!.complete();
      await tester.pumpAndSettle();
      pendingSend = null;
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      expect(input, findsNothing);
      await open(tester);
      haptics.clear();
      failSend = true;
      await tester.enterText(input, 'echo manter');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(haptics, isEmpty);
      expect(tester.widget<TextField>(input).controller!.text, 'echo manter');
      failSend = false;
      failHaptic = true;
      await tester.tap(find.byTooltip('Executar comando'));
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      expect(tester.takeException(), isNull);
      await open(tester);
      haptics.clear();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(sent.where((c) => c.method == 'sendInput').single.arguments, {
        'sessionId': 1,
        'data': '\r',
      });
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'real long-press selects text, preserves handles on paste, and double tap still selects',
    (tester) async {
      await start(tester);
      await bash(tester);
      final finder = find.byType(TerminalView);
      final view = tester.widget<TerminalView>(finder);
      view.terminal.write('\x1b[2J\x1b[Halpha beta\r\ngamma delta');
      await tester.pumpAndSettle();
      final render = tester.state<TerminalViewState>(finder).renderTerminal;
      final word =
          render.localToGlobal(render.getOffset(const CellOffset(7, 0))) +
          const Offset(2, 3);
      await tester.longPressAt(word);
      await tester.pumpAndSettle();
      final selection = TerminalSelection(view.terminal, view.controller!);
      expect(selection.text.trim(), 'beta');
      expect(find.byKey(const ValueKey('selection-start')), findsOneWidget);
      expect(find.byKey(const ValueKey('selection-end')), findsOneWidget);
      expect(haptics, ['vibrate']);
      expect(input, findsNothing);
      expect(find.text('Colar'), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('selection-end')),
        const Offset(20, 20),
      );
      await tester.pumpAndSettle();
      expect(haptics, ['vibrate']);
      final selected = selection.text;
      clipboard = 'echo colado';
      await tester.tap(find.byTooltip('Ações da seleção'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Colar'));
      await tester.pumpAndSettle();
      expect(selection.text, selected);
      expect(haptics, ['vibrate', 'HapticFeedbackType.lightImpact']);
      await tester.tap(find.byTooltip('Nova sessão (máximo 4)'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('selection-start')), findsNothing);
      expect(find.byTooltip('Ações da seleção'), findsNothing);
      await tester.tap(find.text('Shell 1'));
      await tester.pumpAndSettle();
      // Tapping the tab bar is outside the selection and cancels it.
      expect(selection.range, isNull);
      expect(input, findsNothing);
      await tester.tapAt(word);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(word);
      await tester.pumpAndSettle();
      expect(selection.text.trim(), 'beta');
      expect(input, findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'multiline review preserves existing draft and requires explicit execution',
    (tester) async {
      await start(tester);
      await bash(tester);
      await open(tester);
      await tester.enterText(input, '# rascunho\n');
      await tester.tap(find.byTooltip('Ocultar digitação'));
      await tester.pumpAndSettle();
      clipboard = 'echo um\necho dois';
      await pasteMenu(tester);
      expect(haptics, ['vibrate']);
      await tester.tap(find.text('Revisar'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        '# rascunho\necho um\necho dois',
      );
      expect(haptics, ['vibrate', 'HapticFeedbackType.lightImpact']);
      expect(
        sent.where((c) => c.method == 'sendInput' || c.method == 'sendCommand'),
        isEmpty,
      );
      await tester.tap(find.byTooltip('Executar comando'));
      await tester.pumpAndSettle();
      expect(find.text('Executar 3 linhas?'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(sent.where((c) => c.method == 'sendCommand'), isEmpty);
      expect(haptics, hasLength(2));
      await tester.tap(find.byTooltip('Executar comando'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Executar'));
      await tester.pumpAndSettle();
      expect(sent.where((c) => c.method == 'sendCommand'), hasLength(1));
      expect(haptics, hasLength(3));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'resume and scroll leave IME closed; composer paste cannot cross tabs',
    (tester) async {
      await start(tester);
      await bash(tester);
      await open(tester);
      await tester.enterText(input, 'rascunho');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      expect(tester.testTextInput.isVisible, isFalse);
      final finder = find.byType(TerminalView);
      final view = tester.widget<TerminalView>(finder);
      for (var i = 0; i < 80; i++) {
        view.terminal.write('linha $i\r\n');
      }
      await tester.pumpAndSettle();
      await tester.drag(finder, const Offset(0, 150));
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      expect(find.text('Colar'), findsNothing);
      expect(haptics, isEmpty);
      await open(tester);
      expect(tester.widget<TextField>(input).controller!.text, 'rascunho');
      pendingClipboard = Completer<String>();
      await tester.tap(find.text('COLAR'));
      await tester.pump();
      await tester.tap(find.byTooltip('Nova sessão (máximo 4)'));
      await tester.pumpAndSettle();
      pendingClipboard!.complete('não inserir');
      await tester.pumpAndSettle();
      expect(haptics, isEmpty);
      await open(tester);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(sent.where((c) => c.method == 'createSession'), hasLength(2));
      expect(sent.where((c) => c.method == 'restartSession'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'black surface paste works while CORE is mounted; review opens Bash without discarding CORE draft',
    (tester) async {
      await start(tester);
      final coreState = tester.state(
        find.byType(CorePrompt, skipOffstage: false),
      );
      await open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('core-prompt')),
        'tarefa preservada',
      );
      await tester.tap(find.byTooltip('Ocultar digitação'));
      await tester.pumpAndSettle();
      clipboard = 'echo bash';
      await pasteMenu(tester);
      expect(sent.where((c) => c.method == 'sendInput').single.arguments, {
        'sessionId': 1,
        'data': clipboard,
      });
      expect(input, findsNothing);
      clipboard = 'echo um\necho dois';
      await pasteMenu(tester);
      await tester.tap(find.text('Revisar'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, clipboard);
      expect(
        tester.state(find.byType(CorePrompt, skipOffstage: false)),
        same(coreState),
      );
      await tester.tap(find.byTooltip('Arquivos e configurações'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Modo tarefa • CORE local'));
      await tester.pumpAndSettle();
      await open(tester);
      expect(find.text('tarefa preservada'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
