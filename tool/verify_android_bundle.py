#!/usr/bin/env python3
"""Fail-closed arm64 ELF, FFI export, and installed-package layout checks.

APK checks include 16 KiB ZIP offsets for uncompressed native libraries. AABs
are checked for their embedded ELF files and inventory; APK layout is checked
on the separately built APK because an AAB is not installed directly.
These checks do not establish real-model inference or device compatibility.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PAGE_SIZE = 16384
MAIN_LIBRARY = 'liblitert_lm_c.so'
RUNTIME_TAG = 'v0.18.1'
BAZEL_VERSION = '7.6.1'
NDK_VERSION = '28.2.13676358'
BUILD_FLAGS = ['--config=android_arm64', '--config=public_cache',
               '--define=litert_link_capi_so=false', '--define=resolve_symbols_in_exec=false']
UPSTREAM_DEPENDENCIES = {
    'litert': 'ca21dc99de51c76bdcc572afeea1dd937d3c9e5c',
    'tensorflow': 'a1179d3c224967bd979950b823d5ce2a7e8f4c94',
}
RELEASE_LIBRARIES = {
    MAIN_LIBRARY, 'libGemmaModelConstraintProvider.so',
    'libLiteRtDispatch_GoogleTensor.so', 'libLiteRtDispatch_MediaTek.so',
    'libLiteRtDispatch_Qualcomm.so', 'libLiteRtGpuAccelerator.so',
    'libLiteRtOpenClAccelerator.so', 'libLiteRtTopKOpenClSampler.so',
    'libLiteRtTopKWebGpuSampler.so', 'libLiteRtWebGpuAccelerator.so',
    'libwebgpu_dawn.so',
}
NPU_TARGETS = {
    f'@litert//litert/vendors/{vendor}/dispatch:dispatch_api_so'
    for vendor in ('google_tensor', 'qualcomm', 'mediatek')
}


class VerificationError(Exception):
    pass


def verify_elf(data, label):
    if len(data) < 64 or data[:7] != b'\x7fELF\x02\x01\x01':
        raise VerificationError(f'{label}: expected a little-endian ELF64 file')
    header = struct.unpack_from('<HHIQQQIHHHHHH', data, 16)
    kind, machine, version = header[:3]
    if kind != 3 or machine != 183 or version != 1:
        raise VerificationError(f'{label}: expected an AArch64 ELF shared object')
    phoff, ehsize, phentsize, phnum = header[4], header[7], header[8], header[9]
    if ehsize != 64 or phentsize != 56 or phnum == 0xffff:
        raise VerificationError(f'{label}: invalid or unsupported ELF program header table')
    if phoff < 64 or phoff + phentsize * phnum > len(data):
        raise VerificationError(f'{label}: truncated ELF program header table')
    loads = 0
    for index in range(phnum):
        segment = struct.unpack_from('<IIQQQQQQ', data, phoff + index * phentsize)
        segment_type, _, offset, address, _, file_size, memory_size, alignment = segment
        if segment_type != 1:  # PT_LOAD
            continue
        loads += 1
        if alignment < PAGE_SIZE or alignment & (alignment - 1):
            raise VerificationError(f'{label}: PT_LOAD {index} alignment {alignment:#x} '
                                    'must be a power of two >= 16 KiB')
        if offset % alignment != address % alignment:
            raise VerificationError(f'{label}: PT_LOAD {index} offset/address are not congruent')
        if file_size > memory_size or offset + file_size > len(data):
            raise VerificationError(f'{label}: PT_LOAD {index} has invalid/truncated file bounds')
    if not loads:
        raise VerificationError(f'{label}: no PT_LOAD segments')
    return loads


def binary_identity(data):
    # GNU build IDs survive Gradle/llvm-strip removing debug/symbol sections.
    # Without a build ID, require exact bytes instead of accepting a stale .so.
    header = struct.unpack_from('<HHIQQQIHHHHHH', data, 16)
    for index in range(header[9]):
        segment = struct.unpack_from('<IIQQQQQQ', data, header[4] + index * header[8])
        if segment[0] != 4:  # PT_NOTE
            continue
        offset, size = segment[2], segment[5]
        end = offset + size
        if end > len(data):
            raise VerificationError('truncated ELF note segment')
        while offset + 12 <= end:
            name_size, value_size, kind = struct.unpack_from('<III', data, offset)
            offset += 12
            value_offset = offset + ((name_size + 3) & ~3)
            next_offset = value_offset + ((value_size + 3) & ~3)
            if next_offset > end:
                raise VerificationError('truncated ELF note')
            name = data[offset:offset + name_size].rstrip(b'\0')
            if name == b'GNU' and kind == 3 and value_size:
                return ('build-id', data[value_offset:value_offset + value_size].hex())
            offset = next_offset
    return ('sha256', hashlib.sha256(data).hexdigest())


def required_symbols(bindings, bridge_sources):
    symbols = set()
    for path in bindings:
        source = path.read_text()
        # ffigen emits _lookup<NativeFunction<...>>('symbol'). Nested type
        # arguments are allowed; only the literal symbol argument is captured.
        symbols.update(re.findall(r'\b_lookup\s*<.*?>\s*\(\s*[\'"]([A-Za-z_]\w*)[\'"]\s*\)',
                                  source, re.DOTALL))
    if not symbols:
        raise VerificationError('No FFI symbols found in the bindings contract')
    for path in bridge_sources:
        source = path.read_text()
        source = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.DOTALL)
        symbols.update(re.findall(r'\b((?:litert_lm_|lrlm_)\w+)\s*\(', source))
    return symbols


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def contract_files():
    files = [ROOT / 'tool/build_litert_lm_android.sh', ROOT / 'ffigen.yaml']
    for pattern in ('native/*.cc', 'native/*.h', 'lib/src/bindings/*.dart',
                    'third_party/litert_lm/c/*.h'):
        files.extend(ROOT.glob(pattern))
    return {str(path.relative_to(ROOT)): file_hash(path) for path in sorted(files)}


def pinned_commit():
    source = (ROOT / 'tool/build_litert_lm_android.sh').read_text()
    match = re.search(r'LITERT_LM_COMMIT:-([0-9a-f]{40})', source)
    if not match:
        raise VerificationError('Cannot determine pinned LiteRT-LM commit')
    return match[1]


def dependency_overrides():
    source = (ROOT / 'tool/build_litert_lm_android.sh').read_text()
    overrides = {}
    for name in ('rules_cc', 'bazel_skylib'):
        version = re.search(name.upper() + r'_VERSION="([^"]+)"', source)
        checksum = re.search(name.upper() + r'_SHA256="([0-9a-f]{64})"', source)
        if not version or not checksum:
            raise VerificationError(f'Cannot determine pinned {name} build override')
        overrides[name] = {'version': version[1], 'sha256': checksum[1]}
    return overrides


def write_provenance(bundle, source, accelerators, *, ndk_home=None, bazel=None,
                     build_flags=None, build_targets=None):
    result = subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'],
                            capture_output=True, text=True, check=True)
    commit = result.stdout.strip()
    if commit != pinned_commit():
        raise VerificationError(f'Native source commit {commit} differs from pinned commit')
    # The bridge is copied before the build. Reject edits made during a long
    # build instead of attaching current contract hashes to an older snapshot.
    paths = list((ROOT / 'native').glob('*.cc')) + list((ROOT / 'native').glob('*.h'))
    paths += list((ROOT / 'third_party/litert_lm/c').glob('*.h'))
    for contract in paths:
        built = source / 'c' / contract.name
        if not built.is_file() or file_hash(built) != file_hash(contract):
            raise VerificationError(f'{contract}: built source differs from current ABI contract; rebuild')
    if not ndk_home or not bazel or not build_flags or not build_targets:
        raise VerificationError('Writing provenance requires actual NDK/Bazel, build flags and targets')
    properties = (Path(ndk_home) / 'source.properties').read_text()
    revision = re.search(r'^Pkg.Revision\s*=\s*(\S+)\s*$', properties, re.MULTILINE)
    # Bazelisk resolves .bazelversion relative to its working directory, just as
    # it did for the build. Querying from this repository can select a different
    # Bazel even though the upstream build used the pinned toolchain.
    bazel_result = subprocess.run([bazel, '--version'], cwd=source,
                                  capture_output=True, text=True, check=True)
    if not revision or revision[1] != NDK_VERSION or bazel_result.stdout.strip() != f'bazel {BAZEL_VERSION}':
        raise VerificationError('Actual NDK/Bazel version differs from the pinned toolchain: '
                                f'NDK={revision[1] if revision else "unavailable"}, '
                                f'Bazel={bazel_result.stdout.strip()!r}; '
                                f'expected NDK={NDK_VERSION}, Bazel={BAZEL_VERSION}')
    workspace = (source / 'WORKSPACE').read_text()
    refs = dict(re.findall(r'^([A-Z_]+)_REF\s*=\s*"([0-9a-f]{40})"', workspace, re.MULTILINE))
    dependencies = {key: refs.get(key.upper()) for key in UPSTREAM_DEPENDENCIES}
    if dependencies != UPSTREAM_DEPENDENCIES or build_flags != BUILD_FLAGS:
        raise VerificationError('Actual dependency revisions/build flags differ from the pinned build')
    manifest = {
        'schema_version': 1,
        'litert_lm_commit': commit,
        'litert_lm_tag': RUNTIME_TAG,
        'bridge_abi': 1,
        'toolchain': {'bazel': BAZEL_VERSION, 'ndk': revision[1]},
        'upstream_dependencies': dependencies,
        'build_flags': build_flags,
        'build_targets': build_targets,
        'abi': 'arm64-v8a',
        'accelerators': accelerators.split(','),
        'dependency_overrides': dependency_overrides(),
        'patched_workspace_sha256': file_hash(source / 'WORKSPACE'),
        'libraries': {path.name: file_hash(path) for path in bundle_libraries(bundle)},
        'contract_files': contract_files(),
    }
    (bundle / 'native-build.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')


def verify_provenance(bundle):
    path = bundle / 'native-build.json'
    if not path.is_file():
        raise VerificationError(f'{bundle}: missing native build provenance (native-build.json)')
    manifest = json.loads(path.read_text())
    if not isinstance(manifest, dict) or manifest.get('schema_version') != 1:
        raise VerificationError(f'{path}: invalid native build provenance schema')
    if manifest.get('litert_lm_commit') != pinned_commit():
        raise VerificationError(f'{path}: native source commit does not match pinned commit')
    if manifest.get('abi') != 'arm64-v8a':
        raise VerificationError(f'{path}: provenance ABI must be arm64-v8a')
    actual = {library.name: file_hash(library) for library in bundle_libraries(bundle)}
    if manifest.get('libraries') != actual:
        raise VerificationError(f'{path}: native library inventory/hash mismatch; rebuild the bundle')
    if manifest.get('contract_files') != contract_files():
        raise VerificationError(f'{path}: native ABI contract hash mismatch; rebuild the bundle')
    if manifest.get('litert_lm_tag') != RUNTIME_TAG or manifest.get('bridge_abi') != 1:
        raise VerificationError(f'{path}: runtime tag/bridge ABI mismatch')
    if manifest.get('toolchain') != {'bazel': BAZEL_VERSION, 'ndk': NDK_VERSION}:
        raise VerificationError(f'{path}: missing or incompatible toolchain provenance')
    if manifest.get('upstream_dependencies') != UPSTREAM_DEPENDENCIES:
        raise VerificationError(f'{path}: upstream dependency revision mismatch')
    if manifest.get('build_flags') != BUILD_FLAGS:
        raise VerificationError(f'{path}: native build flags mismatch')
    targets = manifest.get('build_targets', [])
    if not isinstance(targets, list) or f'//c:{MAIN_LIBRARY}' not in targets:
        raise VerificationError(f'{path}: missing native build targets')
    if manifest.get('accelerators') != ['vulkan', 'npu']:
        raise VerificationError(f'{path}: release accelerators must be vulkan,npu')
    if not all(target in targets for target in NPU_TARGETS):
        raise VerificationError(f'{path}: missing release NPU build targets')
    missing_libraries = RELEASE_LIBRARIES - set(actual)
    if missing_libraries:
        raise VerificationError(f'{path}: incomplete release inventory: '
                                f'{", ".join(sorted(missing_libraries))}')
    if manifest.get('dependency_overrides') != dependency_overrides():
        raise VerificationError(f'{path}: compatibility override mismatch')
    print(f'OK provenance: pinned source commit {manifest["litert_lm_commit"]}, ABI and file hashes')


def find_nm():
    if os.environ.get('LLVM_NM'):
        return os.environ['LLVM_NM']
    ndk = os.environ.get('ANDROID_NDK_HOME')
    if not ndk:
        sdk = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
        sdk = Path(sdk) if sdk else Path.home() / 'Library/Android/sdk'
        ndk = sdk / 'ndk/28.2.13676358'
    matches = sorted(Path(ndk).glob('toolchains/llvm/prebuilt/*/bin/llvm-nm'))
    if not matches:
        raise VerificationError('llvm-nm not found; set --nm or ANDROID_NDK_HOME')
    return str(matches[0])


def verify_symbols(path, nm, required):
    try:
        result = subprocess.run([nm, '-D', '--defined-only', str(path)],
                                capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        raise VerificationError(f'{path}: symbol reader failed: {detail}') from error
    exported = {line.split()[-1].split('@')[0] for line in result.stdout.splitlines() if line.split()}
    missing = required - exported
    if missing:
        raise VerificationError(f'{path}: missing exported symbols: {", ".join(sorted(missing))}')


def bundle_libraries(bundle):
    libraries = sorted(bundle.rglob('*.so'))
    if not libraries:
        raise VerificationError(f'No shared libraries found in {bundle}')
    names = [path.name for path in libraries]
    if len(names) != len(set(names)):
        raise VerificationError(f'{bundle}: duplicate native library names')
    if MAIN_LIBRARY not in names:
        raise VerificationError(f'{bundle}: missing {MAIN_LIBRARY}')
    return libraries


def verify_directory(path, nm, required):
    libraries = bundle_libraries(path)
    for library in libraries:
        loads = verify_elf(library.read_bytes(), str(library))
        if library.name == MAIN_LIBRARY:
            verify_symbols(library, nm, required)
        print(f'OK {library.name}: AArch64, {loads} PT_LOAD segments aligned to >=16 KiB')
    return len(libraries)


def verify_archive(path, expected, nm, required):
    is_apk = path.suffix.lower() == '.apk'
    prefix = 'lib/arm64-v8a/' if is_apk else 'base/lib/arm64-v8a/'
    with zipfile.ZipFile(path) as archive, path.open('rb') as raw:
        entries = [entry for entry in archive.infolist() if entry.filename.endswith('.so')]
        if not entries:
            raise VerificationError(f'{path}: No shared libraries in archive')
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)):
            raise VerificationError(f'{path}: duplicate native ZIP entries')
        missing = {prefix + name for name in expected} - set(names)
        if missing:
            raise VerificationError(f'{path}: missing bundled libraries: {", ".join(sorted(missing))}')
        for entry in entries:
            pattern = r'lib/arm64-v8a/[^/]+\.so' if is_apk else r'[^/]+/lib/arm64-v8a/[^/]+\.so'
            if not re.fullmatch(pattern, entry.filename):
                raise VerificationError(f'{path}: unexpected native library path/ABI: {entry.filename}')
            label = f'{path}!{entry.filename}'
            data = archive.read(entry)
            verify_elf(data, label)
            source = expected.get(Path(entry.filename).name)
            if source:
                source_data = source.read_bytes()
                verify_elf(source_data, str(source))
                if binary_identity(data) != binary_identity(source_data):
                    raise VerificationError(f'{label}: native binary identity mismatch with {source}')
            if is_apk and entry.compress_type == zipfile.ZIP_STORED:
                raw.seek(entry.header_offset)
                header = raw.read(30)
                if len(header) != 30 or header[:4] != b'PK\x03\x04':
                    raise VerificationError(f'{label}: invalid ZIP local header')
                name_size, extra_size = struct.unpack_from('<HH', header, 26)
                data_offset = entry.header_offset + 30 + name_size + extra_size
                if data_offset % PAGE_SIZE:
                    raise VerificationError(f'{label}: ZIP alignment {data_offset} is not 16 KiB')
            if Path(entry.filename).name == MAIN_LIBRARY:
                with tempfile.TemporaryDirectory(prefix='litert-symbols-') as temp:
                    library = Path(temp) / MAIN_LIBRARY
                    library.write_bytes(data)
                    verify_symbols(library, nm, required)
            print(f'OK {entry.filename}: AArch64, ELF alignment >=16 KiB')
        return len(entries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path, help='arm64-v8a directory, APK, or AAB')
    parser.add_argument('--bundle-dir', type=Path, default=ROOT / 'android/src/main/jniLibs/arm64-v8a',
                        help='source inventory required in APK/AAB')
    parser.add_argument('--bindings', type=Path, action='append', help='ffigen Dart file (repeatable)')
    parser.add_argument('--bridge-source', type=Path, action='append',
                        help='C/C++ bridge whose upstream calls must be exported (repeatable)')
    parser.add_argument('--nm', help='NDK llvm-nm executable')
    parser.add_argument('--require-provenance', action='store_true',
                        help='require the pinned source and current ABI/library hashes')
    parser.add_argument('--write-provenance-source', type=Path,
                        help='record the just-built upstream checkout after bundle verification')
    parser.add_argument('--accelerators', default='vulkan,npu', help='recorded native build accelerators')
    parser.add_argument('--ndk-home', type=Path, help='actual NDK used when writing provenance')
    parser.add_argument('--bazel', help='actual Bazel executable used when writing provenance')
    parser.add_argument('--build-flag', action='append', help='actual build flag (use --build-flag=--flag)')
    parser.add_argument('--build-target', action='append', help='actual Bazel build target')
    args = parser.parse_args()
    try:
        bindings = args.bindings or sorted((ROOT / 'lib/src/bindings').glob('*.dart'))
        bridges = args.bridge_source
        if bridges is None:
            bridges = sorted((ROOT / 'native').glob('*.cc')) + sorted((ROOT / 'native').glob('*.h'))
        required = required_symbols(bindings, bridges)
        nm = args.nm or find_nm()
        if args.require_provenance:
            verify_provenance(args.artifact if args.artifact.is_dir() else args.bundle_dir)
        if args.artifact.is_dir():
            count = verify_directory(args.artifact, nm, required)
        elif args.artifact.suffix.lower() in ('.apk', '.aab'):
            expected = {library.name: library for library in bundle_libraries(args.bundle_dir)}
            count = verify_archive(args.artifact, expected, nm, required)
        else:
            raise VerificationError(f'{args.artifact}: expected a bundle directory, APK, or AAB')
        if args.write_provenance_source:
            if not args.artifact.is_dir():
                raise VerificationError('Provenance can only be recorded for a built native directory')
            write_provenance(args.artifact, args.write_provenance_source, args.accelerators,
                             ndk_home=args.ndk_home, bazel=args.bazel,
                             build_flags=args.build_flag, build_targets=args.build_target)
        print(f'Verified {count} shared libraries and {len(required)} required symbols in {args.artifact}')
    except (VerificationError, OSError, ValueError, struct.error, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
