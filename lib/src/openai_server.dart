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

final class LiteRtLmOpenAiServer {
  LiteRtLmOpenAiServer({
    required LiteRtLmEngine engine,
    LiteRtLmOpenAiServerConfig config = const LiteRtLmOpenAiServerConfig(),
  }) : this._(engine, config);

  LiteRtLmOpenAiServer._(this._engine, this._config);

  final LiteRtLmEngine _engine;
  final LiteRtLmOpenAiServerConfig _config;
  HttpServer? _server;

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

  Future<void> close({bool force = true}) async {
    final server = _server;
    _server = null;
    await server?.close(force: force);
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
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

    final prompt = _promptFromMessages(messages);
    if (prompt == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        'invalid_request_error',
        'Only text message content is supported',
        param: 'messages',
      );
      return;
    }

    final params = _paramsFromRequest(body);
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
        '`prompt` must be a string or array of strings',
        param: 'prompt',
      );
      return;
    }

    final params = _paramsFromRequest(body);
    final stream = body['stream'] == true;
    if (stream) {
      await _streamCompletion(request, prompt, params);
    } else {
      await _completeTextCompletion(request, prompt, params);
    }
  }

  Future<void> _completeChatCompletion(
    HttpRequest request,
    String prompt,
    LiteRtLmGenerationParams params,
  ) async {
    final created = _unixSeconds();
    final id = _nextId('chatcmpl');
    final sessionResult = await _engine.createSession(params: params);
    final session = sessionResult.valueOrNull;
    if (session == null) {
      await _writeFailure(request, sessionResult.errorOrNull);
      return;
    }

    try {
      final generated = await session.generate(prompt);
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
        'usage': _usage(prompt, text),
      });
    } finally {
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

    try {
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
        'usage': _usage(prompt, text),
      });
    } finally {
      await session.dispose();
    }
  }

  Future<void> _streamChatCompletion(
    HttpRequest request,
    String prompt,
    LiteRtLmGenerationParams params,
  ) async {
    final created = _unixSeconds();
    final id = _nextId('chatcmpl');
    final sessionResult = await _engine.createSession(params: params);
    final session = sessionResult.valueOrNull;
    if (session == null) {
      await _writeFailure(request, sessionResult.errorOrNull);
      return;
    }

    final response = request.response;
    _prepareSse(response);
    try {
      await _writeSse(
        response,
        _chatChunk(id, created, _config.modelId, <String, Object?>{
          'role': 'assistant',
        }),
      );

      await for (final event in session.generateStream(prompt)) {
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
    } catch (_) {
      await session.cancel();
    } finally {
      await session.dispose();
      await response.close();
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

    final response = request.response;
    _prepareSse(response);
    try {
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
    } catch (_) {
      await session.cancel();
    } finally {
      await session.dispose();
      await response.close();
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
    if (n == null || n == 1) {
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

  LiteRtLmGenerationParams _paramsFromRequest(Map<String, Object?> body) {
    final defaults = _config.defaultParams;
    return LiteRtLmGenerationParams(
      temperature: _number(body['temperature']) ?? defaults.temperature,
      topK: _integer(body['top_k']) ?? _integer(body['topK']) ?? defaults.topK,
      maxTokens:
          _integer(body['max_tokens']) ??
          _integer(body['maxTokens']) ??
          defaults.maxTokens,
      seed: _integer(body['seed']) ?? defaults.seed,
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
  if (prompt is String) {
    return prompt;
  }
  if (prompt is List && prompt.every((item) => item is String)) {
    return prompt.cast<String>().join('\n');
  }
  return null;
}

String? _promptFromMessages(List<Object?> messages) {
  final buffer = StringBuffer();
  for (final message in messages) {
    if (message is! Map) {
      return null;
    }
    final role = message['role'] as String? ?? 'user';
    final content = _contentText(message['content']);
    if (content == null) {
      return null;
    }
    if (content.isEmpty) {
      continue;
    }
    buffer
      ..write(role.toUpperCase())
      ..write(': ')
      ..writeln(content);
  }
  buffer.write('ASSISTANT: ');
  return buffer.toString();
}

String? _contentText(Object? content) {
  if (content == null) {
    return '';
  }
  if (content is String) {
    return content;
  }
  if (content is List) {
    final parts = <String>[];
    for (final part in content) {
      if (part is! Map) {
        return null;
      }
      final type = part['type'];
      if (type != 'text') {
        return null;
      }
      final text = part['text'];
      if (text is! String) {
        return null;
      }
      parts.add(text);
    }
    return parts.join('\n');
  }
  return null;
}

double? _number(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return null;
}

int? _integer(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return null;
}

Map<String, Object?> _usage(String prompt, String completion) {
  final promptTokens = _roughTokenCount(prompt);
  final completionTokens = _roughTokenCount(completion);
  return <String, Object?>{
    'prompt_tokens': promptTokens,
    'completion_tokens': completionTokens,
    'total_tokens': promptTokens + completionTokens,
  };
}

int _roughTokenCount(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return 0;
  }
  return trimmed.split(RegExp(r'\s+')).length;
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

void _prepareSse(HttpResponse response) {
  response.headers
    ..set(HttpHeaders.contentTypeHeader, 'text/event-stream; charset=utf-8')
    ..set(HttpHeaders.cacheControlHeader, 'no-cache')
    ..set('X-Accel-Buffering', 'no');
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

Future<void> _writeSse(HttpResponse response, Object value) async {
  response.add(utf8.encode('data: ${jsonEncode(value)}\n\n'));
  await response.flush();
}

Future<void> _writeSseDone(HttpResponse response) async {
  response.add(utf8.encode('data: [DONE]\n\n'));
  await response.flush();
}

Future<void> _writeSseError(HttpResponse response, LiteRtLmFailure error) {
  return _writeSse(response, <String, Object?>{
    'error': <String, Object?>{
      'message': error.message,
      'type': error.code,
      'param': null,
      'code': error.code,
    },
  });
}
