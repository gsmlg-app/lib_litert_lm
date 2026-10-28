import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lib_litert_lm/lib_litert_lm.dart';

const _modelPath = String.fromEnvironment('MODEL_PATH');
const _backend = String.fromEnvironment('BACKEND', defaultValue: 'cpu');
const _sha = '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c';
const _revision = '1caa527c1e88b55f046fcd8d2b4265606680663d';

// Package lifecycle acceptance for #3. The downstream application's request
// queue and adoption of this package still require their own device acceptance.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native completion, cancellation, retry and engine unload',
    () async {
      expect(Platform.isAndroid, true);
      final client = _ok(await LiteRtLm.create());
      try {
        final config = LiteRtLmEngineConfig(
          modelPath: _modelPath,
          modelId: 'gemma-4-e2b',
          artifactSha256: _sha,
          revision: _revision,
          backend: _backend,
          maxNumTokens: 4096,
          cacheDir: '${Directory.systemTemp.path}/lrlm-lifecycle-$_backend',
        );
        Directory(config.cacheDir!).createSync(recursive: true);
        final engine = _ok(await client.loadEngine(config));
        try {
          _report('model', {'info': _ok(await engine.getInfo()).toJson()});
          final chats = <LiteRtLmConversation>[];
          try {
            for (var i = 0; i < 2; i++) {
              chats.add(
                _ok(
                  await engine.createConversation(
                    params: const LiteRtLmGenerationParams(maxTokens: 64),
                  ),
                ),
              );
            }
            for (var turn = 0; turn < 6; turn++) {
              final chat = chats[turn % chats.length];
              final message = LiteRtLmMessage.text(text: 'Reply with OK.');
              if (turn.isEven) {
                expect(_ok(await chat.send(message)), isNotEmpty);
              } else {
                final events = await chat.sendStream(message).toList();
                expect(events.whereType<LiteRtLmFailed>(), isEmpty);
                expect(events.whereType<LiteRtLmCancelledEvent>(), isEmpty);
                expect(
                  events.whereType<LiteRtLmCompleted>().single.text,
                  isNotEmpty,
                );
              }
              _report('completed_turn', {
                'turn': turn,
                'conversation': turn % 2,
              });
            }
            await _cancelAndRetry(chats.first, unsubscribe: false);
            await _cancelAndRetry(chats.last, unsubscribe: true);
          } finally {
            for (final chat in chats) {
              await chat.dispose();
            }
          }
          final active = _ok(await engine.createConversation());
          final started = Completer<void>();
          final done = Completer<void>();
          final events = <LiteRtLmEvent>[];
          final subscription = active
              .sendStream(LiteRtLmMessage.text(text: 'Count from 1 to 1000.'))
              .listen(
                (event) {
                  events.add(event);
                  if (event is LiteRtLmToken && !started.isCompleted) {
                    started.complete();
                  }
                },
                onDone: () {
                  done.complete();
                  if (!started.isCompleted) {
                    started.completeError(
                      StateError('No decode token before unload: $events'),
                    );
                  }
                },
              );
          try {
            await started.future;
            await engine.dispose();
            await done.future;
            await subscription.cancel();
            expect(events.whereType<LiteRtLmCancelledEvent>(), hasLength(1));
            expect(
              (await active.send(LiteRtLmMessage.text(text: 'OK'))).errorOrNull,
              isA<LiteRtLmDisposed>(),
            );
            await active.cancel();
            await active.dispose();
            _report('active_engine_unload');
          } finally {
            await subscription.cancel();
            await active.dispose();
          }
        } finally {
          await engine.dispose();
        }
        final reloaded = _ok(await client.loadEngine(config));
        try {
          expect(
            _ok(
              await reloaded.generateMessages([
                LiteRtLmMessage.text(text: 'Reply with OK.'),
              ], params: const LiteRtLmGenerationParams(maxTokens: 64)),
            ),
            isNotEmpty,
          );
          _report('reload_and_generate');
        } finally {
          await reloaded.dispose();
        }
      } finally {
        await client.dispose();
      }
      _report('passed', {'downstreamQueueAcceptance': 'pending'});
    },
    skip: _modelPath.isEmpty
        ? 'Set MODEL_PATH on an Android arm64 device'
        : false,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

Future<void> _cancelAndRetry(
  LiteRtLmConversation chat, {
  required bool unsubscribe,
}) async {
  final first = Completer<void>();
  final terminal = Completer<LiteRtLmEvent>();
  final subscription = chat
      .sendStream(LiteRtLmMessage.text(text: 'Count from 1 to 1000.'))
      .listen((event) {
        if (event is LiteRtLmToken && !first.isCompleted) first.complete();
        if (event is! LiteRtLmToken && !terminal.isCompleted) {
          terminal.complete(event);
          if (!first.isCompleted) {
            first.completeError(
              StateError('No decode token before cancel: $event'),
            );
          }
        }
      });
  try {
    await first.future;
    if (unsubscribe) {
      await subscription.cancel();
    } else {
      await chat.cancel();
      expect(await terminal.future, isA<LiteRtLmCancelledEvent>());
      await subscription.cancel();
    }
    expect(
      _ok(await chat.send(LiteRtLmMessage.text(text: 'Reply with OK.'))),
      isNotEmpty,
    );
    _report(unsubscribe ? 'unsubscribe_and_retry' : 'cancel_and_retry');
  } finally {
    await subscription.cancel();
  }
}

T _ok<T>(LiteRtLmResult<T> result) {
  if (result case LiteRtLmOk<T>(:final value)) return value;
  throw StateError('${result.errorOrNull}');
}

void _report(String scenario, [Map<String, Object?> details = const {}]) {
  // ignore: avoid_print
  print(
    'LRLM_LIFECYCLE ${jsonEncode({'scenario': scenario, 'backend': _backend, ...details})}',
  );
}
