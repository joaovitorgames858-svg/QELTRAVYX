import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Renderizacao basica Flutter', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text('QELTRAVYX'),
        ),
      ),
    );

    expect(find.text('QELTRAVYX'), findsOneWidget);
  });
}
