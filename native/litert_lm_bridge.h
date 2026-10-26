// Copyright 2026. Licensed under the Apache License, Version 2.0.
#ifndef LIB_LITERT_LM_BRIDGE_H_
#define LIB_LITERT_LM_BRIDGE_H_
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "c/conversation.h"
#if defined(_WIN32)
#define LRLM_EXPORT __declspec(dllexport)
#else
#define LRLM_EXPORT __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
// Versioned together with the bundled runtime. A v0.12 bundle must fail loading.
LRLM_EXPORT int lrlm_bridge_abi_version(void);
LRLM_EXPORT const char* lrlm_runtime_version(void);
LRLM_EXPORT const char* lrlm_runtime_commit(void);
// IDs are process-wide, monotonically allocated and never reused. No borrowed
// native pointer crosses an isolate port or an asynchronous Dart callback.
LRLM_EXPORT uint64_t lrlm_operation_create(void);
LRLM_EXPORT int lrlm_operation_start_session(uint64_t id, LiteRtLmSession* session,
    const LiteRtLmInputData* const* inputs, size_t count);
LRLM_EXPORT int lrlm_operation_start_conversation(uint64_t id,
    LiteRtLmConversation* conversation, const char* messages_json);
// Cancelling delivery does NOT prove the producer stopped. The caller also
// requests upstream cancellation, drains events, and joins via handle deletion.
LRLM_EXPORT void lrlm_operation_cancel(uint64_t id);
LRLM_EXPORT bool lrlm_operation_needs_cancel(uint64_t id);
LRLM_EXPORT bool lrlm_operation_is_final(uint64_t id);
// Safe even if a late callback is already in progress: callback holds a shared
// reference and only looks up the numeric ID, never a freed callback_data pointer.
LRLM_EXPORT void lrlm_operation_delete(uint64_t id);
typedef struct LrlmEvent LrlmEvent;
// take transfers one owned payload to Dart; ALWAYS call event_delete, including
// decode errors, subscriber cancellation, shutdown and obsolete operations.
LRLM_EXPORT LrlmEvent* lrlm_operation_take(uint64_t id);
LRLM_EXPORT uint64_t lrlm_event_operation_id(const LrlmEvent* event);
// 0=text, 1=complete, 2=native error, 3=cancelled, 4=backpressure.
LRLM_EXPORT int lrlm_event_kind(const LrlmEvent* event);
LRLM_EXPORT const char* lrlm_event_text(const LrlmEvent* event);
LRLM_EXPORT void lrlm_event_delete(LrlmEvent* event);
LRLM_EXPORT int64_t lrlm_live_operations(void);
LRLM_EXPORT int64_t lrlm_live_events(void);
// Pinned-runtime adapter: counts exactly the inputs consumed by Session,
// including BOS, model template, decoded image patches and audio frames.
// No inference is performed. Negative means failure; copy budget_error now.
LRLM_EXPORT int64_t lrlm_conversation_input_tokens(LiteRtLmEngine* engine,
    LiteRtLmConversation* conversation, const char* messages_json);
LRLM_EXPORT int64_t lrlm_session_input_tokens(LiteRtLmEngine* engine,
    LiteRtLmSession* session, const char* text, bool first_turn);
LRLM_EXPORT int lrlm_engine_context_tokens(LiteRtLmEngine* engine);
LRLM_EXPORT int lrlm_session_context_tokens(LiteRtLmSession* session);
LRLM_EXPORT const char* lrlm_budget_error(void);
// Native structured history (including channels). Borrowed until next call on
// this thread; Dart copies synchronously. Preface/config messages are excluded.
LRLM_EXPORT const char* lrlm_conversation_history(LiteRtLmConversation* conversation);
#ifdef __cplusplus
}
#endif
#endif
