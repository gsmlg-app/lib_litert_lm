## 0.0.1

- Added Android-only LiteRT-LM FFI plugin package.
- Added maintainer native build script for `liblitert_lm_c.so`.
- Added ffigen config and generated bindings for LiteRT-LM `c/engine.h`.
- Added worker-isolate Dart wrapper, streaming events, cancellation, dispose,
  and fake backend tests.
- Added lightweight OpenAI-compatible HTTP server with `/v1/models`,
  `/v1/chat/completions`, `/v1/completions`, and SSE streaming.
- Added minimal Android example app.
