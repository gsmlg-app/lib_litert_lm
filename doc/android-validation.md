# Android native model validation

`tool/android_validate.py` plans or runs the real-model integration harness at
`example/integration_test/native_model_test.dart`. It uses Python's standard
library. The runner does not use the Dart fake backend.

A plan, host unit tests, APK configuration, or successful model load does not
prove model inference or context capacity. No Android device was connected when
this collector was implemented. Device execution and measurements remain open.
A fresh native bundle must also be available; the collector's Flutter APK build
consumes existing JNI libraries and does not build LiteRT-LM itself. See
[native-build.md](native-build.md) for the separate native build and verification
requirements.

## Exact model and runtime pin

The collector validates `tool/models/gemma-4-e2b.json` against these identities;
changing the manifest alone cannot silently change the benchmark:

| Field | Required value |
| --- | --- |
| Model | `gemma-4-e2b` |
| Repository | `litert-community/gemma-4-E2B-it-litert-lm` |
| Revision | `1caa527c1e88b55f046fcd8d2b4265606680663d` |
| Filename | `gemma-4-E2B-it.litertlm` |
| Bytes | `2588147712` |
| SHA-256 | `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c` |
| Declared maximum context | `32768` tokens |
| Runtime | `v0.18.1` |
| Runtime commit | `bda624851d74be34d4e1f7fac1fc4155939539c7` |

The artifact URL is pinned to that revision:

```text
https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/1caa527c1e88b55f046fcd8d2b4265606680663d/gemma-4-E2B-it.litertlm
```

Repository metadata declares the maximum context. Only a successful native
near-capacity/retrieval run provides evidence for an individual tier.
The runner verifies the local file's size and SHA-256, streams the binary into
app-private storage, and verifies its SHA-256 again on the device before rename.
It records each built APK's hash. It does not replace the separate native bundle
provenance verifier or establish production signing/release readiness.

## Plan without an SDK or device

Run from the repository root:

```bash
python3 tool/android_validate.py --plan
```

This prints JSON for all eight combinations of CPU/GPU and
4096/8192/16384/32768 tokens. It invokes neither adb nor Flutter, installs nothing,
and does not create an output directory. Without `--model`, host hashing is
explicitly pending. The plan contains placeholders for the serial and the actual
application-private directory; `--run` resolves them before execution.

Validate a downloaded model while planning a subset:

```bash
python3 tool/android_validate.py --plan \
  --model /absolute/path/gemma-4-E2B-it.litertlm \
  --backends cpu gpu --contexts 4K 8K
```

Optional `--model-image /absolute/path/example.png` and
`--model-audio /absolute/path/example.wav` validate real input files and include
`MODEL_IMAGE_PATH` / `MODEL_AUDIO_PATH` definitions in the plan. PNG/JPEG images
and RIFF/WAVE audio are accepted by signature; native decoding and model modality
support are tested by the harness, not by the signature check.

## Run on an explicit ARM64 Android device

Prerequisites are adb, Flutter/Android build tools, resolved example dependencies,
a fresh verified ARM64 native bundle, a connected/authorized device reporting
`arm64-v8a`, the exact pinned local model, and sufficient device storage for the
model plus temporary upload/APK data. Do not run concurrent collectors against
one checkout/device: Flutter build outputs and the application are shared.

```bash
adb devices -l
python3 tool/android_validate.py --run \
  --device YOUR_EXACT_ADB_SERIAL \
  --model /absolute/path/gemma-4-E2B-it.litertlm \
  --backends cpu gpu --contexts 4K 8K 16K 32K \
  --output build/android-validation/device-run-001
```

The output directory must be new. No device is selected automatically. An
incompatible architecture, missing native library, non-debuggable installation,
failed `run-as`, hash mismatch, build failure, or unavailable tool stops the
respective run and preserves its available evidence. The runner does not root
the device, modify permissions, clear application data, or bypass model checks.

The runner performs these steps:

1. Record Android model/manufacturer, raw SoC/platform properties, ABI list,
   Android release/API, build fingerprint, and `/proc/meminfo` RAM. Empty or
   inaccessible fields remain null. Emulator properties are retained; an
   emulator must not be described as a physical device.
2. Build a debug ARM64 integration APK, then install with `adb install -r -t`.
   Verify the source's actual application ID is
   `dev.gsmlg.litertlm.example`. Resolve its private directory using
   `adb shell -T run-as dev.gsmlg.litertlm.example pwd`; no Android user-0 path is
   assumed.
3. Stream the model through binary stdin to a uniquely named temporary file under
   `files/lrlm-validation/<sha-prefix>/`. Use app-UID `sha256sum`, then rename the
   verified upload. An already matching device file may be reused. Optional media
   files are staged and hashed in the same way. The runner removes only its own
   unfinished upload and retains verified files for subsequent runs.
4. Execute this command shape for each requested backend/context pair, from
   `example/`, substituting the actual serial and private paths:

   ```text
   flutter test --no-pub --no-uninstall integration_test/native_model_test.dart -d SERIAL --dart-define=MODEL_PATH=PRIVATE_MODEL_PATH --dart-define=BACKEND=cpu --dart-define=CONTEXT=4096
   ```

   `--no-uninstall` preserves staged application data between runs. The Flutter
   tool builds the integration target with the requested defines. Optional media
   add `--dart-define=MODEL_IMAGE_PATH=PRIVATE_IMAGE_PATH` and/or
   `--dart-define=MODEL_AUDIO_PATH=PRIVATE_AUDIO_PATH`.
5. Concurrently collect app-UID-filtered logcat and memory samples. Finish or time
   out each Flutter command, stop only the collector's own processes/sampler, and
   retain the raw logs and parsed results.

`--adb` and `--flutter` accept executable paths. `--sample-seconds` defaults to
1 second between completed sampling rounds; adb overhead makes actual sample
spacing variable. `--timeout-seconds` defaults to 3000 seconds per Flutter build
or test command; the harness also has its own timeout. A timeout is a failure,
not a successful cancellation result. A failed tier is retained while independent
requested tiers can still run. Bootstrap/device/deployment blockers stop the
matrix because its prerequisites are missing.

## Evidence files and interpretation

The output root contains `plan.json`, `validation.json`, and `commands.jsonl`.
The command journal preserves arguments, exit codes, raw captured stdout/stderr,
and timestamps for setup and sampling commands. `bootstrap/` contains the first
APK build's stdout/stderr.

Each `cpu-4096`, `gpu-8192`, etc. directory contains:

| File | Evidence |
| --- | --- |
| `stdout.log`, `stderr.log` | Raw Flutter integration output |
| `logcat.log`, `logcat-stderr.log` | Raw app-UID logcat and collector errors |
| `reports.json` | Deduplicated `LRLM_REPORT` objects from stdout/logcat |
| `result.json` | Command/exit/timeout, automated report evaluation, APK identity and sampling summary |
| `memory-samples.jsonl` | Timestamps, process IDs, parsed counters, raw file references and query exit codes |
| `memory/*.meminfo.txt` | Raw `dumpsys meminfo -d APP_ID` |
| `memory/*.proc-*.status.txt` | Raw app-UID `/proc/PID/status` queries |
| `sampler-error.json` | Present only if the host sampling worker failed |

Automatic evaluation uses stdout reports from that exact Flutter command.
Logcat reports are retained for diagnosis but cannot substitute historical
records for a missing current report. UID filtering avoids capturing unrelated
applications' logs; it does not collect every system/LMK event. Inspect logcat
exit status and `logcatActiveAtEnd` before claiming complete log coverage.

Counter names state their source: dumpsys total PSS, native-heap PSS, graphics
PSS, RSS and swap PSS, plus `/proc` RSS and swap. They are reported in KiB.
Missing/OEM-specific fields and permission-denied queries remain null, with raw
output retained. Zero is preserved only when explicitly reported. Graphics PSS
is Android's reported category, not a measurement of all device GPU memory.
The sampler includes Flutter build/startup and both engine phases; its maxima
are observed samples, not continuous native or whole-device peaks. Per-process
RSS is not summed across processes because shared pages would be double-counted.
Sampling itself adds adb/dumpsys overhead. Native TTFT/prefill/decode metrics
remain exactly those emitted by the harness; no whitespace token estimates,
replacement timings, or unavailable native counters are invented.

`cold_engine` means a newly created engine. Neither this label nor the second
`warm_disk_cache` phase proves cold/warm OS page-cache state. Existing runtime
cache files can also survive earlier runs. The runner does not drop system
caches or reboot the device and always records `osPageCacheColdProven: false`.
Do not describe engine-initialization results as cold-storage measurements.

An automated pass requires current reports for all three retrieval positions in
both engine phases, correct pinned model/runtime/effective-context identity,
exact budgets reaching at least 97% of the selected context, cancellation/reuse
outcomes, decode-phase observation, and the multi-turn context-full boundary.
Flutter exit zero with a skipped test or missing reports is incomplete.
Media rows retain `passed`, `not_run_no_file`, or `unsupported_by_artifact`;
unsupported/missing media is not multimodal acceptance.

Native prefill-kernel cancellation remains `pending_native_trace`. A cancellation
requested before the first token can validate cancellation/reuse, but absence of
a token cannot locate execution inside native prefill. Manual
background/foreground lifecycle acceptance also remains `pending`. Consequently,
exit zero and `automated_passed_native_trace_and_manual_pending` describe only
the automated subset. Full acceptance additionally requires linked native tracing
and an actual device background/foreground test, with device/model/runtime,
backend/context, observations and raw evidence recorded separately.

## Host checks

```bash
python3 -m unittest discover -s test/build -p test_android_validate.py
python3 tool/android_validate.py --plan --adb /nonexistent/adb
```

These validate pin checking, command construction, report/memory parsing,
timeout cleanup and planning. They do not build an APK or execute inference.


## Local verification record: 2026-10-27

No Android device was listed by `adb devices -l`; no model was downloaded or
inference run. Verified context tiers and measured device performance are empty.
The host used Flutter 3.47.8 / Dart 3.13.7 and NDK 28.2.13676358.

| Executed check | Result / limit |
| --- | --- |
| `tool/test_native.sh` | ASan/UBSan bridge checks and 16 threaded production-worker FFI tests passed; fixture is not Gemma inference |
| Package `flutter test --no-pub` | 42 tests passed, including the 16 native FFI cases |
| Example `flutter test --no-pub` | 7 widget/control-flow tests passed |
| UI smoke on `flutter-tester` | 1 fake-backend integration test passed; no native-loading evidence |
| Python build/device-tool regressions | 51 tests passed |
| `flutter analyze`, Dart formatting and binding regeneration comparison | Passed |
| Full native bundle build | Blocked during dependency analysis by Rules CC / Skylib conflict; see native-build.md |
| Actual release APK | Built, 71.2 MB; existing debug signing configuration and old JNI bundle |
| Actual release AAB | Built, 63.3 MB; existing debug signing configuration and old JNI bundle |
| APK/AAB provenance and ABI verification | Failed as required: no current native-build.json; old runtime lacks new C/bridge exports |
| Android CPU/GPU 4K/8K/16K/32K matrix, native media decoder, phase trace, background/foreground | Not run; requires a fresh verified native bundle, exact device and pinned model/media |

The APK/AAB build results establish final application packaging completed; they
are not valid upgraded-runtime or release acceptance. The ABI verifier also
rejects those old packaged libraries without `--require-provenance`, proving
missing exports are independently detected. Release and publication remain
blocked; no unrun context tier may be described as verified support.

The first hosted CI run also exposed an SDK bootstrap failure: setup-android v3
defaults to installing the removed `tools` package. All workflows now explicitly
request `platform-tools`; platform/NDK packages remain separately pinned.
The hosted workflow result must be checked independently from these local checks.
