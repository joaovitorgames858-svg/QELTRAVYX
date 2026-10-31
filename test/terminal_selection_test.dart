import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qeltravyx/terminal_selection_overlay.dart';
import 'package:xterm2/xterm.dart';

void main() {
  test('multi-line, independent endpoints and cancellation', () {
    final terminal = Terminal()
      ..resize(30, 5)
      ..write('alpha beta\r\ngamma delta');
    final controller = TerminalController();
    final selection = TerminalSelection(terminal, controller);
    selection.select(const CellOffset(6, 0), const CellOffset(5, 1));
    expect(selection.text.trimRight(), 'beta\ngamma');
    selection.move(true, const CellOffset(0, 0));
    expect(selection.text.trimRight(), 'alpha beta\ngamma');
    selection.move(false, const CellOffset(11, 1));
    expect(selection.text.trimRight(), 'alpha beta\ngamma delta');
    selection.cancel();
    expect(selection.range, isNull);
    controller.dispose();
  });

  test('Unicode, emoji and selection limited to its own buffer/session', () {
    final a = Terminal()
      ..resize(30, 5)
      ..write('ação 😀 fim');
    final b = Terminal()
      ..resize(30, 5)
      ..write('outra sessão');
    final c = TerminalController();
    final selection = TerminalSelection(a, c);
    selection.select(const CellOffset(0, 0), const CellOffset(7, 0));
    expect(selection.text, 'ação 😀');
    expect(TerminalSelection(b, c).range, isNull);
    a.write('\x1b[?1049h');
    expect(selection.range, isNull);
    a.write('\x1b[?1049l');
    expect(selection.text, 'ação 😀');
    c.dispose();
  });

  test('select all bounds scrollback and anchors survive scroll/reflow', () {
    final terminal = Terminal(maxLines: 100)..resize(20, 4);
    for (var i = 0; i < 30; i++) {
      terminal.write('line $i\r\n');
    }
    final controller = TerminalController();
    final selection = TerminalSelection(terminal, controller)
      ..selectAll(maxLines: 5);
    expect(selection.range!.end.y - selection.range!.begin.y, 4);
    selection.select(const CellOffset(0, 28), const CellOffset(7, 28));
    final text = selection.text;
    terminal.write('next\r\n');
    terminal.resize(15, 4);
    expect(selection.text, text);
    controller.dispose();
  });

  testWidgets(
    'one outside tap clears handles; selected text and scrolling retain selection',
    (tester) async {
      final terminal = Terminal()
        ..resize(60, 12)
        ..write('first row text\r\nsecond row text\r\nthird row text');
      final controller = TerminalController();
      final viewKey = GlobalKey<TerminalViewState>();
      final scroll = ScrollController();
      final selection = TerminalSelection(terminal, controller);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const SizedBox(
                  height: 60,
                  child: Center(child: Text('Outside terminal')),
                ),
                SizedBox(
                  width: 600,
                  height: 300,
                  child: TerminalSelectionOverlay(
                    terminal: terminal,
                    controller: controller,
                    viewKey: viewKey,
                    scrollController: scroll,
                    onPaste: () async {},
                    child: TerminalView(
                      terminal,
                      key: viewKey,
                      controller: controller,
                      scrollController: scroll,
                      hardwareKeyboardOnly: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      void select() =>
          selection.select(const CellOffset(0, 0), const CellOffset(12, 2));
      select();
      await tester.pumpAndSettle();
      final render = viewKey.currentState!.renderTerminal;
      Offset cell(int x, int y) =>
          render.localToGlobal(render.getOffset(CellOffset(x, y))) +
          const Offset(2, 2);
      await tester.tapAt(cell(9, 1));
      await tester.pumpAndSettle();
      expect(selection.range, isNotNull);
      await tester.dragFrom(cell(40, 6), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(selection.range, isNotNull);
      await tester.tapAt(cell(40, 6));
      await tester.pumpAndSettle();
      expect(selection.range, isNull);
      expect(find.byKey(const ValueKey('selection-start')), findsNothing);
      expect(find.byKey(const ValueKey('selection-end')), findsNothing);
      select();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Outside terminal'));
      await tester.pumpAndSettle();
      expect(selection.range, isNull);
      expect(find.byTooltip('Ações da seleção'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      scroll.dispose();
    },
  );

  testWidgets('persistent handles, drag, copy menu, font/viewport and cancel', (
    tester,
  ) async {
    final terminal = Terminal()
      ..resize(40, 8)
      ..write('alpha beta\r\ngamma delta');
    final controller = TerminalController();
    final viewKey = GlobalKey<TerminalViewState>();
    final scroll = ScrollController();
    var font = 15.0;
    Widget build() => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 240,
          child: TerminalSelectionOverlay(
            terminal: terminal,
            controller: controller,
            viewKey: viewKey,
            scrollController: scroll,
            onPaste: () async {},
            child: TerminalView(
              terminal,
              key: viewKey,
              controller: controller,
              scrollController: scroll,
              hardwareKeyboardOnly: true,
              textStyle: TerminalStyle(fontSize: font),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    final render = viewKey.currentState!.renderTerminal;
    await tester.longPressAt(
      render.localToGlobal(render.getOffset(const CellOffset(7, 0))) +
          const Offset(1, 3),
    );
    await tester.pumpAndSettle();
    final start = find.byKey(const ValueKey('selection-start'));
    final end = find.byKey(const ValueKey('selection-end'));
    expect(start, findsOneWidget);
    expect(end, findsOneWidget);
    expect(tester.getSize(start), const Size(48, 48));
    final oldStart = controller.selection!.normalized.begin.x;
    await tester.drag(start, const Offset(-30, 0));
    await tester.pumpAndSettle();
    expect(controller.selection!.normalized.begin.x, lessThan(oldStart));
    await tester.drag(end, const Offset(50, 20));
    await tester.pumpAndSettle();
    expect(controller.selection, isNotNull);
    final selected = TerminalSelection(terminal, controller).text;
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.tap(find.byTooltip('Ações da seleção'));
    await tester.pumpAndSettle();
    expect(controller.selection, isNotNull);
    await tester.tap(find.text('Copiar'));
    await tester.pumpAndSettle();
    expect(clipboard, selected);
    expect(end, findsOneWidget);
    font = 22;
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    expect(end, findsOneWidget);
    await tester.tap(find.byTooltip('Ações da seleção'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(end, findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    scroll.dispose();
  });
  testWidgets(
    'scroll, rotation and switching sessions preserve correct anchors',
    (tester) async {
      final terminals = [Terminal(maxLines: 100), Terminal(maxLines: 100)];
      for (final terminal in terminals) {
        terminal.resize(30, 8);
        for (var i = 0; i < 40; i++) {
          terminal.write('row $i abcdef\r\n');
        }
      }
      final controllers = [TerminalController(), TerminalController()];
      final keys = [
        GlobalKey<TerminalViewState>(),
        GlobalKey<TerminalViewState>(),
      ];
      final scrolls = [ScrollController(), ScrollController()];
      var active = 0;
      var size = const Size(380, 220);
      Widget build() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: size.width,
            height: size.height,
            child: TerminalSelectionOverlay(
              key: ValueKey(active),
              terminal: terminals[active],
              controller: controllers[active],
              viewKey: keys[active],
              scrollController: scrolls[active],
              onPaste: () async {},
              child: TerminalView(
                terminals[active],
                key: keys[active],
                controller: controllers[active],
                scrollController: scrolls[active],
                hardwareKeyboardOnly: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      final selection = TerminalSelection(terminals[0], controllers[0]);
      selection.select(const CellOffset(0, 35), const CellOffset(6, 36));
      await tester.pumpAndSettle();
      final text = selection.text;
      final first = tester.getTopLeft(
        find.byKey(const ValueKey('selection-start')),
      );
      scrolls[0].jumpTo(scrolls[0].offset - 20);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('selection-start'))).dy,
        closeTo(first.dy + 20, 0.1),
      );
      size = const Size(600, 180);
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      expect(selection.text, text);
      active = 1;
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('selection-start')), findsNothing);
      active = 0;
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      expect(selection.text, text);
      expect(find.byKey(const ValueKey('selection-start')), findsOneWidget);
      for (var i = 0; i < 120; i++) {
        terminals[0].write('new output\r\n');
      }
      await tester.pumpAndSettle();
      expect(
        selection.range,
        isNull,
      ); // Evicted text must not select unrelated output.
      await tester.pumpWidget(const SizedBox());
      for (final controller in controllers) {
        controller.dispose();
      }
      for (final scroll in scrolls) {
        scroll.dispose();
      }
    },
  );
}
