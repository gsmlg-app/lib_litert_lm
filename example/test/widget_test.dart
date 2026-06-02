import 'package:example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders LiteRT-LM controls', (WidgetTester tester) async {
    await tester.pumpWidget(const LiteRtLmExampleApp());

    expect(find.text('LiteRT-LM'), findsOneWidget);
    expect(find.byIcon(Icons.folder_open), findsOneWidget);
    expect(find.text('Load'), findsOneWidget);
    expect(find.text('Generate'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });
}
