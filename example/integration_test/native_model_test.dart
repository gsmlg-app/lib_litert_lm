import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lib_litert_lm/lib_litert_lm.dart';

const _modelPath = String.fromEnvironment('MODEL_PATH');
const _backend = String.fromEnvironment('BACKEND', defaultValue: 'cpu');
const _context = int.fromEnvironment('CONTEXT', defaultValue: 4096);
const _imagePath = String.fromEnvironment('MODEL_IMAGE_PATH');
const _audioPath = String.fromEnvironment('MODEL_AUDIO_PATH');
const _sha = '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c';
const _revision = '1caa527c1e88b55f046fcd8d2b4265606680663d';
const _reserve = 96;

// No fake backend is imported by this test. A missing device/model is SKIPPED,
// not a successful native-loading or long-context result.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Gemma-4-E2B native capacity, retrieval, cancellation and reuse',
    () async {
      expect(Platform.isAndroid, true);
      expect([4096, 8192, 16384, 32768], contains(_context));
      expect(['cpu', 'gpu'], contains(_backend));
      final client = _ok(await LiteRtLm.create());
      final cache = Directory(
        '${Directory.systemTemp.path}/lrlm-benchmark-$_backend-$_context',
      );
      cache.createSync(recursive: true);
      final rows = <Map<String, Object?>>[];
      try {
        for (final phase in ['cold_engine', 'warm_disk_cache']) {
          final engine = _ok(
            await client.loadEngine(
              LiteRtLmEngineConfig(
                modelPath: _modelPath,
                modelId: 'gemma-4-e2b',
                revision: _revision,
                artifactSha256: _sha,
                backend: _backend,
                maxNumTokens: _context,
                cacheDir: cache.path,
              ),
            ),
          );
          try {
            final info = _ok(await engine.getInfo());
            expect(info.artifactSha256, _sha);
            expect(info.effectiveContextTokens, _context);
            expect(info.maxContextTokens, lessThanOrEqualTo(32768));
            // Fill a NEW conversation to at least 97% of its actual input budget.
            // Moving the marker tests beginning/middle/end independently.
            for (final position in [0.05, 0.50, 0.95]) {
              final chat = _ok(
                await engine.createConversation(
                  params: const LiteRtLmGenerationParams(
                    temperature: 0,
                    maxTokens: _reserve,
                  ),
                ),
              );
              try {
                final prompt = await _nearCapacity(chat, position);
                final budget = _ok(
                  await chat.budget(
                    messages: [LiteRtLmMessage.text(text: prompt)],
                    outputReserve: _reserve,
                  ),
                );
                expect(budget.exact, true);
                expect(
                  budget.requiredTokens!,
                  inInclusiveRange((_context * .97).floor(), _context),
                );
                final result = _ok(
                  await chat.send(LiteRtLmMessage.text(text: prompt)),
                );
                final metrics = _ok(await chat.getMetrics());
                final row = <String, Object?>{
                  'scenario': 'retrieval',
                  'phase': phase,
                  'position': position,
                  'requestedContext': _context,
                  'model': info.toJson(),
                  'budget': budget.toJson(),
                  'metrics': metrics.toJson(),
                  'retrievalCorrect': result.contains('COBALT-731'),
                  'answer': result,
                };
                rows.add(row);
                _report(row);
                expect(
                  row['retrievalCorrect'],
                  true,
                  reason:
                      'Retrieval at $position failed; configuration alone is not capacity acceptance',
                );
              } finally {
                await chat.dispose();
              }
            }
            await _cancelAndRetry(
              engine,
              prefill: true,
              rows: rows,
              phase: phase,
            );
            await _cancelAndRetry(
              engine,
              prefill: false,
              rows: rows,
              phase: phase,
            );
            await _fillMultipleTurns(engine, rows, phase);
          } finally {
            await engine.dispose();
          }
        }
        await _mediaValidation(client, rows);
      } finally {
        await client.dispose();
        _report({
          'scenario': 'summary',
          'backend': _backend,
          'context': _context,
          'completedRows': rows.length,
          'manualLifecycleAcceptance': 'pending',
        });
      }
    },
    skip: _modelPath.isEmpty
        ? 'Set MODEL_PATH on an Android arm64 device'
        : false,
    timeout: const Timeout(Duration(minutes: 40)),
  );
}

T _ok<T>(LiteRtLmResult<T> result) {
  if (result case LiteRtLmOk<T>(:final value)) return value;
  throw StateError('${result.errorOrNull}');
}

String _filler(int lines, double position) {
  final marker = (lines * position).floor();
  final buffer = StringBuffer('Read the whole document.\n');
  for (var i = 0; i < lines; i++) {
    if (i == marker) buffer.writeln('The exact secret key is COBALT-731.');
    buffer.writeln('Record $i: 山川与城市中的普通资料，没有秘密标记。');
  }
  return '$buffer\nWhat is the exact secret key? Reply only with the key.';
}

Future<String> _nearCapacity(
  LiteRtLmConversation chat,
  double position, {
  int reserve = _reserve,
}) async {
  var low = 1, high = _context;
  String best = '';
  while (low <= high) {
    final middle = (low + high) ~/ 2;
    final prompt = _filler(middle, position);
    final budget = _ok(
      await chat.budget(
        messages: [LiteRtLmMessage.text(text: prompt)],
        outputReserve: reserve,
      ),
    );
    if (budget.requiredTokens! <= _context) {
      best = prompt;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  expect(best, isNotEmpty);
  return best;
}

Future<void> _cancelAndRetry(
  LiteRtLmEngine engine, {
  required bool prefill,
  required List<Map<String, Object?>> rows,
  required String phase,
}) async {
  final chat = _ok(
    await engine.createConversation(
      params: const LiteRtLmGenerationParams(maxTokens: 1024),
    ),
  );
  try {
    final prompt = prefill
        ? await _nearCapacity(chat, .5, reserve: 1024)
        : 'Write a very long story, at least 1000 words.';
    final arrived = Completer<void>();
    final terminal = Completer<LiteRtLmEvent>();
    final stream = chat.sendStream(LiteRtLmMessage.text(text: prompt));
    final watch = Stopwatch()..start();
    final subscription = stream.listen((event) {
      if (event is LiteRtLmToken && !arrived.isCompleted) arrived.complete();
      if (event is! LiteRtLmToken && !terminal.isCompleted) {
        terminal.complete(event);
      }
    });
    // A short measured delay requests cancellation during prefill; it is NOT
    // used to free native resources. The terminal/join protocol does that.
    if (prefill) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    } else {
      await Future.any([
        arrived.future,
        terminal.future.then((event) {
          if (!arrived.isCompleted) {
            throw StateError(
              'Generation ended before the first decode token: $event',
            );
          }
        }),
      ]);
    }
    await chat.cancel();
    final outcome = await terminal.future;
    await subscription.cancel();
    // Absence of a token does not prove execution is in the native prefill
    // kernel. Such phase-level evidence requires native tracing.
    final decodeObserved = arrived.isCompleted;
    final retry = _ok(
      await chat.send(LiteRtLmMessage.text(text: 'Reply with OK.')),
    );
    final row = <String, Object?>{
      'scenario': prefill ? 'cancel_prefill' : 'cancel_decode',
      'phase': phase,
      'cancelled': outcome is LiteRtLmCancelledEvent,
      'firstTokenObservedBeforeCancel': decodeObserved,
      'phaseConfirmed': prefill ? null : decodeObserved,
      if (prefill) 'nativePrefillTrace': 'pending',
      'elapsedSeconds': watch.elapsedMicroseconds / 1e6,
      'retry': retry,
    };
    rows.add(row);
    _report(row);
    expect(outcome, isA<LiteRtLmCancelledEvent>());
    if (!prefill) expect(decodeObserved, true);
    expect(retry, isNotEmpty);
  } finally {
    await chat.dispose();
  }
}

Future<void> _fillMultipleTurns(
  LiteRtLmEngine engine,
  List<Map<String, Object?>> rows,
  String phase,
) async {
  final chat = _ok(
    await engine.createConversation(
      params: const LiteRtLmGenerationParams(maxTokens: 32),
    ),
  );
  try {
    for (var turn = 0; turn < 128; turn++) {
      final message = LiteRtLmMessage.text(
        text: 'Turn $turn. ${'普通上下文资料。' * 100} Reply OK.',
      );
      final budget = _ok(
        await chat.budget(messages: [message], outputReserve: 32),
      );
      if (budget.requiredTokens! > _context) {
        final result = await chat.send(message);
        expect(result.errorOrNull, isA<LiteRtLmContextFull>());
        final row = <String, Object?>{
          'scenario': 'multi_turn_full',
          'phase': phase,
          'turn': turn,
          'budget': budget.toJson(),
          'failure': result.errorOrNull?.code,
        };
        rows.add(row);
        _report(row);
        return;
      }
      _ok(await chat.send(message));
    }
    fail('Conversation did not reach context boundary in bounded iterations');
  } finally {
    await chat.dispose();
  }
}

Future<void> _mediaValidation(
  LiteRtLm client,
  List<Map<String, Object?>> rows,
) async {
  for (final entry in {'image': _imagePath, 'audio': _audioPath}.entries) {
    if (entry.value.isEmpty) {
      _report({'scenario': 'media_${entry.key}', 'status': 'not_run_no_file'});
      continue;
    }
    final metadata = _ok(await client.inspectModel(_modelPath));
    final available =
        metadata.backends[entry.key == 'image' ? 'vision' : 'audio'] ?? [];
    if (available.isEmpty) {
      _report({
        'scenario': 'media_${entry.key}',
        'status': 'unsupported_by_artifact',
      });
      continue;
    }
    final encoderBackend = available.contains('cpu') ? 'cpu' : available.first;
    final bytes = await File(entry.value).readAsBytes();
    LiteRtLmContent content(List<int> data) => entry.key == 'image'
        ? LiteRtLmContent.image(data)
        : LiteRtLmContent.audio(data);
    final engine = _ok(
      await client.loadEngine(
        LiteRtLmEngineConfig(
          modelPath: _modelPath,
          artifactSha256: _sha,
          revision: _revision,
          backend: _backend,
          maxNumTokens: _context,
          visionBackend: entry.key == 'image' ? encoderBackend : null,
          audioBackend: entry.key == 'audio' ? encoderBackend : null,
        ),
      ),
    );
    try {
      final chat = _ok(
        await engine.createConversation(
          params: const LiteRtLmGenerationParams(maxTokens: 512),
        ),
      );
      try {
        final message = LiteRtLmMessage(
          role: 'user',
          contents: [
            content(bytes),
            LiteRtLmContent.text(
              entry.key == 'image'
                  ? 'Describe this image briefly.'
                  : 'Transcribe this audio.',
            ),
          ],
        );
        final budget = _ok(
          await chat.budget(messages: [message], outputReserve: 512),
        );
        expect(budget.exact, true);
        final text = _ok(await chat.send(message));
        expect(text, isNotEmpty);
        // Preserve the file signature so rejection exercises the native decoder,
        // rather than only the Dart file-signature guard.
        final prefix = entry.key == 'image' ? 12 : 44;
        final damaged = await chat.send(
          LiteRtLmMessage(
            role: 'user',
            contents: [content(bytes.take(prefix).toList())],
          ),
        );
        expect(
          damaged.isErr,
          true,
          reason: 'Truncated media must fail decoding',
        );
        final retry = _ok(
          await chat.send(LiteRtLmMessage.text(text: 'Reply OK.')),
        );
        final row = <String, Object?>{
          'scenario': 'media_${entry.key}',
          'status': 'passed',
          'encoderBackend': encoderBackend,
          'budget': budget.toJson(),
          'answer': text,
          'damagedInputError': damaged.errorOrNull?.message,
          'retry': retry,
        };
        rows.add(row);
        _report(row);
      } finally {
        await chat.dispose();
      }
    } finally {
      await engine.dispose();
    }
  }
}

void _report(Map<String, Object?> row) {
  // Machine-readable lines are collected by tool/android_validate.py.
  // ignore: avoid_print
  print(
    'LRLM_REPORT ${jsonEncode({'backend': _backend, 'context': _context, ...row})}',
  );
}
