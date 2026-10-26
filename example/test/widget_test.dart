import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_litert_lm/lib_litert_lm.dart';
import 'package:lib_litert_lm/src/fake_backend.dart';

// UI/control-flow smoke tests. The fake backend does not validate native inference.
void main() {
  const pickerChannel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
  late FakeLiteRtLmBackend backend;
  late Map<String, Object?>? attachment;
  late List<bool> byteRequests;

  setUp(() {
    backend = FakeLiteRtLmBackend();
    attachment = null;
    byteRequests = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, (call) async {
          final args = call.arguments as Map;
          final extensions = args['allowedExtensions'] as List;
          if (extensions.contains('litertlm')) {
            return [
              {
                'name': 'model.litertlm',
                'path': '/tmp/model.litertlm',
                'size': 1,
              },
            ];
          }
          byteRequests.add(args['withData'] as bool);
          return attachment == null ? null : [attachment];
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, null);
  });

  Future<void> showApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      LiteRtLmExampleApp(
        createClient: () async => LiteRtLmOk(LiteRtLm.testing(backend)),
      ),
    );
  }

  Future<void> pickAndLoad(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.folder_open));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Load'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'renders text-only defaults, context and real attachment controls',
    (tester) async {
      await showApp(tester);
      expect(find.text('LiteRT-LM'), findsOneWidget);
      expect(find.byKey(const ValueKey('contextSelector')), findsOneWidget);
      expect(find.text('4K'), findsOneWidget);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('visionToggle')))
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('audioToggle')))
            .value,
        isFalse,
      );
      expect(find.textContaining('(Mock)'), findsNothing);
      expect(find.text('New conversation'), findsOneWidget);
    },
  );

  testWidgets(
    'load sends explicit context/modalities and turns reuse conversation',
    (tester) async {
      await showApp(tester);
      await tester.tap(find.text('8K'));
      await tester.tap(find.byKey(const ValueKey('visionToggle')));
      await tester.tap(find.byKey(const ValueKey('audioToggle')));
      await tester.pumpAndSettle();
      await pickAndLoad(tester);
      expect(backend.loadedConfigs.single.maxNumTokens, 8192);
      expect(backend.loadedConfigs.single.visionBackend, 'cpu');
      expect(backend.loadedConfigs.single.audioBackend, 'cpu');
      expect(find.textContaining('effective: unavailable'), findsOneWidget);
      for (var turn = 0; turn < 2; turn++) {
        await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
        await tester.pumpAndSettle();
      }
      expect(backend.createdConversations, hasLength(1));
      expect(backend.sentMessages, hasLength(2));
      expect(
        backend.sentMessages.every(
          (messages) => messages.length == 1 && messages.single.role == 'user',
        ),
        isTrue,
      );
      await tester.tap(find.text('New conversation'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
      await tester.pumpAndSettle();
      expect(backend.createdConversations, hasLength(2));
    },
  );

  testWidgets(
    'picked image bytes are sent and unreadable attachment is rejected',
    (tester) async {
      await showApp(tester);
      await tester.tap(find.byKey(const ValueKey('visionToggle')));
      await tester.pumpAndSettle();
      attachment = {'name': 'missing.png', 'path': null, 'size': 2};
      await tester.tap(find.byKey(const ValueKey('pickImage')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('No readable attachment bytes'),
        findsOneWidget,
      );
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      attachment = {
        'name': 'pixel.png',
        'path': null,
        'size': png.length,
        'bytes': png,
      };
      await tester.tap(find.byKey(const ValueKey('pickImage')));
      await tester.pumpAndSettle();
      await pickAndLoad(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
      await tester.pumpAndSettle();
      expect(byteRequests, [true, true]);
      final contents = backend.sentMessages.single.single.contents;
      expect(contents.whereType<LiteRtLmImageContent>().single.bytes, png);
      expect(contents.whereType<LiteRtLmImageEndContent>(), isEmpty);
    },
  );

  testWidgets('picked WAV bytes are sent without placeholders', (tester) async {
    await showApp(tester);
    await tester.tap(find.byKey(const ValueKey('audioToggle')));
    await tester.pumpAndSettle();
    final wav = Uint8List(48);
    wav.setRange(0, 4, ascii.encode('RIFF'));
    wav.setRange(8, 12, ascii.encode('WAVE'));
    wav.setRange(12, 16, ascii.encode('fmt '));
    wav.setRange(36, 40, ascii.encode('data'));
    final data = ByteData.sublistView(wav);
    data.setUint32(4, 40, Endian.little);
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, 16000, Endian.little);
    data.setUint32(28, 32000, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    data.setUint32(40, 4, Endian.little);
    attachment = {
      'name': 'sample.wav',
      'path': null,
      'size': wav.length,
      'bytes': wav,
    };
    await tester.tap(find.byKey(const ValueKey('pickAudio')));
    await tester.pumpAndSettle();
    await pickAndLoad(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pumpAndSettle();
    expect(
      backend.sentMessages.single.single.contents
          .whereType<LiteRtLmAudioContent>()
          .single
          .bytes,
      wav,
    );
  });

  testWidgets('cancel preserves the wrapper for another user turn', (
    tester,
  ) async {
    backend = FakeLiteRtLmBackend(
      streamTokens: ['one', 'two', 'three'],
      tokenDelay: const Duration(seconds: 1),
    );
    await showApp(tester);
    await pickAndLoad(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pump();
    await tester.pump();
    expect(backend.sentMessages, hasLength(1));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    // Stream cancellation may complete outside the widget frame scheduler.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('statusText'))).data,
      'Cancelled',
    );
    expect(backend.cancelledSessions, contains(1));
    expect(backend.disposedSessions, isEmpty);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Generate'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pump();
    await tester.pump();
    expect(backend.createdConversations, hasLength(1));
    expect(backend.sentMessages, hasLength(2));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    // Stream cancellation may complete outside the widget frame scheduler.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('controls wrap without overflow on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const LiteRtLmExampleApp());
    await tester.scrollUntilVisible(
      find.text('New conversation'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('New conversation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('load completing after unmount closes the client safely', (
    tester,
  ) async {
    final pending = Completer<LiteRtLmResult<LiteRtLm>>();
    await tester.pumpWidget(
      LiteRtLmExampleApp(createClient: () => pending.future),
    );
    await tester.tap(find.byIcon(Icons.folder_open));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Load'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete(LiteRtLmOk(LiteRtLm.testing(backend)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      (await backend.loadEngine(
        const LiteRtLmEngineConfig(modelPath: '/tmp/model.litertlm'),
      )).errorOrNull,
      isA<LiteRtLmDisposed>(),
    );
  });
}
