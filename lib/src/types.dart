import 'dart:async';
import 'dart:convert';

import 'backend.dart';

const LiteRtLmGenerationParams defaultLiteRtLmGenerationParams =
    LiteRtLmGenerationParams();

final class LiteRtLmModelConfig {
  const LiteRtLmModelConfig({
    required this.id,
    required this.huggingFaceModelId,
    required this.huggingFaceModelPage,
  });

  final String id;
  final String huggingFaceModelId;
  final String huggingFaceModelPage;
}

const LiteRtLmModelConfig gemma4E2bModelConfig = LiteRtLmModelConfig(
  id: 'gemma-4-e2b',
  huggingFaceModelId: 'litert-community/gemma-4-E2B-it-litert-lm',
  huggingFaceModelPage:
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm',
);

const LiteRtLmModelConfig gemma4E4bModelConfig = LiteRtLmModelConfig(
  id: 'gemma-4-e4b',
  huggingFaceModelId: 'litert-community/gemma-4-E4B-it-litert-lm',
  huggingFaceModelPage:
      'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm',
);

const List<LiteRtLmModelConfig> availableLiteRtLmModelConfigs =
    <LiteRtLmModelConfig>[gemma4E2bModelConfig, gemma4E4bModelConfig];

const Map<String, LiteRtLmModelConfig> availableLiteRtLmModelConfigById =
    <String, LiteRtLmModelConfig>{
      'gemma-4-e2b': gemma4E2bModelConfig,
      'gemma-4-e4b': gemma4E4bModelConfig,
    };

LiteRtLmModelConfig? liteRtLmModelConfigFor(String modelId) {
  return availableLiteRtLmModelConfigById[modelId];
}

final class LiteRtLmEngineConfig {
  const LiteRtLmEngineConfig({
    required this.modelPath,
    this.backend = 'cpu',
    this.visionBackend,
    this.audioBackend,
    this.modelId,
    this.artifactSha256,
    this.revision,
    this.maxNumTokens,
    this.cacheDir,
    this.litertDispatchLibDir,
    this.prefillChunkSize,
    this.parallelFileSectionLoading = true,
  });

  final String modelPath;
  final String backend;

  /// Leave null to keep vision disabled.
  final String? visionBackend;

  /// Leave null to keep audio disabled.
  final String? audioBackend;
  final String? modelId;
  final String? artifactSha256;
  final String? revision;
  final int? maxNumTokens;
  final String? cacheDir;
  final String? litertDispatchLibDir;
  final int? prefillChunkSize;
  final bool parallelFileSectionLoading;
}

final class LiteRtLmGenerationParams {
  const LiteRtLmGenerationParams({
    this.temperature = 0.8,
    this.topK = 40,
    this.maxTokens = 256,
    this.seed,
    this.applyPromptTemplate = true,
  }) : assert(temperature >= 0),
       assert(topK > 0),
       assert(maxTokens > 0);

  final double temperature;
  final int topK;
  final int maxTokens;
  final int? seed;
  final bool applyPromptTemplate;
}

sealed class LiteRtLmResult<T> {
  const LiteRtLmResult();

  bool get isOk => this is LiteRtLmOk<T>;
  bool get isErr => this is LiteRtLmErr<T>;

  R when<R>({
    required R Function(T value) ok,
    required R Function(LiteRtLmFailure error) err,
  }) {
    return switch (this) {
      LiteRtLmOk<T>(:final value) => ok(value),
      LiteRtLmErr<T>(:final error) => err(error),
    };
  }

  LiteRtLmResult<R> map<R>(R Function(T value) convert) {
    return switch (this) {
      LiteRtLmOk<T>(:final value) => LiteRtLmOk<R>(convert(value)),
      LiteRtLmErr<T>(:final error) => LiteRtLmErr<R>(error),
    };
  }

  T? get valueOrNull => switch (this) {
    LiteRtLmOk<T>(:final value) => value,
    LiteRtLmErr<T>() => null,
  };

  LiteRtLmFailure? get errorOrNull => switch (this) {
    LiteRtLmOk<T>() => null,
    LiteRtLmErr<T>(:final error) => error,
  };
}

final class LiteRtLmOk<T> extends LiteRtLmResult<T> {
  const LiteRtLmOk(this.value);

  final T value;
}

final class LiteRtLmErr<T> extends LiteRtLmResult<T> {
  const LiteRtLmErr(this.error);

  final LiteRtLmFailure error;
}

sealed class LiteRtLmFailure {
  const LiteRtLmFailure(this.message);

  final String message;

  String get code;

  @override
  String toString() => '$code: $message';
}

final class LiteRtLmModelNotFound extends LiteRtLmFailure {
  const LiteRtLmModelNotFound(super.message);

  @override
  String get code => 'model-not-found';
}

final class LiteRtLmOutOfMemory extends LiteRtLmFailure {
  const LiteRtLmOutOfMemory(super.message);

  @override
  String get code => 'oom';
}

final class LiteRtLmUnsupportedModel extends LiteRtLmFailure {
  const LiteRtLmUnsupportedModel(super.message);

  @override
  String get code => 'unsupported-model';
}

final class LiteRtLmNativeInitFailure extends LiteRtLmFailure {
  const LiteRtLmNativeInitFailure(super.message);

  @override
  String get code => 'native-init-failure';
}

final class LiteRtLmGenerationFailure extends LiteRtLmFailure {
  const LiteRtLmGenerationFailure(super.message);

  @override
  String get code => 'generation-failure';
}

final class LiteRtLmDisposed extends LiteRtLmFailure {
  const LiteRtLmDisposed(super.message);

  @override
  String get code => 'disposed';
}

final class LiteRtLmCancelled extends LiteRtLmFailure {
  const LiteRtLmCancelled(super.message);

  @override
  String get code => 'cancelled';
}

sealed class LiteRtLmEvent {
  const LiteRtLmEvent();
}

final class LiteRtLmToken extends LiteRtLmEvent {
  const LiteRtLmToken(this.text);

  final String text;
}

final class LiteRtLmCompleted extends LiteRtLmEvent {
  const LiteRtLmCompleted(this.text);

  final String text;
}

final class LiteRtLmFailed extends LiteRtLmEvent {
  const LiteRtLmFailed(this.error);

  final LiteRtLmFailure error;
}

final class LiteRtLmCancelledEvent extends LiteRtLmEvent {
  const LiteRtLmCancelledEvent([
    this.reason = const LiteRtLmCancelled('cancelled'),
  ]);

  final LiteRtLmCancelled reason;
}

// Shared parent state makes surviving children safe after client/engine closure.
final class _HandleState {
  _HandleState([this.parent]);
  final _HandleState? parent;
  bool _closed = false;
  Future<void>? _closing;
  bool get closed => _closed || (parent?.closed ?? false);
  Future<void> close(Future<void> Function() operation) {
    if (_closing != null) return _closing!;
    final parentClosed = parent?.closed ?? false;
    _closed = true;
    return _closing = parentClosed
        ? Future<void>.value()
        : Future<void>.sync(operation);
  }
}

const _disposed = LiteRtLmDisposed(
  'LiteRT-LM handle or its parent has been disposed',
);
const _unsupported = LiteRtLmUnsupported(
  'Backend does not support this operation',
);

LiteRtLmFailure? _validateMessages(List<LiteRtLmMessage> messages) {
  try {
    for (final message in messages) {
      message.toJson();
    }
    return null;
  } on ArgumentError catch (error) {
    return LiteRtLmInvalidArgument(error.message.toString());
  }
}

final class LiteRtLm {
  LiteRtLm._(this._backend);
  factory LiteRtLm.testing(LiteRtLmBackend backend) = LiteRtLm._;
  static Future<LiteRtLmResult<LiteRtLm>> create({
    String libraryName = 'liblitert_lm_c.so',
  }) async {
    final backend = await LiteRtLmBackend.createNative(
      libraryName: libraryName,
    );
    return backend.map(LiteRtLm._);
  }

  final LiteRtLmBackend _backend;
  final _state = _HandleState();
  Future<LiteRtLmResult<LiteRtLmEngine>> loadEngine(
    LiteRtLmEngineConfig config,
  ) async {
    if (_state.closed) return const LiteRtLmErr(_disposed);
    final result = await _backend.loadEngine(config);
    if (_state.closed) return const LiteRtLmErr(_disposed);
    return result.map((id) => LiteRtLmEngine._(_backend, id, _state));
  }

  Future<LiteRtLmResult<LiteRtLmModelInfo>> inspectModel(String path) async {
    if (_state.closed) return const LiteRtLmErr(_disposed);
    final backend = _backend;
    if (backend is! LiteRtLmAdvancedBackend) {
      return const LiteRtLmErr(_unsupported);
    }
    return (await (backend as LiteRtLmAdvancedBackend).inspectModel(
      path,
    )).map(LiteRtLmModelInfo.fromJson);
  }

  Future<void> dispose() => _state.close(_backend.close);
}

final class LiteRtLmEngine {
  LiteRtLmEngine._(this._backend, this._id, _HandleState parent)
    : _state = _HandleState(parent);
  final LiteRtLmBackend _backend;
  final int _id;
  final _HandleState _state;
  Future<LiteRtLmResult<LiteRtLmSession>> createSession({
    LiteRtLmGenerationParams params = defaultLiteRtLmGenerationParams,
  }) async {
    if (_state.closed) return const LiteRtLmErr(_disposed);
    final result = await _backend.createSession(_id, params);
    if (_state.closed) return const LiteRtLmErr(_disposed);
    return result.map((id) => LiteRtLmSession._(_backend, id, _state));
  }

  Future<LiteRtLmResult<LiteRtLmConversation>> createConversation({
    List<LiteRtLmMessage> messages = const [],
    LiteRtLmGenerationParams params = defaultLiteRtLmGenerationParams,
  }) async {
    if (_state.closed) return const LiteRtLmErr(_disposed);
    final invalid = _validateMessages(messages);
    if (invalid != null) return LiteRtLmErr(invalid);
    final backend = _backend;
    if (backend is! LiteRtLmAdvancedBackend) {
      return const LiteRtLmErr(_unsupported);
    }
    final result = await (backend as LiteRtLmAdvancedBackend)
        .createConversation(_id, messages, params);
    if (_state.closed) return const LiteRtLmErr(_disposed);
    return result.map((id) => LiteRtLmConversation._(_backend, id, _state));
  }

  Future<LiteRtLmResult<String>> generate(
    String prompt, {
    LiteRtLmGenerationParams params = defaultLiteRtLmGenerationParams,
  }) async {
    final result = await createSession(params: params);
    final session = result.valueOrNull;
    if (session == null) return LiteRtLmErr(result.errorOrNull!);
    try {
      return await session.generate(prompt);
    } finally {
      await session.dispose();
    }
  }

  Future<LiteRtLmResult<String>> generateContent(
    List<LiteRtLmContent> contents, {
    LiteRtLmGenerationParams params = defaultLiteRtLmGenerationParams,
  }) async {
    final result = await createSession(params: params);
    final session = result.valueOrNull;
    if (session == null) return LiteRtLmErr(result.errorOrNull!);
    try {
      return await session.generateContent(contents);
    } finally {
      await session.dispose();
    }
  }

  /// Creates a fresh conversation; [messages] is the complete request history.
  Future<LiteRtLmResult<String>> generateMessages(
    List<LiteRtLmMessage> messages, {
    LiteRtLmGenerationParams params = defaultLiteRtLmGenerationParams,
  }) async {
    final result = await createConversation(params: params);
    final conversation = result.valueOrNull;
    if (conversation == null) return LiteRtLmErr(result.errorOrNull!);
    try {
      return await conversation.sendMessages(messages);
    } finally {
      await conversation.dispose();
    }
  }

  Future<LiteRtLmResult<LiteRtLmModelInfo>> getInfo() async {
    if (_state.closed) return const LiteRtLmErr(_disposed);
    final backend = _backend;
    if (backend is! LiteRtLmAdvancedBackend) {
      return const LiteRtLmErr(_unsupported);
    }
    return (await (backend as LiteRtLmAdvancedBackend).engineInfo(
      _id,
    )).map(LiteRtLmModelInfo.fromJson);
  }

  Future<LiteRtLmResult<List<int>>> tokenize(String text) async {
    if (_state.closed) return const LiteRtLmErr(_disposed);
    final backend = _backend;
    if (backend is! LiteRtLmAdvancedBackend) {
      return const LiteRtLmErr(_unsupported);
    }
    return (backend as LiteRtLmAdvancedBackend).tokenize(_id, text);
  }

  Future<void> dispose() => _state.close(() => _backend.disposeEngine(_id));
}

final class LiteRtLmSession {
  LiteRtLmSession._(this._backend, this._id, _HandleState parent)
    : _state = _HandleState(parent);
  final LiteRtLmBackend _backend;
  final int _id;
  final _HandleState _state;
  Future<LiteRtLmResult<String>> generate(String prompt) async {
    if (_state.closed) return const LiteRtLmErr(_disposed);
    return _backend.generate(_id, prompt);
  }

  Stream<LiteRtLmEvent> generateStream(String prompt) {
    if (_state.closed) return Stream.value(const LiteRtLmFailed(_disposed));
    return _backend.generateStream(_id, prompt);
  }

  Future<LiteRtLmResult<String>> generateContent(
    List<LiteRtLmContent> contents,
  ) async {
    if (_state.closed) return const LiteRtLmErr(_disposed);
    try {
      contents = normalizeLiteRtLmContents(contents);
    } on ArgumentError catch (error) {
      return LiteRtLmErr(LiteRtLmInvalidArgument(error.message.toString()));
    }
    return _backend.generateContent(_id, contents);
  }

  Stream<LiteRtLmEvent> generateContentStream(List<LiteRtLmContent> contents) {
    if (_state.closed) return Stream.value(const LiteRtLmFailed(_disposed));
    try {
      contents = normalizeLiteRtLmContents(contents);
    } on ArgumentError catch (error) {
      return Stream.value(
        LiteRtLmFailed(LiteRtLmInvalidArgument(error.message.toString())),
      );
    }
    return _backend.generateContentStream(_id, contents);
  }

  Future<LiteRtLmResult<LiteRtLmMetrics>> getMetrics() =>
      _getMetrics(_backend, _id, _state);
  Future<LiteRtLmResult<LiteRtLmTokenBudget>> budget({
    List<LiteRtLmMessage> messages = const [],
    int outputReserve = 0,
  }) => _budget(_backend, _id, _state, messages, outputReserve);
  Future<void> cancel() async {
    if (!_state.closed) await _backend.cancelSession(_id);
  }

  Future<void> dispose() => _state.close(() => _backend.disposeSession(_id));
}

final class LiteRtLmConversation {
  LiteRtLmConversation._(this._backend, this._id, _HandleState parent)
    : _state = _HandleState(parent);
  final LiteRtLmBackend _backend;
  final int _id;
  final _HandleState _state;
  Future<LiteRtLmResult<String>> send(LiteRtLmMessage message) =>
      sendMessages([message]);
  Future<LiteRtLmResult<String>> sendMessages(List<LiteRtLmMessage> messages) =>
      _collectEvents(sendMessagesStream(messages));
  Stream<LiteRtLmEvent> sendStream(LiteRtLmMessage message) =>
      sendMessagesStream([message]);

  /// Appends only new messages to the native conversation history.
  Stream<LiteRtLmEvent> sendMessagesStream(List<LiteRtLmMessage> messages) {
    if (_state.closed) return Stream.value(const LiteRtLmFailed(_disposed));
    final invalid = _validateMessages(messages);
    if (invalid != null) return Stream.value(LiteRtLmFailed(invalid));
    final backend = _backend;
    if (backend is! LiteRtLmAdvancedBackend) {
      return Stream.value(const LiteRtLmFailed(_unsupported));
    }
    return (backend as LiteRtLmAdvancedBackend).sendMessagesStream(
      _id,
      messages,
    );
  }

  Future<LiteRtLmResult<LiteRtLmMetrics>> getMetrics() =>
      _getMetrics(_backend, _id, _state);
  Future<LiteRtLmResult<LiteRtLmTokenBudget>> budget({
    List<LiteRtLmMessage> messages = const [],
    int outputReserve = 0,
  }) => _budget(_backend, _id, _state, messages, outputReserve);
  Future<void> cancel() async {
    if (!_state.closed) await _backend.cancelSession(_id);
  }

  Future<void> dispose() => _state.close(() => _backend.disposeSession(_id));
}

Future<LiteRtLmResult<String>> _collectEvents(
  Stream<LiteRtLmEvent> events,
) async {
  await for (final event in events) {
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
    LiteRtLmGenerationFailure('Stream ended without completion'),
  );
}

Future<LiteRtLmResult<LiteRtLmMetrics>> _getMetrics(
  LiteRtLmBackend backend,
  int id,
  _HandleState state,
) async {
  if (state.closed) return const LiteRtLmErr(_disposed);
  if (backend is! LiteRtLmAdvancedBackend) {
    return const LiteRtLmErr(_unsupported);
  }
  return (await (backend as LiteRtLmAdvancedBackend).sessionMetrics(
    id,
  )).map(LiteRtLmMetrics.fromJson);
}

Future<LiteRtLmResult<LiteRtLmTokenBudget>> _budget(
  LiteRtLmBackend backend,
  int id,
  _HandleState state,
  List<LiteRtLmMessage> messages,
  int outputReserve,
) async {
  if (state.closed) return const LiteRtLmErr(_disposed);
  if (outputReserve < 0) {
    return const LiteRtLmErr(
      LiteRtLmInvalidArgument('outputReserve must be nonnegative'),
    );
  }
  final invalid = _validateMessages(messages);
  if (invalid != null) return LiteRtLmErr(invalid);
  if (backend is! LiteRtLmAdvancedBackend) {
    return const LiteRtLmErr(_unsupported);
  }
  return (await (backend as LiteRtLmAdvancedBackend).conversationBudget(
    id,
    messages,
    outputReserve,
  )).map(LiteRtLmTokenBudget.fromJson);
}

LiteRtLmFailure liteRtLmFailureFromMap(Map<Object?, Object?> map) {
  final code = map['code'] as String? ?? 'native-init-failure';
  final message = map['message'] as String? ?? 'native operation failed';
  return switch (code) {
    'model-not-found' => LiteRtLmModelNotFound(message),
    'oom' => LiteRtLmOutOfMemory(message),
    'unsupported-model' => LiteRtLmUnsupportedModel(message),
    'generation-failure' => LiteRtLmGenerationFailure(message),
    'disposed' => LiteRtLmDisposed(message),
    'cancelled' => LiteRtLmCancelled(message),
    'busy' => LiteRtLmBusy(message),
    'invalid-argument' => LiteRtLmInvalidArgument(message),
    'unsupported' => LiteRtLmUnsupported(message),
    'worker-failure' => LiteRtLmWorkerFailure(message),
    'backpressure' => LiteRtLmBackpressure(message),
    'context-full' => LiteRtLmContextFull(
      requiredTokens: (map['requiredTokens'] as num?)?.toInt(),
      availableTokens: (map['availableTokens'] as num?)?.toInt(),
      message: message,
    ),
    _ => LiteRtLmNativeInitFailure(message),
  };
}

Map<String, Object?> liteRtLmFailureToMap(LiteRtLmFailure failure) {
  return <String, Object?>{
    'code': failure.code,
    'message': failure.message,
    if (failure is LiteRtLmContextFull) ...{
      'requiredTokens': failure.requiredTokens,
      'availableTokens': failure.availableTokens,
    },
  };
}

/// Represents content input to LiteRT-LM, such as text, images, or audio.
sealed class LiteRtLmContent {
  const LiteRtLmContent();

  /// Creates a text content input.
  const factory LiteRtLmContent.text(String text) = LiteRtLmTextContent;

  /// Creates an image content input.
  const factory LiteRtLmContent.image(List<int> bytes) = LiteRtLmImageContent;

  /// Creates an image end marker input.
  const factory LiteRtLmContent.imageEnd() = LiteRtLmImageEndContent;

  /// Creates an audio content input.
  const factory LiteRtLmContent.audio(List<int> bytes) = LiteRtLmAudioContent;

  /// Creates an audio end marker input.
  const factory LiteRtLmContent.audioEnd() = LiteRtLmAudioEndContent;
}

/// Text content input.
final class LiteRtLmTextContent extends LiteRtLmContent {
  const LiteRtLmTextContent(this.text);
  final String text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiteRtLmTextContent &&
          runtimeType == other.runtimeType &&
          text == other.text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'LiteRtLmTextContent(text: $text)';
}

/// Image content input (raw bytes).
final class LiteRtLmImageContent extends LiteRtLmContent {
  const LiteRtLmImageContent(this.bytes);
  final List<int> bytes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiteRtLmImageContent &&
          runtimeType == other.runtimeType &&
          bytes == other.bytes;

  @override
  int get hashCode => bytes.hashCode;

  @override
  String toString() => 'LiteRtLmImageContent(bytes length: ${bytes.length})';
}

/// Image end marker content.
final class LiteRtLmImageEndContent extends LiteRtLmContent {
  const LiteRtLmImageEndContent();

  @override
  bool operator ==(Object other) => other is LiteRtLmImageEndContent;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'LiteRtLmImageEndContent()';
}

/// Audio content input (raw bytes).
final class LiteRtLmAudioContent extends LiteRtLmContent {
  const LiteRtLmAudioContent(this.bytes);
  final List<int> bytes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiteRtLmAudioContent &&
          runtimeType == other.runtimeType &&
          bytes == other.bytes;

  @override
  int get hashCode => bytes.hashCode;

  @override
  String toString() => 'LiteRtLmAudioContent(bytes length: ${bytes.length})';
}

/// Audio end marker content.
final class LiteRtLmAudioEndContent extends LiteRtLmContent {
  const LiteRtLmAudioEndContent();

  @override
  bool operator ==(Object other) => other is LiteRtLmAudioEndContent;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'LiteRtLmAudioEndContent()';
}

final class LiteRtLmBusy extends LiteRtLmFailure {
  const LiteRtLmBusy(super.message);
  @override
  String get code => 'busy';
}

final class LiteRtLmInvalidArgument extends LiteRtLmFailure {
  const LiteRtLmInvalidArgument(super.message);
  @override
  String get code => 'invalid-argument';
}

final class LiteRtLmUnsupported extends LiteRtLmFailure {
  const LiteRtLmUnsupported(super.message);
  @override
  String get code => 'unsupported';
}

final class LiteRtLmWorkerFailure extends LiteRtLmFailure {
  const LiteRtLmWorkerFailure(super.message);
  @override
  String get code => 'worker-failure';
}

final class LiteRtLmBackpressure extends LiteRtLmFailure {
  const LiteRtLmBackpressure(super.message);
  @override
  String get code => 'backpressure';
}

final class LiteRtLmContextFull extends LiteRtLmFailure {
  const LiteRtLmContextFull({
    required this.requiredTokens,
    required this.availableTokens,
    required String message,
  }) : super(message);
  final int? requiredTokens;
  final int? availableTokens;
  @override
  String get code => 'context-full';
}

/// Role and ordered multimodal content passed directly to native Conversation.
final class LiteRtLmMessage {
  const LiteRtLmMessage({required this.role, required this.contents});
  LiteRtLmMessage.text({this.role = 'user', required String text})
    : contents = [LiteRtLmContent.text(text)];
  final String role;
  final List<LiteRtLmContent> contents;
  Map<String, Object?> toJson() {
    if (!const ['system', 'user', 'assistant'].contains(role)) {
      throw ArgumentError('Unsupported message role: $role');
    }
    return {
      'role': role,
      'content': normalizeLiteRtLmContents(contents)
          .map(
            (content) => switch (content) {
              LiteRtLmTextContent(:final text) => <String, Object?>{
                'type': 'text',
                'text': text,
              },
              LiteRtLmImageContent(:final bytes) => <String, Object?>{
                'type': 'image',
                'blob': base64Encode(bytes),
              },
              LiteRtLmAudioContent(:final bytes) => <String, Object?>{
                'type': 'audio',
                'blob': base64Encode(bytes),
              },
              _ => throw StateError('Unnormalized end marker'),
            },
          )
          .toList(),
    };
  }
}

/// Legacy end markers are optional, but must immediately follow their modality.
List<LiteRtLmContent> normalizeLiteRtLmContents(
  List<LiteRtLmContent> contents,
) {
  final normalized = <LiteRtLmContent>[];
  LiteRtLmContent? previous;
  for (final content in contents) {
    if (content is LiteRtLmImageEndContent ||
        content is LiteRtLmAudioEndContent) {
      if (!(content is LiteRtLmImageEndContent &&
              previous is LiteRtLmImageContent) &&
          !(content is LiteRtLmAudioEndContent &&
              previous is LiteRtLmAudioContent)) {
        throw ArgumentError(
          'End marker must immediately follow matching image/audio content',
        );
      }
    } else {
      normalized.add(content);
    }
    previous = content;
  }
  return normalized;
}

final class LiteRtLmModelInfo {
  const LiteRtLmModelInfo({
    this.path = '',
    this.modelId,
    this.artifactSha256,
    this.revision,
    this.maxContextTokens,
    this.dynamicContext = false,
    this.requestedContextTokens,
    this.effectiveContextTokens,
    this.runtimeVersion = '',
    this.runtimeCommit = '',
    this.backends = const {},
    this.minimumRuntimeVersion,
    this.initializationSeconds,
  });
  final String path;
  final String? modelId;
  final String? artifactSha256;
  final String? revision;
  final int? maxContextTokens;
  final bool dynamicContext;
  final int? requestedContextTokens;
  final int? effectiveContextTokens;
  final String runtimeVersion;
  final String runtimeCommit;
  final Map<String, List<String>> backends;
  final String? minimumRuntimeVersion;
  final double? initializationSeconds;
  factory LiteRtLmModelInfo.fromJson(
    Map<String, Object?> json,
  ) => LiteRtLmModelInfo(
    path: json['path'] as String? ?? '',
    modelId: json['modelId'] as String?,
    artifactSha256: json['artifactSha256'] as String?,
    revision: json['revision'] as String?,
    maxContextTokens: (json['maxContextTokens'] as num?)?.toInt(),
    dynamicContext: json['dynamicContext'] as bool? ?? false,
    requestedContextTokens: (json['requestedContextTokens'] as num?)?.toInt(),
    effectiveContextTokens: (json['effectiveContextTokens'] as num?)?.toInt(),
    runtimeVersion: json['runtimeVersion'] as String? ?? '',
    runtimeCommit: json['runtimeCommit'] as String? ?? '',
    backends:
        (json['backends'] as Map?)?.map(
          (key, value) =>
              MapEntry(key as String, (value as List).cast<String>()),
        ) ??
        const {},
    minimumRuntimeVersion: json['minimumRuntimeVersion'] as String?,
    initializationSeconds: (json['initializationSeconds'] as num?)?.toDouble(),
  );
  Map<String, Object?> toJson() => {
    'path': path,
    'modelId': modelId,
    'artifactSha256': artifactSha256,
    'revision': revision,
    'maxContextTokens': maxContextTokens,
    'dynamicContext': dynamicContext,
    'requestedContextTokens': requestedContextTokens,
    'effectiveContextTokens': effectiveContextTokens,
    'runtimeVersion': runtimeVersion,
    'runtimeCommit': runtimeCommit,
    'backends': backends,
    'minimumRuntimeVersion': minimumRuntimeVersion,
    'initializationSeconds': initializationSeconds,
  };
}

final class LiteRtLmTokenBudget {
  const LiteRtLmTokenBudget({
    this.contextTokens = 0,
    this.usedTokens = 0,
    this.inputTokens,
    this.outputReserve = 0,
    this.requiredTokens,
    this.remainingTokens,
    this.exact = false,
  });
  final int contextTokens;
  final int usedTokens;
  final int? inputTokens;
  final int outputReserve;
  final int? requiredTokens;
  final int? remainingTokens;
  final bool exact;
  factory LiteRtLmTokenBudget.fromJson(Map<String, Object?> json) =>
      LiteRtLmTokenBudget(
        contextTokens: (json['contextTokens'] as num?)?.toInt() ?? 0,
        usedTokens: (json['usedTokens'] as num?)?.toInt() ?? 0,
        inputTokens: (json['inputTokens'] as num?)?.toInt(),
        outputReserve: (json['outputReserve'] as num?)?.toInt() ?? 0,
        requiredTokens: (json['requiredTokens'] as num?)?.toInt(),
        remainingTokens: (json['remainingTokens'] as num?)?.toInt(),
        exact: json['exact'] as bool? ?? false,
      );
  Map<String, Object?> toJson() => {
    'contextTokens': contextTokens,
    'usedTokens': usedTokens,
    'inputTokens': inputTokens,
    'outputReserve': outputReserve,
    'requiredTokens': requiredTokens,
    'remainingTokens': remainingTokens,
    'exact': exact,
  };
}

final class LiteRtLmMetrics {
  const LiteRtLmMetrics({
    this.initializationSeconds,
    this.prefillTokens,
    this.prefillSeconds,
    this.timeToFirstTokenSeconds,
    this.nativeTimeToFirstTokenSeconds,
    this.decodeTokens,
    this.decodeTokensPerSecond,
    this.contextUsedTokens,
    this.effectiveContextTokens,
    this.backend,
  });
  final double? initializationSeconds;
  final int? prefillTokens;
  final double? prefillSeconds;

  /// Wall time from request start to its first token, including prefill.
  final double? timeToFirstTokenSeconds;

  /// Native time to first token, excluding the separately reported prefill.
  final double? nativeTimeToFirstTokenSeconds;
  final int? decodeTokens;
  final double? decodeTokensPerSecond;
  final int? contextUsedTokens;
  final int? effectiveContextTokens;
  final String? backend;
  factory LiteRtLmMetrics.fromJson(
    Map<String, Object?> json,
  ) => LiteRtLmMetrics(
    initializationSeconds: (json['initializationSeconds'] as num?)?.toDouble(),
    prefillTokens: (json['prefillTokens'] as num?)?.toInt(),
    prefillSeconds: (json['prefillSeconds'] as num?)?.toDouble(),
    timeToFirstTokenSeconds: (json['timeToFirstTokenSeconds'] as num?)
        ?.toDouble(),
    nativeTimeToFirstTokenSeconds:
        (json['nativeTimeToFirstTokenSeconds'] as num?)?.toDouble(),
    decodeTokens: (json['decodeTokens'] as num?)?.toInt(),
    decodeTokensPerSecond: (json['decodeTokensPerSecond'] as num?)?.toDouble(),
    contextUsedTokens: (json['contextUsedTokens'] as num?)?.toInt(),
    effectiveContextTokens: (json['effectiveContextTokens'] as num?)?.toInt(),
    backend: json['backend'] as String?,
  );
  Map<String, Object?> toJson() => {
    'initializationSeconds': initializationSeconds,
    'prefillTokens': prefillTokens,
    'prefillSeconds': prefillSeconds,
    'timeToFirstTokenSeconds': timeToFirstTokenSeconds,
    'nativeTimeToFirstTokenSeconds': nativeTimeToFirstTokenSeconds,
    'decodeTokens': decodeTokens,
    'decodeTokensPerSecond': decodeTokensPerSecond,
    'contextUsedTokens': contextUsedTokens,
    'effectiveContextTokens': effectiveContextTokens,
    'backend': backend,
  };
}
