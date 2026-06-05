import 'package:flutter_test/flutter_test.dart';
import 'package:lib_litert_lm/lib_litert_lm.dart';
import 'package:lib_litert_lm/src/fake_backend.dart';

void main() {
  test('loads engine, creates session, and generates text', () async {
    final backend = FakeLiteRtLmBackend(generateText: 'hello from fake');
    final client = LiteRtLm.testing(backend);

    final engineResult = await client.loadEngine(
      const LiteRtLmEngineConfig(modelPath: '/tmp/model.litertlm'),
    );
    final engine = engineResult.valueOrNull;
    expect(engine, isNotNull);

    final sessionResult = await engine!.createSession(
      params: const LiteRtLmGenerationParams(
        temperature: 0.2,
        topK: 8,
        maxTokens: 32,
      ),
    );
    final session = sessionResult.valueOrNull;
    expect(session, isNotNull);

    final text = await session!.generate('Say hello');
    expect(text.valueOrNull, 'hello from fake');

    await session.dispose();
    await engine.dispose();
    await client.dispose();

    expect(backend.disposedSessions, contains(1));
    expect(backend.disposedEngines, contains(1));
  });

  test('streams token events and completion', () async {
    final backend = FakeLiteRtLmBackend(
      streamTokens: const <String>['one', ' ', 'two'],
    );
    final client = LiteRtLm.testing(backend);
    final engine = (await client.loadEngine(
      const LiteRtLmEngineConfig(modelPath: '/tmp/model.litertlm'),
    )).valueOrNull!;
    final session = (await engine.createSession()).valueOrNull!;

    final events = await session.generateStream('prompt').toList();

    expect(
      events.whereType<LiteRtLmToken>().map((event) => event.text),
      const <String>['one', ' ', 'two'],
    );
    expect(events.whereType<LiteRtLmCompleted>().single.text, 'one two');
  });

  test('stream unsubscribe cancels the session', () async {
    final backend = FakeLiteRtLmBackend(
      streamTokens: const <String>['a', 'b', 'c'],
      tokenDelay: const Duration(milliseconds: 20),
    );
    final client = LiteRtLm.testing(backend);
    final engine = (await client.loadEngine(
      const LiteRtLmEngineConfig(modelPath: '/tmp/model.litertlm'),
    )).valueOrNull!;
    final session = (await engine.createSession()).valueOrNull!;

    final subscription = session.generateStream('prompt').listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await subscription.cancel();

    expect(backend.cancelledSessions, contains(1));
  });

  test('disposed handles return typed errors', () async {
    final backend = FakeLiteRtLmBackend();
    final client = LiteRtLm.testing(backend);
    final engine = (await client.loadEngine(
      const LiteRtLmEngineConfig(modelPath: '/tmp/model.litertlm'),
    )).valueOrNull!;
    final session = (await engine.createSession()).valueOrNull!;

    await session.dispose();
    final result = await session.generate('prompt');
    expect(result.errorOrNull, isA<LiteRtLmDisposed>());

    await engine.dispose();
    final sessionResult = await engine.createSession();
    expect(sessionResult.errorOrNull, isA<LiteRtLmDisposed>());
  });

  test('fake backend maps unsupported model as value error', () async {
    final client = LiteRtLm.testing(FakeLiteRtLmBackend());

    final result = await client.loadEngine(
      const LiteRtLmEngineConfig(modelPath: '/tmp/model.bin'),
    );

    expect(result.errorOrNull, isA<LiteRtLmUnsupportedModel>());
  });

  test('engine config carries npu dispatch directory', () async {
    final backend = FakeLiteRtLmBackend();
    final client = LiteRtLm.testing(backend);

    final result = await client.loadEngine(
      const LiteRtLmEngineConfig(
        modelPath: '/tmp/model.litertlm',
        backend: 'npu',
        litertDispatchLibDir: '/data/app/native/lib',
      ),
    );

    expect(result.isOk, isTrue);
    expect(backend.loadedConfigs.single.backend, 'npu');
    expect(
      backend.loadedConfigs.single.litertDispatchLibDir,
      '/data/app/native/lib',
    );
  });

  test(
    'generateContent and generateContentStream support multimodal inputs',
    () async {
      final backend = FakeLiteRtLmBackend(
        generateText: 'multimodal response',
        streamTokens: const <String>['multi', 'modal'],
      );
      final client = LiteRtLm.testing(backend);
      final engine = (await client.loadEngine(
        const LiteRtLmEngineConfig(modelPath: '/tmp/model.litertlm'),
      )).valueOrNull!;
      final session = (await engine.createSession()).valueOrNull!;

      final contents = <LiteRtLmContent>[
        const LiteRtLmContent.text('Here is an image:'),
        const LiteRtLmContent.image(<int>[1, 2, 3]),
        const LiteRtLmContent.imageEnd(),
        const LiteRtLmContent.audio(<int>[4, 5]),
        const LiteRtLmContent.audioEnd(),
        const LiteRtLmContent.text('Describe them.'),
      ];

      // Verify generateContent
      final generateResult = await session.generateContent(contents);
      expect(generateResult.valueOrNull, 'multimodal response');

      // Verify generateContentStream
      final streamEvents = await session
          .generateContentStream(contents)
          .toList();
      expect(
        streamEvents.whereType<LiteRtLmToken>().map((e) => e.text),
        const <String>['multi', 'modal'],
      );
      expect(
        streamEvents.whereType<LiteRtLmCompleted>().single.text,
        'multimodal',
      );

      // Verify engine-level generateContent helper works
      final engineResult = await engine.generateContent(contents);
      expect(engineResult.valueOrNull, 'multimodal response');

      await session.dispose();
      await engine.dispose();
      await client.dispose();
    },
  );
}
