import 'package:example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('drives the example app without a native model', (tester) async {
    await tester.pumpWidget(const LiteRtLmExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('LiteRT-LM'), findsOneWidget);
    expect(find.byKey(const ValueKey('backendSelector')), findsOneWidget);
    expect(find.byKey(const ValueKey('statusText')), findsOneWidget);
    expect(find.text('No model loaded'), findsOneWidget);

    await tester.tap(find.text('NPU'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('npuDispatchDirField')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('npuDispatchDirField')),
      '/data/app/native/lib',
    );
    await tester.pumpAndSettle();
    expect(find.text('/data/app/native/lib'), findsOneWidget);

    await tester.tap(find.text('GPU'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('npuDispatchDirField')), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Load'));
    await tester.pumpAndSettle();
    expect(find.text('Pick a .litertlm file first'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pumpAndSettle();
    expect(find.text('Load a model first'), findsOneWidget);
  });
}
