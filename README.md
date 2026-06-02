# lib_litert_lm

Android-only Flutter FFI bindings for the LiteRT-LM C API from
`google-ai-edge/LiteRT-LM`.

The package shape is intentionally single-package:

- Dart API and ffigen bindings live under `lib/`.
- Prebuilt Android native libraries are packaged from `android/src/main/jniLibs/`.
- Consumers do not run Bazel from Gradle.

## Native Build

Maintainers build the native library first:

```bash
tool/build_litert_lm_android.sh
```

Pinned native inputs:

- LiteRT-LM tag: `v0.12.0`
- LiteRT-LM commit: `ffed38adbc33509480b5340e5173638bc20a68ff`
- Bazel: `7.6.1`
- Android NDK: `28.2.13676358`
- First ABI: `arm64-v8a`
- Output: `android/src/main/jniLibs/arm64-v8a/`
- Default accelerator bundle: `vulkan,npu`

The script patches upstream `c/BUILD` with a `cc_binary(linkshared = True)`
wrapper around `//c:engine`, exports the C API with a dynamic-list file:

```text
{
  LiteRt*;
  litert_lm_*;
};
```

The core LiteRT C API is linked statically into `liblitert_lm_c.so`
(`--dynamic_mode=off`, `linkstatic = True`, and
`--define=litert_link_capi_so=false`). Vulkan/GPU and NPU support are packaged
as runtime libraries beside the FFI wrapper. The script copies the pinned
LiteRT-LM GPU/Vulkan prebuilts, builds the configured LiteRT NPU dispatch
targets, verifies exported symbols with `llvm-nm`, and rejects every bundled
ELF below 16 KB load-segment alignment with `llvm-readobj`.

For Qualcomm or MediaTek NPU builds that require vendor runtime libraries,
maintainers can pass `NPU_VENDOR_LIB_DIRS` to copy extracted SDK `.so` files
into the same ABI bundle.

More detail is in [doc/native-build.md](doc/native-build.md).

## Dart API

```dart
final clientResult = await LiteRtLm.create();
final client = clientResult.valueOrNull;
if (client == null) {
  print(clientResult.errorOrNull);
  return;
}

final engineResult = await client.loadEngine(
  const LiteRtLmEngineConfig(modelPath: '/local/path/model.litertlm'),
);
final engine = engineResult.valueOrNull;
if (engine == null) {
  print(engineResult.errorOrNull);
  return;
}

final session = (await engine.createSession(
  params: const LiteRtLmGenerationParams(
    temperature: 0.8,
    topK: 40,
    maxTokens: 256,
  ),
))
    .valueOrNull!;

await for (final event in session.generateStream('Hello')) {
  switch (event) {
    case LiteRtLmToken(:final text):
      print(text);
    case LiteRtLmCompleted():
      break;
    case LiteRtLmFailed(:final error):
      print(error);
    case LiteRtLmCancelledEvent():
      break;
  }
}

await session.dispose();
await engine.dispose();
await client.dispose();
```

For NPU, load the model with the bundled dispatch library directory:

```dart
final engineResult = await client.loadEngine(
  const LiteRtLmEngineConfig(
    modelPath: '/local/path/model.litertlm',
    backend: 'npu',
    litertDispatchLibDir: '/data/app/.../lib/arm64',
  ),
);
```

On Android this directory is normally the app's `nativeLibraryDir`. The plugin
manifest also contributes optional GPU runtime declarations for
`libvndksupport.so` and `libOpenCL.so`.

## OpenAI-Compatible HTTP Server

The package also includes a lightweight `dart:io` server that wraps a loaded
engine and exposes a small OpenAI-compatible surface:

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/completions`
- `GET /health`

Both chat and legacy completions support `stream: true` with SSE chunks and a
final `data: [DONE]` event.

```dart
final server = LiteRtLmOpenAiServer(
  engine: engine,
  config: const LiteRtLmOpenAiServerConfig(
    modelId: 'local-litert-lm',
    apiKey: 'dev-secret', // optional
  ),
);

final bindResult = await server.bind(address: '127.0.0.1', port: 8080);
print(bindResult.valueOrNull?.uri); // http://127.0.0.1:8080
```

Example request:

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Authorization: Bearer dev-secret' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "local-litert-lm",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": true
  }'
```

Supported request fields are intentionally small: `model`, `messages`,
`prompt`, `stream`, `temperature`, `top_k`/`topK`, `max_tokens`/`maxTokens`,
`seed`, and `n=1`. Tool calls, multimodal messages, logprobs, parallel choices,
and hosted model management are not implemented.

## Model Input

Callers provide a local `.litertlm` file path. Model downloading, hosting, and
selection are intentionally outside this package. The example app uses the
platform file picker, loads the selected model, streams tokens, and supports
cancel.

## Runtime Model

All native calls are confined to one long-lived worker isolate. Public
`LiteRtLmEngine` and `LiteRtLmSession` objects are Dart proxy handles; native
`LiteRtLmEngine*` and `LiteRtLmSession*` pointers stay inside the worker isolate
and are freed exactly once on `dispose()`.

Streaming uses `NativeCallable.listener`. Native callback strings are copied to
Dart before the callback returns. Stream unsubscribe sends native cancellation
for the session.

Errors are sealed Dart values such as `LiteRtLmModelNotFound`,
`LiteRtLmOutOfMemory`, `LiteRtLmUnsupportedModel`, and
`LiteRtLmNativeInitFailure`; raw C status codes are not exposed.

## Scope

Implemented:

- Engine load from a local `.litertlm` path
- Session creation
- Streaming and non-streaming generation
- Temperature, top-K, and max-token parameters
- Cancellation and dispose
- Fake backend tests with no native library required

Out of scope for this first package:

- Model download or hosting
- Multimodal input
- Function calling

The event type is sealed and can be extended in a later breaking-version-aware
API revision for multimodal and tool/function events.
