# Upgrading a bundled 0.1.0 installation

[Issue #3](https://github.com/gsmlg-app/lib_litert_lm/issues/3) reports
`Callback invoked after it has been deleted` in a downstream application's
bundled 0.1.0 on a Pixel Fold. The callback ownership repair shipped in 0.1.1
and is included in subsequent versions. This report does not establish a crash
in the current package.

Version 0.1.2 also fixes a generation blocker found while verifying adoption:
the v0.18.1 CPU sampler accepts `TOP_P`, while the wrapper selected `TOP_K`.
The wrapper now uses `TOP_P` with `p=1`, retaining the requested top-k,
temperature, and seed. This also supports the runtime's CPU sampling fallback
for GPU engines. Adopt 0.1.3 or newer from pub.dev. The 0.1.2 GitHub release
contains the same runtime correction, but its pub.dev upload failed because
publishing credentials expired during the build; 0.1.3 corrects that workflow.

## Adopt the complete package

Update the dependency to the new release as a unit. For a vendored workspace,
replace the package sources, dependencies, generated bindings, native bridge,
vendored headers, and the entire `android/src/main/jniLibs/arm64-v8a/` bundle,
including `native-build.json`, from the same release. Resolve the workspace
dependencies afterward. Preserve the application's models and user data.

Do not pair new Dart sources with the old 0.1.0 JNI libraries. The callback bridge
and LiteRT-LM v0.18.1 ABI are required together. The full bundle contains 11
shared libraries; retaining only the main library omits accelerator dependencies.

From the adopted package directory, verify the bundle:

```bash
python3 tool/verify_android_bundle.py android/src/main/jniLibs/arm64-v8a --require-provenance
```

Build the downstream application's release APK and verify its actual native
contents with the same tool. Successful source adoption or APK installation
alone does not establish inference safety.

## Await native cleanup

Generation Futures and Streams use owned payloads and a static native callback.
`cancel()` acknowledges a cancellation request. Await the generation's terminal
result, subscription cancellation, or `dispose()` before treating cleanup as
complete. Native terminal/join acknowledgement determines resource release;
elapsed time is not proof of completion.

The library rejects overlapping requests on the same conversation with
`LiteRtLmBusy`. An application that offers FIFO scheduling owns that queue,
including removing queued requests before they reach native inference. The
package does not implement the downstream chat scheduler.

## Verify the package on a device

`example/integration_test/native_lifecycle_test.dart` uses the real native
backend and the pinned Gemma E2B artifact. It alternates six Future/Stream
requests between two conversations, cancels during observed decode, tests
subscription cancellation and retry, unloads an engine with active generation,
then reloads the model and generates again. A missing `MODEL_PATH` skips the test
and provides no device evidence.

After staging the pinned model in the example application's private storage,
run from `example/`:

```bash
flutter test --no-pub --no-uninstall integration_test/native_lifecycle_test.dart \
  -d YOUR_EXACT_ADB_SERIAL \
  --dart-define=MODEL_PATH=/absolute/device/private/path/gemma-4-E2B-it.litertlm \
  --dart-define=BACKEND=cpu
```

Repeat with `BACKEND=gpu` when that backend is used by the application. This
command runs a debug integration build. A release-mode test requires building
the same entry point with `flutter build apk --release`, installing it while
preserving the staged model, launching its activity, and collecting its current
app-UID-filtered logcat. Only a complete current `LRLM_LIFECYCLE` sequence ending
in `scenario: passed`, after client disposal, establishes completion. Keep the
APK hash, bundle-verifier output, device identity, model hash, and raw logs.

## Downstream acceptance remains required

On the same Pixel Fold and existing model, verify the actual adopting app:

- Two local conversations serviced in FIFO order.
- Repeated completion followed by another request.
- Cancellation of an active request and removal of a queued request.
- Cancellation followed by retry, and model unload with active work.
- Existing models and user data preserved across the update.

Package tests do not establish that the downstream app adopted the release or
that its queue works. Keep #3 open until those downstream results are recorded.
Long-context, multimodal, and background/foreground checks are independent of
this focused callback-lifecycle test; see [Android validation](android-validation.md).
