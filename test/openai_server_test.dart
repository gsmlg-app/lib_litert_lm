import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lib_litert_lm/lib_litert_lm.dart';
import 'package:lib_litert_lm/src/fake_backend.dart';

void main() {
  late LiteRtLm client;
  late LiteRtLmEngine engine;
  late LiteRtLmOpenAiServer server;
  late HttpClient http;

  setUp(() async {
    client = LiteRtLm.testing(
      FakeLiteRtLmBackend(
        generateText: 'server response',
        streamTokens: const <String>['server', ' ', 'response'],
      ),
    );
    engine = (await client.loadEngine(
      const LiteRtLmEngineConfig(modelPath: '/tmp/model.litertlm'),
    )).valueOrNull!;
    server = LiteRtLmOpenAiServer(
      engine: engine,
      config: const LiteRtLmOpenAiServerConfig(modelId: 'local-test'),
    );
    final bound = await server.bind(port: 0);
    expect(bound.valueOrNull, isNotNull);
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await server.close();
    await engine.dispose();
    await client.dispose();
  });

  test('GET /v1/models returns OpenAI-compatible list', () async {
    final response = await _get(http, server.uri!, '/v1/models');

    expect(response.statusCode, HttpStatus.ok);
    expect(response.json['object'], 'list');
    expect((response.json['data'] as List).single['id'], 'local-test');
  });

  test('POST /v1/chat/completions returns non-streaming response', () async {
    final response = await _postJson(
      http,
      server.uri!,
      '/v1/chat/completions',
      <String, Object?>{
        'model': 'local-test',
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': 'hello'},
        ],
        'temperature': 0.1,
        'top_k': 4,
        'max_tokens': 12,
      },
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.json['object'], 'chat.completion');
    expect(response.json['model'], 'local-test');
    final choices = response.json['choices'] as List;
    expect(choices.single['message']['role'], 'assistant');
    expect(choices.single['message']['content'], 'server response');
  });

  test('POST /v1/chat/completions streams SSE chunks', () async {
    final response = await _postText(
      http,
      server.uri!,
      '/v1/chat/completions',
      <String, Object?>{
        'model': 'local-test',
        'stream': true,
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': 'hello'},
        ],
      },
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.text, contains('data: [DONE]'));
    final payloads = _sseJsonPayloads(response.text);
    expect(payloads.first['object'], 'chat.completion.chunk');
    expect(payloads.first['choices'][0]['delta']['role'], 'assistant');
    expect(
      payloads
          .map((payload) => payload['choices'][0]['delta']['content'])
          .whereType<String>()
          .join(),
      'server response',
    );
  });

  test('POST /v1/completions supports legacy completion shape', () async {
    final response = await _postJson(
      http,
      server.uri!,
      '/v1/completions',
      <String, Object?>{'model': 'local-test', 'prompt': 'complete this'},
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.json['object'], 'text_completion');
    expect(
      (response.json['choices'] as List).single['text'],
      'server response',
    );
  });

  test('rejects unsupported model with OpenAI-shaped error', () async {
    final response = await _postJson(
      http,
      server.uri!,
      '/v1/chat/completions',
      <String, Object?>{'model': 'missing-model', 'messages': <Object?>[]},
    );

    expect(response.statusCode, HttpStatus.notFound);
    expect(response.json['error']['code'], 'model_not_found');
  });
}

Future<_JsonResponse> _get(HttpClient client, Uri baseUri, String path) async {
  final request = await client.getUrl(baseUri.replace(path: path));
  final response = await request.close();
  final text = await utf8.decodeStream(response);
  return _JsonResponse(response.statusCode, jsonDecode(text) as Map);
}

Future<_JsonResponse> _postJson(
  HttpClient client,
  Uri baseUri,
  String path,
  Object body,
) async {
  final response = await _postText(client, baseUri, path, body);
  return _JsonResponse(response.statusCode, jsonDecode(response.text) as Map);
}

Future<_TextResponse> _postText(
  HttpClient client,
  Uri baseUri,
  String path,
  Object body,
) async {
  final request = await client.postUrl(baseUri.replace(path: path));
  request.headers.contentType = ContentType.json;
  request.write(jsonEncode(body));
  final response = await request.close();
  final text = await utf8.decodeStream(response);
  return _TextResponse(response.statusCode, text);
}

List<Map> _sseJsonPayloads(String text) {
  return text
      .split('\n')
      .where((line) => line.startsWith('data: '))
      .map((line) => line.substring('data: '.length))
      .where((payload) => payload != '[DONE]')
      .map((payload) => jsonDecode(payload) as Map)
      .toList(growable: false);
}

final class _JsonResponse {
  const _JsonResponse(this.statusCode, this.json);

  final int statusCode;
  final Map json;
}

final class _TextResponse {
  const _TextResponse(this.statusCode, this.text);

  final int statusCode;
  final String text;
}
