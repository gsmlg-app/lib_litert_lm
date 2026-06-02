# LiteRT-LM Android Native Build

This package bundles a maintainer-built LiteRT-LM C API shared object for
Android. Consumers do not run Bazel from Gradle; they receive the prebuilt
library under `android/src/main/jniLibs/<abi>/`.

## Pinned Inputs

- LiteRT-LM repository: `https://github.com/google-ai-edge/LiteRT-LM.git`
- LiteRT-LM tag: `v0.12.0`
- LiteRT-LM commit: `ffed38adbc33509480b5340e5173638bc20a68ff`
- Bazel: `7.6.1` from upstream `.bazelversion`
- Android NDK: `27.0.12077973`
- First supported ABI: `arm64-v8a`
- Output library: `android/src/main/jniLibs/arm64-v8a/liblitert_lm_c.so`

## Shared-Library Wrapper

LiteRT-LM exposes the C API as the Bazel `cc_library` target `//c:engine`.
There is no upstream shared-library target. The maintainer script patches the
checked-out source tree by adding this target to `c/BUILD`:

```python
cc_binary(
    name = "liblitert_lm_c.so",
    additional_linker_inputs = [
        ":litert_lm_c_api.lds",
    ],
    linkopts = [
        "-Wl,--dynamic-list,$(location :litert_lm_c_api.lds)",
        "-Wl,-z,max-page-size=16384",
        "-Wl,-z,common-page-size=16384",
    ],
    linkshared = True,
    linkstatic = True,
    visibility = ["//visibility:public"],
    deps = [
        ":engine",
    ],
)
```

The dynamic list is:

```text
{
  LiteRt*;
  litert_lm_*;
};
```

This keeps the C API names in the dynamic symbol table for Dart FFI lookup.
The script then verifies that at least `litert_lm_engine_create` and
`litert_lm_session_generate_content_stream` are exported.

## LiteRt Linkage Choice

This package uses static linkage for LiteRT inside `liblitert_lm_c.so`:

- `--config=android_arm64` already sets Android `--dynamic_mode=off` upstream.
- The wrapper target uses `linkstatic = True`.
- The build command passes `--define=litert_link_capi_so=false`.

That makes the Flutter package ship one self-contained native library per ABI.
If a future build chooses dynamic LiteRt C API linkage, `libLiteRt.so` must be
bundled beside `liblitert_lm_c.so` and loaded before the LiteRT-LM library.

## Build Command

Run this from the package root:

```bash
tool/build_litert_lm_android.sh
```

Useful overrides:

```bash
ANDROID_NDK_HOME=/path/to/android-ndk-r27 \
ABI=arm64-v8a \
tool/build_litert_lm_android.sh
```

The script:

1. Clones the pinned LiteRT-LM source with `GIT_LFS_SKIP_SMUDGE=1`.
2. Bootstraps Bazel `7.6.1` if `bazelisk` or matching `bazel` is unavailable.
3. Builds `//c:liblitert_lm_c.so` with `--config=android_arm64`.
4. Copies the result into `android/src/main/jniLibs/arm64-v8a/`.
5. Runs exported-symbol verification with NDK `llvm-nm`.
6. Runs Android 15+ page alignment verification with NDK `llvm-readobj`.

## Page Alignment

Android 15+ devices can use 16 KB pages. The wrapper target passes:

```text
-Wl,-z,max-page-size=16384
-Wl,-z,common-page-size=16384
```

The script rejects the output if any `PT_LOAD` segment reports alignment below
`0x4000`.

## Dart FFI Ownership Model

All native calls run on one long-lived worker isolate. The UI isolate receives
small Dart values and stream events over ports; it never owns native pointers.

| Native value | Allocator | Owner | Free operation | Dart rule |
| --- | --- | --- | --- | --- |
| `LiteRtLmEngineSettings*` | `litert_lm_engine_settings_create` | Worker isolate during engine load | `litert_lm_engine_settings_delete` | Always freed after `litert_lm_engine_create`, success or failure |
| `LiteRtLmEngine*` | `litert_lm_engine_create` | Worker isolate `Engine` handle table | `litert_lm_engine_delete` | Public `LiteRtLmEngine.dispose()` sends one dispose command and guards double dispose |
| `LiteRtLmSessionConfig*` | `litert_lm_session_config_create` | Worker isolate during session creation | `litert_lm_session_config_delete` | Always freed after `litert_lm_engine_create_session`, success or failure |
| `LiteRtLmSession*` | `litert_lm_engine_create_session` | Worker isolate `Session` handle table | `litert_lm_session_delete` | Public `LiteRtLmSession.dispose()` sends one dispose command and guards use after dispose |
| Prompt UTF-8 buffer | Dart worker isolate via `package:ffi` allocator | Worker isolate for call duration | allocator `free` | Allocated before the native call, freed in `finally` after prefill/generate starts |
| `LiteRtLmInputData[]` | Dart worker isolate via `package:ffi` allocator | Worker isolate for call duration | allocator `free` | The text buffer outlives the native call that receives the input array |
| `LiteRtLmResponses*` | Native `litert_lm_session_generate_content` | Worker isolate during non-streaming generation | `litert_lm_responses_delete` | Copy response text to Dart before deleting the responses object |
| `const char*` from `litert_lm_responses_get_response_text_at` | Native responses object | Borrowed only | Freed by `litert_lm_responses_delete` | Copy immediately with UTF-8 conversion; never free directly |
| Stream callback `chunk` | Native stream implementation | Borrowed for callback duration | Native implementation | `NativeCallable.listener` copies chunk to Dart synchronously before returning |
| Stream callback `error_msg` | Native stream implementation | Borrowed for callback duration | Native implementation | Copy to a sealed Dart error value before returning |
| `NativeCallable` callback trampoline | Dart worker isolate | Active stream operation | `NativeCallable.close` | Closed on final/error stream event or cancellation |

The current C callback strings are borrowed, not caller-freed. If LiteRT-LM
adds native-allocated strings in a later C API, the wrapper must copy them and
call the matching native delete/free function in the worker isolate.

## Error Mapping

The public Dart API returns sealed result/error values instead of raw native
codes.

| Native condition | Dart error |
| --- | --- |
| Model path does not exist before native load | `LiteRtLmModelNotFound` |
| Model path does not end in `.litertlm` | `LiteRtLmUnsupportedModel` |
| `DynamicLibrary.open` or symbol lookup fails | `LiteRtLmNativeInitFailure` |
| Native create function returns `NULL` | `LiteRtLmNativeInitFailure`, or `LiteRtLmOutOfMemory` if the native message indicates OOM |
| Native status function returns non-zero | `LiteRtLmNativeInitFailure` for setup or `LiteRtLmGenerationFailure` for generation |
| Stream callback receives `error_msg` | `LiteRtLmGenerationFailure`, or `LiteRtLmOutOfMemory`/`LiteRtLmUnsupportedModel` by message classification |
| Public handle used after `dispose()` | `LiteRtLmDisposed` |
| Stream unsubscribe or explicit cancel | `LiteRtLmCancelled` event, followed by native session cancellation |

Raw C status codes are intentionally not exposed.

## Out of Scope

The Dart API is shaped so more event types can be added later, but this first
package does not implement model download/hosting, multimodal generation, or
function calling. Callers provide a local `.litertlm` path.
