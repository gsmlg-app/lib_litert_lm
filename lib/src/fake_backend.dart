import 'dart:async';

import 'backend.dart';
import 'types.dart';

final class FakeLiteRtLmBackend
    implements LiteRtLmBackend, LiteRtLmAdvancedBackend {
  FakeLiteRtLmBackend({
    this.generateText = 'fake response',
    this.streamTokens = const <String>['fake', ' ', 'response'],
    this.tokenDelay = Duration.zero,
  });

  final String generateText;
  final List<String> streamTokens;
  final Duration tokenDelay;

  final createdConversations = <List<LiteRtLmMessage>>[];
  final metrics = <String, Object?>{};
  final _cancelledRuns = <int>{};
  final sentMessages = <List<LiteRtLmMessage>>[];

  final loadedModels = <String>[];
  final loadedConfigs = <LiteRtLmEngineConfig>[];
  final cancelledSessions = <int>{};
  final disposedSessions = <int>{};
  final disposedEngines = <int>{};

  var _nextEngineId = 1;
  var _nextSessionId = 1;
  var _closed = false;
  final _engines = <int>{};
  final _sessions = <int, int>{};

  @override
  Future<LiteRtLmResult<int>> loadEngine(LiteRtLmEngineConfig config) async {
    if (_closed) {
      return const LiteRtLmErr(
        LiteRtLmDisposed('Fake backend has been closed'),
      );
    }
    if (config.modelPath.contains('missing')) {
      return const LiteRtLmErr(
        LiteRtLmModelNotFound('Fake model does not exist'),
      );
    }
    if (!config.modelPath.endsWith('.litertlm')) {
      return const LiteRtLmErr(
        LiteRtLmUnsupportedModel('Fake model must end in .litertlm'),
      );
    }

    final id = _nextEngineId++;
    _engines.add(id);
    loadedModels.add(config.modelPath);
    loadedConfigs.add(config);
    return LiteRtLmOk(id);
  }

  @override
  Future<LiteRtLmResult<int>> createSession(
    int engineId,
    LiteRtLmGenerationParams params,
  ) async {
    if (!_engines.contains(engineId)) {
      return const LiteRtLmErr(
        LiteRtLmDisposed('Fake engine has been disposed'),
      );
    }
    final id = _nextSessionId++;
    _sessions[id] = engineId;
    return LiteRtLmOk(id);
  }

  @override
  Future<LiteRtLmResult<String>> generate(int sessionId, String prompt) async {
    if (!_sessions.containsKey(sessionId)) {
      return const LiteRtLmErr(
        LiteRtLmDisposed('Fake session has been disposed'),
      );
    }
    return LiteRtLmOk(generateText);
  }

  @override
  Stream<LiteRtLmEvent> generateStream(int sessionId, String prompt) {
    if (!_sessions.containsKey(sessionId)) {
      return Stream<LiteRtLmEvent>.value(
        const LiteRtLmFailed(
          LiteRtLmDisposed('Fake session has been disposed'),
        ),
      );
    }

    late StreamController<LiteRtLmEvent> controller;
    Timer? timer;
    var index = 0;
    var finished = false;
    _cancelledRuns.remove(sessionId);
    final buffer = StringBuffer();

    void emitNext() {
      if (_cancelledRuns.contains(sessionId)) {
        finished = true;
        controller.add(const LiteRtLmCancelledEvent());
        unawaited(controller.close());
        return;
      }
      if (index >= streamTokens.length) {
        finished = true;
        controller.add(LiteRtLmCompleted(buffer.toString()));
        unawaited(controller.close());
        return;
      }
      final token = streamTokens[index++];
      buffer.write(token);
      controller.add(LiteRtLmToken(token));
      timer = Timer(tokenDelay, emitNext);
    }

    controller = StreamController<LiteRtLmEvent>(
      onListen: emitNext,
      onCancel: () {
        timer?.cancel();
        if (!finished) {
          cancelledSessions.add(sessionId);
          _cancelledRuns.add(sessionId);
        }
      },
    );
    return controller.stream;
  }

  @override
  Future<LiteRtLmResult<String>> generateContent(
    int sessionId,
    List<LiteRtLmContent> contents,
  ) async {
    if (!_sessions.containsKey(sessionId)) {
      return const LiteRtLmErr(
        LiteRtLmDisposed('Fake session has been disposed'),
      );
    }
    return LiteRtLmOk(generateText);
  }

  @override
  Stream<LiteRtLmEvent> generateContentStream(
    int sessionId,
    List<LiteRtLmContent> contents,
  ) {
    return generateStream(sessionId, '');
  }

  @override
  Future<void> cancelSession(int sessionId) async {
    cancelledSessions.add(sessionId);
    _cancelledRuns.add(sessionId);
  }

  @override
  Future<void> disposeSession(int sessionId) async {
    disposedSessions.add(sessionId);
    _sessions.remove(sessionId);
  }

  @override
  Future<void> disposeEngine(int engineId) async {
    disposedEngines.add(engineId);
    _engines.remove(engineId);
    _sessions.removeWhere((_, parentEngineId) => parentEngineId == engineId);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _sessions.clear();
    _engines.clear();
  }

  // These capabilities support Dart/HTTP tests only; no native inference is run.
  @override
  Future<LiteRtLmResult<int>> createConversation(
    int engineId,
    List<LiteRtLmMessage> messages,
    LiteRtLmGenerationParams params,
  ) async {
    final result = await createSession(engineId, params);
    if (result.isOk) createdConversations.add(List.of(messages));
    return result;
  }

  @override
  Stream<LiteRtLmEvent> sendMessagesStream(
    int conversationId,
    List<LiteRtLmMessage> messages,
  ) {
    sentMessages.add(List.of(messages));
    return generateStream(conversationId, '');
  }

  @override
  Future<LiteRtLmResult<Map<String, Object?>>> inspectModel(
    String path,
  ) async => LiteRtLmOk({
    'path': path,
    'runtimeVersion': 'fake',
    'runtimeCommit': '',
    'dynamicContext': false,
    'backends': <String, List<String>>{},
  });
  @override
  Future<LiteRtLmResult<Map<String, Object?>>> engineInfo(int engineId) async {
    if (!_engines.contains(engineId)) {
      return const LiteRtLmErr(LiteRtLmDisposed('Fake engine disposed'));
    }
    return inspectModel(loadedModels[engineId - 1]);
  }

  @override
  Future<LiteRtLmResult<List<int>>> tokenize(int engineId, String text) async =>
      const LiteRtLmErr(
        LiteRtLmUnsupported('Fake backend has no model tokenizer'),
      );
  @override
  Future<LiteRtLmResult<Map<String, Object?>>> conversationBudget(
    int conversationId,
    List<LiteRtLmMessage> messages,
    int outputReserve,
  ) async => LiteRtLmOk({
    'contextTokens': 4096,
    'usedTokens': 0,
    'outputReserve': outputReserve,
    'exact': false,
  });
  @override
  Future<LiteRtLmResult<Map<String, Object?>>> sessionMetrics(
    int sessionId,
  ) async => LiteRtLmOk(Map.of(metrics));
}
