"""Regression coverage for the pinned upstream WORKSPACE bootstrap patch."""
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class WorkspaceBootstrapTest(unittest.TestCase):
    def skylib_command(self, root):
        script = (ROOT / 'tool/build_litert_lm_android.sh').read_text()
        patch = script[script.index('patch_bazel_skylib_archive() {'):
                       script.index('\npatch_rules_cc_archive()')]
        constants = ('BAZEL_SKYLIB_VERSION=1.9.0\n'
                     'BAZEL_SKYLIB_SHA256=3b5b49006181f5f8ff626ef8ddceaa95e9bb8ad294f7b5d7b11ea9f7ddaf8c59\n')
        return ['bash', '-c', 'set -euo pipefail\n' + constants + patch +
                '\npatch_bazel_skylib_archive "$1"', 'test', str(root)]

    def test_skylib_pin_precedes_rules_shell_and_survives_cached_repatch(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            workspace = root / 'WORKSPACE'
            original = ('load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")\n'
                        'rules_shell_dependencies()\ngo_rules_dependencies()\ntf_workspace3()\n')
            workspace.write_text(original)
            first = subprocess.run(self.skylib_command(root), capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            output = workspace.read_text()
            self.assertEqual(output.count('name = "bazel_skylib"'), 1)
            self.assertLess(output.index('name = "bazel_skylib"'), output.index('rules_shell_dependencies()'))
            self.assertIn('bazel-skylib-1.9.0.tar.gz', output)
            self.assertIn('3b5b49006181f5f8ff626ef8ddceaa95e9bb8ad294f7b5d7b11ea9f7ddaf8c59', output)
            second = subprocess.run(self.skylib_command(root), capture_output=True, text=True)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(workspace.read_text(), output)

    def test_skylib_patch_rejects_an_unexpected_existing_declaration(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            workspace = root / 'WORKSPACE'
            original = ('load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")\n'
                        'http_archive(name = "bazel_skylib", url = "unexpected")\n')
            workspace.write_text(original)
            result = subprocess.run(self.skylib_command(root), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unexpected upstream Skylib declaration', result.stderr)
            self.assertEqual(workspace.read_text(), original)

    def test_skylib_patch_rejects_cached_pin_drift(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            workspace = root / 'WORKSPACE'
            workspace.write_text('load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")\n')
            first = subprocess.run(self.skylib_command(root), capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            drifted = workspace.read_text().replace('bazel-skylib-1.9.0', 'bazel-skylib-1.7.1')
            workspace.write_text(drifted)
            result = subprocess.run(self.skylib_command(root), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Cached Skylib patch differs', result.stderr)
            self.assertEqual(workspace.read_text(), drifted)

    def test_oss_dispatch_patch_removes_only_disabled_private_hook_dependency(self):
        script = (ROOT / 'tool/build_litert_lm_android.sh').read_text()
        self.assertIn('patch_litert_oss_hooks() {', script)
        patch = script[script.index('patch_litert_oss_hooks() {'):
                       script.index('\nfetch_gpu_prebuilts()')]
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            workspace = root / 'WORKSPACE'
            workspace.write_text('http_archive(\n    name = "litert",\n    patch_cmds = [\n    ],\n)\n')
            command = ['bash', '-c', 'set -euo pipefail\n' + patch +
                       '\npatch_litert_oss_hooks "$1"', 'test', temp]
            first = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            output = workspace.read_text()
            second = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(workspace.read_text(), output)
            build = root / 'litert/vendors/google_tensor/dispatch/BUILD'
            build.parent.mkdir(parents=True)
            original = ('    deps = [\n'
                        '        ":google_tensor_hook",\n'
                        '        "//litert/c:litert_profiler_types",\n'
                        '        # copybara:uncomment "//litert/c/options/google:litert_google_tensor_privileged_options_type",\n'
                        '        "//litert/vendors/google_tensor/hooks",\n'
                        '        # copybara:uncomment "//litert/vendors/google_tensor/dispatch/google:google_tensor_privileged_options_utils",\n'
                        '        "@com_google_absl//absl/algorithm:container",\n'
                        '        "//litert/c/internal:litert_scheduling_info",\n'
                        '    ],\n')
            build.write_text(original)
            applied = subprocess.run(['git', 'apply', str(root / 'lib_litert_lm_google_tensor_oss.patch')],
                                     cwd=root, capture_output=True, text=True)
            self.assertEqual(applied.returncode, 0, applied.stderr)
            self.assertEqual(build.read_text(), original.replace(
                '        "//litert/vendors/google_tensor/hooks",\n', ''))

    def test_proxy_is_initialized_before_transitive_cc_loads_on_reused_checkout(self):
        script = (ROOT / 'tool/build_litert_lm_android.sh').read_text()
        patch = script[script.index('patch_rules_cc_archive() {'):
                       script.index('\nfetch_gpu_prebuilts()')]
        constants = ('RULES_CC_VERSION=0.2.25\n'
                     'RULES_CC_SHA256=bd7124a844d0403b4b353bcea34d6c8b2ba88dc26881c26c9ee668da89b71846\n')
        with tempfile.TemporaryDirectory() as temp:
            workspace = pathlib.Path(temp) / 'WORKSPACE'
            workspace.write_text(
                'load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")\n'
                'go_rules_dependencies()\n'
                'tf_workspace3()\n'
                'load("@org_tensorflow//tensorflow:workspace2.bzl", "tf_workspace2")\n')
            command = ['bash', '-c', 'set -euo pipefail\n' + constants + patch +
                       '\npatch_rules_cc_archive "$1"', 'test', temp]
            first = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            output = workspace.read_text()
            self.assertIn('compatibility_proxy_repo()', output)
            self.assertLess(output.index('tf_workspace3()'), output.index('bazel_features_deps()'))
            self.assertLess(output.index('bazel_features_deps()'), output.index('compatibility_proxy_repo()'))
            self.assertLess(output.index('compatibility_proxy_repo()'), output.index('workspace2.bzl'))
            second = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(workspace.read_text(), output)


if __name__ == '__main__':
    unittest.main()
