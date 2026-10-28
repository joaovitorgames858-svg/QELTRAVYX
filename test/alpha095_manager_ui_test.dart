import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/workspace_manager_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('qeltravyx/workspace');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('explorador gerencia projetos e pastas via canal privado', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'listProjects') return <String>['teste_python'];
          if (call.method == 'listEntries') {
            return <Map<String, Object>>[
              <String, Object>{'name': 'main.py', 'isDirectory': false},
              <String, Object>{'name': 'scripts', 'isDirectory': true},
            ];
          }
          if (call.method == 'readTextFile') return 'print("OK")';
          return null;
        });

    await tester.pumpWidget(
      const MaterialApp(home: QeltravyxWorkspaceManagerPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('teste_python'), findsOneWidget);
    await tester.tap(find.text('teste_python'));
    await tester.pumpAndSettle();
    expect(find.text('main.py'), findsOneWidget);
    expect(find.text('scripts'), findsOneWidget);
    await tester.tap(find.text('main.py'));
    await tester.pumpAndSettle();
    expect(find.text('Salvar arquivo'), findsOneWidget);
  });
}
