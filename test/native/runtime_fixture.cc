// Controllable C ABI producer. It is NOT an inference runtime or tokenizer.
#include "c/engine.h"
#include "c/conversation.h"
#include "c/model_info.h"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
static std::atomic<int> handles{0}, started{0}, cancelled{0}, completed{0};
static std::mutex barrier_mutex;
static std::condition_variable barrier;
static bool released = false;
static thread_local std::string last_error;
struct LiteRtLmStreamChunk { const char* text; bool final; const char* error; };
struct LiteRtLmEngineSettings { int context = 4096; std::string vision, audio; };
struct LiteRtLmEngine { int context; };
struct LiteRtLmLoadedFile {};
struct LiteRtLmSamplerParams {};
struct LiteRtLmSessionConfig { int output = 256; };
struct LiteRtLmConversationConfig { std::string history; int output = 256; };
struct LiteRtLmInputData { std::string text; };
struct LiteRtLmTokenizeResult { std::vector<int> ids; };
struct LiteRtLmBenchmarkInfo { std::vector<int> prefill, decode; };
struct State {
  std::thread task;
  std::atomic<bool> stop{false};
  std::atomic<int> used{0};
  int input = 0;
  std::vector<int> prefills, decodes;
  std::string rendered;
  std::string history = "[]";
  State() { ++handles; }
  ~State() { if (task.joinable()) task.join(); --handles; }
};
struct LiteRtLmSession { State state; };
struct LiteRtLmConversation { State state; };
static int scalars(const std::string& text) {
  int count = 0;
  for (unsigned char c : text) if ((c & 0xc0) != 0x80) ++count;
  return count;
}
static int Start(State& state, bool chat, std::string input, LiteRtLmStreamCallback cb, void* data) {
  if (state.task.joinable()) state.task.join();
  state.stop = false;
  state.input = scalars(input);
  { std::lock_guard<std::mutex> lock(barrier_mutex); released = false; }
  state.task = std::thread([&, chat, input, cb, data] {
    ++started; barrier.notify_all();
    if (input.find("hold_prefill") != std::string::npos) {
      std::unique_lock<std::mutex> lock(barrier_mutex);
      barrier.wait(lock, [&] { return released || state.stop.load(); });
    }
    char text[] = "owned 中文";
    std::string json = "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"owned 中文\"}]}";
    LiteRtLmStreamChunk part{chat ? json.c_str() : text, false, nullptr};
    if (input.find("invalid_event") != std::string::npos) {
      // Valid native memory, intentionally invalid UTF-8 (raw) / JSON (chat).
      part.text = chat ? "invalid-json" : "\xc3\x28";
    }
    cb(data, &part);
    std::memset(text, 'X', sizeof(text)-1);
    json.assign(json.size(), 'X');
    if (input.find("hold_decode") != std::string::npos) {
      std::unique_lock<std::mutex> lock(barrier_mutex);
      barrier.wait(lock, [&] { return released || state.stop.load(); });
    }
    if (input.find("overflow") != std::string::npos) {
      std::string payload = chat ? "{\"content\":\"x\"}" : "x";
      part = {payload.c_str(), false, nullptr};
      for (int i = 0; i < 300; ++i) cb(data, &part);
    }
    if (state.stop) {
      char late[] = "late after cancellation";
      std::string late_json = "{\"content\":\"late after cancellation\"}";
      part = {chat ? late_json.c_str() : late, false, nullptr}; cb(data, &part);
      char error[] = "CANCELLED: fixture stopped";
      part = {nullptr, true, error}; cb(data, &part);
      std::memset(error, 'X', sizeof(error)-1);
    } else if (input.find("native_error") != std::string::npos) {
      char error[] = "INTERNAL: borrowed error preserved";
      part = {nullptr, true, error}; cb(data, &part);
      std::memset(error, 'X', sizeof(error)-1);
    } else {
      state.used += state.input + 3;
      // Each request has two prefill benchmark entries: these are chunks, not
      // separate user turns. The wrapper must sum both without old turns.
      state.prefills.push_back(state.input / 2);
      state.prefills.push_back(state.input - state.input / 2);
      state.decodes.push_back(3);
      const std::string messages = input.size() >= 2 && input.front() == '[' ? input.substr(1,input.size()-2) : input;
      if (state.history.size() > 2) state.history.pop_back(), state.history += ",";
      else state.history = "[";
      state.history += messages + ",{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"owned 中文\"}]}]";
      ++completed;
      part = {nullptr, true, nullptr}; cb(data, &part);
      cb(data, &part); // duplicate terminal
    }
  });
  return 0;
}
extern "C" {
int fixture_handles() { return handles; }
int fixture_started() { return started; }
int fixture_cancelled() { return cancelled; }
int fixture_completed() { return completed; }
int fixture_wait_started(int target) {
  std::unique_lock<std::mutex> lock(barrier_mutex);
  return barrier.wait_for(lock, std::chrono::seconds(5), [=] { return started >= target; }) ? 1 : 0;
}
void fixture_release() { std::lock_guard<std::mutex> lock(barrier_mutex); released = true; barrier.notify_all(); }
int64_t lrlm_conversation_input_tokens(LiteRtLmEngine*, LiteRtLmConversation*, const char* text) {
  // Match the production adapter's single-turn message contract. Do not let
  // this fixture hide the upstream single-turn template's array omission.
  if (!text || text[0] != '{') { last_error = "Expected message object"; return -1; }
  return scalars(text);
}
int64_t lrlm_session_input_tokens(LiteRtLmEngine*, LiteRtLmSession*, const char* text, bool) { return scalars(text); }
int lrlm_engine_context_tokens(LiteRtLmEngine* p) { return p->context; }
int lrlm_session_context_tokens(LiteRtLmSession* p) { return p->state.used; }
const char* lrlm_conversation_history(LiteRtLmConversation* p) { return p->state.history.c_str(); }
const char* lrlm_budget_error() { return "fixture budget error"; }
const char* litert_lm_get_last_error_message() { return last_error.empty() ? nullptr : last_error.c_str(); }
int litert_lm_get_last_error_code() { return 13; }
const char* litert_lm_stream_chunk_get_text(const LiteRtLmStreamChunk* p) { return p->text; }
bool litert_lm_stream_chunk_is_final(const LiteRtLmStreamChunk* p) { return p->final; }
const char* litert_lm_stream_chunk_get_error(const LiteRtLmStreamChunk* p) { return p->error; }
LiteRtLmLoadedFile* litert_lm_loaded_file_create(const char*) { return new LiteRtLmLoadedFile; }
void litert_lm_loaded_file_delete(LiteRtLmLoadedFile* p) { delete p; }
uint32_t litert_lm_loaded_file_max_context_tokens(LiteRtLmLoadedFile*) { return 32768; }
bool litert_lm_loaded_file_is_dynamic_context(LiteRtLmLoadedFile*) { return true; }
const char* litert_lm_loaded_file_min_runtime_version(LiteRtLmLoadedFile*) { return "0.18.0"; }
int32_t litert_lm_loaded_file_modality_supported_backends(LiteRtLmLoadedFile*, LiteRtLmModality, LiteRtLmBackendType* values, int32_t size) {
  if (size > 0 && values) values[0] = kLiteRtLmBackendTypeCpu;
  if (size > 1 && values) values[1] = kLiteRtLmBackendTypeGpu;
  return values ? (size < 2 ? size : 2) : 2;
}
LiteRtLmEngineSettings* litert_lm_engine_settings_create(const char*, const char*, const char* vision, const char* audio) {
  auto* p = new LiteRtLmEngineSettings; p->vision = vision ? vision : ""; p->audio = audio ? audio : ""; return p;
}
void litert_lm_engine_settings_delete(LiteRtLmEngineSettings* p) { delete p; }
void litert_lm_engine_settings_set_max_num_tokens(LiteRtLmEngineSettings* p, int value) { p->context = value; }
void litert_lm_engine_settings_enable_benchmark(LiteRtLmEngineSettings*) {}
void litert_lm_engine_settings_set_parallel_file_section_loading(LiteRtLmEngineSettings*, bool) {}
void litert_lm_engine_settings_set_prefill_chunk_size(LiteRtLmEngineSettings*, int) {}
void litert_lm_engine_settings_set_cache_dir(LiteRtLmEngineSettings*, const char*) {}
void litert_lm_engine_settings_set_litert_dispatch_lib_dir(LiteRtLmEngineSettings*, const char*) {}
LiteRtLmEngine* litert_lm_engine_create(const LiteRtLmEngineSettings* p) { ++handles; return new LiteRtLmEngine{p->context}; }
void litert_lm_engine_delete(LiteRtLmEngine* p) { --handles; delete p; }
LiteRtLmSessionConfig* litert_lm_session_config_create() { return new LiteRtLmSessionConfig; }
void litert_lm_session_config_delete(LiteRtLmSessionConfig* p) { delete p; }
void litert_lm_session_config_set_max_output_tokens(LiteRtLmSessionConfig* p, int n) { p->output = n; }
void litert_lm_session_config_set_apply_prompt_template(LiteRtLmSessionConfig*, bool) {}
void litert_lm_session_config_set_sampler_params(LiteRtLmSessionConfig*, const LiteRtLmSamplerParams*) {}
LiteRtLmSamplerParams* litert_lm_sampler_params_create(LiteRtLmSamplerType) { return new LiteRtLmSamplerParams; }
void litert_lm_sampler_params_delete(LiteRtLmSamplerParams* p) { delete p; }
void litert_lm_sampler_params_set_top_k(LiteRtLmSamplerParams*, int32_t) {}
void litert_lm_sampler_params_set_temperature(LiteRtLmSamplerParams*, float) {}
void litert_lm_sampler_params_set_seed(LiteRtLmSamplerParams*, int32_t) {}
LiteRtLmConversationConfig* litert_lm_conversation_config_create() { return new LiteRtLmConversationConfig; }
void litert_lm_conversation_config_delete(LiteRtLmConversationConfig* p) { delete p; }
void litert_lm_conversation_config_set_session_config(LiteRtLmConversationConfig* p, const LiteRtLmSessionConfig* s) { p->output = s->output; }
void litert_lm_conversation_config_set_filter_channel_content_from_kv_cache(LiteRtLmConversationConfig*, bool) {}
void litert_lm_conversation_config_set_messages(LiteRtLmConversationConfig* p, const char* value) { p->history = value; }
LiteRtLmConversation* litert_lm_conversation_create(LiteRtLmEngine*, LiteRtLmConversationConfig* config) {
  auto* p = new LiteRtLmConversation;
  if (config) p->state.used = scalars(config->history);
  return p;
}
void litert_lm_conversation_delete(LiteRtLmConversation* p) { delete p; }
void litert_lm_conversation_cancel_process(LiteRtLmConversation* p) { ++cancelled; p->state.stop = true; barrier.notify_all(); }
int litert_lm_conversation_send_message_stream(LiteRtLmConversation* p, const char* input, const char*, const LiteRtLmConversationOptionalArgs*, LiteRtLmStreamCallback cb, void* data) { return Start(p->state, true, input, cb, data); }
const char* litert_lm_conversation_render_message_to_string(LiteRtLmConversation* p, const char* input) {
  p->state.rendered = input; return p->state.rendered.c_str();
}
int litert_lm_conversation_get_token_count(LiteRtLmConversation* p) { return p->state.used; }
LiteRtLmSession* litert_lm_engine_create_session(LiteRtLmEngine*, LiteRtLmSessionConfig*) { return new LiteRtLmSession; }
void litert_lm_session_delete(LiteRtLmSession* p) { delete p; }
void litert_lm_session_cancel_process(LiteRtLmSession* p) { ++cancelled; p->state.stop = true; barrier.notify_all(); }
LiteRtLmInputData* litert_lm_input_data_create(LiteRtLmInputDataType, const void* text, size_t n) { return new LiteRtLmInputData{std::string(static_cast<const char*>(text), n)}; }
void litert_lm_input_data_delete(LiteRtLmInputData* p) { delete p; }
int litert_lm_session_generate_content_stream(LiteRtLmSession* p, const LiteRtLmInputData* const* inputs, size_t n, LiteRtLmStreamCallback cb, void* data) { return Start(p->state, false, n ? inputs[0]->text : "", cb, data); }
LiteRtLmTokenizeResult* litert_lm_engine_tokenize(LiteRtLmEngine*, const char* text) {
  auto* p = new LiteRtLmTokenizeResult;
  for (int i = 0; i < scalars(text); ++i) p->ids.push_back(i + 1);
  return p;
}
void litert_lm_tokenize_result_delete(LiteRtLmTokenizeResult* p) { delete p; }
size_t litert_lm_tokenize_result_get_num_tokens(const LiteRtLmTokenizeResult* p) { return p->ids.size(); }
const int* litert_lm_tokenize_result_get_tokens(const LiteRtLmTokenizeResult* p) { return p->ids.data(); }
LiteRtLmBenchmarkInfo* litert_lm_conversation_get_benchmark_info(LiteRtLmConversation* p) { return new LiteRtLmBenchmarkInfo{p->state.prefills, p->state.decodes}; }
LiteRtLmBenchmarkInfo* litert_lm_session_get_benchmark_info(LiteRtLmSession* p) { return new LiteRtLmBenchmarkInfo{p->state.prefills, p->state.decodes}; }
void litert_lm_benchmark_info_delete(LiteRtLmBenchmarkInfo* p) { delete p; }
int litert_lm_benchmark_info_get_num_prefill_turns(const LiteRtLmBenchmarkInfo* p) { return p->prefill.size(); }
int litert_lm_benchmark_info_get_num_decode_turns(const LiteRtLmBenchmarkInfo* p) { return p->decode.size(); }
int litert_lm_benchmark_info_get_prefill_token_count_at(const LiteRtLmBenchmarkInfo* p, int i) { return p->prefill.at(i); }
int litert_lm_benchmark_info_get_decode_token_count_at(const LiteRtLmBenchmarkInfo* p, int i) { return p->decode.at(i); }
double litert_lm_benchmark_info_get_prefill_tokens_per_sec_at(const LiteRtLmBenchmarkInfo*, int) { return 100; }
double litert_lm_benchmark_info_get_decode_tokens_per_sec_at(const LiteRtLmBenchmarkInfo*, int) { return 50; }
double litert_lm_benchmark_info_get_time_to_first_token(const LiteRtLmBenchmarkInfo*) { return .01; }
}
