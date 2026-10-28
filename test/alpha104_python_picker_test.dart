import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/agent_python_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('seleciona um script dentro de uma subpasta', (tester) async {
    const channel = MethodChannel('qeltravyx/workspace');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'listEntries');
      final args = Map<String, dynamic>.from(call.arguments as Map);
      expect(args['project'], 'teste_python');
      if (args['file'] == '') {
        return <Map<String, Object>>[
          <String, Object>{'name': 'laboratorio095', 'isDirectory': true},
        ];
      }
      expect(args['file'], 'laboratorio095');
      return <Map<String, Object>>[
        <String, Object>{'name': 'erro099.py', 'isDirectory': false},
        <String, Object>{'name': 'config.json', 'isDirectory': false},
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    String? selection;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                selection = await showAgentPythonPicker(
                  context: context,
                  project: 'teste_python',
                );
              },
              child: const Text('Abrir arquivos'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Abrir arquivos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('laboratorio095'));
    await tester.pumpAndSettle();
    expect(find.text('config.json'), findsNothing);
    await tester.tap(find.text('erro099.py'));
    await tester.pumpAndSettle();
    expect(selection, 'laboratorio095/erro099.py');
  });
}
