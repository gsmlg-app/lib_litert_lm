#include "native/litert_lm_bridge.h"
#include <cassert>
#include <cstring>
#include <string>
#include <thread>
// The fixture produces callbacks on a background thread and overwrites BOTH
// borrowed strings before start returns. No timing assumptions are involved.
struct LiteRtLmStreamChunk { const char* text; bool final; const char* error; };
static std::string scenario;
static LiteRtLmStreamCallback last_callback;
static void* last_data;
extern "C" const char* litert_lm_stream_chunk_get_text(const LiteRtLmStreamChunk* p) { return p->text; }
extern "C" bool litert_lm_stream_chunk_is_final(const LiteRtLmStreamChunk* p) { return p->final; }
extern "C" const char* litert_lm_stream_chunk_get_error(const LiteRtLmStreamChunk* p) { return p->error; }
extern "C" const char* litert_lm_get_last_error_message() { return "start failed"; }
extern "C" int litert_lm_session_generate_content_stream(LiteRtLmSession*, const LiteRtLmInputData* const*, size_t, LiteRtLmStreamCallback cb, void* data) {
  last_callback = cb; last_data = data;
  std::thread t([=] {
    char text[] = "中文 native token";
    char error[] = "temporary native error";
    LiteRtLmStreamChunk part{text, false, nullptr};
    if (scenario == "overflow") {
      for (int i = 0; i < 500; ++i) cb(data, &part);
    } else { cb(data, &part); }
    std::memset(text, 'X', sizeof(text) - 1);
    if (scenario == "huge_error") {
      std::string huge(2 * 1024 * 1024, 'e');
      part = {nullptr, true, huge.c_str()}; cb(data, &part);
      huge.assign(huge.size(), 'X');
    } else if (scenario == "error") {
      part = {nullptr, true, error}; cb(data, &part);
      std::memset(error, 'X', sizeof(error) - 1);
    } else { part = {nullptr, true, nullptr}; cb(data, &part); }
    // Deliberate illegal duplicate/late callbacks must be harmless.
    cb(data, &part); part = {"late", false, nullptr}; cb(data, &part);
  }); t.join(); return 0;
}
extern "C" int litert_lm_conversation_send_message_stream(LiteRtLmConversation*, const char*, const char*, const LiteRtLmConversationOptionalArgs*, LiteRtLmStreamCallback cb, void* data) {
  return litert_lm_session_generate_content_stream(nullptr, nullptr, 0, cb, data);
}
int main() {
  assert(lrlm_bridge_abi_version() == 1);
  for (const char* mode : {"normal", "error", "overflow"}) {
    scenario = mode; auto id = lrlm_operation_create();
    lrlm_operation_start_session(id, nullptr, nullptr, 0);
    int terminals = 0; bool got_text = false;
    while (auto* event = lrlm_operation_take(id)) {
      assert(lrlm_event_operation_id(event) == id);
      if (lrlm_event_kind(event) == 0) {
        assert(std::string(lrlm_event_text(event)) == "中文 native token"); got_text = true;
      } else {
        ++terminals;
        if (scenario == "error") assert(std::string(lrlm_event_text(event)) == "temporary native error");
        if (scenario == "overflow") assert(lrlm_event_kind(event) == 4);
      }
      lrlm_event_delete(event);
    }
    assert(terminals == 1);
    if (scenario != "overflow") assert(got_text);
    lrlm_operation_delete(id);
  }
  // Cancel after events have already queued: queued text is discarded and one
  // cancelled terminal survives. No consumer has to drain text to unblock join.
  scenario = "normal";
  for (int i = 0; i < 1000; ++i) {
    auto id = lrlm_operation_create();
    lrlm_operation_start_conversation(id, nullptr, "[]");
    lrlm_operation_cancel(id);
    lrlm_operation_cancel(id); // Repeated requests must not duplicate terminal.
    auto* event = lrlm_operation_take(id);
    assert(event && lrlm_event_kind(event) == 3);
    lrlm_event_delete(event);
    assert(lrlm_operation_take(id) == nullptr);
    lrlm_operation_cancel(id); // A consumed terminal cannot be emitted again.
    assert(lrlm_operation_take(id) == nullptr);
    lrlm_operation_delete(id);
    LiteRtLmStreamChunk late{"after registry removal", false, nullptr};
    last_callback(last_data, &late);
  }
  assert(lrlm_live_events() == 0);
  assert(lrlm_live_operations() == 0);
  scenario = "huge_error";
  auto id = lrlm_operation_create();
  lrlm_operation_start_session(id, nullptr, nullptr, 0);
  auto* error = lrlm_operation_take(id);
  assert(error && lrlm_event_kind(error) == 2);
  assert(std::strlen(lrlm_event_text(error)) == 1024 * 1024);
  assert(lrlm_event_text(error)[0] == 'e');
  lrlm_event_delete(error);
  assert(lrlm_operation_take(id) == nullptr);
  lrlm_operation_delete(id);
  assert(lrlm_live_events() == 0 && lrlm_live_operations() == 0);
}
