import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'types.dart';

final class LiteRtLmOpenAiServerConfig {
  const LiteRtLmOpenAiServerConfig({
    this.modelId = 'litert-lm-local',
    this.apiKey,
    this.enableCors = true,
    this.defaultParams = defaultLiteRtLmGenerationParams,
  });

  final String modelId;
  final String? apiKey;
  final bool enableCors;
  final LiteRtLmGenerationParams defaultParams;
}

/// Text HTTP adapter. Each chat request creates a fresh Conversation; clients
/// must submit the complete message history for every request.
final class LiteRtLmOpenAiServer {
  LiteRtLmOpenAiServer({
    required LiteRtLmEngine engine,
    LiteRtLmOpenAiServerConfig config = const LiteRtLmOpenAiServerConfig(),
  }) : this._(engine, config);

  LiteRtLmOpenAiServer._(this._engine, this._config);

  final LiteRtLmEngine _engine;
  final LiteRtLmOpenAiServerConfig _config;
  HttpServer? _server;
  Future<void>? _closing;
  final _requests = <Future<void>>{};
  final _activeCancels = <Object, Future<void> Function()>{};

  Uri? get uri {
    final server = _server;
    if (server == null) {
      return null;
    }
    final host = server.address.isLoopback ? '127.0.0.1' : server.address.host;
    return Uri(scheme: 'http', host: host, port: server.port);
  }

  Future<LiteRtLmResult<LiteRtLmOpenAiServer>> bind({
    Object address = '127.0.0.1',
    int port = 8080,
  }) async {
    await _closing;
    _closing = null;
    if (_server != null) {
      return LiteRtLmOk(this);
    }

    try {
      final server = await HttpServer.bind(address, port);
      _server = server;
      unawaited(_serve(server));
      return LiteRtLmOk(this);
    } catch (error) {
      return LiteRtLmErr(
        LiteRtLmNativeInitFailure('Failed to bind HTTP server: $error'),
      );
    }
  }

  Future<void> close({bool force = true}) => _closing ??= _close(force);

  Future<void> _close(bool force) async {
    final server = _server;
    _server = null;
    await Future.wait(_activeCancels.values.toList().map((cancel) => cancel()));
    await server?.close(force: force);
    await Future.wait(_requests.toList());
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      late Future<void> pending;
      pending = _serveRequest(
        request,
      ).whenComplete(() => _requests.remove(pending));
      _requests.add(pending);
      unawaited(pending);
    }
  }

  Future<void> _serveRequest(HttpRequest request) async {
    try {
      await _handle(request);
    } on SocketException {
      // The client disconnected; generation cleanup runs in the handler's finally.
    } on HttpException {
      // A closed HTTP connection cannot receive an API error response.
    }
  }

  void _trackGeneration(
    Object handle,
    HttpResponse response,
    Future<void> Function() cancel,
  ) {
    _activeCancels[handle] = cancel;
    if (_closing != null) unawaited(cancel());
    unawaited(
      response.done.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) async {
          // Response completion reports disconnected clients even between token writes.
          if (_activeCancels.containsKey(handle)) await cancel();
        },
      ),
    );
  }

  Future<void> _handle(HttpRequest request) async {
    if (_config.enableCors) {
      _addCorsHeaders(request.response);
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
    }

    if (!_authorized(request)) {
      await _writeError(
        request,
        HttpStatus.unauthorized,
        'invalid_api_key',
        'Missing or invalid bearer token',
      );
      return;
    }

    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/v1/models') {
        await _handleModels(request);
      } else if (request.method == 'GET' && path == '/health') {
        await _writeJson(request.response, <String, Object?>{'status': 'ok'});
      } else if (request.method == 'POST' && path == '/v1/chat/completions') {
        await _handleChatCompletions(request);
      } else if (request.method == 'POST' && path == '/v1/completions') {
        await _handleCompletions(request);
      } else {
        await _writeError(
          request,
          HttpStatus.notFound,
          'not_found',
          'Unknown endpoint: ${request.method} $path',
        );
      }
    } on SocketException {
      rethrow;
    } on HttpException {
      rethrow;
    } catch (error) {
      await _writeError(
        request,
        HttpStatus.internalServerError,
        'server_error',
        '$error',
      );
    }
  }

  bool _authorized(HttpRequest request) {
    final apiKey = _config.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      return true;
    }
    return request.headers.value(HttpHeaders.authorizationHeader) ==
        'Bearer $apiKey';
  }

  Future<void> _handleModels(HttpRequest request) {
    final created = _unixSeconds();
    return _writeJson(request.response, <String, Object?>{
      'object': 'list',
      'data': <Object?>[
        <String, Object?>{
          'id': _config.modelId,
          'object': 'model',
          'created': created,
          'owned_by': 'local',
        },
      ],
    });
  }

  Future<void> _handleChatCompletions(HttpRequest request) async {
    final body = await _readJsonObject(request);
    if (body == null) {
      return;
    }
    if (!_requestModelMatches(body)) {
      await _writeError(
        request,
        HttpStatus.notFound,
        'model_not_found',
        'Unknown model: ${body['model']}',
      );
      return;
    }
    if (!await _singleChoiceOnly(request, body)) {
      return;
    }

    final messages = body['messages'];
    if (messages is! List) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        'invalid_request_error',
        '`messages` must be an array',
        param: 'messages',
      );
      return;
    }

    final prompt = _messagesFromRequest(messages);
    if (prompt == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        'invalid_request_error',
        'Messages require supported system/user/assistant roles and text content',
        param: 'messages',
      );
      return;
    }

    final params = await _paramsFromRequest(request, body);
    if (params == null) return;
    final stream = body['stream'] == true;
    if (stream) {
      await _streamChatCompletion(request, prompt, params);
    } else {
      await _completeChatCompletion(request, prompt, params);
    }
  }

  Future<void> _handleCompletions(HttpRequest request) async {
    final body = await _readJsonObject(request);
    if (body == null) {
      return;
    }
    if (!_requestModelMatches(body)) {
      await _writeError(
        request,
        HttpStatus.notFound,
        'model_not_found',
        'Unknown model: ${body['model']}',
      );
      return;
    }
    if (!await _singleChoiceOnly(request, body)) {
      return;
    }

    final prompt = _completionPrompt(body['prompt']);
    if (prompt == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        'invalid_request_error',
        '`prompt` must be a string or an array containing exactly one string',
        param: 'prompt',
      );
      return;
    }

    final params = await _paramsFromRequest(request, body);
    if (params == null) return;
    final stream = body['stream'] == true;
    if (stream) {
      await _streamCompletion(request, prompt, params);
    } else {
      await _completeTextCompletion(request, prompt, params);
    }
  }

  Future<void> _completeChatCompletion(
    HttpRequest request,
    List<LiteRtLmMessage> prompt,
    LiteRtLmGenerationParams params,
  ) async {
    final created = _unixSeconds();
    final id = _nextId('chatcmpl');
    final sessionResult = await _engine.createConversation(params: params);
    final session = sessionResult.valueOrNull;
    if (session == null) {
      await _writeFailure(request, sessionResult.errorOrNull);
      return;
    }

    _trackGeneration(session, request.response, session.cancel);
    try {
      if (_closing != null) return;
      final generated = await session.sendMessages(prompt);
      final text = generated.valueOrNull;
      if (text == null) {
        await _writeFailure(request, generated.errorOrNull);
        return;
      }
      await _writeJson(request.response, <String, Object?>{
        'id': id,
        'object': 'chat.completion',
        'created': created,
        'model': _config.modelId,
        'choices': <Object?>[
          <String, Object?>{
            'index': 0,
            'message': <String, Object?>{'role': 'assistant', 'content': text},
            'finish_reason': 'stop',
          },
        ],
        'usage': _usage((await session.getMetrics()).valueOrNull),
      });
    } finally {
      _activeCancels.remove(session);
      await session.dispose();
    }
  }

  Future<void> _completeTextCompletion(
    HttpRequest request,
    String prompt,
    LiteRtLmGenerationParams params,
  ) async {
    final created = _unixSeconds();
    final id = _nextId('cmpl');
    final sessionResult = await _engine.createSession(params: params);
    final session = sessionResult.valueOrNull;
    if (session == null) {
      await _writeFailure(request, sessionResult.errorOrNull);
      return;
    }

    _trackGeneration(session, request.response, session.cancel);
    try {
      if (_closing != null) return;
      final generated = await session.generate(prompt);
      final text = generated.valueOrNull;
      if (text == null) {
        await _writeFailure(request, generated.errorOrNull);
        return;
      }
      await _writeJson(request.response, <String, Object?>{
        'id': id,
        'object': 'text_completion',
        'created': created,
        'model': _config.modelId,
        'choices': <Object?>[
          <String, Object?>{
            'text': text,
            'index': 0,
            'logprobs': null,
            'finish_reason': 'stop',
          },
        ],
        'usage': _usage((await session.getMetrics()).valueOrNull),
      });
    } finally {
      _activeCancels.remove(session);
      await session.dispose();
    }
  }

  Future<void> _streamChatCompletion(
    HttpRequest request,
    List<LiteRtLmMessage> prompt,
    LiteRtLmGenerationParams params,
  ) async {
    final created = _unixSeconds();
    final id = _nextId('chatcmpl');
    final sessionResult = await _engine.createConversation(params: params);
    final session = sessionResult.valueOrNull;
    if (session == null) {
      await _writeFailure(request, sessionResult.errorOrNull);
      return;
    }

    _trackGeneration(session, request.response, session.cancel);
    Socket? output;
    try {
      final response = await _prepareSse(request.response, session.cancel);
      output = response;
      await _writeSse(
        response,
        _chatChunk(id, created, _config.modelId, <String, Object?>{
          'role': 'assistant',
        }),
      );

      if (_closing != null) return;
      await for (final event in session.sendMessagesStream(prompt)) {
        switch (event) {
          case LiteRtLmToken(:final text):
            await _writeSse(
              response,
              _chatChunk(id, created, _config.modelId, <String, Object?>{
                'content': text,
              }),
            );
          case LiteRtLmCompleted():
            await _writeSse(
              response,
              _chatStopChunk(id, created, _config.modelId),
            );
            await _writeSseDone(response);
            return;
          case LiteRtLmFailed(:final error):
            await _writeSseError(response, error);
            return;
          case LiteRtLmCancelledEvent():
            await _writeSseDone(response);
            return;
        }
      }

      await _writeSse(response, _chatStopChunk(id, created, _config.modelId));
      await _writeSseDone(response);
    } on SocketException {
      await session.cancel();
    } on HttpException {
      await session.cancel();
    } catch (error) {
      await session.cancel();
      if (output == null) rethrow;
      await _writeSseError(
        output,
        LiteRtLmGenerationFailure('Streaming request failed: $error'),
      );
    } finally {
      _activeCancels.remove(session);
      await session.dispose();
      try {
        await output?.close();
      } finally {
        output?.destroy();
      }
    }
  }

  Future<void> _streamCompletion(
    HttpRequest request,
    String prompt,
    LiteRtLmGenerationParams params,
  ) async {
    final created = _unixSeconds();
    final id = _nextId('cmpl');
    final sessionResult = await _engine.createSession(params: params);
    final session = sessionResult.valueOrNull;
    if (session == null) {
      await _writeFailure(request, sessionResult.errorOrNull);
      return;
    }

    _trackGeneration(session, request.response, session.cancel);
    Socket? output;
    try {
      final response = await _prepareSse(request.response, session.cancel);
      output = response;
      if (_closing != null) return;
      await for (final event in session.generateStream(prompt)) {
        switch (event) {
          case LiteRtLmToken(:final text):
            await _writeSse(
              response,
              _completionChunk(id, created, _config.modelId, text),
            );
          case LiteRtLmCompleted():
            await _writeSse(
              response,
              _completionStopChunk(id, created, _config.modelId),
            );
            await _writeSseDone(response);
            return;
          case LiteRtLmFailed(:final error):
            await _writeSseError(response, error);
            return;
          case LiteRtLmCancelledEvent():
            await _writeSseDone(response);
            return;
        }
      }

      await _writeSse(
        response,
        _completionStopChunk(id, created, _config.modelId),
      );
      await _writeSseDone(response);
    } on SocketException {
      await session.cancel();
    } on HttpException {
      await session.cancel();
    } catch (error) {
      await session.cancel();
      if (output == null) rethrow;
      await _writeSseError(
        output,
        LiteRtLmGenerationFailure('Streaming request failed: $error'),
      );
    } finally {
      _activeCancels.remove(session);
      await session.dispose();
      try {
        await output?.close();
      } finally {
        output?.destroy();
      }
    }
  }

  bool _requestModelMatches(Map<String, Object?> body) {
    final model = body['model'];
    return model == null || model == _config.modelId;
  }

  Future<bool> _singleChoiceOnly(
    HttpRequest request,
    Map<String, Object?> body,
  ) async {
    final n = body['n'];
    if (!body.containsKey('n') || (n is int && n == 1)) {
      return true;
    }
    await _writeError(
      request,
      HttpStatus.badRequest,
      'invalid_request_error',
      'Only n=1 is supported',
      param: 'n',
    );
    return false;
  }

  Future<LiteRtLmGenerationParams?> _paramsFromRequest(
    HttpRequest request,
    Map<String, Object?> body,
  ) async {
    final supported = {
      'model',
      if (request.uri.path == '/v1/chat/completions') 'messages' else 'prompt',
      'stream',
      'n',
      'temperature',
      'top_k',
      'topK',
      'max_tokens',
      'maxTokens',
      'seed',
      'apply_prompt_template',
    };
    String? invalid;
    for (final key in body.keys) {
      if (!supported.contains(key)) {
        invalid = key;
        break;
      }
    }
    if (invalid == null &&
        body.containsKey('stream') &&
        body['stream'] is! bool) {
      invalid = 'stream';
    }
    if (invalid == null &&
        body.containsKey('apply_prompt_template') &&
        (body['apply_prompt_template'] is! bool ||
            (request.uri.path == '/v1/chat/completions' &&
                body['apply_prompt_template'] == false))) {
      invalid = 'apply_prompt_template';
    }
    for (final key in ['top_k', 'topK', 'max_tokens', 'maxTokens', 'seed']) {
      if (body.containsKey(key) &&
          (body[key] is! int ||
              (body[key] as int) > 2147483647 ||
              (body[key] as int) < (key == 'seed' ? -2147483648 : 1))) {
        invalid ??= key;
      }
    }
    final temperature = body['temperature'];
    if (body.containsKey('temperature') &&
        (temperature is! num || !temperature.isFinite || temperature < 0)) {
      invalid ??= 'temperature';
    }
    if (invalid != null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        'invalid_request_error',
        'Unsupported or invalid parameter: $invalid',
        param: invalid,
      );
      return null;
    }
    final defaults = _config.defaultParams;
    return LiteRtLmGenerationParams(
      temperature: (temperature as num?)?.toDouble() ?? defaults.temperature,
      topK: body['top_k'] as int? ?? body['topK'] as int? ?? defaults.topK,
      maxTokens:
          body['max_tokens'] as int? ??
          body['maxTokens'] as int? ??
          defaults.maxTokens,
      seed: body['seed'] as int? ?? defaults.seed,
      applyPromptTemplate:
          body['apply_prompt_template'] as bool? ??
          defaults.applyPromptTemplate,
    );
  }

  Future<Map<String, Object?>?> _readJsonObject(HttpRequest request) async {
    try {
      final text = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return decoded.cast<String, Object?>();
      }
    } catch (_) {
      // Fall through to the API-shaped error below.
    }
    await _writeError(
      request,
      HttpStatus.badRequest,
      'invalid_request_error',
      'Request body must be a JSON object',
    );
    return null;
  }

  Future<void> _writeFailure(HttpRequest request, LiteRtLmFailure? failure) {
    final error =
        failure ??
        const LiteRtLmNativeInitFailure('LiteRT-LM operation failed');
    final status = switch (error) {
      LiteRtLmModelNotFound() => HttpStatus.notFound,
      LiteRtLmUnsupportedModel() => HttpStatus.badRequest,
      LiteRtLmOutOfMemory() => HttpStatus.internalServerError,
      LiteRtLmDisposed() => HttpStatus.badRequest,
      LiteRtLmCancelled() => HttpStatus.badRequest,
      LiteRtLmGenerationFailure() => HttpStatus.internalServerError,
      LiteRtLmNativeInitFailure() => HttpStatus.internalServerError,
      LiteRtLmBusy() => HttpStatus.conflict,
      LiteRtLmContextFull() => HttpStatus.badRequest,
      LiteRtLmInvalidArgument() => HttpStatus.badRequest,
      LiteRtLmUnsupported() => HttpStatus.badRequest,
      LiteRtLmWorkerFailure() => HttpStatus.internalServerError,
      LiteRtLmBackpressure() => HttpStatus.serviceUnavailable,
    };
    return _writeError(request, status, error.code, error.message);
  }
}

int _idCounter = 0;

String _nextId(String prefix) {
  _idCounter += 1;
  return '$prefix-${DateTime.now().microsecondsSinceEpoch}-$_idCounter';
}

int _unixSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

String? _completionPrompt(Object? prompt) {
  if (prompt is String) return prompt;
  if (prompt is List && prompt.length == 1 && prompt.single is String) {
    return prompt.single as String;
  }
  return null;
}

List<LiteRtLmMessage>? _messagesFromRequest(List<Object?> messages) {
  if (messages.isEmpty) return null;
  final result = <LiteRtLmMessage>[];
  for (final message in messages) {
    if (message is! Map ||
        message.keys.any((key) => key != 'role' && key != 'content')) {
      return null;
    }
    final role = message['role'];
    if (role is! String ||
        !const ['system', 'user', 'assistant'].contains(role)) {
      return null;
    }
    final content = message['content'];
    final contents = <LiteRtLmContent>[];
    if (content is String) {
      contents.add(LiteRtLmContent.text(content));
    } else if (content is List) {
      for (final part in content) {
        if (part is! Map ||
            part['type'] != 'text' ||
            part['text'] is! String ||
            part.keys.any((key) => key != 'type' && key != 'text')) {
          return null;
        }
        contents.add(LiteRtLmContent.text(part['text'] as String));
      }
    } else {
      return null;
    }
    result.add(LiteRtLmMessage(role: role, contents: contents));
  }
  return result;
}

Map<String, Object?>? _usage(LiteRtLmMetrics? metrics) {
  final promptTokens = metrics?.prefillTokens;
  final completionTokens = metrics?.decodeTokens;
  if (promptTokens == null || completionTokens == null) return null;
  return {
    'prompt_tokens': promptTokens,
    'completion_tokens': completionTokens,
    'total_tokens': promptTokens + completionTokens,
  };
}

Map<String, Object?> _chatChunk(
  String id,
  int created,
  String model,
  Map<String, Object?> delta,
) {
  return <String, Object?>{
    'id': id,
    'object': 'chat.completion.chunk',
    'created': created,
    'model': model,
    'choices': <Object?>[
      <String, Object?>{'index': 0, 'delta': delta, 'finish_reason': null},
    ],
  };
}

Map<String, Object?> _chatStopChunk(String id, int created, String model) {
  return <String, Object?>{
    'id': id,
    'object': 'chat.completion.chunk',
    'created': created,
    'model': model,
    'choices': <Object?>[
      <String, Object?>{
        'index': 0,
        'delta': <String, Object?>{},
        'finish_reason': 'stop',
      },
    ],
  };
}

Map<String, Object?> _completionChunk(
  String id,
  int created,
  String model,
  String text,
) {
  return <String, Object?>{
    'id': id,
    'object': 'text_completion',
    'created': created,
    'model': model,
    'choices': <Object?>[
      <String, Object?>{
        'text': text,
        'index': 0,
        'logprobs': null,
        'finish_reason': null,
      },
    ],
  };
}

Map<String, Object?> _completionStopChunk(
  String id,
  int created,
  String model,
) {
  return <String, Object?>{
    'id': id,
    'object': 'text_completion',
    'created': created,
    'model': model,
    'choices': <Object?>[
      <String, Object?>{
        'text': '',
        'index': 0,
        'logprobs': null,
        'finish_reason': 'stop',
      },
    ],
  };
}

void _addCorsHeaders(HttpResponse response) {
  response.headers
    ..set(HttpHeaders.accessControlAllowOriginHeader, '*')
    ..set(HttpHeaders.accessControlAllowMethodsHeader, 'GET, POST, OPTIONS')
    ..set(
      HttpHeaders.accessControlAllowHeadersHeader,
      'Authorization, Content-Type',
    );
}

Future<Socket> _prepareSse(
  HttpResponse response,
  Future<void> Function() cancel,
) async {
  response.headers
    ..set(HttpHeaders.contentTypeHeader, 'text/event-stream; charset=utf-8')
    ..set(HttpHeaders.cacheControlHeader, 'no-cache')
    ..set('X-Accel-Buffering', 'no')
    ..chunkedTransferEncoding = false;
  // HttpResponse suppresses peer socket errors. A detached connection exposes
  // EOF immediately, including while native inference is waiting for a token.
  response.persistentConnection = false;
  final socket = await response.detachSocket();
  socket.listen(
    (_) {},
    onDone: () => unawaited(cancel()),
    onError: (Object error) => unawaited(cancel()),
  );
  return socket;
}

Future<void> _writeJson(HttpResponse response, Object value) async {
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(value));
  await response.close();
}

Future<void> _writeError(
  HttpRequest request,
  int status,
  String code,
  String message, {
  String? param,
}) async {
  request.response.statusCode = status;
  await _writeJson(request.response, <String, Object?>{
    'error': <String, Object?>{
      'message': message,
      'type': code,
      'param': param,
      'code': code,
    },
  });
}

Future<void> _writeSse(IOSink response, Object value) async {
  response.add(utf8.encode('data: ${jsonEncode(value)}\n\n'));
  await response.flush();
}

Future<void> _writeSseDone(IOSink response) async {
  response.add(utf8.encode('data: [DONE]\n\n'));
  await response.flush();
}

Future<void> _writeSseError(IOSink response, LiteRtLmFailure error) {
  return _writeSse(response, <String, Object?>{
    'error': <String, Object?>{
      'message': error.message,
      'type': error.code,
      'param': null,
      'code': error.code,
    },
  });
}
