#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .dart_tool
native_test_dir="$(mktemp -d "$PWD/.dart_tool/native-tests.XXXXXX")"
trap 'rm -rf "$native_test_dir"' EXIT
# Deterministic C++ ownership/queue tests under real memory/UB sanitizers.
c++ -std=c++17 -pthread -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I. -Ithird_party/litert_lm native/litert_lm_bridge.cc \
  test/native/bridge_test.cc -o "$native_test_dir/bridge-test"
"$native_test_dir/bridge-test"
# This compiles a threaded shared fixture, opens it through DynamicLibrary,
# and executes the production control worker. It is not a model inference test.
flutter test --no-pub test/native_backend_ffi_test.dart --reporter expanded
