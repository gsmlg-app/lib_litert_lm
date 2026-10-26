## 0.1.1

- Target LiteRT-LM v0.18.1 at bda624851d74be34d4e1f7fac1fc4155939539c7;
  vendor its Conversation/ModelInfo/error headers and regenerate the opaque ABI.
  The complete ARM64 bundle, all required symbols and final APK/AAB provenance
  checks passed. Android device/model acceptance remains unrun.
- Copy native borrowed callback strings inside a C++ bridge with a bounded owned
  event queue; remove asynchronous Dart callbacks over borrowed memory.
- Unify Future/Stream generation, cancellation and hierarchical close. Join native
  tasks before cleanup, reject same-session overlaps, invalidate child handles,
  and settle pending work on worker failure. Rebuild poisoned Conversations from
  completed structured history after cancellation/error.
- Add role-preserving persistent Conversations, one-shot full-history generation,
  opt-in image/audio encoders and real encoded-file processor input. Preserve
  existing Session and content entry points; raw sessions reset on cancel/error.
- Add artifact SHA256/capacity/backend discovery, model-processor/tokenizer budgets,
  explicit context-full errors and nullable native performance metrics. Restrict
  prefillChunkSize to CPU dynamic-context models. Remove whitespace-based usage.
- Validate OpenAI roles/parameters instead of silently flattening/discarding them;
  retain stateless HTTP semantics and cancel active operations on server shutdown.
- Add sanitizer/native-thread FFI regressions, fail-closed arm64 ELF/symbol/
  provenance/archive checks and opt-in Android Gemma-4-E2B capacity/media tooling.
- Pin TensorFlow's Skylib 1.9.0 before Rules Shell initialization and record the
  checksum-fixed override in native provenance; reject cached pin drift.
- Replace example placeholder media with real file inputs, add context selection
  and persistent chat/reset, and correct fake UI smoke/native-loading claims.
- No 4K/8K/16K/32K real-model tier has been verified; no 64K/128K support is claimed.

## 0.0.3

- Split GitHub release creation from standalone pub.dev publish workflows.
- Switched regular pub.dev publishing to GitHub Actions OIDC trusted publishing
  with `id-token: write`.

## 0.0.2

- Documented required Android host app manifest configuration for LiteRT-LM
  runtime libraries and large local model loading.

## 0.0.1

- Added Android-only LiteRT-LM FFI plugin package.
- Added maintainer native build script for `liblitert_lm_c.so` and the
  Android Vulkan/NPU runtime bundle.
- Added ffigen config and generated bindings for LiteRT-LM `c/engine.h`.
- Added worker-isolate Dart wrapper, streaming events, cancellation, dispose,
  and fake backend tests.
- Added lightweight OpenAI-compatible HTTP server with `/v1/models`,
  `/v1/chat/completions`, `/v1/completions`, and SSE streaming.
- Added Android example app with CPU/GPU/NPU backend selection.
- Added GitHub Actions for CI, tests, native Android bundle builds, e2e smoke
  tests, and release publishing.
