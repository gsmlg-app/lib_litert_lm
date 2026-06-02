import 'native_backend.dart';
import 'types.dart';

abstract interface class LiteRtLmBackend {
  static Future<LiteRtLmResult<LiteRtLmBackend>> createNative({
    required String libraryName,
  }) {
    return NativeLiteRtLmBackend.start(libraryName: libraryName);
  }

  Future<LiteRtLmResult<int>> loadEngine(LiteRtLmEngineConfig config);

  Future<LiteRtLmResult<int>> createSession(
    int engineId,
    LiteRtLmGenerationParams params,
  );

  Future<LiteRtLmResult<String>> generate(int sessionId, String prompt);

  Stream<LiteRtLmEvent> generateStream(int sessionId, String prompt);

  Future<void> cancelSession(int sessionId);

  Future<void> disposeSession(int sessionId);

  Future<void> disposeEngine(int engineId);

  Future<void> close();
}
