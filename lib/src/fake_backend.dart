import 'dart:async';

import 'backend.dart';
import 'types.dart';

final class FakeLiteRtLmBackend implements LiteRtLmBackend {
  FakeLiteRtLmBackend({
    this.generateText = 'fake response',
    this.streamTokens = const <String>['fake', ' ', 'response'],
    this.tokenDelay = Duration.zero,
  });

  final String generateText;
  final List<String> streamTokens;
  final Duration tokenDelay;

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
    final buffer = StringBuffer();

    void emitNext() {
      if (cancelledSessions.contains(sessionId)) {
        controller.add(const LiteRtLmCancelledEvent());
        unawaited(controller.close());
        return;
      }
      if (index >= streamTokens.length) {
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
        cancelledSessions.add(sessionId);
      },
    );
    return controller.stream;
  }

  @override
  Future<void> cancelSession(int sessionId) async {
    cancelledSessions.add(sessionId);
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
}
