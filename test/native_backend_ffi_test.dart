import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lib_litert_lm/lib_litert_lm.dart';
import 'package:lib_litert_lm/src/bindings/litert_lm_bindings_generated.dart';
import 'package:lib_litert_lm/src/native_backend.dart';

void main() {
  late String libraryPath;
  late Directory temporary;
  late String model;
  late _Fixture fixture;
  late LiteRtLmBindings bridge;
  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('litert-lm-ffi-');
    model = '${temporary.path}/fixture.litertlm';
    File(model).writeAsStringSync('C ABI fixture, not a model');
    libraryPath =
        '${temporary.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
    final compile = await Process.run('c++', [
      '-std=c++17',
      '-shared',
      '-fPIC',
      '-pthread',
      '-Ithird_party/litert_lm',
      'native/litert_lm_bridge.cc',
      'test/native/runtime_fixture.cc',
      '-o',
      libraryPath,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final library = DynamicLibrary.open(libraryPath);
    fixture = _Fixture(library);
    bridge = LiteRtLmBindings(library);
  });
  tearDownAll(() => temporary.deleteSync(recursive: true));
  tearDown(() {
    expect(
      fixture.handles(),
      0,
      reason: 'native handles must be joined and freed',
    );
    expect(bridge.lrlm_live_operations(), 0);
    expect(bridge.lrlm_live_events(), 0);
  });
  Future<NativeLiteRtLmBackend> backend() async {
    final result = await NativeLiteRtLmBackend.startForTesting(
      libraryName: libraryPath,
    );
    expect(result.isOk, true, reason: '${result.errorOrNull}');
    final value = result.valueOrNull!;
    addTearDown(value.close);
    return value;
  }

  Future<int> engine(
    NativeLiteRtLmBackend b, {
    bool media = false,
    int context = 4096,
  }) async {
    final result = await b.loadEngine(
      LiteRtLmEngineConfig(
        modelPath: model,
        maxNumTokens: context,
        visionBackend: media ? 'cpu' : null,
        audioBackend: media ? 'cpu' : null,
      ),
    );
    expect(result.isOk, true, reason: '${result.errorOrNull}');
    return result.valueOrNull!;
  }

  Future<int> session(
    NativeLiteRtLmBackend b,
    int e, {
    bool raw = false,
  }) async {
    final result = await b.createSession(
      e,
      LiteRtLmGenerationParams(applyPromptTemplate: !raw, maxTokens: 32),
    );
    expect(result.isOk, true, reason: '${result.errorOrNull}');
    return result.valueOrNull!;
  }

  test('production remains Android-only', () async {
    if (!Platform.isAndroid) {
      expect(
        (await NativeLiteRtLmBackend.start(libraryName: libraryPath)).isErr,
        true,
      );
    }
  });
  test(
    'real threaded ABI preserves borrowed text and temporary errors',
    () async {
      final b = await backend();
      final e = await engine(b);
      for (final raw in [false, true]) {
        final s = await session(b, e, raw: raw);
        final events = await b.generateStream(s, 'normal').toList();
        expect(events.whereType<LiteRtLmToken>().single.text, 'owned 中文');
        expect(events.whereType<LiteRtLmCompleted>().single.text, 'owned 中文');
        final error = await b.generate(s, 'native_error');
        expect(
          error.errorOrNull?.message,
          'INTERNAL: borrowed error preserved',
        );
        await b.disposeSession(s);
      }
      await b.close();
    },
  );
  test(
    'CPU-compatible sampling preserves top-k and zero-temperature requests',
    () async {
      final b = await backend();
      final e = await engine(b);
      for (final raw in [false, true]) {
        for (final temperature in [0.0, 0.8]) {
          final s = (await b.createSession(
            e,
            LiteRtLmGenerationParams(
              applyPromptTemplate: !raw,
              temperature: temperature,
              topK: 17,
              seed: 42,
            ),
          )).valueOrNull!;
          try {
            final result = await b.generate(s, 'sampler compatibility');
            expect(result.errorOrNull, isNull);
            expect(result.valueOrNull, 'owned 中文');
            expect(
              fixture.samplerP(),
              1.0,
              reason:
                  'Keep every top-k candidate; do not add nucleus filtering',
            );
          } finally {
            await b.disposeSession(s);
          }
        }
      }
      await b.close();
    },
  );
  test(
    'Future cancellation reaches native during prefill and decode, then retry',
    () async {
      final b = await backend();
      final e = await engine(b);
      final s = await session(b, e);
      for (final phase in ['hold_prefill', 'hold_decode']) {
        final start = fixture.started();
        final before = fixture.completed();
        final cancels = fixture.cancelled();
        final future = b.generate(s, phase);
        expect(fixture.waitStarted(start + 1), 1);
        await b.cancelSession(s);
        final result = await future.timeout(const Duration(seconds: 5));
        expect(result.errorOrNull, isA<LiteRtLmCancelled>());
        expect(fixture.cancelled(), cancels + 1);
        expect(
          fixture.completed(),
          before,
          reason: 'natural completion barrier was never released',
        );
        expect((await b.generate(s, 'retry')).valueOrNull, 'owned 中文');
      }
      await b.close();
    },
  );
  test(
    'subscription cancellation drains late callbacks and pending payloads',
    () async {
      final b = await backend();
      final e = await engine(b);
      final s = await session(b, e);
      final first = Completer<void>();
      final seen = <LiteRtLmEvent>[];
      final subscription = b.generateStream(s, 'hold_decode').listen((event) {
        seen.add(event);
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      await subscription.cancel().timeout(const Duration(seconds: 5));
      expect(seen.whereType<LiteRtLmToken>().map((e) => e.text), ['owned 中文']);
      expect(bridge.lrlm_live_events(), 0);
      expect(bridge.lrlm_live_operations(), 0);
      expect((await b.generate(s, 'next')).valueOrNull, 'owned 中文');
      await b.close();
    },
  );
  test(
    'overlap is busy and cannot cancel or receive the first operation',
    () async {
      final b = await backend();
      final e = await engine(b);
      final s = await session(b, e);
      final start = fixture.started();
      final first = b.generate(s, 'hold_prefill');
      expect(fixture.waitStarted(start + 1), 1);
      expect((await b.generate(s, 'overlap')).errorOrNull, isA<LiteRtLmBusy>());
      fixture.release();
      expect((await first).valueOrNull, 'owned 中文');
      expect((await b.generate(s, 'new operation')).valueOrNull, 'owned 中文');
      await b.close();
    },
  );
  test(
    'client close invalidates children and joins active native task',
    () async {
      final b = await backend();
      final client = LiteRtLm.testing(b);
      final e = (await client.loadEngine(
        LiteRtLmEngineConfig(modelPath: model),
      )).valueOrNull!;
      final s = (await e.createSession()).valueOrNull!;
      final start = fixture.started();
      final generating = s.generate('hold_prefill');
      expect(fixture.waitStarted(start + 1), 1);
      await client.dispose().timeout(const Duration(seconds: 5));
      expect((await generating).errorOrNull, isA<LiteRtLmCancelled>());
      await Future.wait([
        s.cancel(),
        s.dispose(),
        e.dispose(),
        client.dispose(),
      ]).timeout(const Duration(seconds: 1));
      expect((await s.generate('closed')).errorOrNull, isA<LiteRtLmDisposed>());
    },
  );
  test(
    'worker startup failure and abnormal exit settle outstanding work',
    () async {
      final invalid = await NativeLiteRtLmBackend.startForTesting(
        libraryName: '${temporary.path}/missing.so',
      );
      expect(invalid.errorOrNull, isA<LiteRtLmNativeInitFailure>());
      final b = await backend();
      final e = await engine(b);
      final s = await session(b, e);
      final start = fixture.started();
      final generation = b.generate(s, 'hold_prefill');
      expect(fixture.waitStarted(start + 1), 1);
      await b.crashForTesting();
      final pending = b.engineInfo(e);
      expect(
        (await generation.timeout(const Duration(seconds: 5))).isErr,
        true,
      );
      expect(
        (await pending.timeout(const Duration(seconds: 5))).errorOrNull,
        isA<LiteRtLmWorkerFailure>(),
      );
      await b.disposeSession(s);
      await b.disposeEngine(e);
      await b.close();
    },
  );
  test(
    'bounded queue returns backpressure and releases all native payloads',
    () async {
      final b = await backend();
      final e = await engine(b);
      final s = await session(b, e);
      final events = await b.generateStream(s, 'overflow').toList();
      expect(
        events.whereType<LiteRtLmFailed>().single.error,
        isA<LiteRtLmBackpressure>(),
      );
      expect(events.whereType<LiteRtLmCompleted>(), isEmpty);
      await b.close();
    },
  );
  test(
    'ModelInfo, true tokenizer calls and output reserve enforce context',
    () async {
      final b = await backend();
      final e = await engine(b, context: 128);
      final info = (await b.engineInfo(e)).valueOrNull!;
      expect(info['maxContextTokens'], 32768);
      expect(info['effectiveContextTokens'], 128);
      expect(info['artifactSha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
      final tokens = (await b.tokenize(e, '中文没有空格')).valueOrNull!;
      expect(
        tokens.length,
        6,
        reason:
            'fixture tokenizer emits one scalar per token, not whitespace words',
      );
      final s = await session(b, e);
      final budget = (await b.conversationBudget(s, [
        LiteRtLmMessage.text(text: '中文'),
      ], 32)).valueOrNull!;
      expect(budget['exact'], true);
      expect(budget['inputTokens'] as int, greaterThan(2));
      expect(
        (await b.generate(s, '长' * 200)).errorOrNull,
        isA<LiteRtLmContextFull>(),
      );
      expect((await b.generate(s, '短')).isOk, true);
      final metrics = (await b.sessionMetrics(s)).valueOrNull!;
      expect(metrics['decodeTokens'], 3);
      expect(metrics['prefillTokens'], isPositive);
      await b.close();
    },
  );
  test(
    'unsupported prefill config and media errors are explicit; encoded media crosses FFI',
    () async {
      final b = await backend();
      expect(
        (await b.loadEngine(
          LiteRtLmEngineConfig(
            modelPath: model,
            backend: 'gpu',
            prefillChunkSize: 128,
          ),
        )).errorOrNull,
        isA<LiteRtLmInvalidArgument>(),
      );
      final textEngine = await engine(b);
      final textSession = await session(b, textEngine);
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j2ioAAAAASUVORK5CYII=',
      );
      expect(
        (await b.generateContent(textSession, [
          LiteRtLmContent.image(png),
        ])).errorOrNull,
        isA<LiteRtLmUnsupported>(),
      );
      final e = await engine(b, media: true);
      final s = await session(b, e);
      expect(
        (await b.createConversation(textEngine, [
          LiteRtLmMessage(role: 'user', contents: [LiteRtLmContent.image(png)]),
        ], const LiteRtLmGenerationParams())).errorOrNull,
        isA<LiteRtLmUnsupported>(),
      );
      final raw = await session(b, e, raw: true);
      expect(
        (await b.conversationBudget(raw, [
          LiteRtLmMessage(role: 'user', contents: [LiteRtLmContent.image(png)]),
        ], 32)).errorOrNull,
        isA<LiteRtLmUnsupported>(),
      );
      expect(
        (await b.conversationBudget(s, [
          const LiteRtLmMessage(
            role: 'user',
            contents: [
              LiteRtLmContent.audio([1, 2]),
            ],
          ),
        ], 32)).errorOrNull,
        isA<LiteRtLmInvalidArgument>(),
      );
      expect(
        (await b.generateContent(s, [
          const LiteRtLmContent.image([1, 2, 3]),
        ])).errorOrNull,
        isA<LiteRtLmInvalidArgument>(),
      );
      expect(
        (await b.generateContent(s, [LiteRtLmContent.image(png)])).valueOrNull,
        'owned 中文',
      );
      await b.close();
    },
  );
  test(
    'invalid native event fails, joins, and allows retry instead of false cancel',
    () async {
      final b = await backend();
      final e = await engine(b);
      for (final raw in [false, true]) {
        final s = await session(b, e, raw: raw);
        final result = await b.generate(s, 'invalid_event');
        expect(result.errorOrNull, isA<LiteRtLmGenerationFailure>());
        expect(result.errorOrNull!.message, contains('Invalid native event'));
        expect((await b.generate(s, 'retry')).isOk, true);
      }
      await b.close();
    },
  );
  test(
    'chunk metrics exclude previous turns and cancelled history keeps preface',
    () async {
      final b = await backend();
      final e = await engine(b);
      final system = LiteRtLmMessage.text(role: 'system', text: '保留系统角色');
      final first = LiteRtLmMessage.text(text: 'first round');
      final s = (await b.createConversation(e, [
        system,
      ], const LiteRtLmGenerationParams(maxTokens: 32))).valueOrNull!;
      expect(
        (await b.sendMessagesStream(s, [first]).last),
        isA<LiteRtLmCompleted>(),
      );
      final metrics = (await b.sessionMetrics(s)).valueOrNull!;
      final firstInput = jsonEncode(first.toJson()).runes.length;
      expect(metrics['prefillTokens'], firstInput);
      expect(metrics['prefillSeconds'], closeTo(firstInput / 100, .000001));
      expect(metrics['decodeTokens'], 3);
      final second = LiteRtLmMessage.text(text: 'second shorter');
      await b.sendMessagesStream(s, [second]).drain<void>();
      expect(
        (await b.sessionMetrics(s)).valueOrNull!['prefillTokens'],
        jsonEncode(second.toJson()).runes.length,
      );

      final start = fixture.started();
      final held = b.generate(s, 'hold_prefill');
      expect(fixture.waitStarted(start + 1), 1);
      await b.cancelSession(s);
      expect((await held).errorOrNull, isA<LiteRtLmCancelled>());
      final assistant = LiteRtLmMessage.text(
        role: 'assistant',
        text: 'owned 中文',
      );
      final committed = jsonEncode([
        system.toJson(),
        first.toJson(),
        assistant.toJson(),
        second.toJson(),
        assistant.toJson(),
      ]);
      final budget = (await b.conversationBudget(s, [], 0)).valueOrNull!;
      expect(budget['inputTokens'], 0);
      expect(
        budget['usedTokens'],
        committed.runes.length,
        reason:
            'Reconstruction must retain configured history and completed turns only',
      );
      expect((await b.generate(s, 'retry')).isOk, true);
      await b.close();
    },
  );
  test(
    'raw session budgets retain total context and errors permit clean retry',
    () async {
      final b = await backend();
      final e = await engine(b, context: 128);
      final s = await session(b, e, raw: true);
      expect((await b.generate(s, '中文')).isOk, true);
      expect(
        (await b.conversationBudget(s, [], 0)).valueOrNull!['usedTokens'],
        5,
      );
      expect((await b.generate(s, 'more')).isOk, true);
      expect((await b.sessionMetrics(s)).valueOrNull!['contextUsedTokens'], 12);
      expect((await b.generate(s, 'native_error')).isErr, true);
      expect((await b.generate(s, 'retry')).isOk, true);
      expect((await b.sessionMetrics(s)).valueOrNull!['contextUsedTokens'], 8);
      await b.close();
    },
  );
  test(
    'paused subscriber permits native terminal cleanup without unbounded delivery',
    () async {
      final b = await backend();
      final e = await engine(b);
      final s = await session(b, e);
      final paused = Completer<void>();
      final delivered = <LiteRtLmEvent>[];
      late StreamSubscription<LiteRtLmEvent> subscription;
      subscription = b.generateStream(s, 'normal').listen((event) {
        delivered.add(event);
        if (event is LiteRtLmToken && !paused.isCompleted) {
          subscription.pause();
          paused.complete();
        }
      });
      await paused.future;
      // The producer has a finite native terminal. Wait on actual resource
      // counters and worker replies, yielding the event loop rather than
      // guessing native completion from a fixed sleep.
      await (() async {
        while (bridge.lrlm_live_operations() != 0 ||
            bridge.lrlm_live_events() != 0) {
          await b.engineInfo(e);
          await Future<void>.delayed(Duration.zero);
        }
      })().timeout(const Duration(seconds: 5));
      expect(delivered, hasLength(1));
      expect(
        (await b.generate(s, 'new turn while old consumer paused')).isOk,
        true,
      );
      await subscription.cancel();
      await b.close();
    },
  );
  test(
    'batch roles use preface plus one object without mutating budget preview',
    () async {
      final b = await backend();
      final e = await engine(b);
      final s = await session(b, e);
      final messages = [
        LiteRtLmMessage.text(role: 'system', text: '保留角色'),
        LiteRtLmMessage.text(text: 'earlier question'),
        LiteRtLmMessage.text(role: 'assistant', text: 'earlier answer'),
        LiteRtLmMessage.text(text: 'new question'),
      ];
      final budget = (await b.conversationBudget(s, messages, 32)).valueOrNull!;
      final prefix = jsonEncode(
        messages.take(3).map((m) => m.toJson()).toList(),
      );
      expect(
        budget['requiredTokens'],
        prefix.runes.length +
            jsonEncode(messages.last.toJson()).runes.length +
            32,
      );
      expect(
        (await b.conversationBudget(s, [], 0)).valueOrNull!['usedTokens'],
        0,
      );
      expect(
        await b.sendMessagesStream(s, messages).last,
        isA<LiteRtLmCompleted>(),
      );
      final start = fixture.started();
      final held = b.generate(s, 'hold_prefill');
      expect(fixture.waitStarted(start + 1), 1);
      await b.cancelSession(s);
      await held;
      final committed = jsonEncode([
        ...messages.map((m) => m.toJson()),
        LiteRtLmMessage.text(role: 'assistant', text: 'owned 中文').toJson(),
      ]);
      expect(
        (await b.conversationBudget(s, [], 0)).valueOrNull!['usedTokens'],
        committed.runes.length,
      );
      await b.close();
    },
  );
  test(
    'repeated generate, cancel and dispose do not grow native resources',
    () async {
      final b = await backend();
      final e = await engine(b);
      for (var i = 0; i < 40; i++) {
        final s = await session(b, e);
        final start = fixture.started();
        final generation = b.generate(s, 'hold_prefill');
        expect(fixture.waitStarted(start + 1), 1);
        await b.disposeSession(s);
        expect((await generation).errorOrNull, isA<LiteRtLmCancelled>());
        expect(bridge.lrlm_live_operations(), 0);
        expect(bridge.lrlm_live_events(), 0);
        expect(fixture.handles(), 1);
      }
      await b.close();
    },
  );
}

final class _Fixture {
  _Fixture(DynamicLibrary lib)
    : handles = lib.lookupFunction<Int32 Function(), int Function()>(
        'fixture_handles',
      ),
      started = lib.lookupFunction<Int32 Function(), int Function()>(
        'fixture_started',
      ),
      cancelled = lib.lookupFunction<Int32 Function(), int Function()>(
        'fixture_cancelled',
      ),
      completed = lib.lookupFunction<Int32 Function(), int Function()>(
        'fixture_completed',
      ),
      samplerP = lib.lookupFunction<Float Function(), double Function()>(
        'fixture_sampler_p',
      ),
      waitStarted = lib
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
            'fixture_wait_started',
          ),
      release = lib.lookupFunction<Void Function(), void Function()>(
        'fixture_release',
      );
  final int Function() handles, started, cancelled, completed;
  final double Function() samplerP;
  final int Function(int) waitStarted;
  final void Function() release;
}
