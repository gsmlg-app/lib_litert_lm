import 'package:example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('UI smoke only: controls without native inference', (
    tester,
  ) async {
    await tester.pumpWidget(const LiteRtLmExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('LiteRT-LM'), findsOneWidget);
    expect(find.byKey(const ValueKey('backendSelector')), findsOneWidget);
    expect(find.byKey(const ValueKey('contextSelector')), findsOneWidget);
    expect(find.byKey(const ValueKey('visionToggle')), findsOneWidget);

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

    // Wait for system keyboard dismissal and layout resize to settle
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    final toggleFinder = find.byKey(const ValueKey('visionToggle'));
    await tester.scrollUntilVisible(
      toggleFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(toggleFinder, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggleFinder).value, isFalse);

    await tester.tap(toggleFinder);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggleFinder).value, isTrue);

    final loadButton = find.widgetWithText(FilledButton, 'Load');
    await tester.scrollUntilVisible(
      loadButton,
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(loadButton);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('statusText')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Pick a .litertlm file first'), findsOneWidget);

    final generateButton = find.widgetWithText(FilledButton, 'Generate');
    await tester.ensureVisible(generateButton);
    await tester.tap(generateButton);
    await tester.pumpAndSettle();
    expect(find.text('Load a model first'), findsOneWidget);
  });
}
