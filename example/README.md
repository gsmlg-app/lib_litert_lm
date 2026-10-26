# LiteRT-LM Example

Run on Android after the maintainer native build has produced:

```text
../android/src/main/jniLibs/arm64-v8a/*.so
```

```bash
flutter run
```

Pick a local `.litertlm` file and select a text backend and requested context
(4K, 8K, 16K, or 32K). Enable vision or audio before loading when the model
supports that modality; each enabled modality uses its explicit CPU backend.
Both are disabled by default. Changing these settings requires reloading.
After load, the screen shows requested and effective context from engine info;
`unavailable` means the runtime did not report a value.

Use the image picker for a local PNG/JPEG or the audio picker for a WAV. The app
reads the chosen file's bytes and checks its format signature. Unreadable or
empty files produce an error; no placeholder image or audio bytes are sent.
Attachments apply to the next completed user turn and then clear. Enabling a
modality also permits text-only follow-up turns.

Each Generate appends one new user message to a persistent native Conversation.
New conversation disposes that history and starts a fresh conversation on the
next Generate. Cancel retains the Conversation wrapper; the runtime restores its
committed history before the next turn. Model reload and screen disposal close
existing handles.

Run host UI/control-flow smoke tests with:

```bash
flutter test --no-pub test/widget_test.dart
```

These tests use a fake backend and mocked file-picker results. They do not prove
native inference or model support. The device integration test also checks only
controls and errors without loading a model:

```bash
flutter test integration_test/app_e2e_test.dart -d <device-id>
```

Native acceptance additionally requires a real compatible model on an Android
ARM64 device: inspect requested/effective context, complete text turns at the
selected context, verify a follow-up retains history, cancel and reuse a
conversation, reset it, and submit actual PNG/JPEG/WAV files with the respective
modality enabled. Record model identity, backend, context and runtime information
with those results.
