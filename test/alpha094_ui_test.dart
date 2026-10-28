import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qeltravyx/command_editor_page.dart';
import 'package:qeltravyx/command_history_page.dart';

void main() {
  testWidgets('Aplicar editor devolve rascunho, sem execução', (tester) async {
    String? received;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => Scaffold(
        body: ElevatedButton(
          onPressed: () async {
            received = await Navigator.of(context).push<String>(
              MaterialPageRoute(
                builder: (_) => const CommandEditorPage(initialText: 'echo original'),
              ),
            );
          },
          child: const Text('Abrir'),
        ),
      )),
    ));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'echo ALTERADO');
    await tester.tap(find.text('Aplicar').first);
    await tester.pumpAndSettle();
    expect(received, 'echo ALTERADO');
  });

  testWidgets('Histórico seleciona comando sem executar', (tester) async {
    QeltravyxHistorySelection? received;
    final history = <String>['echo antigo', 'echo novo'];
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => Scaffold(
        body: ElevatedButton(
          onPressed: () async {
            received = await Navigator.of(context).push<QeltravyxHistorySelection>(
              MaterialPageRoute(
                builder: (_) => QeltravyxHistoryPage(
                  commands: history,
                  onClear: () async {
                    history.clear();
                    return true;
                  },
                ),
              ),
            );
          },
          child: const Text('Abrir histórico'),
        ),
      )),
    ));
    await tester.tap(find.text('Abrir histórico'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('echo novo'));
    await tester.pumpAndSettle();
    expect(received?.command, 'echo novo');
    expect(received?.openEditor, isFalse);
  });
}
