import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/agent_pro_hub.dart';

void main() {
  testWidgets('acoes sao bloqueadas sem projeto', (tester) async {
    var actions = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentProHub(
            project: null,
            busy: false,
            canPrepareRepair: false,
            onGenerate: () => actions++,
            onPrepareRepair: () => actions++,
            onRunTest: () => actions++,
          ),
        ),
      ),
    );

    final generate = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Gerar / editar codigo'),
    );
    expect(generate.onPressed, isNull);
    expect(actions, 0);
  });

  testWidgets('geracao e teste acionam fluxos delegados', (tester) async {
    var generates = 0;
    var tests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentProHub(
              project: 'teste_python',
              busy: false,
              canPrepareRepair: false,
              onGenerate: () => generates++,
              onPrepareRepair: () {},
              onRunTest: () => tests++,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Gerar / editar codigo'));
    await tester.tap(find.text('Testar Python'));
    expect(generates, 1);
    expect(tests, 1);
    final repair = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Preparar correcao'),
    );
    expect(repair.onPressed, isNull);
  });

  testWidgets('correcao habilita somente apos erro detectado', (tester) async {
    var repairs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentProHub(
              project: 'teste_python',
              busy: false,
              canPrepareRepair: true,
              onGenerate: () {},
              onPrepareRepair: () => repairs++,
              onRunTest: () {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Preparar correcao'));
    expect(repairs, 1);
  });
}
