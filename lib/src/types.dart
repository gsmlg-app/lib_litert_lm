import 'dart:async';

import 'backend.dart';

const LiteRtLmGenerationParams defaultLiteRtLmGenerationParams =
    LiteRtLmGenerationParams();

final class LiteRtLmEngineConfig {
  const LiteRtLmEngineConfig({
    required this.modelPath,
    this.backend = 'cpu',
    this.maxNumTokens,
    this.cacheDir,
    this.litertDispatchLibDir,
    this.prefillChunkSize,
    this.parallelFileSectionLoading = true,
  });

  final String modelPath;
  final String backend;
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
  bool _disposed = false;

  Future<LiteRtLmResult<LiteRtLmEngine>> loadEngine(
    LiteRtLmEngineConfig config,
  ) async {
    if (_disposed) {
      return const LiteRtLmErr(
        LiteRtLmDisposed('LiteRT-LM client has been disposed'),
      );
    }

    final result = await _backend.loadEngine(config);
    return result.map((id) => LiteRtLmEngine._(_backend, id));
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _backend.close();
  }
}

final class LiteRtLmEngine {
  LiteRtLmEngine._(this._backend, this._id);

  final LiteRtLmBackend _backend;
  final int _id;
  bool _disposed = false;

  Future<LiteRtLmResult<LiteRtLmSession>> createSession({
    LiteRtLmGenerationParams params = defaultLiteRtLmGenerationParams,
  }) async {
    if (_disposed) {
      return const LiteRtLmErr(
        LiteRtLmDisposed('LiteRT-LM engine has been disposed'),
      );
    }

    final result = await _backend.createSession(_id, params);
    return result.map((id) => LiteRtLmSession._(_backend, id));
  }

  Future<LiteRtLmResult<String>> generate(
    String prompt, {
    LiteRtLmGenerationParams params = defaultLiteRtLmGenerationParams,
  }) async {
    final sessionResult = await createSession(params: params);
    return switch (sessionResult) {
      LiteRtLmErr<LiteRtLmSession>(:final error) => LiteRtLmErr(error),
      LiteRtLmOk<LiteRtLmSession>(:final value) => () async {
        try {
          return await value.generate(prompt);
        } finally {
          await value.dispose();
        }
      }(),
    };
  }

  Future<LiteRtLmResult<String>> generateContent(
    List<LiteRtLmContent> contents, {
    LiteRtLmGenerationParams params = defaultLiteRtLmGenerationParams,
  }) async {
    final sessionResult = await createSession(params: params);
    return switch (sessionResult) {
      LiteRtLmErr<LiteRtLmSession>(:final error) => LiteRtLmErr(error),
      LiteRtLmOk<LiteRtLmSession>(:final value) => () async {
        try {
          return await value.generateContent(contents);
        } finally {
          await value.dispose();
        }
      }(),
    };
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _backend.disposeEngine(_id);
  }
}

final class LiteRtLmSession {
  LiteRtLmSession._(this._backend, this._id);

  final LiteRtLmBackend _backend;
  final int _id;
  bool _disposed = false;

  Future<LiteRtLmResult<String>> generate(String prompt) async {
    if (_disposed) {
      return const LiteRtLmErr(
        LiteRtLmDisposed('LiteRT-LM session has been disposed'),
      );
    }
    return _backend.generate(_id, prompt);
  }

  Stream<LiteRtLmEvent> generateStream(String prompt) {
    if (_disposed) {
      return Stream<LiteRtLmEvent>.value(
        const LiteRtLmFailed(
          LiteRtLmDisposed('LiteRT-LM session has been disposed'),
        ),
      );
    }
    return _backend.generateStream(_id, prompt);
  }

  Future<LiteRtLmResult<String>> generateContent(
    List<LiteRtLmContent> contents,
  ) async {
    if (_disposed) {
      return const LiteRtLmErr(
        LiteRtLmDisposed('LiteRT-LM session has been disposed'),
      );
    }
    return _backend.generateContent(_id, contents);
  }

  Stream<LiteRtLmEvent> generateContentStream(List<LiteRtLmContent> contents) {
    if (_disposed) {
      return Stream<LiteRtLmEvent>.value(
        const LiteRtLmFailed(
          LiteRtLmDisposed('LiteRT-LM session has been disposed'),
        ),
      );
    }
    return _backend.generateContentStream(_id, contents);
  }

  Future<void> cancel() async {
    if (_disposed) {
      return;
    }
    await _backend.cancelSession(_id);
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _backend.disposeSession(_id);
  }
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
    _ => LiteRtLmNativeInitFailure(message),
  };
}

Map<String, Object?> liteRtLmFailureToMap(LiteRtLmFailure failure) {
  return <String, Object?>{'code': failure.code, 'message': failure.message};
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
