#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUILD_ROOT="${BUILD_ROOT:-"$ROOT_DIR/.dart_tool/litert_lm_native"}"
readonly OUT_ROOT="${OUT_ROOT:-"$ROOT_DIR/android/src/main/jniLibs"}"
readonly LITERT_LM_REPO="${LITERT_LM_REPO:-https://github.com/google-ai-edge/LiteRT-LM.git}"
readonly LITERT_LM_TAG="${LITERT_LM_TAG:-v0.12.0}"
readonly LITERT_LM_COMMIT="${LITERT_LM_COMMIT:-ffed38adbc33509480b5340e5173638bc20a68ff}"
readonly BAZEL_VERSION="${BAZEL_VERSION:-7.6.1}"
readonly NDK_VERSION="${NDK_VERSION:-28.2.13676358}"
readonly LIB_NAME="liblitert_lm_c.so"
readonly ACCELERATORS="${ACCELERATORS:-vulkan,npu}"
readonly NPU_TARGETS="${NPU_TARGETS:-@litert//litert/vendors/google_tensor/dispatch:dispatch_api_so @litert//litert/vendors/qualcomm/dispatch:dispatch_api_so @litert//litert/vendors/mediatek/dispatch:dispatch_api_so}"
readonly NPU_VENDOR_LIB_DIRS="${NPU_VENDOR_LIB_DIRS:-}"

readonly ABI="${ABI:-arm64-v8a}"
case "$ABI" in
  arm64-v8a)
    readonly BAZEL_ANDROID_CONFIG="android_arm64"
    readonly PREBUILT_ANDROID_DIR="android_arm64"
    ;;
  armeabi-v7a)
    readonly BAZEL_ANDROID_CONFIG="android_arm"
    readonly PREBUILT_ANDROID_DIR=""
    ;;
  x86)
    readonly BAZEL_ANDROID_CONFIG="android_x86"
    readonly PREBUILT_ANDROID_DIR=""
    ;;
  x86_64)
    readonly BAZEL_ANDROID_CONFIG="android_x86_64"
    readonly PREBUILT_ANDROID_DIR="android_x86_64"
    ;;
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

fetch_gpu_prebuilts() {
  local src_dir="$1"

  if ! accelerator_enabled "gpu" && ! accelerator_enabled "vulkan"; then
    return
  fi

  if [[ -z "$PREBUILT_ANDROID_DIR" ]]; then
    echo "GPU/Vulkan runtime prebuilts are not pinned for ABI $ABI." >&2
    exit 1
  fi

  if ! git -C "$src_dir" lfs version >/dev/null 2>&1; then
    echo "git-lfs is required to fetch LiteRT-LM GPU/Vulkan prebuilts." >&2
    exit 2
  fi

  git -C "$src_dir" lfs pull \
    --include="prebuilt/$PREBUILT_ANDROID_DIR/*.so" \
    --exclude=""
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

accelerator_enabled() {
  local name="$1"
  [[ ",$ACCELERATORS," == *",$name,"* ]]
}

copy_gpu_runtime_libs() {
  local src_dir="$1"
  local out_dir="$2"

  if ! accelerator_enabled "gpu" && ! accelerator_enabled "vulkan"; then
    return
  fi

  if [[ -z "$PREBUILT_ANDROID_DIR" ]]; then
    echo "GPU/Vulkan runtime prebuilts are not pinned for ABI $ABI." >&2
    exit 1
  fi

  local prebuilt_dir="$src_dir/prebuilt/$PREBUILT_ANDROID_DIR"
  if [[ ! -d "$prebuilt_dir" ]]; then
    echo "LiteRT-LM GPU/Vulkan runtime directory not found: $prebuilt_dir" >&2
    exit 1
  fi

  local copied=0
  while IFS= read -r runtime_so; do
    cp "$runtime_so" "$out_dir/$(basename "$runtime_so")"
    copied=$((copied + 1))
  done < <(find "$prebuilt_dir" -maxdepth 1 -type f -name '*.so' | sort)

  if (( copied == 0 )); then
    echo "No GPU/Vulkan runtime libraries found in $prebuilt_dir" >&2
    exit 1
  fi
}

copy_npu_dispatch_libs() {
  local src_dir="$1"
  local out_dir="$2"

  if ! accelerator_enabled "npu"; then
    return
  fi

  local vendors_dir="$src_dir/bazel-bin/external/litert/litert/vendors"
  if [[ ! -d "$vendors_dir" ]]; then
    echo "NPU dispatch output directory not found: $vendors_dir" >&2
    exit 1
  fi

  local dispatch_copied=0
  while IFS= read -r dispatch_so; do
    cp "$dispatch_so" "$out_dir/$(basename "$dispatch_so")"
    dispatch_copied=$((dispatch_copied + 1))
  done < <(find "$vendors_dir" \
    \( -path '*/google_tensor/*' -o -path '*/qualcomm/*' -o -path '*/mediatek/*' \) \
    -type f -name '*.so' | sort)

  if [[ -n "$NPU_VENDOR_LIB_DIRS" ]]; then
    local vendor_dir
    local old_ifs="$IFS"
    IFS=':'
    for vendor_dir in $NPU_VENDOR_LIB_DIRS; do
      IFS="$old_ifs"
      [[ -z "$vendor_dir" ]] && continue
      if [[ ! -d "$vendor_dir" ]]; then
        echo "NPU vendor library directory not found: $vendor_dir" >&2
        exit 1
      fi
      while IFS= read -r vendor_so; do
        cp "$vendor_so" "$out_dir/$(basename "$vendor_so")"
      done < <(find "$vendor_dir" -type f -name '*.so' | sort)
      IFS=':'
    done
    IFS="$old_ifs"
  fi

  if (( dispatch_copied == 0 )); then
    echo "No NPU dispatch libraries were built from targets: $NPU_TARGETS" >&2
    exit 1
  fi
}

copy_runtime_libs() {
  local src_dir="$1"
  local out_dir="$OUT_ROOT/$ABI"

  copy_gpu_runtime_libs "$src_dir" "$out_dir"
  copy_npu_dispatch_libs "$src_dir" "$out_dir"
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

verify_runtime_bundle() {
  local out_dir="$OUT_ROOT/$ABI"
  local checked=0

  while IFS= read -r so; do
    verify_page_alignment "$so"
    checked=$((checked + 1))
  done < <(find "$out_dir" -maxdepth 1 -type f -name '*.so' | sort)

  if (( checked == 0 )); then
    echo "No shared libraries found in $out_dir" >&2
    exit 1
  fi
}

main() {
  mkdir -p "$BUILD_ROOT"

  local bazel src_dir out_so
  bazel="$(find_bazel)"
  src_dir="$(checkout_source)"
  patch_shared_target "$src_dir"
  fetch_gpu_prebuilts "$src_dir"

  local targets=("//c:$LIB_NAME")
  if accelerator_enabled "npu"; then
    local npu_target
    for npu_target in $NPU_TARGETS; do
      targets+=("$npu_target")
    done
  fi

  (
    cd "$src_dir"
    ANDROID_NDK_HOME="$NDK_HOME" \
    ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-"$HOME/Library/Android/sdk"}}" \
      "$bazel" build \
        "${targets[@]}" \
        "--config=$BAZEL_ANDROID_CONFIG" \
        --config=public_cache \
        --define=litert_link_capi_so=false \
        --define=resolve_symbols_in_exec=false
  )

  out_so="$(copy_output "$src_dir")"
  copy_runtime_libs "$src_dir"
  verify_symbols "$out_so"
  verify_runtime_bundle

  echo "Built Android native bundle in $OUT_ROOT/$ABI"
}

main "$@"
