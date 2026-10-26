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

  Future<LiteRtLmResult<String>> generateContent(
    int sessionId,
    List<LiteRtLmContent> contents,
  );

  Stream<LiteRtLmEvent> generateContentStream(
    int sessionId,
    List<LiteRtLmContent> contents,
  );

  Future<void> cancelSession(int sessionId);

  Future<void> disposeSession(int sessionId);

  Future<void> disposeEngine(int engineId);

  Future<void> close();
}

/// Optional runtime capabilities. Existing backend implementations stay valid.
abstract interface class LiteRtLmAdvancedBackend {
  Future<LiteRtLmResult<int>> createConversation(
    int engineId,
    List<LiteRtLmMessage> messages,
    LiteRtLmGenerationParams params,
  );
  Stream<LiteRtLmEvent> sendMessagesStream(
    int conversationId,
    List<LiteRtLmMessage> messages,
  );
  Future<LiteRtLmResult<Map<String, Object?>>> inspectModel(String path);
  Future<LiteRtLmResult<Map<String, Object?>>> engineInfo(int engineId);
  Future<LiteRtLmResult<List<int>>> tokenize(int engineId, String text);
  Future<LiteRtLmResult<Map<String, Object?>>> conversationBudget(
    int conversationId,
    List<LiteRtLmMessage> messages,
    int outputReserve,
  );
  Future<LiteRtLmResult<Map<String, Object?>>> sessionMetrics(int sessionId);
}
