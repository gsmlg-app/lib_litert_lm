#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUILD_ROOT="${BUILD_ROOT:-"$ROOT_DIR/.dart_tool/litert_lm_native"}"
readonly OUT_ROOT="${OUT_ROOT:-"$ROOT_DIR/android/src/main/jniLibs"}"
readonly LITERT_LM_REPO="${LITERT_LM_REPO:-https://github.com/google-ai-edge/LiteRT-LM.git}"
readonly LITERT_LM_TAG="${LITERT_LM_TAG:-v0.18.1}"
readonly LITERT_LM_COMMIT="${LITERT_LM_COMMIT:-bda624851d74be34d4e1f7fac1fc4155939539c7}"
readonly BAZEL_VERSION="${BAZEL_VERSION:-7.6.1}"
readonly NDK_VERSION="${NDK_VERSION:-28.2.13676358}"
readonly RULES_CC_VERSION="0.2.25"
readonly RULES_CC_SHA256="bd7124a844d0403b4b353bcea34d6c8b2ba88dc26881c26c9ee668da89b71846"
readonly BAZEL_SKYLIB_VERSION="1.9.0"
readonly BAZEL_SKYLIB_SHA256="3b5b49006181f5f8ff626ef8ddceaa95e9bb8ad294f7b5d7b11ea9f7ddaf8c59"
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
  *) echo "Unsupported ABI: $ABI (only arm64-v8a is packaged and verified)" >&2; exit 2 ;;
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

if [[ ! -x "$LLVM_NM" ]]; then
  echo "Could not find llvm-nm under $NDK_HOME" >&2
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
      "$src_dir" >&2 || return
  fi

  # This function returns only the path on stdout and runs in command
  # substitution, where Bash does not reliably inherit errexit.
  git -C "$src_dir" fetch --depth 1 origin "$LITERT_LM_COMMIT" >&2 || return
  git -C "$src_dir" checkout --detach "$LITERT_LM_COMMIT" >&2 || return
  git -C "$src_dir" lfs install --skip-smudge >/dev/null 2>&1 || true
  echo "$src_dir"
}

patch_shared_target() {
  local src_dir="$1"
  local build_file="$src_dir/c/BUILD"
  local lds_file="$src_dir/c/litert_lm_c_api.lds"

  cp "$ROOT_DIR/native/litert_lm_bridge.cc" "$src_dir/c/litert_lm_bridge.cc"
  cp "$ROOT_DIR/native/litert_lm_bridge.h" "$src_dir/c/litert_lm_bridge.h"
  cp "$ROOT_DIR/native/litert_lm_model_bridge.cc" "$src_dir/c/litert_lm_model_bridge.cc"
  cat >"$lds_file" <<'EOF'
{
  LiteRt*;
  litert_lm_*;
  lrlm_*;
};
EOF

  # Replace our previous injected target when reusing a cached checkout.
  python3 - "$build_file" <<'PYBUILD'
import pathlib
import re
import sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
source = re.sub(r'\ncc_binary\(\n\s*name = "liblitert_lm_c\.so",.*?\n\)\n',
                '\n', source, flags=re.DOTALL)
source += """
cc_binary(
    name = "liblitert_lm_c.so",
    srcs = ["litert_lm_bridge.cc", "litert_lm_bridge.h", "litert_lm_model_bridge.cc"],
    additional_linker_inputs = [":litert_lm_c_api.lds"],
    linkopts = [
        "-Wl,--dynamic-list,$(location :litert_lm_c_api.lds)",
        "-Wl,--no-undefined",
        "-Wl,-z,max-page-size=16384",
        "-Wl,-z,common-page-size=16384",
    ],
    linkshared = True,
    linkstatic = True,
    visibility = ["//visibility:public"],
    deps = [
        ":engine", ":engine_internal", ":conversation_internal",
        ":conversation_headers", ":model_info_headers", ":error_reporter_headers",
        "//runtime/core:session_utils",
        "//runtime/conversation/model_data_processor:model_data_processor_factory",
    ],
)
"""
path.write_text(source)
PYBUILD
}

patch_minizip_archive() {
  local src_dir="$1"
  local workspace_file="$src_dir/WORKSPACE"

  perl -0pi -e 's#url = "https://zlib\.net/fossils/zlib-1\.3\.1\.tar\.gz",#urls = [\n        "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz",\n        "https://zlib.net/fossils/zlib-1.3.1.tar.gz",\n    ],#' \
    "$workspace_file"
}

patch_bazel_skylib_archive() {
  local src_dir="$1"
  # Rules Shell otherwise predeclares Skylib 1.7.1, whose bool_flag lacks the
  # scope attribute required by Rules CC. Use the pinned TensorFlow archive.
  python3 - "$src_dir/WORKSPACE" "$BAZEL_SKYLIB_VERSION" "$BAZEL_SKYLIB_SHA256" <<'PYSKYLIB'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
version, checksum = sys.argv[2:]
source = path.read_text()
marker = '# lib_litert_lm: Skylib required by the pinned TensorFlow workspace.\n'
declaration = f'''
{marker}http_archive(
    name = "bazel_skylib",
    sha256 = "{checksum}",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/bazel-skylib/releases/download/{version}/bazel-skylib-{version}.tar.gz",
        "https://github.com/bazelbuild/bazel-skylib/releases/download/{version}/bazel-skylib-{version}.tar.gz",
    ],
)
'''
if marker in source:
    if declaration not in source:
        sys.exit('Cached Skylib patch differs from the pinned archive; inspect before rebuilding')
else:
    anchor = 'load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")\n'
    if source.count(anchor) != 1 or 'name = "bazel_skylib"' in source:
        sys.exit('Unexpected upstream Skylib declaration; inspect before patching')
    path.write_text(source.replace(anchor, anchor + declaration, 1))
PYSKYLIB
}

patch_rules_cc_archive() {
  local src_dir="$1"
  # Go declares rules_cc 0.1.5 before TensorFlow can select its required 0.2.25,
  # which supplies compatibility_proxy_repo. Use TensorFlow's exact archive.
  python3 - "$src_dir/WORKSPACE" "$RULES_CC_VERSION" "$RULES_CC_SHA256" <<'PYRULES'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
version, checksum = sys.argv[2:]
source = path.read_text()
marker = '# lib_litert_lm: rules_cc required by the pinned TensorFlow workspace.\n'
if marker not in source:
    anchor = 'load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")\n'
    if source.count(anchor) != 1 or 'name = "rules_cc"' in source:
        sys.exit('Unexpected upstream rules_cc declaration; inspect before patching')
    declaration = f'''
{marker}http_archive(
    name = "rules_cc",
    sha256 = "{checksum}",
    strip_prefix = "rules_cc-{version}",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/rules_cc/releases/download/{version}/rules_cc-{version}.tar.gz",
        "https://github.com/bazelbuild/rules_cc/releases/download/{version}/rules_cc-{version}.tar.gz",
    ],
)
'''
    source = source.replace(anchor, anchor + declaration, 1)
# workspace2 loads C++ rules before workspace1 can initialize their proxy.
# Initialize bazel_features first because rules_cc's extension loads it.
proxy_marker = '# lib_litert_lm: initialize C++ compatibility before dependent loads.\n'
if proxy_marker not in source:
    anchor = 'tf_workspace3()\n'
    if source.count(anchor) != 1:
        sys.exit('Unexpected TensorFlow bootstrap; inspect before patching')
    bootstrap = '''
load("@bazel_features//:deps.bzl", "bazel_features_deps")
bazel_features_deps()
load("@rules_cc//cc:extensions.bzl", "compatibility_proxy_repo")
compatibility_proxy_repo()
'''
    source = source.replace(anchor, anchor + '\n' + proxy_marker + bootstrap, 1)
path.write_text(source)
PYRULES
}

patch_litert_oss_hooks() {
  local src_dir="$1"
  # The pinned public LiteRT archive exports an unconditional dependency on
  # Google's private power profiler. All hook use is already guarded by the
  # disabled LITERT_GOOGLE_TENSOR_HAS_HOOKS macro in google_tensor_hook.cc.
  # Remove only that unused dependency; keep the Google Tensor dispatch target.
  cat >"$src_dir/lib_litert_lm_google_tensor_oss.patch" <<'PATCH'
--- a/litert/vendors/google_tensor/dispatch/BUILD
+++ b/litert/vendors/google_tensor/dispatch/BUILD
@@ -138,7 +138,6 @@
         ":google_tensor_hook",
         "//litert/c:litert_profiler_types",
         # copybara:uncomment "//litert/c/options/google:litert_google_tensor_privileged_options_type",
-        "//litert/vendors/google_tensor/hooks",
         # copybara:uncomment "//litert/vendors/google_tensor/dispatch/google:google_tensor_privileged_options_utils",
         "@com_google_absl//absl/algorithm:container",
         "//litert/c/internal:litert_scheduling_info",
PATCH
  python3 - "$src_dir/WORKSPACE" <<'PYHOOKS'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
marker = '# lib_litert_lm: omit disabled internal Google Tensor profiling dependency.\n'
if marker not in source:
    anchor = '    name = "litert",\n    patch_cmds = [\n'
    if source.count(anchor) != 1:
        sys.exit('Unexpected LiteRT archive declaration; inspect before patching')
    source = source.replace(anchor, '    name = "litert",\n    ' + marker +
        '    patches = ["@//:lib_litert_lm_google_tensor_oss.patch"],\n' +
        '    patch_args = ["-p1"],\n    patch_cmds = [\n', 1)
    path.write_text(source)
PYHOOKS
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
  local out_dir="$2"
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
  local out_dir="$2"

  copy_gpu_runtime_libs "$src_dir" "$out_dir"
  copy_npu_dispatch_libs "$src_dir" "$out_dir"
}

verify_runtime_bundle() {
  local src_dir="$1"
  local out_dir="$2"
  local bazel="$3"
  shift 3
  local metadata_args=() target
  for target in "$@"; do
    metadata_args+=(--build-target "$target")
  done
  python3 "$ROOT_DIR/tool/verify_android_bundle.py" "$out_dir" \
    --nm "$LLVM_NM" \
    --write-provenance-source "$src_dir" \
    --accelerators "$ACCELERATORS" \
    --ndk-home "$NDK_HOME" --bazel "$bazel" \
    --build-flag="--config=$BAZEL_ANDROID_CONFIG" \
    --build-flag=--config=public_cache \
    --build-flag=--define=litert_link_capi_so=false \
    --build-flag=--define=resolve_symbols_in_exec=false \
    "${metadata_args[@]}"
}

main() {
  mkdir -p "$BUILD_ROOT"

  local bazel src_dir
  bazel="$(find_bazel)"
  src_dir="$(checkout_source)"
  patch_shared_target "$src_dir"
  patch_minizip_archive "$src_dir"
  patch_bazel_skylib_archive "$src_dir"
  patch_rules_cc_archive "$src_dir"
  patch_litert_oss_hooks "$src_dir"
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

  # Validate a fresh staging directory so removed upstream prebuilts cannot
  # survive from an older bundle, and a failed validation preserves the bundle.
  mkdir -p "$OUT_ROOT"
  local stage_dir previous_dir=""
  stage_dir="$(mktemp -d "$OUT_ROOT/.bundle-$ABI.XXXXXX")"
  trap "rm -rf $(printf '%q' "$stage_dir")" EXIT
  copy_output "$src_dir" "$stage_dir"
  copy_runtime_libs "$src_dir" "$stage_dir"
  verify_runtime_bundle "$src_dir" "$stage_dir" "$bazel" "${targets[@]}"

  if [[ -d "$OUT_ROOT/$ABI" ]]; then
    previous_dir="$(mktemp -d "$OUT_ROOT/.previous-$ABI.XXXXXX")"
    rmdir "$previous_dir"
    mv "$OUT_ROOT/$ABI" "$previous_dir"
  fi
  if ! mv "$stage_dir" "$OUT_ROOT/$ABI"; then
    if [[ -n "$previous_dir" ]]; then
      mv "$previous_dir" "$OUT_ROOT/$ABI"
    fi
    exit 1
  fi
  trap - EXIT
  if [[ -n "$previous_dir" ]]; then
    rm -rf "$previous_dir"
  fi

  echo "Built Android native bundle in $OUT_ROOT/$ABI"
}

main "$@"
