"""Deterministic ELF/package regressions; no Android toolchain is required."""
import hashlib
import json
import re
import pathlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
VERIFIER = ROOT / 'tool/verify_android_bundle.py'
FLAGS = ['--config=android_arm64', '--config=public_cache',
         '--define=litert_link_capi_so=false', '--define=resolve_symbols_in_exec=false']


def elf(*, machine=183, segments=None):
    if segments is None:
        segments = [(1, 0, 0, 0x4000)]
    ident = b'\x7fELF' + bytes([2, 1, 1]) + bytes(9)
    header = struct.pack('<HHIQQQIHHHHHH', 3, machine, 1, 0, 64, 0, 0,
                         64, 56, len(segments), 0, 0, 0)
    programs = b''.join(struct.pack('<IIQQQQQQ', kind, 5, offset, address,
                                   address, 0, 0, alignment)
                        for kind, offset, address, alignment in segments)
    return ident + header + programs


class BundleVerifierTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.bundle = self.root / 'arm64-v8a'
        self.bundle.mkdir()
        (self.bundle / 'liblitert_lm_c.so').write_bytes(elf())
        self.bindings = self.root / 'bindings.dart'
        self.bindings.write_text("_lookup<ffi.NativeFunction<ffi.Void Function()>>('litert_lm_engine_create');\n"
                                 "_lookup<ffi.NativeFunction<ffi.Void Function()>>('litert_lm_extra');\n")
        self.bridge = self.root / 'bridge.cc'
        self.bridge.write_text('// isolated test bridge\n')
        self.nm = self.root / 'llvm-nm'
        self.nm.write_text('#!/bin/sh\nprintf "0000 T litert_lm_engine_create\\n0001 T litert_lm_extra\\n"\n')
        self.nm.chmod(0o755)

    def run_verifier(self, artifact=None, *, bridge=None, provenance=False, source=None, metadata=False):
        args = [sys.executable, str(VERIFIER), str(artifact or self.bundle),
                '--bundle-dir', str(self.bundle), '--bindings', str(self.bindings),
                '--nm', str(self.nm)]
        if provenance:
            args += ['--require-provenance']
        args += ['--bridge-source', str(bridge or self.bridge)]
        env = None
        if source:
            args += ['--write-provenance-source', str(source)]
            env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'])
        if metadata:
            args += ['--ndk-home', str(self.root / 'ndk'), '--bazel', str(self.root / 'bazel'),
                     '--build-target', '//c:liblitert_lm_c.so']
            args += ['--build-flag=' + flag for flag in FLAGS]
        return subprocess.run(args, capture_output=True, text=True, env=env)

    def assert_rejected(self, message, artifact=None, **kwargs):
        result = self.run_verifier(artifact, **kwargs)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)

    def test_accepts_valid_arm64_elf(self):
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_missing_or_unreadable_elf(self):
        (self.bundle / 'liblitert_lm_c.so').write_bytes(b'not an ELF')
        self.assert_rejected('ELF')

    def test_rejects_zero_load_segments(self):
        (self.bundle / 'liblitert_lm_c.so').write_bytes(elf(segments=[(4, 0, 0, 8)]))
        self.assert_rejected('PT_LOAD')

    def test_rejects_wrong_architecture(self):
        (self.bundle / 'liblitert_lm_c.so').write_bytes(elf(machine=62))
        self.assert_rejected('AArch64')

    def test_checks_every_load_and_every_library(self):
        (self.bundle / 'libvendor.so').write_bytes(
            elf(segments=[(1, 0, 0, 0x4000), (1, 0, 0, 0x1000)]))
        self.assert_rejected('alignment')

    def test_rejects_non_power_of_two_alignment(self):
        (self.bundle / 'liblitert_lm_c.so').write_bytes(elf(segments=[(1, 0, 0, 0x5000)]))
        self.assert_rejected('alignment')

    def test_rejects_incongruent_load_address(self):
        (self.bundle / 'liblitert_lm_c.so').write_bytes(elf(segments=[(1, 0, 1, 0x4000)]))
        self.assert_rejected('congruent')

    def test_rejects_truncated_program_headers(self):
        (self.bundle / 'liblitert_lm_c.so').write_bytes(elf()[:-1])
        self.assert_rejected('truncated')

    def test_rejects_empty_bundle(self):
        (self.bundle / 'liblitert_lm_c.so').unlink()
        self.assert_rejected('No shared libraries')

    def test_rejects_nm_reader_failure_even_with_partial_output(self):
        self.nm.write_text('#!/bin/sh\nprintf "0000 T litert_lm_engine_create\\n0001 T litert_lm_extra\\n"\nexit 7\n')
        self.assert_rejected('symbol reader failed')

    def test_requires_every_ffi_symbol(self):
        self.nm.write_text('#!/bin/sh\nprintf "0000 T litert_lm_engine_create\\n"\n')
        self.assert_rejected('litert_lm_extra')

    def test_rejects_empty_symbol_contract(self):
        self.bindings.write_text('// no lookups\n')
        self.assert_rejected('No FFI symbols')

    def test_requires_bridge_references(self):
        bridge = self.root / 'bridge.c'
        bridge.write_text('void bridge(void) { litert_lm_bridge_only(); }\n')
        self.assert_rejected('litert_lm_bridge_only', bridge=bridge)

    def test_requires_bridge_exports_as_well_as_upstream_calls(self):
        bridge = self.root / 'bridge.h'
        bridge.write_text('extern "C" int lrlm_bridge_only(void);\n')
        self.assert_rejected('lrlm_bridge_only', bridge=bridge)

    def test_provenance_is_required_when_requested(self):
        self.assert_rejected('missing native build provenance', provenance=True)

    def test_provenance_rejects_wrong_commit(self):
        (self.bundle / 'native-build.json').write_text(json.dumps({
            'schema_version': 1, 'litert_lm_commit': '0' * 40,
            'abi': 'arm64-v8a', 'libraries': {}, 'contract_files': {}}))
        self.assert_rejected('commit', provenance=True)

    def test_provenance_rejects_stale_library_hash(self):
        script = (ROOT / 'tool/build_litert_lm_android.sh').read_text()
        commit = re.search(r'LITERT_LM_COMMIT:-([0-9a-f]{40})', script)[1]
        (self.bundle / 'native-build.json').write_text(json.dumps({
            'schema_version': 1, 'litert_lm_commit': commit,
            'abi': 'arm64-v8a', 'libraries': {'liblitert_lm_c.so': 'bad'},
            'contract_files': {}}))
        self.assert_rejected('hash', provenance=True)

    def make_provenance(self):
        files = [ROOT / 'tool/build_litert_lm_android.sh', ROOT / 'ffigen.yaml']
        for pattern in ('native/*.cc', 'native/*.h', 'lib/src/bindings/*.dart',
                        'third_party/litert_lm/c/*.h'):
            files.extend(ROOT.glob(pattern))
        digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        script = (ROOT / 'tool/build_litert_lm_android.sh').read_text()
        manifest = {
            'schema_version': 1,
            'litert_lm_commit': re.search(r'LITERT_LM_COMMIT:-([0-9a-f]{40})', script)[1],
            'abi': 'arm64-v8a',
            'litert_lm_tag': 'v0.18.1',
            'bridge_abi': 1,
            'toolchain': {'bazel': '7.6.1', 'ndk': '28.2.13676358'},
            'upstream_dependencies': {
                'litert': 'ca21dc99de51c76bdcc572afeea1dd937d3c9e5c',
                'tensorflow': 'a1179d3c224967bd979950b823d5ce2a7e8f4c94'},
            'build_flags': FLAGS,
            'build_targets': ['//c:liblitert_lm_c.so'],
            'dependency_overrides': {'rules_cc': {'version': '0.2.25',
                'sha256': 'bd7124a844d0403b4b353bcea34d6c8b2ba88dc26881c26c9ee668da89b71846'}},
            'libraries': {'liblitert_lm_c.so': digest(self.bundle / 'liblitert_lm_c.so')},
            'contract_files': {str(path.relative_to(ROOT)): digest(path) for path in files},
        }
        return manifest

    def test_accepts_matching_provenance(self):
        (self.bundle / 'native-build.json').write_text(json.dumps(self.make_provenance()))
        result = self.run_verifier(provenance=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_missing_or_different_toolchain_and_build_records(self):
        for field, bad, error in [
            ('toolchain', None, 'toolchain'),
            ('toolchain', {'bazel': '8.0', 'ndk': '28.2.13676358'}, 'toolchain'),
            ('build_flags', [], 'build flags'),
            ('build_targets', [], 'build targets'),
            ('upstream_dependencies', {}, 'dependency revision'),
            ('dependency_overrides', {}, 'compatibility override'),
        ]:
            with self.subTest(field=field, value=bad):
                manifest = self.make_provenance()
                manifest[field] = bad
                (self.bundle / 'native-build.json').write_text(json.dumps(manifest))
                self.assert_rejected(error, provenance=True)

    def test_records_actual_toolchain_flags_targets_and_selected_dependency_refs(self):
        source = self.root / 'upstream'
        (source / 'c').mkdir(parents=True)
        for directory in ('native', 'third_party/litert_lm/c'):
            for path in (ROOT / directory).glob('*'):
                if path.suffix in ('.cc', '.h'):
                    shutil.copyfile(path, source / 'c' / path.name)
        expected = self.make_provenance()
        # WORKSPACE may redeclare a constant; the final selected ref must win.
        (source / 'WORKSPACE').write_text('LITERT_REF = "' + '0' * 40 + '"\n' +
            '\n'.join(f'{name.upper()}_REF = "{ref}"' for name, ref in
                      expected['upstream_dependencies'].items()))
        git = self.root / 'git'
        git.write_text('#!/bin/sh\nprintf "%s\\n" "' + expected['litert_lm_commit'] + '"\n')
        git.chmod(0o755)
        (self.root / 'ndk').mkdir()
        (self.root / 'ndk/source.properties').write_text('Pkg.Revision = 28.2.13676358\n')
        bazel = self.root / 'bazel'
        bazel.write_text('#!/bin/sh\nprintf "bazel 7.6.1\\n"\n')
        bazel.chmod(0o755)
        result = self.run_verifier(source=source, metadata=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        recorded = json.loads((self.bundle / 'native-build.json').read_text())
        for field in ['toolchain', 'build_flags', 'build_targets', 'upstream_dependencies']:
            self.assertEqual(recorded[field], expected[field])
        (self.root / 'ndk/source.properties').write_text('Pkg.Revision = 27.0.0\n')
        result = self.run_verifier(source=source, metadata=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Actual NDK/Bazel version', result.stderr)

    def test_rejects_stale_contract_provenance(self):
        manifest = self.make_provenance()
        manifest['contract_files']['ffigen.yaml'] = 'stale'
        (self.bundle / 'native-build.json').write_text(json.dumps(manifest))
        self.assert_rejected('contract hash mismatch', provenance=True)

    def test_does_not_record_provenance_for_stale_copied_bridge(self):
        source = self.root / 'upstream'
        (source / 'c').mkdir(parents=True)
        for directory in ('native', 'third_party/litert_lm/c'):
            for path in (ROOT / directory).glob('*'):
                if path.suffix in ('.cc', '.h'):
                    shutil.copyfile(path, source / 'c' / path.name)
        (source / 'c/litert_lm_bridge.cc').write_text('// stale copied bridge\n')
        commit = self.make_provenance()['litert_lm_commit']
        git = self.root / 'git'
        git.write_text('#!/bin/sh\nprintf "%s\\n" "' + commit + '"\n')
        git.chmod(0o755)
        self.assert_rejected('built source differs', source=source)

    def make_archive(self, name, libs, *, aligned=True, compressed=False):
        path = self.root / name
        prefix = 'base/lib/arm64-v8a/' if name.endswith('.aab') else 'lib/arm64-v8a/'
        with zipfile.ZipFile(path, 'w') as archive:
            for lib_name, data in libs.items():
                entry = zipfile.ZipInfo(prefix + lib_name)
                entry.compress_type = zipfile.ZIP_DEFLATED if compressed else zipfile.ZIP_STORED
                if aligned and not compressed and name.endswith('.apk'):
                    offset = archive.fp.tell() + 30 + len(entry.filename.encode())
                    padding = (-offset) % 16384
                    if padding < 4:
                        padding += 16384
                    entry.extra = struct.pack('<HH', 0xffff, padding - 4) + bytes(padding - 4)
                archive.writestr(entry, data)
        return path

    def test_accepts_aligned_apk_and_aab(self):
        for name in ('app.apk', 'app.aab'):
            artifact = self.make_archive(name, {'liblitert_lm_c.so': elf()})
            result = self.run_verifier(artifact)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_apk_missing_any_bundled_library(self):
        (self.bundle / 'libvendor.so').write_bytes(elf())
        artifact = self.make_archive('app.apk', {'liblitert_lm_c.so': elf()})
        self.assert_rejected('libvendor.so', artifact)

    def test_checks_additional_apk_libraries(self):
        artifact = self.make_archive('app.apk', {'liblitert_lm_c.so': elf(),
                                               'libflutter.so': elf(machine=62)})
        self.assert_rejected('AArch64', artifact)

    def test_rejects_unaligned_uncompressed_apk(self):
        artifact = self.make_archive('app.apk', {'liblitert_lm_c.so': elf()}, aligned=False)
        self.assert_rejected('ZIP alignment', artifact)

    def test_accepts_compressed_apk_with_aligned_elf(self):
        artifact = self.make_archive('app.apk', {'liblitert_lm_c.so': elf()}, compressed=True)
        result = self.run_verifier(artifact)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_stale_packaged_library_with_same_exports(self):
        artifact = self.make_archive('app.aab', {'liblitert_lm_c.so': elf() + b'stale binary'})
        self.assert_rejected('identity mismatch', artifact)

    def test_build_id_allows_gradle_symbol_stripping(self):
        note = struct.pack('<III', 4, 4, 3) + b'GNU\0' + b'abcd'
        data = bytearray(elf(segments=[(1, 0, 0, 0x4000), (4, 176, 0, 4)]))
        struct.pack_into('<Q', data, 64 + 56 + 32, len(note))
        data.extend(note)
        (self.bundle / 'liblitert_lm_c.so').write_bytes(data + b'debug section')
        artifact = self.make_archive('app.aab', {'liblitert_lm_c.so': data})
        result = self.run_verifier(artifact)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_packaged_build_id_mismatch(self):
        note = struct.pack('<III', 4, 4, 3) + b'GNU\0' + b'abcd'
        data = bytearray(elf(segments=[(1, 0, 0, 0x4000), (4, 176, 0, 4)]))
        struct.pack_into('<Q', data, 64 + 56 + 32, len(note))
        data.extend(note)
        (self.bundle / 'liblitert_lm_c.so').write_bytes(data)
        data[-4:] = b'efgh'
        artifact = self.make_archive('app.aab', {'liblitert_lm_c.so': data})
        self.assert_rejected('identity mismatch', artifact)

    def test_checks_packaged_symbols(self):
        artifact = self.make_archive('app.aab', {'liblitert_lm_c.so': elf()})
        self.nm.write_text('#!/bin/sh\nprintf "0000 T litert_lm_engine_create\\n"\n')
        self.assert_rejected('litert_lm_extra', artifact)


class NativeTargetTest(unittest.TestCase):
    def test_repatch_replaces_old_target_and_preserves_upstream_targets(self):
        source = (ROOT / 'tool/build_litert_lm_android.sh').read_text()
        patch = source[source.index('patch_shared_target() {'):source.index('\npatch_minizip_archive()')]
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            (root / 'native').mkdir()
            (root / 'native/litert_lm_bridge.cc').write_text('// bridge source\n')
            (root / 'native/litert_lm_bridge.h').write_text('// bridge header\n')
            (root / 'native/litert_lm_model_bridge.cc').write_text('// model bridge source\n')
            (root / 'upstream/c').mkdir(parents=True)
            build = root / 'upstream/c/BUILD'
            original = 'cc_library(name = "upstream_engine")\n'
            build.write_text(original + '\ncc_binary(\n    name = "liblitert_lm_c.so",\n    deps = [":old"],\n)\n')
            result = subprocess.run(['bash', '-c', 'set -euo pipefail\nROOT_DIR="$1"\n' + patch +
                                     '\npatch_shared_target "$1/upstream"\npatch_shared_target "$1/upstream"',
                                     'test', str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = build.read_text()
            self.assertTrue(output.startswith(original))
            self.assertEqual(output.count('name = "liblitert_lm_c.so"'), 1)
            self.assertIn('litert_lm_bridge.cc', output)
            self.assertIn('litert_lm_model_bridge.cc', output)
            self.assertEqual((root / 'upstream/c/litert_lm_model_bridge.cc').read_text(),
                             '// model bridge source\n')
            self.assertNotIn(':old', output)
            self.assertIn('lrlm_*', (root / 'upstream/c/litert_lm_c_api.lds').read_text())

    def test_cached_checkout_diagnostics_do_not_pollute_source_path(self):
        source = (ROOT / 'tool/build_litert_lm_android.sh').read_text()
        checkout = source[source.index('checkout_source() {'):source.index('\npatch_shared_target()')]
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            (root / 'LiteRT-LM/.git').mkdir(parents=True)
            fake_git = 'git() { if [[ "$*" == *checkout* ]]; then echo "M c/BUILD"; fi; }\n'
            result = subprocess.run(['bash', '-c', 'set -euo pipefail\nBUILD_ROOT="$1"\n'
                                     'LITERT_LM_COMMIT=fixture\n' + fake_git + checkout +
                                     '\nresult="$(checkout_source)"\nprintf "%s" "$result"',
                                     'test', str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, str(root / 'LiteRT-LM'))

    def test_git_failure_propagates_out_of_checkout_command_substitution(self):
        source = (ROOT / 'tool/build_litert_lm_android.sh').read_text()
        checkout = source[source.index('checkout_source() {'):source.index('\npatch_shared_target()')]
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            (root / 'LiteRT-LM/.git').mkdir(parents=True)
            fake_git = 'git() { if [[ "$*" == *fetch* ]]; then return 7; fi; }\n'
            result = subprocess.run(['bash', '-c', 'set -euo pipefail\nBUILD_ROOT="$1"\n'
                                     'LITERT_LM_COMMIT=fixture\n' + fake_git + checkout +
                                     '\nresult="$(checkout_source)"\nprintf "%s" "$result"',
                                     'test', str(root)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertEqual(result.stdout, '')

    def test_rules_cc_pin_precedes_go_dependencies_and_is_idempotent(self):
        source = (ROOT / 'tool/build_litert_lm_android.sh').read_text()
        self.assertIn('patch_rules_cc_archive() {', source)
        patch = source[source.index('patch_rules_cc_archive() {'):source.index('\nfetch_gpu_prebuilts()')]
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            workspace = root / 'WORKSPACE'
            workspace.write_text('load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")\n'
                                 'go_rules_dependencies()\ntf_workspace3()\n')
            constants = ('RULES_CC_VERSION=0.2.25\n'
                         'RULES_CC_SHA256=bd7124a844d0403b4b353bcea34d6c8b2ba88dc26881c26c9ee668da89b71846\n')
            result = subprocess.run(['bash', '-c', 'set -euo pipefail\n' + constants + patch +
                                     '\npatch_rules_cc_archive "$1"\npatch_rules_cc_archive "$1"',
                                     'test', str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = workspace.read_text()
            self.assertEqual(output.count('name = "rules_cc"'), 1)
            self.assertLess(output.index('name = "rules_cc"'), output.index('go_rules_dependencies()'))
            self.assertIn('rules_cc-0.2.25', output)
            self.assertIn('bd7124a844d0403b4b353bcea34d6c8b2ba88dc26881c26c9ee668da89b71846', output)


if __name__ == '__main__':
    unittest.main()
