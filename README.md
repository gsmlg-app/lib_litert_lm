# lib_litert_lm

[![pub package](https://img.shields.io/pub/v/lib_litert_lm.svg)](https://pub.dev/packages/lib_litert_lm)
[![CI](https://github.com/gsmlg-app/lib_litert_lm/actions/workflows/ci.yml/badge.svg)](https://github.com/gsmlg-app/lib_litert_lm/actions/workflows/ci.yml)
[![Tests](https://github.com/gsmlg-app/lib_litert_lm/actions/workflows/test.yml/badge.svg)](https://github.com/gsmlg-app/lib_litert_lm/actions/workflows/test.yml)
[![End-to-End](https://github.com/gsmlg-app/lib_litert_lm/actions/workflows/e2e.yml/badge.svg)](https://github.com/gsmlg-app/lib_litert_lm/actions/workflows/e2e.yml)

Android-only Flutter FFI bindings for the LiteRT-LM C API from [`google-ai-edge/LiteRT-LM`](https://github.com/google-ai-edge/LiteRT-LM).

This package provides a high-performance, responsive Dart and Flutter interface to run Large Language Models on Android devices using the official Google LiteRT-LM native runtime.

---

## Table of Contents

- [Project Structure](#project-structure)
- [Prerequisites \& Setup](#prerequisites--setup)
- [Android App Configuration](#android-app-configuration)
- [Available Models](#available-models)
- [Running Tests](#running-tests)
- [Running the Example App](#running-the-example-app)
- [Native Build](#native-build)
- [Dart API \& Worker Isolate Architecture](#dart-api--worker-isolate-architecture)
- [OpenAI-Compatible HTTP Server](#openai-compatible-http-server)
- [Error Mapping](#error-mapping)
- [Scope](#scope)
- [CI/CD Workflows](#cicd-workflows)

---

## Project Structure

The package is organized in a single-package shape for ease of integration:

```text
lib_litert_lm/
├── android/                  # Android Gradle config & prebuilt native .so libraries
│   └── src/main/jniLibs/     # Bundled CPU, Vulkan, and NPU dispatch runtimes per ABI
├── doc/                      # Deep-dive documentation
│   └── native-build.md       # Detailed guide on building native libraries
├── example/                  # Flutter demonstration app for CPU/GPU/NPU testing
├── lib/                      # Dart FFI library source code
│   ├── lib_litert_lm.dart    # Main package entrypoint exporting public APIs
│   └── src/
│       ├── backend.dart      # Common backend interface
│       ├── bindings/         # Auto-generated C API bindings (via ffigen)
│       ├── fake_backend.dart # In-memory backend for mocking and unit testing
│       ├── native_backend.dart # Production FFI implementation running in a worker isolate
│       ├── openai_server.dart  # Lightweight OpenAI-compatible HTTP server wrapper
│       └── types.dart        # Public configuration records and exception types
├── test/                     # Unit test suites using the fake backend
├── tool/                     # Developer tooling
│   └── build_litert_lm_android.sh  # Script to compile and bundle the Android C API wrapper
└── ffigen.yaml               # Flutter ffigen configuration file
```

---

## Prerequisites & Setup

Ensure you have the Flutter SDK installed on your system.

To fetch dependencies and initialize the workspace, run:

```bash
flutter pub get
```

---

## Android App Configuration

Host apps should add the LiteRT-LM runtime declarations to
`android/app/src/main/AndroidManifest.xml`. Merge these into the existing
`<application>` element rather than replacing the generated Flutter manifest
contents:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:largeHeap="true">
        <uses-native-library android:name="libvndksupport.so" android:required="false" />
        <uses-native-library android:name="libOpenCL.so" android:required="false" />
    </application>
</manifest>
```

`android:largeHeap="true"` gives large local models more room to load, while
the optional native-library declarations allow Android to expose vendor runtime
libraries such as VNDK support and OpenCL when they are present on the device.

---

## Available Models

The public model catalog maps the supported package model IDs to their
Hugging Face model pages:

| Model ID | Hugging Face model |
| --- | --- |
| `gemma-4-e2b` | [`litert-community/gemma-4-E2B-it-litert-lm`](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) |
| `gemma-4-e4b` | [`litert-community/gemma-4-E4B-it-litert-lm`](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) |

```dart
final modelConfig = liteRtLmModelConfigFor('gemma-4-e4b');
print(modelConfig?.huggingFaceModelPage);
```

---

## Running Tests

Unit tests are written using a mock/fake backend ([`FakeLiteRtLmBackend`](file:///Users/gao/Workspace/gsmlg-app/lib_litert_lm/lib/src/fake_backend.dart)), which executes completely in Dart. This means **no Android device, NDK, or native build environment is required** to run tests.

Execute all unit tests with:

```bash
flutter test
```

---

## Running the Example App

The `example` directory contains a Flutter application that demonstrates how to pick a model file, load it using a chosen backend, and generate stream responses.

To run the example app:

1. Connect an Android device or start an Android Emulator.
2. Change directory and execute:
   ```bash
   cd example
   flutter run
   ```

### Example App Features
- **Model Picker**: Use the system file picker to select a local `.litertlm` model file.
- **Backend Selector**: Toggle between **CPU**, **GPU (Vulkan)**, and **NPU** runtimes at launch.
- **NPU Directory Field**: Input the custom dispatch library directory path (usually the application's `nativeLibraryDir`) required to load Qualcomm, MediaTek, or Google Tensor NPU accelerators.
- **Streaming & Cancellation**: Start generation and stream text tokens to the UI in real-time, with option to cancel the generation mid-stream.

---

## Native Build

Maintainers build and bundle the native C libraries first. Consumers do not run Bazel from Gradle; instead, they receive prebuilt libraries located in `android/src/main/jniLibs/<abi>/`.

### Build Command

```bash
tool/build_litert_lm_android.sh
```

### Pinned Native Inputs
- **LiteRT-LM Tag**: `v0.12.0`
- **LiteRT-LM Commit**: `ffed38adbc33509480b5340e5173638bc20a68ff`
- **Bazel**: `7.6.1` (automatically bootstrapped by the script if not present)
- **Android NDK**: `28.2.13676358`
- **Primary Target ABI**: `arm64-v8a`
- **Default Accelerator Bundle**: `vulkan,npu`

### Shared Library Wrapper & Symbol Verification
The build script patches upstream `c/BUILD` to wrap the C API with a `cc_binary(linkshared = True)`. The core LiteRT C API is linked statically into `liblitert_lm_c.so` using:
- `--dynamic_mode=off`
- `linkstatic = True`
- `--define=litert_link_capi_so=false`

Only the required FFI exports (`LiteRt*` and `litert_lm_*`) are placed in the dynamic symbol table using a custom linker dynamic-list file:
```text
{
  LiteRt*;
  litert_lm_*;
};
```
The script runs `llvm-nm` to ensure critical exports are present, and validates that every bundled library complies with **Android 15+ 16 KB page-alignment** using `llvm-readobj` program headers (`PT_LOAD` segment alignment check).

For more detailed information, see [doc/native-build.md](doc/native-build.md).

---

## Dart API & Worker Isolate Architecture

To ensure the Flutter UI remains responsive (60fps/120fps) and completely free of frame drops (jank), **all native calls are confined to one long-lived background worker isolate**. 

The main UI thread interacts only with Dart proxy handles (`LiteRtLmEngine` and `LiteRtLmSession`). Data and event streams are serialized and communicated across isolates via `SendPort` and `ReceivePort`.

### Usage Example

```dart
import 'package:lib_litert_lm/lib_litert_lm.dart';

// 1. Initialize the client (loads the native FFI library)
final clientResult = await LiteRtLm.create();
final client = clientResult.valueOrNull;
if (client == null) {
  print('Init error: ${clientResult.errorOrNull}');
  return;
}

// 2. Load the LLM engine with configuration
final engineResult = await client.loadEngine(
  const LiteRtLmEngineConfig(
    modelPath: '/data/local/tmp/gemini-nano.litertlm',
    backend: 'cpu', // 'cpu', 'gpu' (Vulkan), or 'npu'
  ),
);
final engine = engineResult.valueOrNull;
if (engine == null) {
  print('Load error: ${engineResult.errorOrNull}');
  return;
}

// 3. Create a generation session with parameters
final sessionResult = await engine.createSession(
  params: const LiteRtLmGenerationParams(
    temperature: 0.7,
    topK: 40,
    maxTokens: 512,
  ),
);
final session = sessionResult.valueOrNull!;

// 4. Stream tokens in real time
final eventStream = session.generateStream('Explain quantum computing.');
await for (final event in eventStream) {
  switch (event) {
    case LiteRtLmToken(:final text):
      // Fired when a new text chunk is generated
      print('Token: $text');
    case LiteRtLmCompleted(:final text):
      // Fired when generation finishes successfully
      print('Complete generation: $text');
    case LiteRtLmFailed(:final error):
      // Fired if a generation error occurs
      print('Generation error: ${error.message}');
    case LiteRtLmCancelledEvent():
      // Fired if the session generation was explicitly canceled
      print('Generation canceled');
  }
}

// 5. Clean up resources
await session.dispose();
await engine.dispose();
await client.dispose();
```

### Loading NPU Runtimes
To load the model on an NPU accelerator, specify the backend as `'npu'` and point to the directory containing vendor dispatch libraries:

```dart
final engineResult = await client.loadEngine(
  const LiteRtLmEngineConfig(
    modelPath: '/path/to/model.litertlm',
    backend: 'npu',
    litertDispatchLibDir: '/data/app/native/lib', // App's nativeLibraryDir containing NPU .so dispatch files
  ),
);
```

---

## OpenAI-Compatible HTTP Server

The package includes `LiteRtLmOpenAiServer`, an HTTP server built on `dart:io` that exposes an OpenAI-compatible API wrapping a loaded engine. This allows local app-level integrations or testing via external developer toolchains (e.g. SDKs, playground interfaces).

### Configuration Options
Use `LiteRtLmOpenAiServerConfig` to adjust:
- `modelId` (Default: `'litert-lm-local'`): The ID representing the model.
- `apiKey` (Optional): A bearer API token required for authorization.
- `enableCors` (Default: `true`): Appends standard CORS headers to support web requests.
- `defaultParams`: Default fallback `LiteRtLmGenerationParams`.

### Exposing and Binding
```dart
final server = LiteRtLmOpenAiServer(
  engine: engine,
  config: const LiteRtLmOpenAiServerConfig(
    modelId: 'gemini-nano',
    apiKey: 'my-secret-key',
  ),
);

// Bind to local address and port
final bindResult = await server.bind(address: '127.0.0.1', port: 8080);
print('Server running at: ${server.uri}'); // http://127.0.0.1:8080
```

### Supported API Endpoints
1. `GET /v1/models`
2. `POST /v1/chat/completions` (chat history)
3. `POST /v1/completions` (legacy text generation)
4. `GET /health` (simple health-check endpoint returning `{"status": "ok"}`)

### Client Completion Example (SSE Stream)
```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Authorization: Bearer my-secret-key' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gemini-nano",
    "messages": [
      {"role": "user", "content": "How far is the Moon?"}
    ],
    "stream": true
  }'
```

---

## Error Mapping

Rather than passing raw C status codes or pointers directly, errors are structured as sealed Dart classes inheriting from `LiteRtLmFailure`.

| C Condition / Error string | Dart Exception Class | Exception Code (`.code`) |
| --- | --- | --- |
| Model path does not exist before load | `LiteRtLmModelNotFound` | `'model-not-found'` |
| Model path does not end in `.litertlm` | `LiteRtLmUnsupportedModel` | `'unsupported-model'` |
| Native initialization / memory allocation failure | `LiteRtLmOutOfMemory` | `'oom'` |
| Underlying FFI Dynamic Library load fails | `LiteRtLmNativeInitFailure` | `'native-init-failure'` |
| Generation engine failures or callback errors | `LiteRtLmGenerationFailure` | `'generation-failure'` |
| Session cancelled by user | `LiteRtLmCancelled` | `'cancelled'` |
| Methods called after engine or session is closed | `LiteRtLmDisposed` | `'disposed'` |

---

## Scope

### In Scope
- Loading `.litertlm` models from local Android filesystem paths.
- Execution via CPU, GPU (Vulkan), or NPU (Tensor, Qualcomm, MediaTek).
- Real-time token streaming and prompt-template application.
- Direct parameter adjustments (temperature, topK, maxTokens, random seed).
- Clean resource isolation in a dedicated background worker thread.
- Standardized local HTTP completion server compatibility.

### Out of Scope (First Version)
- Remote model downloading, cloud hosting, or asset extraction.
- Multimodal generations (images, audio, video).
- Function/Tool calling and structural JSON constraints.

---

## CI/CD Workflows

Continuous Integration is set up under `.github/workflows/` using GitHub Actions:

- **Lints & Unit Tests** ([`ci.yml`](file:///Users/gao/Workspace/gsmlg-app/lib_litert_lm/.github/workflows/ci.yml), [`test.yml`](file:///Users/gao/Workspace/gsmlg-app/lib_litert_lm/.github/workflows/test.yml)): Automatically validates Dart syntax, code lints (`flutter_lints`), and executes all unit tests on every pull request.
- **Native Android Build** ([`native-android.yml`](file:///Users/gao/Workspace/gsmlg-app/lib_litert_lm/.github/workflows/native-android.yml)): Builds the native `liblitert_lm_c.so` library for the designated ABIs using Bazel.
- **E2E Integration & Smoke Tests** ([`e2e.yml`](file:///Users/gao/Workspace/gsmlg-app/lib_litert_lm/.github/workflows/e2e.yml)): Spawns emulator instances to run smoke/integration tests verifying native loading.
- **Auto Release Automation** ([`release.yml`](file:///Users/gao/Workspace/gsmlg-app/lib_litert_lm/.github/workflows/release.yml)): Manages package version tagging, changelog generation, and automated uploads.
