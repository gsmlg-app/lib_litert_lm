# LiteRT-LM Android native build

Consumers load the maintainer bundle in `android/src/main/jniLibs/arm64-v8a/`.
Gradle does not run Bazel. The entire bundle and ABI must agree; old v0.12
binaries cannot be used with the current Conversation/bridge bindings.

## Fixed inputs

| Input | Value |
| --- | --- |
| LiteRT-LM | `v0.18.1` |
| Source commit | `bda624851d74be34d4e1f7fac1fc4155939539c7` |
| Repository | `https://github.com/google-ai-edge/LiteRT-LM.git` |
| Bazel | `7.6.1`, upstream WORKSPACE build; Bzlmod is disabled upstream |
| Android NDK | `28.2.13676358` |
| ABI/config | `arm64-v8a` / `android_arm64` |
| Accelerator selection | `vulkan,npu` by default |
| Bridge ABI | `1` |
| Core linkage | `linkstatic = True`, `--dynamic_mode=off`, `--define=litert_link_capi_so=false` |
| Linker layout | `-z max-page-size=16384`, `-z common-page-size=16384` |

`tool/build_litert_lm_android.sh` copies the bridge sources from `native/` into the pinned
checkout, adds a shared target around `//c:engine`, and exports `litert_lm_*`,
`lrlm_*` and `LiteRt*`. It also links Conversation, ModelInfo and error APIs.
The C++ model adapter intentionally depends on internal APIs from this exact
commit; upgrading the runtime requires rebuilding and rechecking the adapter.

Vendored C headers are exact copies from that source commit. Regenerate bindings:

```bash
flutter pub get
dart run ffigen --config ffigen.yaml
```

Opaque C objects remain opaque. The generated ABI includes Conversation,
ModelInfo, tokenizer, benchmark and error-reporting functions as well as the
bridge. Every generated lookup and every bridge reference is checked against the
main library's exported symbols, rather than checking two representative names.

## Build and package verification

Install Git LFS and the fixed NDK, then run from the package root:

```bash
ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/28.2.13676358" \
ABI=arm64-v8a ACCELERATORS=vulkan,npu tool/build_litert_lm_android.sh
python3 tool/verify_android_bundle.py android/src/main/jniLibs/arm64-v8a --require-provenance
(cd example && flutter build apk --release --target-platform android-arm64)
(cd example && flutter build appbundle --release --target-platform android-arm64)
python3 tool/verify_android_bundle.py example/build/app/outputs/flutter-apk/app-release.apk --require-provenance
python3 tool/verify_android_bundle.py example/build/app/outputs/bundle/release/app-release.aab --require-provenance
```

Use `BUILD_ROOT=/large/scratch/path` to put the checkout/Bazel bootstrap on a
larger disk. Preserve default release pins; overrides are development inputs and
must pass the provenance contract before publication. The build first stages the
complete output, verifies it and only then replaces the installed ABI directory.
A failed build leaves the previous bundle intact.

The bundle includes the main library, GPU libraries from the pinned upstream LFS
objects, and Google Tensor/Qualcomm/MediaTek NPU dispatch libraries built from the
pinned LiteRT dependency. Optional `NPU_VENDOR_LIB_DIRS` directories supply vendor
runtime libraries where a particular SDK/device needs them. These extra files are
also inventoried and verified. `NPU_TARGETS` / `ACCELERATORS` can select a development
subset; record the selection and do not call it the full default bundle.

`native-build.json` records source tag/commit, LiteRT dependency revision,
Bazel/NDK/ABI, accelerators, build flags, compatibility overrides, source/header/
binding hashes, and every output library hash. The verifier checks this record
against the current source. APK/AAB inventories and GNU build IDs must match the
verified source bundle after Gradle stripping.

The verifier parses ELF64 program headers directly. It rejects unreadable or
invalid files, wrong architecture, zero `PT_LOAD` segments, truncated ranges,
non-power-of-two or sub-16-KiB alignment, and incongruent load offsets/addresses.
Symbol-reader failure is fatal. Every packaged `.so`, including Flutter and
accelerator libraries, is checked. Uncompressed APK native entries also need
16-KiB ZIP data alignment; AAB layout is not installed directly, so its embedded
ELFs/inventory are checked separately from APK ZIP alignment. `--config-only`
does not establish any of these final-package or runtime properties.

## Compatibility patches and current build evidence

The pinned release's legacy WORKSPACE initializes some transitive repositories
before TensorFlow can select its required versions. The script records narrow,
reproducible compatibility patches:

- Predeclare TensorFlow's Rules CC `0.2.25` archive and initialize its
  `bazel_features`/compatibility proxy before dependent workspace loads.
- Predeclare TensorFlow's checksum-fixed Skylib `1.9.0` before Rules Shell can
  select `1.7.1`. Rules CC needs the newer `bool_flag` `scope` attribute. Cached
  patch drift or unexpected existing declarations fail rather than silently
  selecting another version. Both overrides are recorded in provenance.
- Remove one unconditional Google-only profiling dependency from LiteRT's public
  Google Tensor dispatch BUILD target. Actual profiling code is already disabled
  by `LITERT_GOOGLE_TENSOR_HAS_HOOKS`; the dispatch target remains in the bundle.
- Keep the checksum-fixed zlib archive with an official GitHub release mirror.

Earlier 2026-10-27 runs were **blocked during Bazel analysis**: Rules CC `0.2.25`
requires Skylib >=1.8.0, but Rules Shell predeclares `1.7.1`, whose `bool_flag`
lacks the `scope` attribute. The build now predeclares the pinned TensorFlow
workspace's Skylib `1.9.0`, SHA256
`3b5b49006181f5f8ff626ef8ddceaa95e9bb8ad294f7b5d7b11ea9f7ddaf8c59`.
The first follow-up full build succeeded with official Bazel `7.6.1`: all four
targets were analyzed and 4,350 actions completed in 1040.280 seconds. Both bridge
sources, including the C++ model adapter, compiled and the main shared library
linked. The complete 11-library bundle and `native-build.json` replaced the old
v0.12 outputs only after verification passed. The new upstream GPU inventory
includes `libwebgpu_dawn.so`.

Staging and installed-bundle checks passed for all 191 required C/bridge symbols
and every ARM64 library's `PT_LOAD` alignment (at least 16 KiB). No second native
repair build was needed. This is compilation and ABI evidence, not Android
loading or Gemma inference. See Android validation for final APK/AAB verification
and the separate unrun device/model acceptance gates.

## Callback ownership and control state

`NativeCallable.listener` is asynchronous: it **cannot synchronously copy**
borrowed native callback memory before the C caller returns. The production path
uses no Dart native callback trampoline. Its static C++ callback copies text and
errors inside the upstream callback, while those pointers are valid.

| Value | Owner and lifetime | Release |
| --- | --- | --- |
| Upstream stream chunk/text/error | Borrowed only during the upstream callback | Upstream; bridge never frees it |
| Bridge operation | Process-wide unique numeric ID in a shared-reference registry | Worker removes it after terminal cleanup/join |
| Queued event | Native operation queue, at most 64 entries / 1 MiB | Queue deletion or ownership transfer through `take` |
| Taken event | Dart worker, owned native payload | `lrlm_event_delete` in `finally`, including decoding failure |
| Input UTF-8 / InputData | Worker through stream-start call | Freed after v0.18.1 synchronously parses/copies inputs and schedules tasks |
| Settings/config/sampler | Worker during create call | Corresponding native delete in `finally` |
| Engine / Session / Conversation | Worker handle tables | Children stop/join before parent delete |
| Native structured history / budget error text | Borrowed synchronous getter, thread-local | Copy immediately before next getter; never posted as pointers |

The queue reserves a terminal slot and never blocks native producer threads.
Overflow discards queued text, suppresses subsequent text, requests cancellation
and reports backpressure. During generation, a delivery credit limits messages in flight to the main
isolate; paused subscriptions do not create an unbounded Dart queue.
After native final, the remaining finite queue is drained even while the
subscription is paused; the Dart controller buffers at most that bounded final
burst so native cleanup never waits for resume. Every operation gets a different ID; delayed callbacks can only find their own
registry entry. After removal they are ignored without dereferencing callback
state. A callback already executing holds a shared reference until it returns.

Worker handles move through ready, generating, cancel-requested, closing and
closed states. Future generation collects the asynchronous stream operation, so
native generation does not block the control isolate. Same-session overlaps fail
busy. Cancelling delivery and proving the producer stopped are separate steps:

1. Stop subscriber delivery and mark the operation cancelled.
2. Request native cancellation; continue draining owned payloads.
3. On native terminal, delete/join the native handle. Explicit close uses the same
   cancel/join protocol. Native queues cannot wait for the Dart event loop, so
   destructor join does not depend on a Dart callback acknowledgement.
4. Release the operation registry/queued payloads and send one terminal result.

No timeout is used as proof that native threads stopped. v0.18.1 documents
cancelled native sessions as poisoned; reconstruct Conversations from completed
structured history (including channels) for retry. Raw sessions reset. On native
error the handle is also discarded to avoid continuing unknown partial state.
Parent closure synchronously invalidates surviving Dart children. Isolate
onExit/onError fail pending requests and streams; this cannot catch native process
SIGSEGV or restore a crashed Android process.

## Model processing and budget contract

Conversation applies its model template once; its underlying Session template is
disabled. Native generation and budget rendering receive one message object,
because v0.18.1 single-turn templates omit array message bodies. Multi-message
appends rebuild completed history plus the new prefix as an explicit preface;
the last user object generates the response. Budget previews use a temporary
native Conversation and do not mutate the live history. Such batches repeat
prefill, while ordinary one-message sends retain the KV cache.

Encoded PNG/JPEG/WAV blobs are processed by the model-specific native
processor into tensor inputs; raw Session is reserved for untemplated text.
The adapter counts the same native rendered/preprocessed inputs, tokenizer/BOS,
vision patches and audio frames before scheduling inference, and adds the native
current step plus requested output reserve. It does not approximate Chinese with
whitespace or silently trim history. Decoder/metadata failures preserve native
error details. Real Gemma processor/token counts still require Android acceptance.

Benchmark entries may represent multiple prefill chunks per operation. Dart sums
only newly appended entries and computes token-weighted durations/rates. Unknown
measurements remain null. Wall TTFT and upstream decode TTFT have different
origins and are exposed separately. ResourceExhausted alone is not classified OOM.

## Test boundaries

```bash
tool/test_native.sh
python3 -m unittest discover -s test/build -v
```

The C++ test runs under ASan/UBSan and immediately overwrites borrowed buffers.
The host shared fixture runs the production worker across real FFI/native-thread
boundaries with explicit barriers, late callbacks, cancellation and allocation
counters. Its tokenizer/model metadata are deliberate fixtures. Fake Dart tests
cover API/UI/HTTP flow. Neither fixture nor the fake UI smoke is model inference.
Use [Android validation](android-validation.md) for real artifact/long-context,
media, memory, retrieval, background/foreground and cancellation evidence.
