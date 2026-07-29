import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_theme.dart';

void main() {
  testWidgets('NeoRecall theme builds MaterialApp shell', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.light),
        darkTheme: buildNeoRecallTheme(Brightness.dark),
        home: const Scaffold(body: Text('NeoRecall')),
      ),
    );
    expect(find.text('NeoRecall'), findsOneWidget);
  });
}
