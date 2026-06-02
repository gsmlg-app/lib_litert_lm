# LiteRT-LM Example

Run on Android after the maintainer native build has produced:

```text
../android/src/main/jniLibs/arm64-v8a/*.so
```

Then:

```bash
flutter run
```

Pick a local `.litertlm` file, load it, enter a prompt, and stream tokens.

Run the example app e2e smoke test on a connected Android device or emulator:

```bash
flutter test integration_test/app_e2e_test.dart -d <device-id>
```
