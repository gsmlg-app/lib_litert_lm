# lib_litert_lm

[![pub package](https://img.shields.io/pub/v/lib_litert_lm.svg)](https://pub.dev/packages/lib_litert_lm)
[![CI](https://github.com/gsmlg-app/lib_litert_lm/actions/workflows/ci.yml/badge.svg)](https://github.com/gsmlg-app/lib_litert_lm/actions/workflows/ci.yml)

Android arm64 Flutter FFI bindings for [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM).
Callers supply a local `.litertlm` file. Text, image and audio messages use the
runtime's Conversation, model chat template and processors.

## Runtime and acceptance status

The source, generated ABI and bundled runtime use **v0.18.1**, commit
`bda624851d74be34d4e1f7fac1fc4155939539c7`, NDK `28.2.13676358`, Bazel `7.6.1`.
The main runtime, GPU libraries, vendor dispatch libraries, header, bindings and
bridge must be built and verified together. A v0.12 bundle is incompatible and
fails initialization; replacing only one library is unsupported.

For vendored 0.1.0 installations affected by callback lifetime crashes, follow
the [adoption and device acceptance guide](doc/upgrading-from-0.1.0.md).

The complete ARM64 bundle has compiled and passed provenance, all 191 required
C/bridge symbols and 16 KiB ELF checks. Device evidence is recorded separately
from those artifact checks.

The tracked Gemma-4-E2B validation artifact is
`gemma-4-E2B-it.litertlm` at revision
`1caa527c1e88b55f046fcd8d2b4265606680663d`, SHA256
`181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`.
Its published capacity is **32K**. Artifact metadata is recorded in
[tool/models/gemma-4-e2b.json](tool/models/gemma-4-e2b.json); model names alone do
not establish capacity or backend compatibility.

The focused native lifecycle test has passed on a physical Pixel Fold with the
pinned Gemma model in release mode, using CPU/GPU and a 4096-token configured
context.
It covers short sequential requests, cancellation/retry, active unload and reload;
the downstream application's adoption and request queue remain unverified.
The 4K/8K/16K/32K near-capacity tiers and media/performance matrix remain
unverified. Native ownership fixtures establish separate FFI safety properties.
See [Android validation](doc/android-validation.md) for the run matrix and evidence.
See [native build](doc/native-build.md) for build status and bundle gates.

## Android setup

```bash
flutter pub get
```

The plugin contributes optional native-library declarations. Hosts may merge
these into their existing `<application>` if their manifest policy requires it:

```xml
<uses-native-library android:name="libvndksupport.so" android:required="false" />
<uses-native-library android:name="libOpenCL.so" android:required="false" />
```

`largeHeap` controls the managed heap; neither it nor physical RAM establishes
native/GPU context capacity. GPU/NPU execution requires a compatible artifact,
device driver and packaged runtime. NPU vendor dispatch can additionally need
vendor SDK libraries and `litertDispatchLibDir`.

## Persistent chat

```dart
import 'package:lib_litert_lm/lib_litert_lm.dart';

final clientResult = await LiteRtLm.create();
final client = clientResult.valueOrNull!; // Handle errorOrNull in an application.
final engineResult = await client.loadEngine(const LiteRtLmEngineConfig(
  modelPath: '/data/user/0/your.app/files/gemma-4-E2B-it.litertlm',
  modelId: 'gemma-4-e2b',
  backend: 'cpu',
  maxNumTokens: 8192, // Total input + history + generated-token context.
));
final engine = engineResult.valueOrNull!;
final chatResult = await engine.createConversation(
  messages: [LiteRtLmMessage.text(role: 'system', text: 'Answer concisely.')],
  params: const LiteRtLmGenerationParams(maxTokens: 256), // Per response.
);
final chat = chatResult.valueOrNull!;
try {
  final message = LiteRtLmMessage.text(text: '请解释本地注意力。');
  final budgetResult = await chat.budget(messages: [message], outputReserve: 256);
  final budget = budgetResult.valueOrNull!;
  if (budget.requiredTokens! > budget.contextTokens) {
    // The caller chooses summarization/trimming/reset; the library never trims.
    throw StateError('Need ${budget.requiredTokens}, have ${budget.contextTokens}');
  }
  await for (final event in chat.sendStream(message)) {
    if (event is LiteRtLmToken) print(event.text);
    if (event is LiteRtLmFailed) print(event.error.message);
  }
  // Append ONLY the new message. The native conversation retains prior turns.
  final next = await chat.send(LiteRtLmMessage.text(text: 'Give an example.'));
  print(next.valueOrNull ?? next.errorOrNull);
  print((await chat.getMetrics()).valueOrNull?.toJson());
} finally {
  await chat.dispose();
  await engine.dispose();
  await client.dispose();
}
```

`engine.generateMessages(history)` is the one-shot full-history entry point.
`createConversation(messages: preface)` creates a reusable chat; each `send` or
`sendMessages` appends new messages. A batch with multiple messages rebuilds
its completed prefix as a native preface and repeats prefill; single-message
sends retain the native KV cache. This avoids the upstream single-turn renderer
ignoring array message bodies. Roles remain structured and the native model
template is applied once. Only system/user/assistant text, image and audio
content is supported; tools/video/unknown roles are rejected explicitly.

## Cancellation and ownership

Future generation collects the same asynchronous operation as Stream generation.
The control isolate can receive cancellation while native prefill/decode runs.
`cancel()` acknowledges the **request**; await the generation terminal result,
subscription cancellation, or `dispose()` for cleanup completion. A session
rejects overlapping generations with `LiteRtLmBusy`.

A static C++ callback copies borrowed native strings before returning. A bounded
queue holds at most 64 events / 1 MiB with a reserved terminal slot. Slow or
paused consumers that overflow receive `LiteRtLmBackpressure`; native producers
never wait for Dart. Stream chunks can contain several model tokens.

Unsubscription stops delivery while the worker drains and frees native payloads.
Cancellation and errors delete/join the native session before releasing operation
state. v0.18.1 marks cancelled sessions poisoned: the next Conversation request
rebuilds from completed structured history, preserving model channels and dropping
the cancelled turn. Rebuilding repeats prefill. Raw untemplated sessions restart
with an empty context after cancellation/error. Parent disposal invalidates all
children; later child `cancel`/`dispose` calls are idempotent. Worker exit/error
settles pending requests; a process-level native SIGSEGV remains process-fatal.

## Model capacity, budget and metrics

`client.inspectModel(path)` and `engine.getInfo()` report artifact SHA256,
optional model ID/revision, supported modality backends, dynamic/static capacity,
requested/effective context, runtime version/commit and initialization time.
Dynamic models default to at most 4096 tokens; request larger contexts explicitly.
Static models require their fixed artifact context. `prefillChunkSize` is accepted
only for CPU dynamic-context models; GPU does not offer equivalent chunk control.

`chat.budget` renders with the native model template and processor, counts its
actual tokenizer/BOS/image-patch/audio-frame inputs and includes committed context
and output reserve. An empty message list queries committed context with zero new
input. `engine.tokenize(text)` counts raw text only, without chat-template overhead.
Context overflow returns `LiteRtLmContextFull` with required/available counts when
known. Nothing is silently truncated. Media budgeting decodes/preprocesses input
and can be expensive; generation still performs its own native preprocessing.

`getMetrics()` reports available native prefill/decode token counts and rates,
prefill seconds, context use, backend and effective context. Prefill chunks are
summed for the current operation without recounting previous turns. Wall TTFT
starts after budget validation and ends at the first visible response chunk;
`nativeTimeToFirstTokenSeconds` is the upstream decode-first-token measure and
excludes separately measured prefill. Unavailable metrics remain null. Native
errors retain their message; only explicit allocation evidence is classified OOM.

## Images and audio

Set `visionBackend` / `audioBackend` explicitly when loading the engine. Both are
null by default so text-only engines do not initialize encoders:

```dart
final config = LiteRtLmEngineConfig(
  modelPath: modelPath,
  backend: 'cpu',
  visionBackend: 'cpu', // Must be supported by this exact artifact.
  audioBackend: 'cpu',
);
final message = LiteRtLmMessage(role: 'user', contents: [
  LiteRtLmContent.image(await File(imagePath).readAsBytes()),
  const LiteRtLmContent.text('Describe the image.'),
]);
```

Import `dart:io` for the file example. Inputs are encoded **PNG/JPEG** or **WAV**
files, 1 byte to 32 MiB each, not raw pixel/PCM buffers. The model processor
performs native decoding, resampling/patch extraction and tensor preparation;
its format, duration and resolution limits can return native validation errors.
Disabled encoders and artifact/backend mismatches return `LiteRtLmUnsupported`.
Damaged input returns a failure with native details. Legacy imageEnd/audioEnd
markers remain accepted immediately after their matching content; processors
insert native delimiters. The example picks real files and validates signatures.

## OpenAI-compatible adapter

`LiteRtLmOpenAiServer(engine: engine)` exposes `/health`, `/v1/models`,
`/v1/chat/completions`, and `/v1/completions`. Chat messages use the same native
Conversation path; they are not flattened into `SYSTEM: / USER:` text. HTTP is
stateless: each request prefills its supplied full history. There is no implicit
global chat or cross-request cache. Use the Dart Conversation for persistent chat.

The adapter accepts supported text roles/content and the documented sampling
subset; unsupported tool/media/unknown parameters return explicit errors.
Usage comes from real native metrics, with null for unavailable values, never
whitespace counts. Streaming disconnect cancels/cleans its operation; immediate
non-stream peer-disconnect cancellation is not guaranteed by `dart:io`'s buffered
response transport. Server shutdown cancels all registered active operations.

## Verification and delivery

| Check | Purpose |
| --- | --- |
| Fake backend unit/widget tests | Public API, HTTP validation and UI control flow |
| `integration_test/app_e2e_test.dart` | UI smoke using fake backend; no native-loading claim |
| `tool/test_native.sh` | ASan/UBSan C++ ownership test plus threaded host FFI production-worker fixture |
| `python3 -m unittest discover -s test/build -v` | Fail-closed ELF, symbols/provenance, archive and device-tool regressions |
| `integration_test/native_model_test.dart` | Opt-in Android real-model capacity/retrieval/cancel/media tests |

```bash
dart format --output=none --set-exit-if-changed lib test example/lib example/test example/integration_test
flutter analyze
tool/test_native.sh
flutter test
(cd example && flutter test)
python3 -m unittest discover -s test/build -v
```

[Native build instructions](doc/native-build.md) cover generating the whole bundle,
checking all Dart/bridge symbols, 16 KiB ELF/ZIP alignment and actual APK/AAB
packaging. CI and publish workflows require matching `native-build.json` provenance
and package checks; `flutter build apk --config-only` is only a configuration check.
Release rebuilds the native bundle by default. Explicit `rebuild_native=false`
reuses a committed bundle only after the same mandatory provenance and package
checks; see the [release instructions](doc/native-build.md#release-an-already-built-bundle).
The example release signing configuration uses the Android debug key; its artifacts
are validation/demo outputs. Publish workflows do not establish device inference
or long-context acceptance and must not advertise unrun tiers as verified.
