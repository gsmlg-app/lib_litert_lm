import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import 'backend.dart';
import 'bindings/litert_lm_bindings_generated.dart' as c;
import 'types.dart';

/// Android production backend. Host loading is deliberately only available from
/// this internal library for tests of the real FFI boundary.
final class NativeLiteRtLmBackend
    implements LiteRtLmBackend, LiteRtLmAdvancedBackend {
  NativeLiteRtLmBackend._();
  final _messages = ReceivePort();
  final _exits = ReceivePort();
  final _errors = ReceivePort();
  final _ready = Completer<LiteRtLmResult<SendPort>>();
  final _pending = <int, Completer<Object?>>{};
  final _streams = <int, _Consumer>{};
  SendPort? _commands;
  int _nextId = 1;
  bool _closing = false;
  bool _closed = false;
  Future<void>? _closeFuture;
  LiteRtLmFailure? _workerFailure;

  static Future<LiteRtLmResult<LiteRtLmBackend>> start({
    required String libraryName,
  }) => _start(libraryName, allowHost: false);

  static Future<LiteRtLmResult<NativeLiteRtLmBackend>> startForTesting({
    required String libraryName,
  }) => _start(libraryName, allowHost: true);

  static Future<LiteRtLmResult<NativeLiteRtLmBackend>> _start(
    String path, {
    required bool allowHost,
  }) async {
    if (!Platform.isAndroid && !allowHost) {
      return const LiteRtLmErr(
        LiteRtLmNativeInitFailure('LiteRT-LM native backend is Android-only'),
      );
    }
    final backend = NativeLiteRtLmBackend._();
    backend._messages.listen(backend._receive);
    backend._exits.listen((_) => backend._workerEnded());
    backend._errors.listen((raw) => backend._workerEnded('$raw'));
    try {
      await Isolate.spawn<Map<String, Object?>>(
        _workerMain,
        {
          'libraryName': path,
          'replyTo': backend._messages.sendPort,
          'testing': allowHost,
        },
        onExit: backend._exits.sendPort,
        onError: backend._errors.sendPort,
        errorsAreFatal: true,
        debugName: 'LiteRT-LM native control',
      );
      final ready = await backend._ready.future;
      if (ready case LiteRtLmErr<SendPort>(:final error)) {
        backend._finishPorts();
        return LiteRtLmErr(error);
      }
      backend._commands = ready.valueOrNull;
      return LiteRtLmOk(backend);
    } catch (error) {
      backend._workerEnded('$error');
      return LiteRtLmErr(
        LiteRtLmNativeInitFailure('Worker startup failed: $error'),
      );
    }
  }

  void _receive(Object? raw) {
    if (raw is! Map) return;
    if (raw['ready'] == true) {
      if (!_ready.isCompleted) {
        _ready.complete(LiteRtLmOk(raw['port'] as SendPort));
      }
      return;
    }
    if (raw['ready'] == false) {
      final failure = liteRtLmFailureFromMap(raw['error'] as Map);
      if (!_ready.isCompleted) _ready.complete(LiteRtLmErr(failure));
      return;
    }
    if (raw['reply'] case final int id) {
      _pending.remove(id)?.complete(raw);
      return;
    }
    if (raw['stream'] case final int id) {
      final consumer = _streams[id];
      if (consumer == null) return;
      final terminal = raw['type'] != 'token';
      if (terminal) {
        _streams.remove(id);
        consumer.finished = true;
      }
      if (!consumer.cancelled) {
        final LiteRtLmEvent event = switch (raw['type']) {
          'token' => LiteRtLmToken(raw['text'] as String),
          'complete' => LiteRtLmCompleted(raw['text'] as String),
          'cancelled' => const LiteRtLmCancelledEvent(),
          _ => LiteRtLmFailed(liteRtLmFailureFromMap(raw['error'] as Map)),
        };
        consumer.controller.add(event);
        if (terminal) {
          unawaited(consumer.controller.close());
        } else if (!consumer.controller.isPaused && !consumer.cancelled) {
          _commands?.send({'command': 'credit', 'stream': id});
        }
      }
      if (terminal && !consumer.done.isCompleted) consumer.done.complete();
    }
  }

  void _workerEnded([String? detail]) {
    if (_closed) return;
    _closed = true;
    final failure = _workerFailure = LiteRtLmWorkerFailure(
      'LiteRT-LM worker exited${detail == null ? '' : ': $detail'}',
    );
    if (!_ready.isCompleted) _ready.complete(LiteRtLmErr(failure));
    for (final entry in _pending.entries) {
      entry.value.complete({
        'reply': entry.key,
        'ok': false,
        'error': liteRtLmFailureToMap(failure),
      });
    }
    _pending.clear();
    for (final consumer in _streams.values) {
      consumer.finished = true;
      if (!consumer.cancelled) {
        consumer.controller.add(LiteRtLmFailed(failure));
        unawaited(consumer.controller.close());
      }
      if (!consumer.done.isCompleted) consumer.done.complete();
    }
    _streams.clear();
    _finishPorts();
  }

  void _finishPorts() {
    _messages.close();
    _exits.close();
    _errors.close();
  }

  Future<LiteRtLmResult<T>> _request<T>(
    String command,
    Map<String, Object?> args, {
    bool duringClose = false,
  }) async {
    if (_closed || (_closing && !duringClose)) {
      return LiteRtLmErr(
        _workerFailure ?? const LiteRtLmDisposed('Backend is closed'),
      );
    }
    final id = _nextId++;
    final done = Completer<Object?>();
    _pending[id] = done;
    _commands!.send({'command': command, 'request': id, ...args});
    final raw = (await done.future) as Map;
    if (raw['ok'] == true) return LiteRtLmOk(raw['value'] as T);
    return LiteRtLmErr(liteRtLmFailureFromMap(raw['error'] as Map));
  }

  Stream<LiteRtLmEvent> _stream(int session, Map<String, Object?> input) {
    final id = _nextId++;
    final consumer = _Consumer();
    consumer.controller = StreamController<LiteRtLmEvent>(
      sync: true,
      onListen: () {
        if (_closing || _closed) {
          consumer.finished = true;
          consumer.controller.add(
            LiteRtLmFailed(
              _workerFailure ?? const LiteRtLmDisposed('Backend is closed'),
            ),
          );
          unawaited(consumer.controller.close());
          consumer.done.complete();
          return;
        }
        _streams[id] = consumer;
        _commands!.send({
          'command': 'generate',
          'stream': id,
          'sessionId': session,
          ...input,
        });
      },
      onResume: () {
        if (!consumer.finished && !consumer.cancelled) {
          _commands?.send({'command': 'credit', 'stream': id});
        }
      },
      onCancel: () async {
        consumer.cancelled = true;
        if (!consumer.finished && !_closed) {
          // Keep the global receive port alive until cleanup acknowledgement.
          _commands?.send({'command': 'cancelStream', 'stream': id});
          await consumer.done.future;
        }
      },
    );
    return consumer.controller.stream;
  }

  @override
  Future<LiteRtLmResult<int>> loadEngine(LiteRtLmEngineConfig config) =>
      _request('loadEngine', {'config': config});
  @override
  Future<LiteRtLmResult<int>> createSession(
    int engineId,
    LiteRtLmGenerationParams params,
  ) => _request('createSession', {'engineId': engineId, 'params': params});
  @override
  Future<LiteRtLmResult<int>> createConversation(
    int engineId,
    List<LiteRtLmMessage> messages,
    LiteRtLmGenerationParams params,
  ) => _request('createSession', {
    'engineId': engineId,
    'params': params,
    'messages': messages,
    'conversation': true,
  });
  @override
  Stream<LiteRtLmEvent> generateStream(int sessionId, String prompt) =>
      _stream(sessionId, {
        'contents': [LiteRtLmContent.text(prompt)],
      });
  @override
  Stream<LiteRtLmEvent> generateContentStream(
    int sessionId,
    List<LiteRtLmContent> contents,
  ) => _stream(sessionId, {'contents': contents});
  @override
  Stream<LiteRtLmEvent> sendMessagesStream(
    int conversationId,
    List<LiteRtLmMessage> messages,
  ) => _stream(conversationId, {'messages': messages});
  @override
  Future<LiteRtLmResult<String>> generate(int sessionId, String prompt) =>
      _collect(generateStream(sessionId, prompt));
  @override
  Future<LiteRtLmResult<String>> generateContent(
    int sessionId,
    List<LiteRtLmContent> contents,
  ) => _collect(generateContentStream(sessionId, contents));
  @override
  Future<LiteRtLmResult<Map<String, Object?>>> inspectModel(String path) =>
      _request('inspectModel', {'path': path});
  @override
  Future<LiteRtLmResult<Map<String, Object?>>> engineInfo(int engineId) =>
      _request('engineInfo', {'engineId': engineId});
  @override
  Future<LiteRtLmResult<List<int>>> tokenize(int engineId, String text) =>
      _request('tokenize', {'engineId': engineId, 'text': text});
  @override
  Future<LiteRtLmResult<Map<String, Object?>>> conversationBudget(
    int conversationId,
    List<LiteRtLmMessage> messages,
    int outputReserve,
  ) => _request('budget', {
    'sessionId': conversationId,
    'messages': messages,
    'reserve': outputReserve,
  });
  @override
  Future<LiteRtLmResult<Map<String, Object?>>> sessionMetrics(int sessionId) =>
      _request('metrics', {'sessionId': sessionId});
  @override
  Future<void> cancelSession(int sessionId) async {
    if (_closing || _closed) return;
    await _request<Object?>('cancelSession', {'sessionId': sessionId});
  }

  @override
  Future<void> disposeSession(int sessionId) async {
    if (_closing || _closed) return;
    await _request<Object?>('disposeSession', {'sessionId': sessionId});
  }

  @override
  Future<void> disposeEngine(int engineId) async {
    if (_closing || _closed) return;
    await _request<Object?>('disposeEngine', {'engineId': engineId});
  }

  @override
  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    _closing = true;
    await _request<Object?>('close', const {}, duringClose: true);
    _closed = true;
    _finishPorts();
  }

  /// Internal fixture hook: force an isolate error while native work is active.
  Future<void> crashForTesting() async =>
      _commands?.send({'command': 'testCrash'});
}

Future<LiteRtLmResult<String>> _collect(Stream<LiteRtLmEvent> stream) async {
  await for (final event in stream) {
    switch (event) {
      case LiteRtLmCompleted(:final text):
        return LiteRtLmOk(text);
      case LiteRtLmFailed(:final error):
        return LiteRtLmErr(error);
      case LiteRtLmCancelledEvent(:final reason):
        return LiteRtLmErr(reason);
      case LiteRtLmToken():
        break;
    }
  }
  return const LiteRtLmErr(
    LiteRtLmWorkerFailure('Stream ended without a terminal event'),
  );
}

final class _Consumer {
  late final StreamController<LiteRtLmEvent> controller;
  final done = Completer<void>();
  bool cancelled = false;
  bool finished = false;
}

void _workerMain(Map<String, Object?> start) {
  final reply = start['replyTo']! as SendPort;
  try {
    final library = ffi.DynamicLibrary.open(start['libraryName']! as String);
    final bindings = c.LiteRtLmBindings(library);
    if (bindings.lrlm_bridge_abi_version() != 1 ||
        _string(bindings.lrlm_runtime_version()) != 'v0.18.1' ||
        _string(bindings.lrlm_runtime_commit()) !=
            'bda624851d74be34d4e1f7fac1fc4155939539c7') {
      throw StateError(
        'Incompatible native bundle; rebuild the complete v0.18.1 bundle',
      );
    }
    final worker = _NativeWorker(bindings, reply, start['testing']! as bool);
    reply.send({'ready': true, 'port': worker.commands.sendPort});
    worker.listen();
  } catch (error) {
    reply.send({
      'ready': false,
      'error': liteRtLmFailureToMap(
        LiteRtLmNativeInitFailure(
          'Native bundle initialization failed: $error',
        ),
      ),
    });
  }
}

String _string(ffi.Pointer<ffi.Char> pointer) =>
    pointer == ffi.nullptr ? '' : pointer.cast<Utf8>().toDartString();
T _utf8<T>(String? value, T Function(ffi.Pointer<ffi.Char>) run) {
  final p = value?.toNativeUtf8(allocator: calloc);
  try {
    return run(p?.cast<ffi.Char>() ?? ffi.nullptr);
  } finally {
    if (p != null) calloc.free(p);
  }
}

final class _NativeError implements Exception {
  _NativeError(this.failure);
  final LiteRtLmFailure failure;
}

Never _fail(LiteRtLmFailure failure) => throw _NativeError(failure);

enum _HandlePhase { ready, generating, cancelRequested, closing, closed }

final class _NativeEngine {
  _NativeEngine(this.pointer, this.config, this.info);
  final ffi.Pointer<c.LiteRtLmEngine> pointer;
  final LiteRtLmEngineConfig config;
  final Map<String, Object?> info;
  _HandlePhase phase = _HandlePhase.ready;
}

final class _NativeSession {
  _NativeSession(this.engineId, this.params, this.conversation, this.history);
  final int engineId;
  final LiteRtLmGenerationParams params;
  final bool conversation;
  final List<Map<String, Object?>> history;
  List<Map<String, Object?>> nativePreface = [];
  ffi.Pointer<c.LiteRtLmConversation> chat = ffi.nullptr;
  ffi.Pointer<c.LiteRtLmSession> raw = ffi.nullptr;
  _HandlePhase phase = _HandlePhase.ready;
  int? streamId;
  int prefillTurns = 0;
  int decodeTurns = 0;
  Map<String, Object?> metrics = {};
}

final class _Operation {
  _Operation(this.stream, this.session, this.native, this.messages, this.start);
  final int stream;
  final _NativeSession session;
  final int native;
  final List<Map<String, Object?>> messages;
  final Stopwatch start;
  final text = StringBuffer();
  double? ttft;
  bool credit = true;
  bool cancelRequested = false;
  bool backpressure = false;
}

final class _NativeWorker {
  _NativeWorker(this.b, this.reply, this.testing);
  final c.LiteRtLmBindings b;
  final SendPort reply;
  final bool testing;
  final commands = ReceivePort();
  final engines = <int, _NativeEngine>{};
  final sessions = <int, _NativeSession>{};
  final operations = <int, _Operation>{};
  int nextEngine = 1, nextSession = 1;
  Timer? timer;
  bool closing = false;
  bool fatalExit = false;

  void listen() {
    commands.listen((raw) {
      if (raw is! Map || fatalExit) return;
      final args = raw.cast<String, Object?>();
      final request = args['request'] as int?;
      try {
        Object? value;
        switch (args['command']) {
          case 'loadEngine':
            value = _loadEngine(args['config']! as LiteRtLmEngineConfig);
          case 'inspectModel':
            value = _inspect(args['path']! as String);
          case 'engineInfo':
            value = _engine(args['engineId']! as int).info;
          case 'createSession':
            value = _createSession(args);
          case 'generate':
            _generate(args);
            return;
          case 'credit':
            operations[args['stream']]?.credit = true;
            return;
          case 'cancelStream':
            final op = operations[args['stream']];
            if (op != null) _cancel(op);
            return;
          case 'cancelSession':
            final session = sessions[args['sessionId']];
            final op = operations[session?.streamId];
            if (op != null) _cancel(op);
          case 'disposeSession':
            _disposeSession(args['sessionId']! as int);
          case 'disposeEngine':
            _disposeEngine(args['engineId']! as int);
          case 'budget':
            final session = _session(args['sessionId']! as int);
            if (session.streamId != null) {
              _fail(const LiteRtLmBusy('Session is generating'));
            }
            value = _budget(session, _messages(args), args['reserve']! as int);
          case 'tokenize':
            value = _tokenize(
              _engine(args['engineId']! as int),
              args['text']! as String,
            );
          case 'metrics':
            final session = _session(args['sessionId']! as int);
            if (session.streamId != null) {
              _fail(
                const LiteRtLmBusy(
                  'Metrics are available after native completion',
                ),
              );
            }
            value = session.metrics;
          case 'testCrash':
            if (!testing) _fail(const LiteRtLmUnsupported('Unknown command'));
            fatalExit = true;
            _closeAll();
            // Send an actual uncaught isolate error; parent onError/onExit must
            // terminate all requests, even if no normal reply is sent.
            Timer.run(() => throw StateError('Native fixture worker failure'));
            return;
          case 'close':
            _closeAll();
            _ok(request, null);
            commands.close();
            return;
          default:
            _fail(const LiteRtLmInvalidArgument('Unknown worker command'));
        }
        _ok(request, value);
      } catch (error, stack) {
        final failure = error is _NativeError
            ? error.failure
            : LiteRtLmGenerationFailure('Native operation failed: $error');
        if (args['command'] == 'generate') {
          _event(args['stream']! as int, 'error', failure: failure);
        } else {
          reply.send({
            'reply': request,
            'ok': false,
            'error': liteRtLmFailureToMap(failure),
          });
        }
        if (error is! _NativeError && testing) {
          // Diagnostics remain Dart errors. Native SIGSEGV is process fatal and
          // cannot be recovered by this worker error handler.
          assert(stack.toString().isNotEmpty);
        }
      }
    });
  }

  void _ok(int? id, Object? value) {
    if (id != null) reply.send({'reply': id, 'ok': true, 'value': value});
  }

  void _event(int id, String type, {String? text, LiteRtLmFailure? failure}) {
    if (fatalExit) return;
    reply.send({
      'stream': id,
      'type': type,
      'text': text,
      if (failure != null) 'error': liteRtLmFailureToMap(failure),
    });
  }

  _NativeEngine _engine(int id) {
    final engine = engines[id];
    if (engine == null || engine.phase != _HandlePhase.ready) {
      _fail(const LiteRtLmDisposed('Engine is closed'));
    }
    return engine;
  }

  _NativeSession _session(int id) {
    final session = sessions[id];
    if (session == null ||
        session.phase == _HandlePhase.closing ||
        session.phase == _HandlePhase.closed) {
      _fail(const LiteRtLmDisposed('Session is closed'));
    }
    return session;
  }

  LiteRtLmFailure _nativeError(String fallback) {
    final message = _string(b.litert_lm_get_last_error_message());
    return _classify(message.isEmpty ? fallback : message);
  }

  void _checkPointer(ffi.Pointer<ffi.NativeType> pointer, String action) {
    if (pointer == ffi.nullptr) _fail(_nativeError(action));
  }

  String _hash(String path) {
    final out = _DigestSink();
    final converter = sha256.startChunkedConversion(out);
    final file = File(path).openSync();
    try {
      while (true) {
        final chunk = file.readSync(1024 * 1024);
        if (chunk.isEmpty) break;
        converter.add(chunk);
      }
      converter.close();
      return out.digest.toString();
    } finally {
      file.closeSync();
    }
  }

  Map<String, Object?> _inspect(String path) {
    if (!File(path).existsSync()) {
      _fail(LiteRtLmModelNotFound('Model not found: $path'));
    }
    if (!path.toLowerCase().endsWith('.litertlm')) {
      _fail(const LiteRtLmUnsupportedModel('Expected a .litertlm file'));
    }
    return _utf8(path, (p) {
      final file = b.litert_lm_loaded_file_create(p);
      _checkPointer(file, 'Cannot read model capabilities');
      try {
        final backends = <String, List<String>>{};
        for (final entry in {
          'text': c.LiteRtLmModality.kLiteRtLmModalityText,
          'vision': c.LiteRtLmModality.kLiteRtLmModalityVision,
          'audio': c.LiteRtLmModality.kLiteRtLmModalityAudio,
        }.entries) {
          final count = b.litert_lm_loaded_file_modality_supported_backends(
            file,
            entry.value,
            ffi.nullptr,
            0,
          );
          final values = calloc<ffi.Int32>(count > 0 ? count : 1);
          try {
            final actual = b.litert_lm_loaded_file_modality_supported_backends(
              file,
              entry.value,
              values.cast(),
              count,
            );
            backends[entry.key] = [
              for (var i = 0; i < actual; i++)
                switch (values[i]) {
                  1 => 'cpu',
                  2 => 'gpu',
                  3 => 'npu',
                  _ => 'unknown:${values[i]}',
                },
            ];
          } finally {
            calloc.free(values);
          }
        }
        final maximum = b.litert_lm_loaded_file_max_context_tokens(file);
        return {
          'path': path,
          'artifactSha256': _hash(path),
          'maxContextTokens': maximum > 0 ? maximum : null,
          'dynamicContext': b.litert_lm_loaded_file_is_dynamic_context(file),
          'backends': backends,
          'minimumRuntimeVersion': _string(
            b.litert_lm_loaded_file_min_runtime_version(file),
          ),
          'runtimeVersion': _string(b.lrlm_runtime_version()),
          'runtimeCommit': _string(b.lrlm_runtime_commit()),
        };
      } finally {
        b.litert_lm_loaded_file_delete(file);
      }
    });
  }

  int _loadEngine(LiteRtLmEngineConfig config) {
    if (closing) _fail(const LiteRtLmDisposed('Client is closing'));
    final info = _inspect(config.modelPath);
    if (config.artifactSha256 != null &&
        config.artifactSha256!.toLowerCase() != info['artifactSha256']) {
      _fail(
        const LiteRtLmInvalidArgument(
          'Model SHA256 does not match the requested artifact',
        ),
      );
    }
    final maximum = info['maxContextTokens'] as int?;
    if (maximum == null) {
      _fail(
        const LiteRtLmUnsupportedModel(
          'Artifact has no discoverable context capacity',
        ),
      );
    }
    final dynamicContext = info['dynamicContext']! as bool;
    final context =
        config.maxNumTokens ??
        (dynamicContext ? (maximum < 4096 ? maximum : 4096) : maximum);
    if (context <= 0 ||
        context > maximum ||
        (!dynamicContext && context != maximum)) {
      _fail(
        LiteRtLmInvalidArgument(
          'Requested context $context; artifact ${dynamicContext ? 'maximum' : 'fixed context'} is $maximum',
        ),
      );
    }
    final backends = info['backends']! as Map<String, List<String>>;
    for (final entry in {
      'text': config.backend,
      'vision': config.visionBackend,
      'audio': config.audioBackend,
    }.entries) {
      if (entry.value != null &&
          !(backends[entry.key]?.contains(entry.value) ?? false)) {
        _fail(
          LiteRtLmUnsupported(
            'Artifact does not support ${entry.key} backend ${entry.value}',
          ),
        );
      }
    }
    if (config.prefillChunkSize != null &&
        (config.prefillChunkSize! <= 0 ||
            config.backend != 'cpu' ||
            !dynamicContext)) {
      _fail(
        const LiteRtLmInvalidArgument(
          'prefillChunkSize requires a CPU dynamic-context artifact and a positive chunk size',
        ),
      );
    }
    return _utf8(
      config.modelPath,
      (path) => _utf8(
        config.backend,
        (backend) => _utf8(
          config.visionBackend,
          (vision) => _utf8(config.audioBackend, (audio) {
            final settings = b.litert_lm_engine_settings_create(
              path,
              backend,
              vision,
              audio,
            );
            _checkPointer(settings, 'Cannot create engine settings');
            try {
              b.litert_lm_engine_settings_set_max_num_tokens(settings, context);
              b.litert_lm_engine_settings_enable_benchmark(settings);
              b.litert_lm_engine_settings_set_parallel_file_section_loading(
                settings,
                config.parallelFileSectionLoading,
              );
              if (config.prefillChunkSize != null) {
                b.litert_lm_engine_settings_set_prefill_chunk_size(
                  settings,
                  config.prefillChunkSize!,
                );
              }
              if (config.cacheDir != null) {
                _utf8(
                  config.cacheDir,
                  (p) => b.litert_lm_engine_settings_set_cache_dir(settings, p),
                );
              }
              if (config.litertDispatchLibDir != null) {
                _utf8(
                  config.litertDispatchLibDir,
                  (p) =>
                      b.litert_lm_engine_settings_set_litert_dispatch_lib_dir(
                        settings,
                        p,
                      ),
                );
              }
              final watch = Stopwatch()..start();
              final pointer = b.litert_lm_engine_create(settings);
              _checkPointer(pointer, 'Engine creation failed');
              watch.stop();
              final actualContext = b.lrlm_engine_context_tokens(pointer);
              if (actualContext <= 0 || actualContext > maximum) {
                b.litert_lm_engine_delete(pointer);
                _fail(
                  const LiteRtLmNativeInitFailure(
                    'Native effective context is invalid',
                  ),
                );
              }
              info.addAll({
                'requestedContextTokens': config.maxNumTokens,
                'effectiveContextTokens': actualContext,
                'modelId': config.modelId,
                'revision': config.revision,
                'initializationSeconds': watch.elapsedMicroseconds / 1e6,
              });
              final id = nextEngine++;
              engines[id] = _NativeEngine(pointer, config, info);
              return id;
            } finally {
              b.litert_lm_engine_settings_delete(settings);
            }
          }),
        ),
      ),
    );
  }

  int _createSession(Map<String, Object?> args) {
    final engineId = args['engineId']! as int;
    final engine = _engine(engineId);
    final params = args['params']! as LiteRtLmGenerationParams;
    if (!params.temperature.isFinite ||
        params.temperature < 0 ||
        params.topK <= 0 ||
        params.maxTokens <= 0) {
      _fail(const LiteRtLmInvalidArgument('Invalid generation parameters'));
    }
    final session = _NativeSession(
      engineId,
      params,
      args['conversation'] == true || params.applyPromptTemplate,
      [
        for (final msg
            in (args['messages'] as List<LiteRtLmMessage>? ??
                <LiteRtLmMessage>[]))
          msg.toJson(),
      ],
    );
    _validateModalities(engine, session.history, generation: false);
    _openSession(session, engine);
    final id = nextSession++;
    sessions[id] = session;
    return id;
  }

  void _openSession(
    _NativeSession session,
    _NativeEngine engine, {
    List<Map<String, Object?>>? preface,
  }) {
    session.prefillTurns = 0;
    session.decodeTurns = 0;
    session.nativePreface = List.of(preface ?? session.history);
    final config = b.litert_lm_session_config_create();
    _checkPointer(config, 'Cannot create session settings');
    final sampler = b.litert_lm_sampler_params_create(
      c.LiteRtLmSamplerType.kLiteRtLmSamplerTypeTopP,
    );
    try {
      _checkPointer(sampler, 'Cannot create sampler settings');
      b.litert_lm_sampler_params_set_top_k(sampler, session.params.topK);
      // v0.18.1 CPU sampling (also a GPU fallback) implements TOP_P only.
      // p=1 keeps all top-k candidates and preserves the public sampling API.
      b.litert_lm_sampler_params_set_top_p(sampler, 1);
      b.litert_lm_sampler_params_set_temperature(
        sampler,
        session.params.temperature,
      );
      b.litert_lm_sampler_params_set_seed(sampler, session.params.seed ?? 0);
      b.litert_lm_session_config_set_sampler_params(config, sampler);
      b.litert_lm_session_config_set_max_output_tokens(
        config,
        session.params.maxTokens,
      );
      // Conversation applies the model template exactly once.
      b.litert_lm_session_config_set_apply_prompt_template(config, false);
      if (session.conversation) {
        final chatConfig = b.litert_lm_conversation_config_create();
        _checkPointer(chatConfig, 'Cannot create Conversation settings');
        try {
          b.litert_lm_conversation_config_set_session_config(
            chatConfig,
            config,
          );
          b.litert_lm_conversation_config_set_filter_channel_content_from_kv_cache(
            chatConfig,
            false,
          );
          if (session.nativePreface.isNotEmpty) {
            _utf8(
              jsonEncode(session.nativePreface),
              (p) =>
                  b.litert_lm_conversation_config_set_messages(chatConfig, p),
            );
          }
          session.chat = b.litert_lm_conversation_create(
            engine.pointer,
            chatConfig,
          );
          _checkPointer(session.chat, 'Conversation creation failed');
        } finally {
          b.litert_lm_conversation_config_delete(chatConfig);
        }
      } else {
        session.raw = b.litert_lm_engine_create_session(engine.pointer, config);
        _checkPointer(session.raw, 'Session creation failed');
      }
    } finally {
      if (sampler != ffi.nullptr) b.litert_lm_sampler_params_delete(sampler);
      b.litert_lm_session_config_delete(config);
    }
  }

  List<Map<String, Object?>> _messages(Map<String, Object?> args) {
    if (args['messages'] case final List<LiteRtLmMessage> messages) {
      return [for (final message in messages) message.toJson()];
    }
    return [
      LiteRtLmMessage(
        role: 'user',
        contents: args['contents']! as List<LiteRtLmContent>,
      ).toJson(),
    ];
  }

  void _validateModalities(
    _NativeEngine engine,
    List<Map<String, Object?>> messages, {
    bool generation = true,
  }) {
    if (generation && (messages.isEmpty || messages.last['role'] != 'user')) {
      _fail(
        const LiteRtLmInvalidArgument(
          'A generation must end with a user message',
        ),
      );
    }
    for (final message in messages) {
      for (final item in message['content']! as List) {
        final type = (item as Map)['type'];
        if (type == 'image' && engine.config.visionBackend == null ||
            type == 'audio' && engine.config.audioBackend == null) {
          _fail(
            LiteRtLmUnsupported(
              '$type encoder is not enabled; configure its backend when loading the engine',
            ),
          );
        }
        if (type == 'image' || type == 'audio') {
          final bytes = base64Decode(item['blob']! as String);
          if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) {
            _fail(
              const LiteRtLmInvalidArgument(
                'Media must contain 1..32 MiB of encoded file data',
              ),
            );
          }
          final png =
              bytes.length >= 8 &&
              bytes[0] == 137 &&
              ascii.decode(bytes.sublist(1, 4), allowInvalid: true) == 'PNG';
          final jpeg =
              bytes.length >= 3 &&
              bytes[0] == 255 &&
              bytes[1] == 216 &&
              bytes[2] == 255;
          final wav =
              bytes.length >= 44 &&
              ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
              ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WAVE';
          if (type == 'image' && !png && !jpeg || type == 'audio' && !wav) {
            _fail(
              LiteRtLmInvalidArgument(
                type == 'image'
                    ? 'Image must be an encoded PNG or JPEG file'
                    : 'Audio must be an encoded WAV file',
              ),
            );
          }
        }
      }
    }
  }

  void _generate(Map<String, Object?> args) {
    final stream = args['stream']! as int;
    final session = _session(args['sessionId']! as int);
    if (session.streamId != null) {
      _fail(const LiteRtLmBusy('Only one generation may run per session'));
    }
    final engine = _engine(session.engineId);
    final messages = _messages(args);
    _validateModalities(engine, messages);
    if (session.chat == ffi.nullptr && session.raw == ffi.nullptr) {
      _openSession(session, engine);
    }
    final budget = _budget(session, messages, session.params.maxTokens);
    final required = budget['requiredTokens'] as int?;
    final context = budget['contextTokens']! as int;
    if (required != null && required > context) {
      _fail(
        LiteRtLmContextFull(
          requiredTokens: required,
          availableTokens: context,
          message:
              'Context needs $required tokens including output reserve; available $context',
        ),
      );
    }
    if (session.conversation && messages.length > 1) {
      // v0.18.1 single-turn templates accept an object, not an array. A batch
      // explicitly rebuilds its committed prefix; ordinary single-message
      // sends retain the existing native KV cache.
      _deleteHandle(session);
      _openSession(
        session,
        engine,
        preface: [...session.history, ...messages.take(messages.length - 1)],
      );
    }
    final native = b.lrlm_operation_create();
    if (native == 0) {
      _fail(const LiteRtLmGenerationFailure('Native operation IDs exhausted'));
    }
    final op = _Operation(
      stream,
      session,
      native,
      messages,
      Stopwatch()..start(),
    );
    session.phase = _HandlePhase.generating;
    session.streamId = stream;
    operations[stream] = op;
    try {
      if (session.conversation) {
        _utf8(
          jsonEncode(messages.last),
          (p) => b.lrlm_operation_start_conversation(native, session.chat, p),
        );
      } else {
        final text = messages
            .expand((m) => m['content'] as List)
            .map((p) => (p as Map)['text'] as String)
            .join();
        _utf8(text, (p) {
          final input = b.litert_lm_input_data_create(
            c.LiteRtLmInputDataType.kLiteRtLmInputDataTypeText,
            p.cast(),
            utf8.encode(text).length,
          );
          _checkPointer(input, 'Cannot create text input');
          final array = calloc<ffi.Pointer<c.LiteRtLmInputData>>(1)
            ..value = input;
          try {
            b.lrlm_operation_start_session(native, session.raw, array, 1);
          } finally {
            calloc.free(array);
            b.litert_lm_input_data_delete(input);
          }
        });
      }
    } catch (_) {
      operations.remove(stream);
      session.streamId = null;
      session.phase = _HandlePhase.ready;
      b.lrlm_operation_delete(native);
      rethrow;
    }
    timer ??= Timer.periodic(const Duration(milliseconds: 2), (_) => _pump());
    _pump();
  }

  List<int> _tokenize(_NativeEngine engine, String text) => _utf8(text, (p) {
    final tokens = b.litert_lm_engine_tokenize(engine.pointer, p);
    _checkPointer(tokens, 'Tokenizer failed');
    try {
      final count = b.litert_lm_tokenize_result_get_num_tokens(tokens);
      return List<int>.of(
        b
            .litert_lm_tokenize_result_get_tokens(tokens)
            .cast<ffi.Int32>()
            .asTypedList(count),
      );
    } finally {
      b.litert_lm_tokenize_result_delete(tokens);
    }
  });
  Map<String, Object?> _budget(
    _NativeSession session,
    List<Map<String, Object?>> messages,
    int reserve,
  ) {
    if (reserve < 0) {
      _fail(const LiteRtLmInvalidArgument('Output reserve cannot be negative'));
    }
    final engine = _engine(session.engineId);
    if (messages.isNotEmpty) _validateModalities(engine, messages);
    if (!session.conversation &&
        messages.any(
          (message) => (message['content'] as List).any(
            (part) => (part as Map)['type'] != 'text',
          ),
        )) {
      _fail(
        const LiteRtLmUnsupported(
          'Raw Session accepts text; use Conversation for media',
        ),
      );
    }
    if (session.conversation && messages.length > 1) {
      // Budget a batch using a temporary native preface, without mutating or
      // discarding the live conversation or its completed history.
      final preview = _NativeSession(session.engineId, session.params, true, [
        ...session.history,
        ...messages.take(messages.length - 1),
      ]);
      _openSession(preview, engine);
      try {
        return _budget(preview, [messages.last], reserve);
      } finally {
        _deleteHandle(preview);
      }
    }
    if (session.chat == ffi.nullptr && session.raw == ffi.nullptr) {
      _openSession(session, engine);
    }
    final used = session.conversation
        ? b.litert_lm_conversation_get_token_count(session.chat)
        : b.lrlm_session_context_tokens(session.raw);
    if (used < 0) {
      _fail(
        session.conversation
            ? _nativeError('Cannot query context use')
            : _classify(_string(b.lrlm_budget_error())),
      );
    }
    final input = messages.isEmpty
        ? 0
        : session.conversation
        ? _utf8(
            jsonEncode(messages.single),
            (p) => b.lrlm_conversation_input_tokens(
              engine.pointer,
              session.chat,
              p,
            ),
          )
        : _utf8(
            messages
                .expand((m) => m['content'] as List)
                .map((p) => (p as Map)['text'])
                .join(),
            (p) => b.lrlm_session_input_tokens(
              engine.pointer,
              session.raw,
              p,
              used == 0,
            ),
          );
    if (input < 0) _fail(_classify(_string(b.lrlm_budget_error())));
    final context = engine.info['effectiveContextTokens']! as int;
    final required = used + input + reserve;
    return {
      'contextTokens': context,
      'usedTokens': used,
      'inputTokens': input,
      'outputReserve': reserve,
      'requiredTokens': required,
      'remainingTokens': context - required,
      'exact': true,
    };
  }

  void _cancel(_Operation op, {bool overflow = false}) {
    if (op.cancelRequested) return;
    op.cancelRequested = true;
    op.backpressure = overflow;
    op.session.phase = _HandlePhase.cancelRequested;
    if (!overflow) b.lrlm_operation_cancel(op.native);
    if (op.session.conversation) {
      b.litert_lm_conversation_cancel_process(op.session.chat);
    } else {
      b.litert_lm_session_cancel_process(op.session.raw);
    }
  }

  void _pump() {
    for (final op in operations.values.toList()) {
      try {
        if (b.lrlm_operation_needs_cancel(op.native)) {
          _cancel(op, overflow: true);
        }
        // Once native final is queued, its remaining queue is finite/bounded.
        // Drain it even for a paused subscriber, so native cleanup never waits
        // for a Dart resume. The controller buffers at most this final burst.
        if (!op.credit &&
            !op.cancelRequested &&
            !b.lrlm_operation_is_final(op.native)) {
          continue;
        }
        final payload = b.lrlm_operation_take(op.native);
        if (payload == ffi.nullptr) continue;
        int kind;
        String text;
        try {
          if (b.lrlm_event_operation_id(payload) != op.native) continue;
          kind = b.lrlm_event_kind(payload);
          text = _string(b.lrlm_event_text(payload));
        } finally {
          b.lrlm_event_delete(payload);
        }
        if (kind == 0) {
          if (op.cancelRequested) continue;
          text = op.session.conversation ? _chatText(text) : text;
          if (text.isEmpty) continue;
          op.ttft ??= op.start.elapsedMicroseconds / 1e6;
          op.text.write(text);
          op.credit = false;
          _event(op.stream, 'token', text: text);
        } else {
          _finish(op, kind, text);
        }
      } catch (error) {
        // Malformed UTF-8/JSON is a failure, never a justification to release a
        // live producer. Join via native deletion before releasing operation.
        _cancel(op);
        _deleteHandle(op.session);
        _finish(op, 2, 'Invalid native event: $error', failureAfterStop: true);
      }
    }
    if (operations.isEmpty) {
      timer?.cancel();
      timer = null;
    }
  }

  String _chatText(String text) {
    final json = jsonDecode(text) as Map;
    final content = json['content'];
    if (content is String) return content;
    if (content is List) {
      return content
          .whereType<Map>()
          .where((p) => p['type'] == 'text')
          .map((p) => p['text'] as String)
          .join();
    }
    return '';
  }

  void _finish(
    _Operation op,
    int kind,
    String detail, {
    bool failureAfterStop = false,
  }) {
    if (!operations.containsKey(op.stream)) return;
    final session = op.session;
    final cancelled = !failureAfterStop && (op.cancelRequested || kind == 3);
    if (cancelled || kind != 1) {
      // Upstream v0.18.1 documents cancelled Conversation as poisoned. Delete
      // joins native tasks; next request rebuilds from committed history only.
      _deleteHandle(session);
    } else {
      session.metrics = _metrics(session, op);
      if (kind == 1 && session.conversation) {
        final nativeHistory =
            jsonDecode(_string(b.lrlm_conversation_history(session.chat)))
                as List;
        session.history
          ..clear()
          ..addAll(session.nativePreface)
          ..addAll(
            nativeHistory.map((m) => (m as Map).cast<String, Object?>()),
          );
      }
    }
    b.lrlm_operation_delete(op.native);
    operations.remove(op.stream);
    session.streamId = null;
    if (session.phase != _HandlePhase.closing) {
      session.phase = _HandlePhase.ready;
    }
    if (op.backpressure || kind == 4) {
      _event(
        op.stream,
        'error',
        failure: LiteRtLmBackpressure(
          detail.isEmpty ? 'Native event queue overflowed' : detail,
        ),
      );
    } else if (cancelled) {
      _event(op.stream, 'cancelled');
    } else if (kind == 1) {
      _event(op.stream, 'complete', text: op.text.toString());
    } else {
      _event(op.stream, 'error', failure: _classify(detail));
    }
  }

  Map<String, Object?> _metrics(_NativeSession session, _Operation op) {
    final engine = engines[session.engineId]!;
    final result = <String, Object?>{
      'initializationSeconds': engine.info['initializationSeconds'],
      'timeToFirstTokenSeconds': op.ttft,
      'backend': engine.config.backend,
      'effectiveContextTokens': engine.info['effectiveContextTokens'],
      'contextUsedTokens': session.conversation
          ? b.litert_lm_conversation_get_token_count(session.chat)
          : b.lrlm_session_context_tokens(session.raw),
    };
    final info = session.conversation
        ? b.litert_lm_conversation_get_benchmark_info(session.chat)
        : b.litert_lm_session_get_benchmark_info(session.raw);
    if (info == ffi.nullptr) return result;
    try {
      final prefill = b.litert_lm_benchmark_info_get_num_prefill_turns(info);
      final decode = b.litert_lm_benchmark_info_get_num_decode_turns(info);
      // Native benchmark "turns" can be individual prefill chunks. Sum every
      // newly completed turn, without recounting previous conversation rounds.
      int prefillTokens = 0, decodeTokens = 0;
      double prefillSeconds = 0, decodeSeconds = 0;
      bool validPrefillTime = true, validDecodeTime = true;
      for (var i = session.prefillTurns; i < prefill; i++) {
        final count = b.litert_lm_benchmark_info_get_prefill_token_count_at(
          info,
          i,
        );
        final speed = b.litert_lm_benchmark_info_get_prefill_tokens_per_sec_at(
          info,
          i,
        );
        prefillTokens += count;
        if (speed > 0 && speed.isFinite) {
          prefillSeconds += count / speed;
        } else {
          validPrefillTime = false;
        }
      }
      for (var i = session.decodeTurns; i < decode; i++) {
        final count = b.litert_lm_benchmark_info_get_decode_token_count_at(
          info,
          i,
        );
        final speed = b.litert_lm_benchmark_info_get_decode_tokens_per_sec_at(
          info,
          i,
        );
        decodeTokens += count;
        if (speed > 0 && speed.isFinite) {
          decodeSeconds += count / speed;
        } else {
          validDecodeTime = false;
        }
      }
      if (prefill > session.prefillTurns) {
        result['prefillTokens'] = prefillTokens;
        result['prefillSeconds'] = validPrefillTime ? prefillSeconds : null;
      }
      if (decode > session.decodeTurns) {
        result['decodeTokens'] = decodeTokens;
        result['decodeTokensPerSecond'] = validDecodeTime && decodeSeconds > 0
            ? decodeTokens / decodeSeconds
            : null;
      }
      session.prefillTurns = prefill;
      session.decodeTurns = decode;
      final ttft = b.litert_lm_benchmark_info_get_time_to_first_token(info);
      result['nativeTimeToFirstTokenSeconds'] = ttft.isFinite && ttft >= 0
          ? ttft
          : null;
      return result;
    } finally {
      b.litert_lm_benchmark_info_delete(info);
    }
  }

  void _deleteHandle(_NativeSession session) {
    if (session.chat != ffi.nullptr) {
      b.litert_lm_conversation_delete(session.chat);
      session.chat = ffi.nullptr;
    }
    if (session.raw != ffi.nullptr) {
      b.litert_lm_session_delete(session.raw);
      session.raw = ffi.nullptr;
    }
  }

  void _disposeSession(int id) {
    final session = sessions[id];
    if (session == null) return;
    session.phase = _HandlePhase.closing;
    final op = operations[session.streamId];
    if (op != null) _cancel(op);
    // Native queues never wait for Dart. Destructor can join safely on this
    // control thread; no closed Dart callback or full blocking queue can deadlock.
    _deleteHandle(session);
    if (op != null) _finish(op, 3, '');
    session.phase = _HandlePhase.closed;
    sessions.remove(id);
  }

  void _disposeEngine(int id) {
    final engine = engines[id];
    if (engine == null) return;
    engine.phase = _HandlePhase.closing;
    for (final entry
        in sessions.entries.where((e) => e.value.engineId == id).toList()) {
      _disposeSession(entry.key);
    }
    b.litert_lm_engine_delete(engine.pointer);
    engine.phase = _HandlePhase.closed;
    engines.remove(id);
  }

  void _closeAll() {
    closing = true;
    for (final id in engines.keys.toList()) {
      _disposeEngine(id);
    }
    timer?.cancel();
    timer = null;
  }
}

final class _DigestSink implements Sink<Digest> {
  late Digest digest;
  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}

LiteRtLmFailure _classify(String text) {
  // ResourceExhausted also covers context/buffer limits. Do not label it OOM
  // without explicit allocator evidence from the native error.
  if (RegExp(
    r'bad_alloc|out of memory|failed to allocate memory',
    caseSensitive: false,
  ).hasMatch(text)) {
    return LiteRtLmOutOfMemory(text);
  }
  if (text.startsWith('CANCELLED:')) return LiteRtLmCancelled(text);
  if (RegExp(
    r'max.*tokens.*exceed|context.*(full|exceed)|input.*tokens.*exceed',
    caseSensitive: false,
  ).hasMatch(text)) {
    return LiteRtLmContextFull(
      requiredTokens: null,
      availableTokens: null,
      message: text,
    );
  }
  if (text.startsWith('UNIMPLEMENTED:')) return LiteRtLmUnsupported(text);
  if (text.startsWith('INVALID_ARGUMENT:')) {
    return LiteRtLmInvalidArgument(text);
  }
  return LiteRtLmGenerationFailure(text);
}
