#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUILD_ROOT="${BUILD_ROOT:-"$ROOT_DIR/.dart_tool/litert_lm_native"}"
readonly OUT_ROOT="${OUT_ROOT:-"$ROOT_DIR/android/src/main/jniLibs"}"
readonly LITERT_LM_REPO="${LITERT_LM_REPO:-https://github.com/google-ai-edge/LiteRT-LM.git}"
readonly LITERT_LM_TAG="${LITERT_LM_TAG:-v0.12.0}"
readonly LITERT_LM_COMMIT="${LITERT_LM_COMMIT:-ffed38adbc33509480b5340e5173638bc20a68ff}"
readonly BAZEL_VERSION="${BAZEL_VERSION:-7.6.1}"
readonly NDK_VERSION="${NDK_VERSION:-27.0.12077973}"
readonly LIB_NAME="liblitert_lm_c.so"

readonly ABI="${ABI:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) readonly BAZEL_ANDROID_CONFIG="android_arm64" ;;
  armeabi-v7a) readonly BAZEL_ANDROID_CONFIG="android_arm" ;;
  x86) readonly BAZEL_ANDROID_CONFIG="android_x86" ;;
  x86_64) readonly BAZEL_ANDROID_CONFIG="android_x86_64" ;;
  *) echo "Unsupported ABI: $ABI" >&2; exit 2 ;;
esac

if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
  readonly NDK_HOME="$ANDROID_NDK_HOME"
else
  readonly ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-"$HOME/Library/Android/sdk"}}"
  readonly NDK_HOME="$ANDROID_SDK_ROOT/ndk/$NDK_VERSION"
fi

if [[ ! -d "$NDK_HOME" ]]; then
  echo "Android NDK not found at $NDK_HOME" >&2
  echo "Install NDK $NDK_VERSION or set ANDROID_NDK_HOME." >&2
  exit 2
fi

readonly LLVM_NM="$(find "$NDK_HOME/toolchains/llvm/prebuilt" -path '*/bin/llvm-nm' -type f | head -n 1)"
readonly NDK_BIN="$(dirname "$LLVM_NM")"
readonly LLVM_READOBJ="$NDK_BIN/llvm-readobj"

if [[ ! -x "$LLVM_NM" || ! -x "$LLVM_READOBJ" ]]; then
  echo "Could not find llvm-nm and llvm-readobj under $NDK_HOME" >&2
  exit 2
fi

download_bazel() {
  local bin_dir="$BUILD_ROOT/bin"
  local bazel_bin="$bin_dir/bazel-$BAZEL_VERSION"
  mkdir -p "$bin_dir"

  if [[ -x "$bazel_bin" ]]; then
    echo "$bazel_bin"
    return
  fi

  local os arch artifact
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os:$arch" in
    Darwin:arm64) artifact="bazel-$BAZEL_VERSION-darwin-arm64" ;;
    Darwin:x86_64) artifact="bazel-$BAZEL_VERSION-darwin-x86_64" ;;
    Linux:aarch64|Linux:arm64) artifact="bazel-$BAZEL_VERSION-linux-arm64" ;;
    Linux:x86_64) artifact="bazel-$BAZEL_VERSION-linux-x86_64" ;;
    *) echo "Unsupported host for Bazel bootstrap: $os $arch" >&2; exit 2 ;;
  esac

  curl -fL \
    "https://github.com/bazelbuild/bazel/releases/download/$BAZEL_VERSION/$artifact" \
    -o "$bazel_bin"
  chmod +x "$bazel_bin"
  echo "$bazel_bin"
}

find_bazel() {
  if command -v bazelisk >/dev/null 2>&1; then
    command -v bazelisk
    return
  fi

  if command -v bazel >/dev/null 2>&1 && bazel --version | grep -q "$BAZEL_VERSION"; then
    command -v bazel
    return
  fi

  download_bazel
}

checkout_source() {
  local src_dir="$BUILD_ROOT/LiteRT-LM"
  if [[ ! -d "$src_dir/.git" ]]; then
    rm -rf "$src_dir"
    GIT_LFS_SKIP_SMUDGE=1 git clone \
      --filter=blob:none \
      --depth 1 \
      --branch "$LITERT_LM_TAG" \
      "$LITERT_LM_REPO" \
      "$src_dir"
  fi

  git -C "$src_dir" fetch --depth 1 origin "$LITERT_LM_COMMIT"
  git -C "$src_dir" checkout --detach "$LITERT_LM_COMMIT"
  git -C "$src_dir" lfs install --skip-smudge >/dev/null 2>&1 || true
  echo "$src_dir"
}

patch_shared_target() {
  local src_dir="$1"
  local build_file="$src_dir/c/BUILD"
  local lds_file="$src_dir/c/litert_lm_c_api.lds"

  cat >"$lds_file" <<'EOF'
{
  LiteRt*;
  litert_lm_*;
};
EOF

  if ! grep -q 'name = "liblitert_lm_c.so"' "$build_file"; then
    cat >>"$build_file" <<'EOF'

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
EOF
  fi
}

copy_output() {
  local src_dir="$1"
  local src_so="$src_dir/bazel-bin/c/$LIB_NAME"
  local out_dir="$OUT_ROOT/$ABI"
  local out_so="$out_dir/$LIB_NAME"

  if [[ ! -f "$src_so" ]]; then
    echo "Bazel output not found: $src_so" >&2
    exit 1
  fi

  mkdir -p "$out_dir"
  cp "$src_so" "$out_so"
  echo "$out_so"
}

verify_symbols() {
  local so="$1"
  local exported
  exported="$("$LLVM_NM" -D --defined-only "$so" | awk '{print $NF}' | sort -u)"

  if ! grep -q '^litert_lm_engine_create$' <<<"$exported"; then
    echo "Missing exported symbol: litert_lm_engine_create" >&2
    exit 1
  fi

  if ! grep -q '^litert_lm_session_generate_content_stream$' <<<"$exported"; then
    echo "Missing exported symbol: litert_lm_session_generate_content_stream" >&2
    exit 1
  fi

  if grep -Ev '^(LiteRt|litert_lm_)' <<<"$exported" | grep -q .; then
    echo "Warning: exported symbols outside LiteRt*/litert_lm_* were found." >&2
    grep -Ev '^(LiteRt|litert_lm_)' <<<"$exported" | sed -n '1,40p' >&2
  fi
}

verify_page_alignment() {
  local so="$1"
  local alignment
  while read -r alignment; do
    [[ -z "$alignment" ]] && continue
    if (( alignment < 0x4000 )); then
      echo "ELF load segment alignment is below 16 KB: $alignment" >&2
      exit 1
    fi
  done < <("$LLVM_READOBJ" --program-headers "$so" \
    | awk '/Type: PT_LOAD/{in_load=1} in_load && /Alignment:/{print $2; in_load=0}')
}

main() {
  mkdir -p "$BUILD_ROOT"

  local bazel src_dir out_so
  bazel="$(find_bazel)"
  src_dir="$(checkout_source)"
  patch_shared_target "$src_dir"

  (
    cd "$src_dir"
    ANDROID_NDK_HOME="$NDK_HOME" \
    ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-"$HOME/Library/Android/sdk"}}" \
      "$bazel" build \
        "//c:$LIB_NAME" \
        "--config=$BAZEL_ANDROID_CONFIG" \
        --config=public_cache \
        --define=litert_link_capi_so=false \
        --define=resolve_symbols_in_exec=false
  )

  out_so="$(copy_output "$src_dir")"
  verify_symbols "$out_so"
  verify_page_alignment "$out_so"

  echo "Built $out_so"
}

main "$@"
