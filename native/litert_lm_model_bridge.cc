// Copyright 2026. Licensed under the Apache License, Version 2.0.
// Compiled ONLY against the pinned v0.18.1 runtime. This adapter reuses the
// model's processor and Session preprocessing, not a Dart token approximation.
#include "litert_lm_bridge.h"
#include "c/engine_internal.h"
#include "c/conversation_internal.h"
#include "runtime/core/session_utils.h"
#include "runtime/conversation/model_data_processor/model_data_processor_factory.h"
#include <limits>
#include <string>
#include <variant>
#include <vector>

namespace {
thread_local std::string budget_error;
thread_local std::string history_json;
using namespace litert::lm;
absl::StatusOr<int64_t> CountPrepared(Engine& engine,
    const SessionConfig& config, const std::vector<InputData>& input, bool first) {
  // Engine exposes a const tokenizer but Session's own preprocessing API takes
  // a mutable reference to the same tokenizer (its native implementation does
  // the same). No tokenizer state is replaced or guessed here.
  auto& tokenizer = const_cast<litert::support::Tokenizer&>(engine.GetTokenizer());
  ABSL_ASSIGN_OR_RETURN(auto templated,
      ApplyPromptTemplates(input, ContentType::kNA, config, tokenizer, first));
  ABSL_ASSIGN_OR_RETURN(auto prepared,
      PreprocessContents(templated, config, tokenizer, std::nullopt));
  int64_t total = 0;
  for (const auto& part : prepared) {
    if (const auto* text = std::get_if<InputText>(&part)) {
      ABSL_ASSIGN_OR_RETURN(const auto* tensor, text->GetPreprocessedTextTensor());
      ABSL_ASSIGN_OR_RETURN(auto ids, litert::support::Tokenizer::TensorBufferToTokenIds(*tensor));
      if (ids.size() != 1) return absl::InvalidArgumentError("Token budget requires batch size one");
      total += ids.front().size();
    } else if (const auto* image = std::get_if<InputImage>(&part)) {
      ABSL_ASSIGN_OR_RETURN(auto properties, engine.GetVisionExecutorProperties());
      int count = properties.num_tokens_per_image;
      // Identical footprint rule to v0.18.1 runtime/core/cached_session.cc
      // GetImageHash: model-derived active patch count / shrink factor.
      if (properties.patch_num_shrink_factor.has_value() && image->IsTensorBufferMap()) {
        ABSL_ASSIGN_OR_RETURN(const auto* tensors, image->GetPreprocessedImageTensorMap());
        const auto it = tensors->find("positions_xy");
        if (it != tensors->end()) {
          LITERT_ASSIGN_OR_RETURN(auto type, it->second.TensorType());
          auto dims = type.Layout().Dimensions();
          const int shrink = *properties.patch_num_shrink_factor;
          if (shrink <= 0) return absl::InvalidArgumentError("Invalid vision shrink factor");
          if (dims.size() >= 2) count = (dims[1] + shrink - 1) / shrink;
        }
      }
      if (count < 0) return absl::InvalidArgumentError("Invalid vision token count");
      total += count;
    } else if (const auto* audio = std::get_if<InputAudio>(&part)) {
      ABSL_ASSIGN_OR_RETURN(auto properties, engine.GetAudioExecutorProperties());
      ABSL_ASSIGN_OR_RETURN(const auto* tensor, audio->GetPreprocessedAudioTensor());
      LITERT_ASSIGN_OR_RETURN(auto type, tensor->TensorType());
      auto dims = type.Layout().Dimensions();
      if (dims.size() < 2 || properties.audio_shrink_factor <= 0 || dims[dims.size()-2] <= 0) {
        return absl::InvalidArgumentError("Invalid processed audio layout or shrink factor");
      }
      const int64_t frames = dims[dims.size()-2];
      total += (frames + properties.audio_shrink_factor - 1) / properties.audio_shrink_factor;
    } else if (std::holds_alternative<InputImageEnd>(part) ||
               std::holds_alternative<InputAudioEnd>(part)) {
      ++total;
    } else { return absl::UnimplementedError("Unsupported model input in token budget"); }
    if (total > std::numeric_limits<int>::max()) return absl::OutOfRangeError("Input token count overflow");
  }
  return total;
}
absl::StatusOr<int64_t> CountConversation(LiteRtLmEngine* c_engine,
    LiteRtLmConversation* c_conversation, const char* text) {
  if (!c_engine || !c_conversation || !text) return absl::InvalidArgumentError("Invalid budget handles");
  auto& engine = *c_engine->engine;
  auto& conversation = *c_conversation->conversation;
  const auto& config = conversation.GetConfig();
  const auto& session_config = config.GetSessionConfig();
  auto message = nlohmann::ordered_json::parse(text, nullptr, false);
  if (message.is_discarded()) return absl::InvalidArgumentError("Invalid message JSON");
  if (!message.is_object()) return absl::InvalidArgumentError("Token budget requires a single message object; put batch history in the preface");
  ABSL_ASSIGN_OR_RETURN(auto rendered, conversation.RenderMessageIntoString(message, OptionalArgs()));
  ABSL_ASSIGN_OR_RETURN(auto processor, CreateModelDataProcessor(
      config.GetProcessorConfig(), config.GetPreface(), &engine.GetTokenizer(),
      session_config.GetStopTokenIds(), false));
  bool history_empty = true;
  conversation.AccessHistory([&](const std::vector<Message>& history) { history_empty = history.empty(); });
  nlohmann::ordered_json messages = nlohmann::ordered_json::array();
  if (history_empty && !config.prefill_preface_on_init()) {
    const auto& preface = std::get<JsonPreface>(config.GetPreface());
    if (preface.messages.is_array()) messages = preface.messages;
    else if (!preface.messages.is_null()) messages.push_back(preface.messages);
  }
  if (message.is_array()) for (const auto& msg : message) messages.push_back(msg);
  else messages.push_back(message);
  ABSL_ASSIGN_OR_RETURN(auto inputs, processor->ToInputDataVector(rendered, messages, std::monostate()));
  ABSL_ASSIGN_OR_RETURN(auto used, conversation.GetTokenCount());
  return CountPrepared(engine, session_config, inputs, used == 0);
}
int64_t Extract(absl::StatusOr<int64_t> result) {
  if (!result.ok()) { budget_error = result.status().ToString(); return -1; }
  budget_error.clear(); return *result;
}
}
extern "C" {
int64_t lrlm_conversation_input_tokens(LiteRtLmEngine* engine,
    LiteRtLmConversation* conversation, const char* text) {
  return Extract(CountConversation(engine, conversation, text));
}
int64_t lrlm_session_input_tokens(LiteRtLmEngine* engine,
    LiteRtLmSession* session, const char* text, bool first) {
  if (!engine || !session || !text) { budget_error = "Invalid raw token budget input"; return -1; }
  std::vector<InputData> inputs;
  inputs.emplace_back(InputText(std::string(text)));
  return Extract(CountPrepared(*engine->engine,
      session->session->GetSessionConfig(), inputs, first));
}
int lrlm_engine_context_tokens(LiteRtLmEngine* engine) {
  return engine ? engine->engine->GetEngineSettings().GetMainExecutorSettings().GetMaxNumTokens() : 0;
}
int lrlm_session_context_tokens(LiteRtLmSession* session) {
  if (!session) { budget_error = "Invalid session context input"; return -1; }
  auto count = session->session->GetCurrentStep();
  if (!count.ok()) { budget_error = count.status().ToString(); return -1; }
  return *count;
}
const char* lrlm_budget_error() { return budget_error.c_str(); }
const char* lrlm_conversation_history(LiteRtLmConversation* conversation) {
  if (!conversation) return nullptr;
  conversation->conversation->AccessHistory([](const std::vector<Message>& history) {
    history_json = nlohmann::ordered_json(history).dump();
  });
  return history_json.c_str();
}
}
