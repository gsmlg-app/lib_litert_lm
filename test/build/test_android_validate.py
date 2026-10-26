"""Host collector tests. No adb, Android device, model inference or SDK is needed."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tool/android_validate.py'
spec = importlib.util.spec_from_file_location('android_validate', SCRIPT)
av = importlib.util.module_from_spec(spec)
spec.loader.exec_module(av)


class AndroidValidationTest(unittest.TestCase):
    def test_plan_never_invokes_adb_and_includes_every_explicit_tier(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'must-not-be-created'
            result = subprocess.run([sys.executable, str(SCRIPT), '--plan',
                                     '--adb', '/missing/adb', '--output', str(output)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(result.stdout)
            self.assertEqual(plan['applicationId'], 'dev.gsmlg.litertlm.example')
            self.assertEqual(len(plan['runs']), 8)
            self.assertEqual({r['context'] for r in plan['runs']}, {4096, 8192, 16384, 32768})
            self.assertEqual({r['backend'] for r in plan['runs']}, {'cpu', 'gpu'})
            self.assertEqual(plan['status'], 'planned_not_run')
            self.assertFalse(output.exists())

    def test_pinned_manifest_rejects_revisions_hashes_and_runtime_drift(self):
        manifest = av.load_manifest(ROOT / 'tool/models/gemma-4-e2b.json')
        self.assertEqual(manifest['bytes'], 2588147712)
        for field in ['revision', 'sha256', 'runtimeCommit', 'filename', 'bytes']:
            changed = copy.deepcopy(manifest)
            changed[field] = 'changed'
            with self.assertRaises(av.ValidationError, msg=field):
                av.validate_manifest(changed)

    def test_model_hash_and_size_are_both_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'fixture.litertlm'
            path.write_bytes(b'model fixture')
            expected = {'bytes': path.stat().st_size,
                        'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
            self.assertEqual(av.verify_file(path, expected)['sha256'], expected['sha256'])
            with self.assertRaises(av.ValidationError):
                av.verify_file(path, dict(expected, bytes=1))
            with self.assertRaises(av.ValidationError):
                av.verify_file(path, dict(expected, sha256='0' * 64))

    def test_flutter_commands_keep_app_data_and_pass_actual_private_paths(self):
        command = av.flutter_test_command('flutter', 'serial-1', 'gpu', 32768,
                                         '/data/user/10/app/files/model.litertlm',
                                         '/data/user/10/app/files/image.png',
                                         '/data/user/10/app/files/audio.wav')
        self.assertIn('--no-uninstall', command)
        self.assertIn('--no-pub', command)
        self.assertIn('--dart-define=BACKEND=gpu', command)
        self.assertIn('--dart-define=CONTEXT=32768', command)
        self.assertIn('--dart-define=MODEL_IMAGE_PATH=/data/user/10/app/files/image.png', command)
        self.assertIn('--dart-define=MODEL_AUDIO_PATH=/data/user/10/app/files/audio.wav', command)
        self.assertIn('integration_test/native_model_test.dart', command)
        self.assertEqual(command[command.index('-d') + 1], 'serial-1')

    def test_run_as_command_quotes_remote_arguments_without_host_shell(self):
        import shlex
        command = av.run_as_command('adb', 'serial', ['sh', '-c', "cat > 'files/a $b'" ])
        self.assertEqual(command[:5], ['adb', '-s', 'serial', 'shell', '-T'])
        self.assertEqual(shlex.split(command[5]), ['run-as', av.APP_ID, 'sh', '-c', "cat > 'files/a $b'"])

    def test_reports_accept_prefixes_unicode_and_trailing_progress(self):
        text = '\x1b[2K00:10 +0: LRLM_REPORT {"answer":"山川", "context":4096} extra\n'
        text += 'I/flutter (123): LRLM_REPORT {"scenario":"summary"}\n'
        text += 'LRLM_REPORT {broken}\nLRLM_REPORT [1,2]\n'
        reports, errors = av.parse_reports(text)
        self.assertEqual(len(reports), 2)
        self.assertEqual(reports[0]['answer'], '山川')
        self.assertEqual(len(errors), 2)

    def test_meminfo_parses_summary_and_legacy_pss_without_inventing_values(self):
        parsed = av.parse_meminfo(''' App Summary\n Native Heap: 120\n Graphics: 30\n TOTAL PSS: 456 TOTAL RSS: 800 TOTAL SWAP PSS: 7\n''')
        self.assertEqual(parsed, {'pssKiB': 456, 'nativeHeapPssKiB': 120,
                                 'graphicsPssKiB': 30, 'swapPssKiB': 7, 'rssKiB': 800})
        self.assertEqual(av.parse_meminfo(' Native Heap 12 2 0 4\n TOTAL 40 10 0 5\n')['pssKiB'], 40)
        missing = av.parse_meminfo('Permission Denial: unavailable')
        self.assertTrue(all(value is None for value in missing.values()))
        self.assertEqual(av.parse_meminfo('Graphics: 0')['graphicsPssKiB'], 0)

    def test_proc_memory_distinguishes_zero_from_permission_denial(self):
        result = av.parse_proc_status('VmRSS:\t200 kB\nVmSwap:\t0 kB\nRssAnon: 150 kB\n')
        self.assertEqual(result['rssKiB'], 200)
        self.assertEqual(result['swapKiB'], 0)
        self.assertIsNone(result['rssFileKiB'])
        self.assertTrue(all(v is None for v in av.parse_proc_status('Permission denied').values()))

    def test_evaluation_requires_reports_even_when_flutter_exits_zero(self):
        evaluated = av.evaluate_run([], 0, 'cpu', 4096)
        self.assertEqual(evaluated['automatedStatus'], 'incomplete')
        self.assertEqual(evaluated['manualLifecycleAcceptance'], 'pending')
        self.assertEqual(av.evaluate_run([], 1, 'cpu', 4096)['automatedStatus'], 'failed')

    def test_evaluation_checks_all_native_scenarios_and_keeps_manual_pending(self):
        rows = []
        for phase in ['cold_engine', 'warm_disk_cache']:
            for position in [.05, .5, .95]:
                rows.append({'backend': 'cpu', 'context': 4096, 'scenario': 'retrieval',
                             'phase': phase, 'position': position, 'retrievalCorrect': True,
                             'model': {'artifactSha256': av.PIN['sha256'], 'revision': av.PIN['revision'],
                                       'runtimeCommit': av.PIN['runtimeCommit'], 'runtimeVersion': av.PIN['runtimeVersion'],
                                       'effectiveContextTokens': 4096},
                             'budget': {'exact': True, 'requiredTokens': 4000}})
            for scenario in ['cancel_prefill', 'cancel_decode']:
                rows.append({'backend': 'cpu', 'context': 4096, 'phase': phase,
                             'scenario': scenario, 'cancelled': True,
                             'phaseConfirmed': None if scenario == 'cancel_prefill' else True,
                             'nativePrefillTrace': 'pending', 'retry': 'OK'})
            rows.append({'backend': 'cpu', 'context': 4096, 'phase': phase,
                         'scenario': 'multi_turn_full', 'failure': 'context-full'})
        rows.append({'backend': 'cpu', 'context': 4096, 'scenario': 'summary', 'completedRows': 12})
        result = av.evaluate_run(rows, 0, 'cpu', 4096)
        self.assertEqual(result['automatedStatus'], 'passed')
        self.assertEqual(result['manualLifecycleAcceptance'], 'pending')
        self.assertFalse(result['osPageCacheColdProven'])
        self.assertEqual(result['nativePrefillPhaseAcceptance'], 'pending_native_trace')
        rows[0]['retrievalCorrect'] = False
        self.assertEqual(av.evaluate_run(rows, 0, 'cpu', 4096)['automatedStatus'], 'failed')

    def test_device_metadata_checks_arm64_and_records_raw_soc_and_ram(self):
        class FakeCommands:
            def capture(self, command, **kwargs):
                if command[-1] == 'ro.product.cpu.abilist':
                    stdout = 'arm64-v8a,armeabi-v7a'
                elif command[-1] == 'ro.soc.model':
                    stdout = 'SM8550'
                elif command[-1] == '/proc/meminfo':
                    stdout = 'MemTotal: 12345 kB\n'
                else:
                    stdout = ''
                return {'exitCode': 0, 'stdout': stdout, 'stderr': ''}
        result = av.device_metadata(FakeCommands(), 'adb', 'exact-serial')
        self.assertEqual(result['serial'], 'exact-serial')
        self.assertEqual(result['totalRamKiB'], 12345)
        self.assertEqual(result['properties']['ro.soc.model'], 'SM8550')
        self.assertIsNone(result['properties']['ro.product.model'])

    def test_binary_deployment_verifies_device_sha_before_rename(self):
        class FakeCommands:
            def __init__(self):
                self.calls = []
                self.uploaded = None
            def capture(self, command, **kwargs):
                import shlex
                remote = shlex.split(command[-1])
                self.calls.append(remote)
                if kwargs.get('stdin'):
                    self.uploaded = kwargs['stdin'].read()
                stdout = ''
                if 'sha256sum' in remote:
                    path = remote[-1]
                    stdout = ('a' * 64 + '  ' + path) if '.upload-' in path else ''
                return {'exitCode': 0, 'stdout': stdout, 'stderr': ''}
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'binary'
            source.write_bytes(b'\x00\xff\x01')
            commands = FakeCommands()
            result = av.deploy_file(commands, 'adb', 'serial', {'path': str(source)},
                                    'files/validation/model', 'a' * 64)
            self.assertEqual(commands.uploaded, b'\x00\xff\x01')
            self.assertTrue(result['deviceHashVerified'])
            commands_seen = [call[2] for call in commands.calls]
            self.assertLess(commands_seen.index('sha256sum', 2), commands_seen.index('mv'))

    def test_sampling_summary_keeps_unavailable_values_null(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            self.assertIsNone(av.sampling_summary(output)['maxObservedPssKiB'])
            (output / 'memory-samples.jsonl').write_text(json.dumps({
                'meminfo': {'pssKiB': 20, 'nativeHeapPssKiB': None, 'graphicsPssKiB': 0},
                'processes': [{'rssKiB': 30, 'swapKiB': 0}],
            }) + '\n')
            result = av.sampling_summary(output)
            self.assertEqual(result['maxObservedPssKiB'], 20)
            self.assertIsNone(result['maxObservedNativeHeapPssKiB'])
            self.assertEqual(result['maxObservedGraphicsPssKiB'], 0)
            self.assertEqual(result['maxObservedProcessSwapKiB'], 0)

    def test_live_command_timeout_stops_its_own_process_and_preserves_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            code = 'import time; print("before timeout", flush=True); time.sleep(30)'
            result = av.run_logged([sys.executable, '-c', code], output, timeout=1.0)
            self.assertTrue(result['timedOut'])
            self.assertNotEqual(result['exitCode'], 0)
            self.assertIn('before timeout', (output / 'stdout.log').read_text())


if __name__ == '__main__':
    unittest.main()
