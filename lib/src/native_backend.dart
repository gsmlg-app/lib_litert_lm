import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'backend.dart';
import 'bindings/litert_lm_bindings_generated.dart' as c;
import 'types.dart';

final class NativeLiteRtLmBackend implements LiteRtLmBackend {
  NativeLiteRtLmBackend._(this._isolate, this._commands);

  final Isolate _isolate;
  final SendPort _commands;
  var _closed = false;
  var _nextStreamId = 1;

  static Future<LiteRtLmResult<LiteRtLmBackend>> start({
    required String libraryName,
  }) async {
    if (!Platform.isAndroid) {
      return const LiteRtLmErr(
        LiteRtLmNativeInitFailure('LiteRT-LM native backend is Android-only'),
      );
    }

    final readyPort = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<Map<String, Object?>>(
        _workerMain,
        <String, Object?>{
          'libraryName': libraryName,
          'replyTo': readyPort.sendPort,
        },
        debugName: 'LiteRT-LM FFI worker',
      );
      final raw = await readyPort.first;
      final result = _decodeWorkerReady(raw);
      return result.map(
        (sendPort) => NativeLiteRtLmBackend._(isolate!, sendPort),
      );
    } catch (error) {
      isolate?.kill(priority: Isolate.immediate);
      return LiteRtLmErr(
        LiteRtLmNativeInitFailure('Failed to start LiteRT-LM worker: $error'),
      );
    } finally {
      readyPort.close();
    }
  }

  @override
  Future<LiteRtLmResult<int>> loadEngine(LiteRtLmEngineConfig config) {
    return _requestResult<int>('loadEngine', <String, Object?>{
      'modelPath': config.modelPath,
      'backend': config.backend,
      'maxNumTokens': config.maxNumTokens,
      'cacheDir': config.cacheDir,
      'litertDispatchLibDir': config.litertDispatchLibDir,
      'prefillChunkSize': config.prefillChunkSize,
      'parallelFileSectionLoading': config.parallelFileSectionLoading,
    });
  }

  @override
  Future<LiteRtLmResult<int>> createSession(
    int engineId,
    LiteRtLmGenerationParams params,
  ) {
    return _requestResult<int>('createSession', <String, Object?>{
      'engineId': engineId,
      'temperature': params.temperature,
      'topK': params.topK,
      'maxTokens': params.maxTokens,
      'seed': params.seed,
      'applyPromptTemplate': params.applyPromptTemplate,
    });
  }

  @override
  Future<LiteRtLmResult<String>> generate(int sessionId, String prompt) {
    return _requestResult<String>('generate', <String, Object?>{
      'sessionId': sessionId,
      'prompt': prompt,
    });
  }

  @override
  Stream<LiteRtLmEvent> generateStream(int sessionId, String prompt) {
    if (_closed) {
      return Stream<LiteRtLmEvent>.value(
        const LiteRtLmFailed(
          LiteRtLmDisposed('LiteRT-LM backend has been closed'),
        ),
      );
    }

    final streamId = _nextStreamId++;
    final events = ReceivePort();
    StreamSubscription<Object?>? subscription;
    var finished = false;

    late final StreamController<LiteRtLmEvent> controller;
    controller = StreamController<LiteRtLmEvent>(
      onListen: () {
        subscription = events.listen((raw) {
          final event = _decodeStreamEvent(raw);
          switch (event) {
            case _DecodedStreamEvent(:final value, :final closes):
              controller.add(value);
              if (closes) {
                finished = true;
                unawaited(controller.close());
              }
          }
        });
        _commands.send(<String, Object?>{
          'command': 'generateStream',
          'streamId': streamId,
          'sessionId': sessionId,
          'prompt': prompt,
          'events': events.sendPort,
        });
      },
      onCancel: () async {
        await subscription?.cancel();
        events.close();
        if (!finished) {
          _commands.send(<String, Object?>{
            'command': 'cancelStream',
            'streamId': streamId,
            'sessionId': sessionId,
          });
        }
      },
    );

    return controller.stream;
  }

  @override
  Future<LiteRtLmResult<String>> generateContent(
    int sessionId,
    List<LiteRtLmContent> contents,
  ) {
    return _requestResult<String>('generateContent', <String, Object?>{
      'sessionId': sessionId,
      'contents': contents,
    });
  }

  @override
  Stream<LiteRtLmEvent> generateContentStream(
    int sessionId,
    List<LiteRtLmContent> contents,
  ) {
    if (_closed) {
      return Stream<LiteRtLmEvent>.value(
        const LiteRtLmFailed(
          LiteRtLmDisposed('LiteRT-LM backend has been closed'),
        ),
      );
    }

    final streamId = _nextStreamId++;
    final events = ReceivePort();
    StreamSubscription<Object?>? subscription;
    var finished = false;

    late final StreamController<LiteRtLmEvent> controller;
    controller = StreamController<LiteRtLmEvent>(
      onListen: () {
        subscription = events.listen((raw) {
          final event = _decodeStreamEvent(raw);
          switch (event) {
            case _DecodedStreamEvent(:final value, :final closes):
              controller.add(value);
              if (closes) {
                finished = true;
                unawaited(controller.close());
              }
          }
        });
        _commands.send(<String, Object?>{
          'command': 'generateContentStream',
          'streamId': streamId,
          'sessionId': sessionId,
          'contents': contents,
          'events': events.sendPort,
        });
      },
      onCancel: () async {
        await subscription?.cancel();
        events.close();
        if (!finished) {
          _commands.send(<String, Object?>{
            'command': 'cancelStream',
            'streamId': streamId,
            'sessionId': sessionId,
          });
        }
      },
    );

    return controller.stream;
  }

  @override
  Future<void> cancelSession(int sessionId) {
    return _requestVoid('cancelSession', <String, Object?>{
      'sessionId': sessionId,
    });
  }

  @override
  Future<void> disposeSession(int sessionId) {
    return _requestVoid('disposeSession', <String, Object?>{
      'sessionId': sessionId,
    });
  }

  @override
  Future<void> disposeEngine(int engineId) {
    return _requestVoid('disposeEngine', <String, Object?>{
      'engineId': engineId,
    });
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _requestVoid('close', const <String, Object?>{});
    _isolate.kill(priority: Isolate.immediate);
  }

  Future<LiteRtLmResult<T>> _requestResult<T>(
    String command,
    Map<String, Object?> args,
  ) async {
    if (_closed) {
      return const LiteRtLmErr(
        LiteRtLmDisposed('LiteRT-LM backend has been closed'),
      );
    }

    final reply = ReceivePort();
    try {
      _commands.send(<String, Object?>{
        'command': command,
        'replyTo': reply.sendPort,
        ...args,
      });
      final raw = await reply.first;
      return _decodeResult<T>(raw);
    } finally {
      reply.close();
    }
  }

  Future<void> _requestVoid(String command, Map<String, Object?> args) async {
    final reply = ReceivePort();
    try {
      _commands.send(<String, Object?>{
        'command': command,
        'replyTo': reply.sendPort,
        ...args,
      });
      await reply.first;
    } finally {
      reply.close();
    }
  }
}

final class _DecodedStreamEvent {
  const _DecodedStreamEvent(this.value, {this.closes = false});

  final LiteRtLmEvent value;
  final bool closes;
}

LiteRtLmResult<SendPort> _decodeWorkerReady(Object? raw) {
  if (raw case <Object?, Object?>{
    'ok': true,
    'sendPort': final SendPort port,
  }) {
    return LiteRtLmOk(port);
  }
  if (raw case <Object?, Object?>{'ok': false, 'error': final Map error}) {
    return LiteRtLmErr(liteRtLmFailureFromMap(error));
  }
  return const LiteRtLmErr(
    LiteRtLmNativeInitFailure('LiteRT-LM worker returned an invalid handshake'),
  );
}

LiteRtLmResult<T> _decodeResult<T>(Object? raw) {
  if (raw case <Object?, Object?>{'ok': true, 'value': final Object? value}) {
    if (value is T) {
      return LiteRtLmOk(value);
    }
    return LiteRtLmErr(
      LiteRtLmNativeInitFailure('Native worker returned ${value.runtimeType}'),
    );
  }
  if (raw case <Object?, Object?>{'ok': false, 'error': final Map error}) {
    return LiteRtLmErr(liteRtLmFailureFromMap(error));
  }
  return const LiteRtLmErr(
    LiteRtLmNativeInitFailure('Native worker returned an invalid response'),
  );
}

_DecodedStreamEvent _decodeStreamEvent(Object? raw) {
  if (raw case <Object?, Object?>{'type': 'token', 'text': final String text}) {
    return _DecodedStreamEvent(LiteRtLmToken(text));
  }
  if (raw case <Object?, Object?>{
    'type': 'complete',
    'text': final String text,
  }) {
    return _DecodedStreamEvent(LiteRtLmCompleted(text), closes: true);
  }
  if (raw case <Object?, Object?>{'type': 'cancelled'}) {
    return const _DecodedStreamEvent(LiteRtLmCancelledEvent(), closes: true);
  }
  if (raw case <Object?, Object?>{'type': 'error', 'error': final Map error}) {
    return _DecodedStreamEvent(
      LiteRtLmFailed(liteRtLmFailureFromMap(error)),
      closes: true,
    );
  }
  return const _DecodedStreamEvent(
    LiteRtLmFailed(
      LiteRtLmNativeInitFailure('Native worker returned an invalid event'),
    ),
    closes: true,
  );
}

void _workerMain(Map<String, Object?> start) {
  final replyTo = start['replyTo']! as SendPort;
  try {
    final libraryName = start['libraryName']! as String;
    final library = ffi.DynamicLibrary.open(libraryName);
    final state = _NativeWorkerState(c.LiteRtLmBindings(library));
    replyTo.send(<String, Object?>{
      'ok': true,
      'sendPort': state.commands.sendPort,
    });
    state.listen();
  } catch (error) {
    replyTo.send(<String, Object?>{
      'ok': false,
      'error': liteRtLmFailureToMap(
        LiteRtLmNativeInitFailure('Failed to load LiteRT-LM library: $error'),
      ),
    });
  }
}

final class _NativeWorkerState {
  _NativeWorkerState(this.bindings);

  final c.LiteRtLmBindings bindings;
  final commands = ReceivePort();
  final engines = <int, _NativeEngine>{};
  final sessions = <int, _NativeSession>{};
  final streams = <int, _ActiveStream>{};
  var nextEngineId = 1;
  var nextSessionId = 1;

  void listen() {
    commands.listen(handle);
  }

  void handle(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      return;
    }
    final command = raw['command'] as String?;
    final replyTo = raw['replyTo'] as SendPort?;
    switch (command) {
      case 'loadEngine':
        _reply(replyTo, _loadEngine(raw));
      case 'createSession':
        _reply(replyTo, _createSession(raw));
      case 'generate':
        _reply(replyTo, _generate(raw));
      case 'generateStream':
        _generateStream(raw);
      case 'generateContent':
        _reply(replyTo, _generateContent(raw));
      case 'generateContentStream':
        _generateContentStream(raw);
      case 'cancelStream':
        _cancelStream(raw);
        _replyOk(replyTo, null);
      case 'cancelSession':
        _cancelSession(raw);
        _replyOk(replyTo, null);
      case 'disposeSession':
        _disposeSession(raw);
        _replyOk(replyTo, null);
      case 'disposeEngine':
        _disposeEngine(raw);
        _replyOk(replyTo, null);
      case 'close':
        _closeAll();
        _replyOk(replyTo, null);
        commands.close();
      default:
        _reply(
          replyTo,
          const LiteRtLmErr<void>(
            LiteRtLmNativeInitFailure('Unknown worker command'),
          ),
        );
    }
  }

  LiteRtLmResult<int> _loadEngine(Map<Object?, Object?> args) {
    final modelPath = args['modelPath']! as String;
    final backend = args['backend']! as String;
    final maxNumTokens = args['maxNumTokens'] as int?;
    final cacheDir = args['cacheDir'] as String?;
    final litertDispatchLibDir = args['litertDispatchLibDir'] as String?;
    final prefillChunkSize = args['prefillChunkSize'] as int?;
    final parallelFileSectionLoading =
        args['parallelFileSectionLoading'] as bool? ?? true;

    if (!File(modelPath).existsSync()) {
      return LiteRtLmErr(
        LiteRtLmModelNotFound('Model file does not exist: $modelPath'),
      );
    }
    if (!modelPath.toLowerCase().endsWith('.litertlm')) {
      return LiteRtLmErr(
        LiteRtLmUnsupportedModel('Expected a .litertlm model: $modelPath'),
      );
    }

    final modelPathPtr = modelPath.toNativeUtf8(allocator: calloc);
    final backendPtr = backend.toNativeUtf8(allocator: calloc);
    try {
      final settings = bindings.litert_lm_engine_settings_create(
        modelPathPtr.cast<ffi.Char>(),
        backendPtr.cast<ffi.Char>(),
        ffi.nullptr.cast<ffi.Char>(),
        ffi.nullptr.cast<ffi.Char>(),
      );
      if (settings == ffi.nullptr) {
        return const LiteRtLmErr(
          LiteRtLmNativeInitFailure('Failed to create engine settings'),
        );
      }

      try {
        if (maxNumTokens != null) {
          bindings.litert_lm_engine_settings_set_max_num_tokens(
            settings,
            maxNumTokens,
          );
        }
        bindings.litert_lm_engine_settings_set_parallel_file_section_loading(
          settings,
          parallelFileSectionLoading,
        );
        if (cacheDir != null && cacheDir.isNotEmpty) {
          final cacheDirPtr = cacheDir.toNativeUtf8(allocator: calloc);
          try {
            bindings.litert_lm_engine_settings_set_cache_dir(
              settings,
              cacheDirPtr.cast<ffi.Char>(),
            );
          } finally {
            calloc.free(cacheDirPtr);
          }
        }
        if (litertDispatchLibDir != null && litertDispatchLibDir.isNotEmpty) {
          final dispatchDirPtr = litertDispatchLibDir.toNativeUtf8(
            allocator: calloc,
          );
          try {
            bindings.litert_lm_engine_settings_set_litert_dispatch_lib_dir(
              settings,
              dispatchDirPtr.cast<ffi.Char>(),
            );
          } finally {
            calloc.free(dispatchDirPtr);
          }
        }
        if (prefillChunkSize != null) {
          bindings.litert_lm_engine_settings_set_prefill_chunk_size(
            settings,
            prefillChunkSize,
          );
        }

        final engine = bindings.litert_lm_engine_create(settings);
        if (engine == ffi.nullptr) {
          return const LiteRtLmErr(
            LiteRtLmNativeInitFailure('Failed to create LiteRT-LM engine'),
          );
        }

        final id = nextEngineId++;
        engines[id] = _NativeEngine(engine);
        return LiteRtLmOk(id);
      } finally {
        bindings.litert_lm_engine_settings_delete(settings);
      }
    } catch (error) {
      return LiteRtLmErr(_classifyNativeFailure('$error'));
    } finally {
      calloc.free(modelPathPtr);
      calloc.free(backendPtr);
    }
  }

  LiteRtLmResult<int> _createSession(Map<Object?, Object?> args) {
    final engineId = args['engineId']! as int;
    final engine = engines[engineId];
    if (engine == null || engine.disposed) {
      return const LiteRtLmErr(
        LiteRtLmDisposed('LiteRT-LM engine has been disposed'),
      );
    }

    final config = bindings.litert_lm_session_config_create();
    if (config == ffi.nullptr) {
      return const LiteRtLmErr(
        LiteRtLmNativeInitFailure('Failed to create session config'),
      );
    }

    final sampler = calloc<c.LiteRtLmSamplerParams>();
    try {
      sampler.ref
        ..typeAsInt = c.LiteRtLmSamplerType.kLiteRtLmSamplerTypeTopK.value
        ..top_k = args['topK']! as int
        ..top_p = 1.0
        ..temperature = args['temperature']! as double
        ..seed = args['seed'] as int? ?? 0;

      bindings.litert_lm_session_config_set_max_output_tokens(
        config,
        args['maxTokens']! as int,
      );
      bindings.litert_lm_session_config_set_apply_prompt_template(
        config,
        args['applyPromptTemplate'] as bool? ?? true,
      );
      bindings.litert_lm_session_config_set_sampler_params(config, sampler);

      final session = bindings.litert_lm_engine_create_session(
        engine.pointer,
        config,
      );
      if (session == ffi.nullptr) {
        return const LiteRtLmErr(
          LiteRtLmNativeInitFailure('Failed to create LiteRT-LM session'),
        );
      }

      final id = nextSessionId++;
      sessions[id] = _NativeSession(session, engineId: engineId);
      return LiteRtLmOk(id);
    } catch (error) {
      return LiteRtLmErr(_classifyNativeFailure('$error'));
    } finally {
      bindings.litert_lm_session_config_delete(config);
      calloc.free(sampler);
    }
  }

  LiteRtLmResult<String> _generate(Map<Object?, Object?> args) {
    final sessionId = args['sessionId']! as int;
    final session = sessions[sessionId];
    if (session == null || session.disposed) {
      return const LiteRtLmErr(
        LiteRtLmDisposed('LiteRT-LM session has been disposed'),
      );
    }

    final prompt = args['prompt']! as String;
    final responses = _withTextInput(prompt, (input) {
      return bindings.litert_lm_session_generate_content(
        session.pointer,
        input,
        1,
      );
    });

    if (responses == ffi.nullptr) {
      return const LiteRtLmErr(
        LiteRtLmGenerationFailure('Native generation returned no response'),
      );
    }

    try {
      final count = bindings.litert_lm_responses_get_num_candidates(responses);
      if (count <= 0) {
        return const LiteRtLmOk('');
      }
      final textPtr = bindings.litert_lm_responses_get_response_text_at(
        responses,
        0,
      );
      if (textPtr == ffi.nullptr) {
        return const LiteRtLmErr(
          LiteRtLmGenerationFailure('Native response text was null'),
        );
      }
      return LiteRtLmOk(textPtr.cast<Utf8>().toDartString());
    } catch (error) {
      return LiteRtLmErr(_classifyNativeFailure('$error', generation: true));
    } finally {
      bindings.litert_lm_responses_delete(responses);
    }
  }

  void _generateStream(Map<Object?, Object?> args) {
    final streamId = args['streamId']! as int;
    final sessionId = args['sessionId']! as int;
    final events = args['events']! as SendPort;
    final session = sessions[sessionId];
    if (session == null || session.disposed) {
      events.send(<String, Object?>{
        'type': 'error',
        'error': liteRtLmFailureToMap(
          const LiteRtLmDisposed('LiteRT-LM session has been disposed'),
        ),
      });
      return;
    }

    final buffer = StringBuffer();
    late final ffi.NativeCallable<c.LiteRtLmStreamCallbackFunction> callback;
    callback = ffi.NativeCallable<c.LiteRtLmStreamCallbackFunction>.listener((
      ffi.Pointer<ffi.Void> callbackData,
      ffi.Pointer<ffi.Char> chunk,
      bool isFinal,
      ffi.Pointer<ffi.Char> errorMsg,
    ) {
      final active = streams[streamId];
      if (active == null) {
        return;
      }
      final errorText = errorMsg == ffi.nullptr
          ? null
          : errorMsg.cast<Utf8>().toDartString();
      if (errorText != null && errorText.isNotEmpty) {
        active.events.send(<String, Object?>{
          'type': 'error',
          'error': liteRtLmFailureToMap(
            _classifyNativeFailure(errorText, generation: true),
          ),
        });
        scheduleMicrotask(() => _closeStream(streamId));
        return;
      }

      final text = chunk == ffi.nullptr
          ? ''
          : chunk.cast<Utf8>().toDartString();
      if (text.isNotEmpty) {
        buffer.write(text);
        active.events.send(<String, Object?>{'type': 'token', 'text': text});
      }
      if (isFinal) {
        active.events.send(<String, Object?>{
          'type': 'complete',
          'text': buffer.toString(),
        });
        scheduleMicrotask(() => _closeStream(streamId));
      }
    });

    streams[streamId] = _ActiveStream(sessionId, events, callback);
    final status = _withTextInput(args['prompt']! as String, (input) {
      return bindings.litert_lm_session_generate_content_stream(
        session.pointer,
        input,
        1,
        callback.nativeFunction,
        ffi.nullptr.cast<ffi.Void>(),
      );
    });

    if (status != 0) {
      events.send(<String, Object?>{
        'type': 'error',
        'error': liteRtLmFailureToMap(
          const LiteRtLmGenerationFailure('Failed to start native stream'),
        ),
      });
      _closeStream(streamId);
    }
  }

  LiteRtLmResult<String> _generateContent(Map<Object?, Object?> args) {
    final sessionId = args['sessionId']! as int;
    final session = sessions[sessionId];
    if (session == null || session.disposed) {
      return const LiteRtLmErr(
        LiteRtLmDisposed('LiteRT-LM session has been disposed'),
      );
    }

    final contents = args['contents']! as List<LiteRtLmContent>;
    final responses = _withTextInputList(contents, (inputs, count) {
      return bindings.litert_lm_session_generate_content(
        session.pointer,
        inputs,
        count,
      );
    });

    if (responses == ffi.nullptr) {
      return const LiteRtLmErr(
        LiteRtLmGenerationFailure('Native generation returned no response'),
      );
    }

    try {
      final count = bindings.litert_lm_responses_get_num_candidates(responses);
      if (count <= 0) {
        return const LiteRtLmOk('');
      }
      final textPtr = bindings.litert_lm_responses_get_response_text_at(
        responses,
        0,
      );
      if (textPtr == ffi.nullptr) {
        return const LiteRtLmErr(
          LiteRtLmGenerationFailure('Native response text was null'),
        );
      }
      return LiteRtLmOk(textPtr.cast<Utf8>().toDartString());
    } catch (error) {
      return LiteRtLmErr(_classifyNativeFailure('$error', generation: true));
    } finally {
      bindings.litert_lm_responses_delete(responses);
    }
  }

  void _generateContentStream(Map<Object?, Object?> args) {
    final streamId = args['streamId']! as int;
    final sessionId = args['sessionId']! as int;
    final events = args['events']! as SendPort;
    final session = sessions[sessionId];
    if (session == null || session.disposed) {
      events.send(<String, Object?>{
        'type': 'error',
        'error': liteRtLmFailureToMap(
          const LiteRtLmDisposed('LiteRT-LM session has been disposed'),
        ),
      });
      return;
    }

    final buffer = StringBuffer();
    late final ffi.NativeCallable<c.LiteRtLmStreamCallbackFunction> callback;
    callback = ffi.NativeCallable<c.LiteRtLmStreamCallbackFunction>.listener((
      ffi.Pointer<ffi.Void> callbackData,
      ffi.Pointer<ffi.Char> chunk,
      bool isFinal,
      ffi.Pointer<ffi.Char> errorMsg,
    ) {
      final active = streams[streamId];
      if (active == null) {
        return;
      }
      final errorText = errorMsg == ffi.nullptr
          ? null
          : errorMsg.cast<Utf8>().toDartString();
      if (errorText != null && errorText.isNotEmpty) {
        active.events.send(<String, Object?>{
          'type': 'error',
          'error': liteRtLmFailureToMap(
            _classifyNativeFailure(errorText, generation: true),
          ),
        });
        scheduleMicrotask(() => _closeStream(streamId));
        return;
      }

      final text = chunk == ffi.nullptr
          ? ''
          : chunk.cast<Utf8>().toDartString();
      if (text.isNotEmpty) {
        buffer.write(text);
        active.events.send(<String, Object?>{'type': 'token', 'text': text});
      }
      if (isFinal) {
        active.events.send(<String, Object?>{
          'type': 'complete',
          'text': buffer.toString(),
        });
        scheduleMicrotask(() => _closeStream(streamId));
      }
    });

    streams[streamId] = _ActiveStream(sessionId, events, callback);
    final contents = args['contents']! as List<LiteRtLmContent>;
    final status = _withTextInputList(contents, (inputs, count) {
      return bindings.litert_lm_session_generate_content_stream(
        session.pointer,
        inputs,
        count,
        callback.nativeFunction,
        ffi.nullptr.cast<ffi.Void>(),
      );
    });

    if (status != 0) {
      events.send(<String, Object?>{
        'type': 'error',
        'error': liteRtLmFailureToMap(
          const LiteRtLmGenerationFailure('Failed to start native stream'),
        ),
      });
      _closeStream(streamId);
    }
  }

  void _cancelStream(Map<Object?, Object?> args) {
    final streamId = args['streamId']! as int;
    final sessionId = args['sessionId']! as int;
    sessions[sessionId]?.cancel(bindings);
    streams[streamId]?.events.send(<String, Object?>{'type': 'cancelled'});
    _closeStream(streamId);
  }

  void _cancelSession(Map<Object?, Object?> args) {
    final sessionId = args['sessionId']! as int;
    sessions[sessionId]?.cancel(bindings);
  }

  void _disposeSession(Map<Object?, Object?> args) {
    final sessionId = args['sessionId']! as int;
    sessions.remove(sessionId)?.dispose(bindings);
  }

  void _disposeEngine(Map<Object?, Object?> args) {
    final engineId = args['engineId']! as int;
    final sessionIds = sessions.entries
        .where((entry) => entry.value.engineId == engineId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final sessionId in sessionIds) {
      sessions.remove(sessionId)?.dispose(bindings);
    }
    engines.remove(engineId)?.dispose(bindings);
  }

  void _closeStream(int streamId) {
    streams.remove(streamId)?.close();
  }

  void _closeAll() {
    for (final stream in streams.values) {
      sessions[stream.sessionId]?.cancel(bindings);
      stream.close();
    }
    streams.clear();
    for (final session in sessions.values) {
      session.dispose(bindings);
    }
    sessions.clear();
    for (final engine in engines.values) {
      engine.dispose(bindings);
    }
    engines.clear();
  }

  T _withTextInput<T>(
    String text,
    T Function(ffi.Pointer<c.LiteRtLmInputData> input) run,
  ) {
    final bytes = utf8.encode(text);
    final textPtr = text.toNativeUtf8(allocator: calloc);
    final input = calloc<c.LiteRtLmInputData>();
    try {
      input.ref
        ..typeAsInt = c.LiteRtLmInputDataType.kLiteRtLmInputDataTypeText.value
        ..data = textPtr.cast<ffi.Void>()
        ..size = bytes.length;
      return run(input);
    } finally {
      calloc.free(input);
      calloc.free(textPtr);
    }
  }

  T _withTextInputList<T>(
    List<LiteRtLmContent> contents,
    T Function(ffi.Pointer<c.LiteRtLmInputData> inputs, int count) run,
  ) {
    final count = contents.length;
    final inputs = calloc<c.LiteRtLmInputData>(count);
    final allocatedPointers = <ffi.Pointer<ffi.Void>>[];

    try {
      for (var i = 0; i < count; i++) {
        final content = contents[i];
        final input = (inputs + i).ref;

        switch (content) {
          case LiteRtLmTextContent(:final text):
            final bytes = utf8.encode(text);
            final textPtr = text.toNativeUtf8(allocator: calloc);
            allocatedPointers.add(textPtr.cast<ffi.Void>());
            input
              ..typeAsInt =
                  c.LiteRtLmInputDataType.kLiteRtLmInputDataTypeText.value
              ..data = textPtr.cast<ffi.Void>()
              ..size = bytes.length;

          case LiteRtLmImageContent(:final bytes):
            final ptr = calloc<ffi.Uint8>(bytes.length);
            allocatedPointers.add(ptr.cast<ffi.Void>());
            ptr.asTypedList(bytes.length).setAll(0, bytes);
            input
              ..typeAsInt =
                  c.LiteRtLmInputDataType.kLiteRtLmInputDataTypeImage.value
              ..data = ptr.cast<ffi.Void>()
              ..size = bytes.length;

          case LiteRtLmImageEndContent():
            input
              ..typeAsInt =
                  c.LiteRtLmInputDataType.kLiteRtLmInputDataTypeImageEnd.value
              ..data = ffi.nullptr
              ..size = 0;

          case LiteRtLmAudioContent(:final bytes):
            final ptr = calloc<ffi.Uint8>(bytes.length);
            allocatedPointers.add(ptr.cast<ffi.Void>());
            ptr.asTypedList(bytes.length).setAll(0, bytes);
            input
              ..typeAsInt =
                  c.LiteRtLmInputDataType.kLiteRtLmInputDataTypeAudio.value
              ..data = ptr.cast<ffi.Void>()
              ..size = bytes.length;

          case LiteRtLmAudioEndContent():
            input
              ..typeAsInt =
                  c.LiteRtLmInputDataType.kLiteRtLmInputDataTypeAudioEnd.value
              ..data = ffi.nullptr
              ..size = 0;
        }
      }
      return run(inputs, count);
    } finally {
      calloc.free(inputs);
      for (final ptr in allocatedPointers) {
        calloc.free(ptr);
      }
    }
  }
}

final class _NativeEngine {
  _NativeEngine(this.pointer);

  ffi.Pointer<c.LiteRtLmEngine> pointer;
  var disposed = false;

  void dispose(c.LiteRtLmBindings bindings) {
    if (disposed) {
      return;
    }
    disposed = true;
    bindings.litert_lm_engine_delete(pointer);
    pointer = ffi.nullptr;
  }
}

final class _NativeSession {
  _NativeSession(this.pointer, {this.engineId});

  ffi.Pointer<c.LiteRtLmSession> pointer;
  final int? engineId;
  var disposed = false;

  void cancel(c.LiteRtLmBindings bindings) {
    if (!disposed) {
      bindings.litert_lm_session_cancel_process(pointer);
    }
  }

  void dispose(c.LiteRtLmBindings bindings) {
    if (disposed) {
      return;
    }
    disposed = true;
    bindings.litert_lm_session_delete(pointer);
    pointer = ffi.nullptr;
  }
}

final class _ActiveStream {
  _ActiveStream(this.sessionId, this.events, this.callback);

  final int sessionId;
  final SendPort events;
  final ffi.NativeCallable<c.LiteRtLmStreamCallbackFunction> callback;

  void close() {
    callback.close();
  }
}

void _reply<T>(SendPort? replyTo, LiteRtLmResult<T> result) {
  if (replyTo == null) {
    return;
  }
  switch (result) {
    case LiteRtLmOk<T>(:final value):
      _replyOk(replyTo, value);
    case LiteRtLmErr<T>(:final error):
      replyTo.send(<String, Object?>{
        'ok': false,
        'error': liteRtLmFailureToMap(error),
      });
  }
}

void _replyOk(SendPort? replyTo, Object? value) {
  replyTo?.send(<String, Object?>{'ok': true, 'value': value});
}

LiteRtLmFailure _classifyNativeFailure(
  String message, {
  bool generation = false,
}) {
  final lower = message.toLowerCase();
  if (lower.contains('oom') || lower.contains('out of memory')) {
    return LiteRtLmOutOfMemory(message);
  }
  if (lower.contains('unsupported') || lower.contains('not supported')) {
    return LiteRtLmUnsupportedModel(message);
  }
  if (generation) {
    return LiteRtLmGenerationFailure(message);
  }
  return LiteRtLmNativeInitFailure(message);
}
