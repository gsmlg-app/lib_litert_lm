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
