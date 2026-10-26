import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lib_litert_lm/lib_litert_lm.dart';
import 'package:lib_litert_lm/src/backend.dart';
import 'package:lib_litert_lm/src/fake_backend.dart';
import 'package:lib_litert_lm/src/types.dart'
    show liteRtLmFailureFromMap, liteRtLmFailureToMap;

void main() {
  test(
    'messages preserve role and modality and consume matching end markers',
    () {
      final message = LiteRtLmMessage(
        role: 'user',
        contents: const [
          LiteRtLmContent.text('look'),
          LiteRtLmContent.image([1, 2]),
          LiteRtLmContent.imageEnd(),
          LiteRtLmContent.audio([3]),
          LiteRtLmContent.audioEnd(),
          LiteRtLmContent.text('listen'),
        ],
      );
      expect(message.toJson(), {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'look'},
          {'type': 'image', 'blob': 'AQI='},
          {'type': 'audio', 'blob': 'Aw=='},
          {'type': 'text', 'text': 'listen'},
        ],
      });
      expect(
        () => const LiteRtLmMessage(role: 'tool', contents: []).toJson(),
        throwsArgumentError,
      );
      expect(
        () => const LiteRtLmMessage(
          role: 'user',
          contents: [
            LiteRtLmContent.image([1]),
            LiteRtLmContent.audioEnd(),
          ],
        ).toJson(),
        throwsArgumentError,
      );
    },
  );

  test(
    'conversation appends only new messages and one-shot keeps full roles',
    () async {
      final backend = FakeLiteRtLmBackend(streamTokens: ['answer']);
      final client = LiteRtLm.testing(backend);
      final engine = (await client.loadEngine(
        const LiteRtLmEngineConfig(
          modelPath: '/tmp/model.litertlm',
          visionBackend: 'gpu',
          audioBackend: 'cpu',
          modelId: 'model',
          artifactSha256: 'sha',
          revision: 'rev',
        ),
      )).valueOrNull!;
      final system = LiteRtLmMessage.text(role: 'system', text: 'be helpful');
      final user = LiteRtLmMessage.text(text: 'hi');
      final conversation = (await engine.createConversation(
        messages: [system],
      )).valueOrNull!;
      expect((await conversation.send(user)).valueOrNull, 'answer');
      expect(
        (await conversation.send(
          LiteRtLmMessage.text(text: 'next'),
        )).valueOrNull,
        'answer',
      );
      expect(backend.createdConversations.single, [system]);
      expect(backend.sentMessages.map((m) => m.single.role), ['user', 'user']);
      await engine.generateMessages([system, user]);
      expect(backend.createdConversations.last, isEmpty);
      expect(backend.sentMessages.last, [system, user]);
      expect(
        (await conversation.getMetrics()).valueOrNull!.prefillTokens,
        isNull,
      );
      expect(
        (await conversation.budget(
          messages: [user],
          outputReserve: 10,
        )).valueOrNull!.exact,
        isFalse,
      );
      await client.dispose();
      expect(
        (await conversation.send(user)).errorOrNull,
        isA<LiteRtLmDisposed>(),
      );
      await conversation.cancel();
      await conversation.dispose();
    },
  );

  test('typed info, budget, metrics and context failures round-trip nulls', () {
    final info = LiteRtLmModelInfo.fromJson({
      'path': '/m',
      'dynamicContext': true,
      'runtimeVersion': '1',
      'runtimeCommit': 'abc',
      'backends': {
        'text': ['cpu'],
        'vision': <String>[],
      },
      'effectiveContextTokens': 1024,
    });
    expect(LiteRtLmModelInfo.fromJson(info.toJson()).maxContextTokens, isNull);
    expect(info.backends['text'], ['cpu']);
    final budget = LiteRtLmTokenBudget.fromJson({
      'contextTokens': 100,
      'usedTokens': 20,
      'outputReserve': 10,
      'exact': false,
    });
    expect(LiteRtLmTokenBudget.fromJson(budget.toJson()).inputTokens, isNull);
    final metrics = LiteRtLmMetrics.fromJson({
      'timeToFirstTokenSeconds': 0.3,
      'nativeTimeToFirstTokenSeconds': 0.1,
      'decodeTokens': 8,
    });
    expect(LiteRtLmMetrics.fromJson(metrics.toJson()).decodeTokens, 8);
    expect(metrics.prefillTokens, isNull);
    const error = LiteRtLmContextFull(
      requiredTokens: 120,
      availableTokens: 100,
      message: 'full',
    );
    final restored =
        liteRtLmFailureFromMap(liteRtLmFailureToMap(error))
            as LiteRtLmContextFull;
    expect(restored.requiredTokens, 120);
    expect(restored.availableTokens, 100);
  });

  test(
    'invalid messages fail before dispatch and legacy capabilities stay optional',
    () async {
      final backend = _DelayedCloseBackend();
      final client = LiteRtLm.testing(backend);
      final engine = (await client.loadEngine(
        const LiteRtLmEngineConfig(modelPath: '/tmp/model.litertlm'),
      )).valueOrNull!;
      final session = (await engine.createSession()).valueOrNull!;
      expect(
        (await engine.createConversation()).errorOrNull,
        isA<LiteRtLmUnsupported>(),
      );
      expect(
        (await client.inspectModel('/tmp/model.litertlm')).errorOrNull,
        isA<LiteRtLmUnsupported>(),
      );
      expect((await engine.getInfo()).errorOrNull, isA<LiteRtLmUnsupported>());
      expect(
        (await engine.tokenize('hello')).errorOrNull,
        isA<LiteRtLmUnsupported>(),
      );
      expect(
        (await session.getMetrics()).errorOrNull,
        isA<LiteRtLmUnsupported>(),
      );
      expect((await session.budget()).errorOrNull, isA<LiteRtLmUnsupported>());
      expect(
        (await session.budget(outputReserve: -1)).errorOrNull,
        isA<LiteRtLmInvalidArgument>(),
      );
      expect(
        (await session.generateContent(const [
          LiteRtLmContent.imageEnd(),
        ])).errorOrNull,
        isA<LiteRtLmInvalidArgument>(),
      );
      final events = await session.generateContentStream(const [
        LiteRtLmContent.audioEnd(),
      ]).toList();
      expect(
        (events.single as LiteRtLmFailed).error,
        isA<LiteRtLmInvalidArgument>(),
      );
      backend.closed.complete();
      await client.dispose();
    },
  );

  test(
    'session and engine concurrent dispose callers all await completion',
    () async {
      final backend = _DelayedCloseBackend();
      final client = LiteRtLm.testing(backend);
      final engine = (await client.loadEngine(
        const LiteRtLmEngineConfig(modelPath: '/tmp/model.litertlm'),
      )).valueOrNull!;
      final session = (await engine.createSession()).valueOrNull!;
      final firstSession = session.dispose();
      var sessionDone = false;
      final secondSession = session.dispose().then((_) => sessionDone = true);
      await Future<void>.delayed(Duration.zero);
      expect(sessionDone, isFalse);
      expect(backend.sessionDisposeCalls, 1);
      backend.sessionDisposed.complete();
      await Future.wait([firstSession, secondSession]);
      final firstEngine = engine.dispose();
      var engineDone = false;
      final secondEngine = engine.dispose().then((_) => engineDone = true);
      await Future<void>.delayed(Duration.zero);
      expect(engineDone, isFalse);
      expect(backend.engineDisposeCalls, 1);
      backend.engineDisposed.complete();
      await Future.wait([firstEngine, secondEngine]);
      backend.closed.complete();
      await client.dispose();
    },
  );

  test(
    'engine disposal invalidates conversations and all session operations',
    () async {
      final backend = FakeLiteRtLmBackend();
      final client = LiteRtLm.testing(backend);
      final engine = (await client.loadEngine(
        const LiteRtLmEngineConfig(modelPath: '/tmp/model.litertlm'),
      )).valueOrNull!;
      final session = (await engine.createSession()).valueOrNull!;
      final conversation = (await engine.createConversation()).valueOrNull!;
      await engine.dispose();
      expect(
        (await session.generate('hello')).errorOrNull,
        isA<LiteRtLmDisposed>(),
      );
      expect(
        (await session.generateContent(const [])).errorOrNull,
        isA<LiteRtLmDisposed>(),
      );
      expect(
        (await session.generateStream('hello').toList()).single,
        isA<LiteRtLmFailed>(),
      );
      expect(
        (await session.generateContentStream(const []).toList()).single,
        isA<LiteRtLmFailed>(),
      );
      expect((await session.getMetrics()).errorOrNull, isA<LiteRtLmDisposed>());
      expect((await session.budget()).errorOrNull, isA<LiteRtLmDisposed>());
      expect(
        (await conversation.send(
          LiteRtLmMessage.text(text: 'hello'),
        )).errorOrNull,
        isA<LiteRtLmDisposed>(),
      );
      await session.cancel();
      await conversation.cancel();
      await session.dispose();
      await conversation.dispose();
      expect(backend.cancelledSessions, isEmpty);
      expect(backend.disposedSessions, isEmpty);
      await client.dispose();
    },
  );

  test('concurrent dispose callers await the same backend close', () async {
    final backend = _DelayedCloseBackend();
    final client = LiteRtLm.testing(backend);
    final first = client.dispose();
    var secondCompleted = false;
    final second = client.dispose().then((_) => secondCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(secondCompleted, isFalse);
    expect(backend.closeCalls, 1);
    backend.closed.complete();
    await Future.wait([first, second]);
  });
}

final class _DelayedCloseBackend implements LiteRtLmBackend {
  final closed = Completer<void>();
  var closeCalls = 0;
  var engineDisposeCalls = 0;
  var sessionDisposeCalls = 0;
  final engineDisposed = Completer<void>();
  final sessionDisposed = Completer<void>();
  @override
  Future<LiteRtLmResult<int>> loadEngine(LiteRtLmEngineConfig config) async =>
      const LiteRtLmOk(1);
  @override
  Future<LiteRtLmResult<int>> createSession(
    int engineId,
    LiteRtLmGenerationParams params,
  ) async => const LiteRtLmOk(1);
  @override
  Future<void> disposeEngine(int engineId) {
    engineDisposeCalls++;
    return engineDisposed.future;
  }

  @override
  Future<void> disposeSession(int sessionId) {
    sessionDisposeCalls++;
    return sessionDisposed.future;
  }

  @override
  Future<void> close() {
    closeCalls++;
    return closed.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
