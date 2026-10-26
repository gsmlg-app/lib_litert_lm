// Copyright 2026. Licensed under the Apache License, Version 2.0.
#include "litert_lm_bridge.h"
#include "c/error_reporter.h"
#include <atomic>
#include <cstring>
#include <deque>
#include <memory>
#include <limits>
#include <mutex>
#include <string>
#include <unordered_map>

namespace {
constexpr size_t kMaxEvents = 64;
constexpr size_t kMaxBytes = 1024 * 1024;
std::atomic<uint64_t> next_id{1};
std::atomic<int64_t> live_events{0};
}
struct LrlmEvent {
  uint64_t id;
  int kind;
  std::string text;
  LrlmEvent(uint64_t op, int type, std::string value)
      : id(op), kind(type), text(std::move(value)) { ++live_events; }
  ~LrlmEvent() { --live_events; }
};
namespace {
struct Operation {
  std::mutex mutex;
  std::deque<std::unique_ptr<LrlmEvent>> queue;
  size_t bytes = 0;
  bool cancelled = false;
  bool overflow = false;
  bool final = false;
  bool started = false;
  bool terminal_taken = false;
};
std::mutex registry_mutex;
std::unordered_map<uint64_t, std::shared_ptr<Operation>> operations;
std::shared_ptr<Operation> Find(uint64_t id) {
  std::lock_guard<std::mutex> lock(registry_mutex);
  const auto it = operations.find(id);
  return it == operations.end() ? nullptr : it->second;
}
void Clear(Operation& op) { op.queue.clear(); op.bytes = 0; }
void Push(Operation& op, uint64_t id, int kind, std::string text) {
  op.bytes += text.size();
  op.queue.push_back(std::make_unique<LrlmEvent>(id, kind, std::move(text)));
}
void Finish(Operation& op, uint64_t id, int kind, std::string error = {}) {
  if (op.final) return;
  op.final = true;
  if (op.cancelled) { Clear(op); kind = 3; error.clear(); }
  else if (op.overflow) {
    Clear(op); kind = 4;
    error = "Native event queue exceeded 64 payloads or 1 MiB; generation stopped";
  }
  if (error.size() > kMaxBytes) error.resize(kMaxBytes);
  if (op.bytes > kMaxBytes - error.size()) Clear(op);
  Push(op, id, kind, std::move(error));
}
// This native function lives for the lifetime of the loaded library. The numeric
// callback_data is NEVER dereferenced. Erasing the registry cannot invalidate a
// callback already running (it holds a shared_ptr), nor a future late callback.
void Callback(void* data, const LiteRtLmStreamChunk* chunk) {
  const auto id = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(data));
  auto op = Find(id);
  if (!op || !chunk) return;
  std::lock_guard<std::mutex> lock(op->mutex);
  if (op->final) return;
  const char* text = litert_lm_stream_chunk_get_text(chunk);
  const char* error = litert_lm_stream_chunk_get_error(chunk);
  const bool final = litert_lm_stream_chunk_is_final(chunk);
  // Strings are inspected and copied before returning to the upstream caller.
  if (error && *error) {
    const auto n = strnlen(error, kMaxBytes + 1);
    Finish(*op, id, 2, std::string(error, n > kMaxBytes ? kMaxBytes : n));
    return;
  }
  if (text && *text && !op->cancelled && !op->overflow) {
    const auto n = strnlen(text, kMaxBytes + 1);
    // One slot is reserved for the terminal event. Never block an inference
    // thread on Dart: slow/paused/abandoned consumers cause explicit overflow.
    if (op->queue.size() >= kMaxEvents - 1 || n > kMaxBytes - op->bytes) {
      op->overflow = true;
      Clear(*op);
    } else { Push(*op, id, 0, std::string(text, n)); }
  }
  if (final) Finish(*op, id, 1);
}
bool Start(uint64_t id) {
  auto op = Find(id);
  if (!op) return false;
  std::lock_guard<std::mutex> lock(op->mutex);
  if (op->started) return false;
  op->started = true;
  return true;
}
void StartFailed(uint64_t id) {
  // Thread-local error must be copied on the SAME thread as the failed C call.
  const char* error = litert_lm_get_last_error_message();
  auto op = Find(id);
  if (!op) return;
  std::lock_guard<std::mutex> lock(op->mutex);
  Finish(*op, id, 2, error ? std::string(error, strnlen(error, kMaxBytes))
                          : "Native stream failed to start");
}
}
extern "C" {
int lrlm_bridge_abi_version() { return 1; }
const char* lrlm_runtime_version() { return "v0.18.1"; }
const char* lrlm_runtime_commit() { return "bda624851d74be34d4e1f7fac1fc4155939539c7"; }
uint64_t lrlm_operation_create() {
  uint64_t id = next_id.load();
  do {
    if (id == 0) return 0; // Permanently exhausted; never wrap and reuse an ID.
  } while (!next_id.compare_exchange_weak(id,
      id == std::numeric_limits<uint64_t>::max() ? 0 : id + 1));
  auto op = std::make_shared<Operation>();
  std::lock_guard<std::mutex> lock(registry_mutex);
  operations.emplace(id, std::move(op));
  return id;
}
int lrlm_operation_start_session(uint64_t id, LiteRtLmSession* session,
    const LiteRtLmInputData* const* inputs, size_t count) {
  if (!Start(id)) return -1;
  const int status = litert_lm_session_generate_content_stream(session, inputs,
      count, Callback, reinterpret_cast<void*>(static_cast<uintptr_t>(id)));
  if (status != 0) StartFailed(id);
  return status;
}
int lrlm_operation_start_conversation(uint64_t id,
    LiteRtLmConversation* conversation, const char* messages_json) {
  if (!Start(id)) return -1;
  const int status = litert_lm_conversation_send_message_stream(conversation,
      messages_json, nullptr, nullptr, Callback,
      reinterpret_cast<void*>(static_cast<uintptr_t>(id)));
  if (status != 0) StartFailed(id);
  return status;
}
void lrlm_operation_cancel(uint64_t id) {
  auto op = Find(id);
  if (!op) return;
  std::lock_guard<std::mutex> lock(op->mutex);
  if (op->cancelled || op->terminal_taken) return;
  op->cancelled = true;
  Clear(*op);
  if (op->final) Push(*op, id, 3, {});
}
bool lrlm_operation_needs_cancel(uint64_t id) {
  auto op = Find(id);
  if (!op) return false;
  std::lock_guard<std::mutex> lock(op->mutex);
  return op->overflow && !op->final;
}
bool lrlm_operation_is_final(uint64_t id) {
  auto op = Find(id);
  if (!op) return false;
  std::lock_guard<std::mutex> lock(op->mutex);
  return op->final;
}
void lrlm_operation_delete(uint64_t id) {
  std::lock_guard<std::mutex> lock(registry_mutex);
  operations.erase(id);
}
LrlmEvent* lrlm_operation_take(uint64_t id) {
  auto op = Find(id);
  if (!op) return nullptr;
  std::lock_guard<std::mutex> lock(op->mutex);
  if (op->queue.empty()) return nullptr;
  auto event = std::move(op->queue.front());
  op->queue.pop_front();
  op->bytes -= event->text.size();
  if (event->kind != 0) op->terminal_taken = true;
  return event.release();
}
uint64_t lrlm_event_operation_id(const LrlmEvent* event) { return event->id; }
int lrlm_event_kind(const LrlmEvent* event) { return event->kind; }
const char* lrlm_event_text(const LrlmEvent* event) { return event->text.c_str(); }
void lrlm_event_delete(LrlmEvent* event) { delete event; }
int64_t lrlm_live_operations() {
  std::lock_guard<std::mutex> lock(registry_mutex);
  return operations.size();
}
int64_t lrlm_live_events() { return live_events.load(); }
}
