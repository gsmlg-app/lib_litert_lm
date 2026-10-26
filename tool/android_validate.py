#!/usr/bin/env python3
"""Plan/run pinned Android native-model validation; standard library only.

A plan and host unit tests are not native inference evidence. Real runs retain
raw evidence and keep unavailable counters null and manual acceptance pending.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
APP_ID = 'dev.gsmlg.litertlm.example'
CONTEXTS = (4096, 8192, 16384, 32768)
PIN = {
    'modelId': 'gemma-4-e2b',
    'repository': 'litert-community/gemma-4-E2B-it-litert-lm',
    'revision': '1caa527c1e88b55f046fcd8d2b4265606680663d',
    'filename': 'gemma-4-E2B-it.litertlm',
    'sha256': '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
    'bytes': 2588147712,
    'declaredMaxContextTokens': 32768,
    'runtimeVersion': 'v0.18.1',
    'runtimeCommit': 'bda624851d74be34d4e1f7fac1fc4155939539c7',
}


class ValidationError(Exception):
    pass


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def validate_manifest(manifest):
    if not isinstance(manifest, dict):
        raise ValidationError('Model manifest must be an object')
    for key, expected in PIN.items():
        if manifest.get(key) != expected:
            raise ValidationError(f'Pinned manifest mismatch: {key}')
    return manifest


def load_manifest(path):
    return validate_manifest(json.loads(Path(path).read_text()))


def file_identity(path):
    path = Path(path).resolve()
    if not path.is_file():
        raise ValidationError(f'Not a readable regular file: {path}')
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b''):
            digest.update(chunk)
    return {'path': str(path), 'bytes': path.stat().st_size, 'sha256': digest.hexdigest()}


def verify_file(path, expected):
    if not Path(path).is_file() or Path(path).stat().st_size != expected['bytes']:
        raise ValidationError(f'Pinned model byte length mismatch: {path}')
    actual = file_identity(path)
    if actual['sha256'] != expected['sha256']:
        raise ValidationError(f'Pinned model SHA-256 mismatch: {path}')
    return actual


def attachment_identity(path, kind):
    actual = file_identity(path)
    with Path(path).open('rb') as source:
        header = source.read(12)
    png = header.startswith(b'\x89PNG\r\n\x1a\n')
    jpeg = header.startswith(b'\xff\xd8\xff')
    wav = header[:4] == b'RIFF' and header[8:12] == b'WAVE'
    if not ((png or jpeg) if kind == 'image' else wav):
        raise ValidationError(f'Expected actual PNG/JPEG image or WAV audio: {path}')
    actual['deviceFilename'] = 'input-image.png' if png else 'input-image.jpg' if jpeg else 'input-audio.wav'
    return actual


def adb_command(adb, serial, *arguments):
    return [adb, '-s', serial, *arguments]


def run_as_command(adb, serial, arguments):
    # adb shell parses a remote command. Quote once for that shell; never use a
    # host shell, and never interpolate model bytes into command text.
    return adb_command(adb, serial, 'shell', '-T', shlex.join(['run-as', APP_ID, *arguments]))


def flutter_test_command(flutter, serial, backend, context, model_path,
                         image_path=None, audio_path=None):
    command = [flutter, 'test', '--no-pub', '--no-uninstall',
               'integration_test/native_model_test.dart', '-d', serial,
               f'--dart-define=MODEL_PATH={model_path}',
               f'--dart-define=BACKEND={backend}', f'--dart-define=CONTEXT={context}']
    for key, value in [('MODEL_IMAGE_PATH', image_path), ('MODEL_AUDIO_PATH', audio_path)]:
        if value is not None:
            command.append(f'--dart-define={key}={value}')
    return command


def bootstrap_command(flutter):
    return [flutter, 'build', 'apk', '--debug', '--no-pub', '--target-platform',
            'android-arm64', '-t', 'integration_test/native_model_test.dart']


def parse_reports(text):
    reports, errors = [], []
    decoder = json.JSONDecoder()
    for number, line in enumerate(text.splitlines(), 1):
        line = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', line)
        marker = line.find('LRLM_REPORT ')
        if marker < 0:
            continue
        try:
            payload, _ = decoder.raw_decode(line[marker + len('LRLM_REPORT '):].lstrip())
            if not isinstance(payload, dict):
                raise ValueError('report is not a JSON object')
            reports.append(payload)
        except (ValueError, json.JSONDecodeError) as error:
            errors.append({'line': number, 'error': str(error)})
    return reports, errors


def _counter(text, patterns):
    for pattern in patterns:
        match = re.search(pattern, text, re.MULTILINE)
        if match:
            return int(match.group(1))
    return None


def parse_meminfo(text):
    return {
        'pssKiB': _counter(text, [r'TOTAL PSS:\s*(\d+)', r'^\s*TOTAL:\s*(\d+)', r'^\s*TOTAL\s+(\d+)']),
        'nativeHeapPssKiB': _counter(text, [r'^\s*Native Heap:\s*(\d+)', r'^\s*Native Heap\s+(\d+)']),
        'graphicsPssKiB': _counter(text, [r'^\s*Graphics:\s*(\d+)']),
        'swapPssKiB': _counter(text, [r'TOTAL SWAP PSS:\s*(\d+)']),
        'rssKiB': _counter(text, [r'TOTAL RSS:\s*(\d+)']),
    }


def parse_proc_status(text):
    return {name: _counter(text, [rf'^{field}:\s*(\d+)\s+kB']) for name, field in [
        ('rssKiB', 'VmRSS'), ('swapKiB', 'VmSwap'), ('rssAnonKiB', 'RssAnon'),
        ('rssFileKiB', 'RssFile'), ('rssShmemKiB', 'RssShmem')]}


def evaluate_run(rows, exit_code, backend, context, requested_media=()):
    problems, missing = [], []
    relevant = [row for row in rows if row.get('backend') == backend and row.get('context') == context]
    for phase in ['cold_engine', 'warm_disk_cache']:
        for position in [.05, .5, .95]:
            found = [r for r in relevant if r.get('scenario') == 'retrieval'
                     and r.get('phase') == phase and r.get('position') == position]
            if not found:
                missing.append(f'{phase}/retrieval/{position}')
            else:
                for row in found:
                    if row.get('retrievalCorrect') is not True:
                        problems.append(f'{phase}/retrieval/{position} incorrect')
                    model, budget = row.get('model', {}), row.get('budget', {})
                    expected = {'artifactSha256': PIN['sha256'], 'revision': PIN['revision'],
                                'runtimeCommit': PIN['runtimeCommit'], 'runtimeVersion': PIN['runtimeVersion'],
                                'effectiveContextTokens': context}
                    if any(model.get(key) != value for key, value in expected.items()):
                        problems.append(f'{phase}/retrieval/{position} model/runtime/context identity mismatch')
                    required = budget.get('requiredTokens')
                    if budget.get('exact') is not True or type(required) is not int or not math.floor(context * .97) <= required <= context:
                        problems.append(f'{phase}/retrieval/{position} lacks exact near-capacity evidence')
        for scenario in ['cancel_prefill', 'cancel_decode', 'multi_turn_full']:
            found = [r for r in relevant if r.get('phase') == phase and r.get('scenario') == scenario]
            if not found:
                missing.append(f'{phase}/{scenario}')
            elif scenario == 'multi_turn_full':
                if any(r.get('failure') != 'context-full' for r in found):
                    problems.append(f'{phase}/{scenario} did not report context-full')
            elif any(r.get('cancelled') is not True
                     or (scenario == 'cancel_decode' and r.get('phaseConfirmed') is not True)
                     or not isinstance(r.get('retry'), str) or not r['retry'] for r in found):
                problems.append(f'{phase}/{scenario} cancellation/reuse not confirmed')
    if not any(r.get('scenario') == 'summary' for r in relevant):
        missing.append('summary')
    media = {}
    for kind in ['image', 'audio']:
        found = [r for r in relevant if r.get('scenario') == f'media_{kind}']
        media[kind] = found[-1].get('status', 'not_reported') if found else 'not_reported'
        if kind in requested_media and media[kind] not in ['passed', 'unsupported_by_artifact']:
            missing.append(f'media_{kind} requested but not validated')
    status = 'failed' if exit_code != 0 or problems else 'incomplete' if missing else 'passed'
    return {'automatedStatus': status, 'problems': problems, 'missingReports': missing,
            'manualLifecycleAcceptance': 'pending', 'nativePrefillPhaseAcceptance': 'pending_native_trace',
            'mediaAcceptance': media, 'osPageCacheColdProven': False,
            'cacheInterpretation': 'cold_engine is fresh engine initialization; OS page cache is uncontrolled'}


class Commands:
    def __init__(self, output, cwd=ROOT / 'example'):
        self.output, self.cwd = Path(output), cwd
        self.lock = threading.Lock()

    def capture(self, arguments, *, stdin=None, timeout=30, check=True):
        started = utc_now()
        try:
            result = subprocess.run(arguments, stdin=stdin, capture_output=True,
                                    cwd=self.cwd, timeout=timeout)
            code = result.returncode
            stdout = result.stdout.decode('utf-8', errors='replace')
            stderr = result.stderr.decode('utf-8', errors='replace')
        except subprocess.TimeoutExpired as error:
            code, stdout, stderr = 124, '', f'Command timed out: {error}'
        except OSError as error:
            code, stdout, stderr = 127, '', str(error)
        record = {'startedUtc': started, 'finishedUtc': utc_now(), 'command': arguments,
                  'exitCode': code, 'stdout': stdout, 'stderr': stderr}
        with self.lock, (self.output / 'commands.jsonl').open('a') as log:
            log.write(json.dumps(record, ensure_ascii=False) + '\n')
        if check and code:
            raise ValidationError(f'Command failed ({code}): {shlex.join(arguments)}\n{stderr[-1000:]}')
        return record


def stop_process(process):
    if process.poll() is not None:
        return
    if os.name == 'posix':
        os.killpg(process.pid, signal.SIGTERM)
    else:
        process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        if os.name == 'posix':
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
        process.wait(timeout=10)


def run_logged(command, output, timeout, cwd=None):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    started, timed_out = utc_now(), False
    with (output / 'stdout.log').open('wb') as stdout, (output / 'stderr.log').open('wb') as stderr:
        process = subprocess.Popen(command, cwd=cwd, stdout=stdout, stderr=stderr,
                                   start_new_session=(os.name == 'posix'))
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            stop_process(process)
    return {'command': command, 'startedUtc': started, 'finishedUtc': utc_now(),
            'exitCode': process.returncode, 'timedOut': timed_out}


def device_metadata(commands, adb, serial):
    commands.capture(adb_command(adb, serial, 'get-state'))
    properties = {}
    for key in ['ro.product.manufacturer', 'ro.product.model', 'ro.soc.manufacturer',
                'ro.soc.model', 'ro.board.platform', 'ro.hardware', 'ro.product.cpu.abilist',
                'ro.build.version.release', 'ro.build.version.sdk', 'ro.build.fingerprint',
                'ro.kernel.qemu']:
        value = commands.capture(adb_command(adb, serial, 'shell', 'getprop', key))['stdout'].strip()
        properties[key] = value or None
    if 'arm64-v8a' not in (properties['ro.product.cpu.abilist'] or '').split(','):
        raise ValidationError('Selected device does not report arm64-v8a support')
    memory = commands.capture(adb_command(adb, serial, 'shell', 'cat', '/proc/meminfo'), check=False)
    return {'serial': serial, 'observedUtc': utc_now(), 'properties': properties,
            'totalRamKiB': _counter(memory['stdout'], [r'^MemTotal:\s*(\d+)\s+kB']),
            'memoryQueryError': memory['stderr'] or None}


def deploy_file(commands, adb, serial, identity, relative_path, expected_sha):
    final = str(PurePosixPath(relative_path))
    commands.capture(run_as_command(adb, serial, ['mkdir', '-p', str(PurePosixPath(final).parent)]))
    existing = commands.capture(run_as_command(adb, serial, ['sha256sum', final]), timeout=600, check=False)
    if existing['exitCode'] == 0 and existing['stdout'].split()[:1] == [expected_sha]:
        return {'relativePath': final, 'sha256': expected_sha, 'deviceHashVerified': True, 'reused': True}
    partial = final + '.upload-' + uuid.uuid4().hex
    try:
        with Path(identity['path']).open('rb') as source:
            commands.capture(run_as_command(adb, serial, ['sh', '-c', f'cat > {shlex.quote(partial)}']),
                             stdin=source, timeout=1200)
        result = commands.capture(run_as_command(adb, serial, ['sha256sum', partial]), timeout=600)
        if result['stdout'].split()[:1] != [expected_sha]:
            raise ValidationError(f'Device SHA-256 mismatch for {final}')
        commands.capture(run_as_command(adb, serial, ['mv', partial, final]))
    finally:
        commands.capture(run_as_command(adb, serial, ['rm', '-f', partial]), check=False)
    return {'relativePath': final, 'sha256': expected_sha, 'deviceHashVerified': True, 'reused': False}


def sample_memory(commands, adb, serial, output, stopped, interval):
    samples = output / 'memory'
    samples.mkdir()
    started, index = time.monotonic(), 0
    while not stopped.is_set():
        index += 1
        sample_started = utc_now()
        pid_result = commands.capture(adb_command(adb, serial, 'shell', 'pidof', APP_ID), timeout=10, check=False)
        if stopped.is_set():
            break
        pids = [int(value) for value in pid_result['stdout'].split() if value.isdigit()]
        memory = commands.capture(adb_command(adb, serial, 'shell', 'dumpsys', 'meminfo', '-d', APP_ID),
                                  timeout=15, check=False)
        memory_path = samples / f'{index:06}.meminfo.txt'
        memory_path.write_text(memory['stdout'] + '\n' + memory['stderr'])
        row = {'sampleStartedUtc': sample_started, 'observedUtc': utc_now(), 'elapsedSeconds': time.monotonic() - started,
               'appPids': pids, 'meminfo': parse_meminfo(memory['stdout']),
               'rawMeminfo': str(memory_path.relative_to(output)),
               'meminfoExitCode': memory['exitCode'], 'processes': []}
        for pid in pids:
            if stopped.is_set():
                break
            proc = commands.capture(run_as_command(adb, serial, ['cat', f'/proc/{pid}/status']),
                                    timeout=10, check=False)
            path = samples / f'{index:06}.proc-{pid}.status.txt'
            path.write_text(proc['stdout'] + '\n' + proc['stderr'])
            row['processes'].append({'pid': pid, **parse_proc_status(proc['stdout']),
                                     'exitCode': proc['exitCode'], 'rawStatus': str(path.relative_to(output))})
        with (output / 'memory-samples.jsonl').open('a') as log:
            log.write(json.dumps(row) + '\n')
        stopped.wait(interval)



def memory_worker(*arguments):
    try:
        sample_memory(*arguments)
    except Exception as error:
        write_json(arguments[3] / 'sampler-error.json', {'observedUtc': utc_now(), 'error': str(error)})


def sampling_summary(output):
    output = Path(output)
    path = output / 'memory-samples.jsonl'
    rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    fields = [('maxObservedPssKiB', 'pssKiB'), ('maxObservedNativeHeapPssKiB', 'nativeHeapPssKiB'),
              ('maxObservedGraphicsPssKiB', 'graphicsPssKiB')]
    summary = {'sampleCount': len(rows), 'samplingLimit': 'Observed samples are not a continuous process peak'}
    for name, field in fields:
        values = [r.get('meminfo', {}).get(field) for r in rows]
        summary[name] = max((v for v in values if v is not None), default=None)
    for name, field in [('maxObservedProcessRssKiB', 'rssKiB'), ('maxObservedProcessSwapKiB', 'swapKiB')]:
        values = [p.get(field) for r in rows for p in r.get('processes', [])]
        summary[name] = max((v for v in values if v is not None), default=None)
    error_path = output / 'sampler-error.json'
    summary['collectorError'] = json.loads(error_path.read_text()) if error_path.exists() else None
    return summary


def make_plan(args):
    manifest = load_manifest(args.manifest)
    gradle = (ROOT / 'example/android/app/build.gradle.kts').read_text()
    app = re.search(r'applicationId\s*=\s*"([^"]+)"', gradle)
    if not app or app.group(1) != APP_ID:
        raise ValidationError('Example applicationId differs from the collector contract')
    model = verify_file(args.model, manifest) if args.model else None
    image = attachment_identity(args.model_image, 'image') if args.model_image else None
    audio = attachment_identity(args.model_audio, 'audio') if args.model_audio else None
    base = f'<app-private-dir>/files/lrlm-validation/{manifest["sha256"][:16]}'
    return {'schemaVersion': 1, 'status': 'planned_not_run', 'applicationId': APP_ID,
            'model': manifest, 'hostModel': model, 'hostImage': image, 'hostAudio': audio,
            'hostHashVerified': model is not None, 'bootstrapCommand': bootstrap_command(args.flutter),
            'installCommand': adb_command(args.adb, args.device or '<serial>', 'install', '-r', '-t', str(ROOT / 'example/build/app/outputs/flutter-apk/app-debug.apk')),
            'privateDirectoryCommand': run_as_command(args.adb, args.device or '<serial>', ['pwd']),
            'deployment': {'transport': 'binary stdin through adb shell -T run-as; SHA-256 verified before atomic rename',
                           'modelPath': f'{base}/{manifest["filename"]}',
                           'stdinSource': args.model and str(args.model),
                           'copyCommandTemplate': run_as_command(args.adb, args.device or '<serial>', ['sh', '-c', 'cat > files/lrlm-validation/<sha-prefix>/<filename>.upload-<unique-id>'])},
            'runs': [{'backend': backend, 'context': context,
                      'command': flutter_test_command(args.flutter, args.device or '<serial>', backend,
                          context, f'{base}/{manifest["filename"]}',
                          f'{base}/{image["deviceFilename"]}' if image else None,
                          f'{base}/{audio["deviceFilename"]}' if audio else None)}
                     for backend in args.backends for context in args.contexts],
            'manualLifecycleAcceptance': 'pending', 'nativePrefillPhaseAcceptance': 'pending_native_trace',
            'osPageCacheColdProven': False,
            'evidenceLimit': 'No device/model inference is performed by --plan'}


def execute(args, plan):
    if not args.device or not args.model:
        raise ValidationError('--run requires --device and the pinned local --model')
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    commands = Commands(output)
    report = {'schemaVersion': 1, 'startedUtc': utc_now(), 'status': 'running', 'runs': [],
              'manualLifecycleAcceptance': 'pending', 'nativePrefillPhaseAcceptance': 'pending_native_trace',
              'osPageCacheColdProven': False}
    write_json(output / 'plan.json', plan)
    try:
        report['device'] = device_metadata(commands, args.adb, args.device)
        report['tools'] = {'adb': commands.capture([args.adb, 'version'])['stdout'],
                           'flutter': commands.capture([args.flutter, '--version', '--machine'], timeout=120)['stdout']}
        bootstrap = run_logged(bootstrap_command(args.flutter), output / 'bootstrap', args.timeout_seconds,
                               cwd=ROOT / 'example')
        report['bootstrap'] = bootstrap
        if bootstrap['exitCode']:
            raise ValidationError('Debuggable ARM64 bootstrap APK build failed; inspect bootstrap logs')
        apk = ROOT / 'example/build/app/outputs/flutter-apk/app-debug.apk'
        report['bootstrapApk'] = file_identity(apk)
        commands.capture(adb_command(args.adb, args.device, 'install', '-r', '-t', str(apk)), timeout=300)
        private = commands.capture(run_as_command(args.adb, args.device, ['pwd']))['stdout'].strip()
        if not private.startswith('/data/') or PurePosixPath(private).name != APP_ID:
            raise ValidationError('run-as did not return the actual application-private directory')
        uid = commands.capture(run_as_command(args.adb, args.device, ['id', '-u']))['stdout'].strip()
        if not uid.isdigit():
            raise ValidationError('run-as did not report an application UID')
        report['applicationPrivateDirectory'], report['applicationUid'] = private, int(uid)
        relative = f'files/lrlm-validation/{PIN["sha256"][:16]}'
        deployed = {}
        for kind, identity, name in [('model', plan['hostModel'], PIN['filename']),
                                     ('image', plan['hostImage'], (plan['hostImage'] or {}).get('deviceFilename')),
                                     ('audio', plan['hostAudio'], (plan['hostAudio'] or {}).get('deviceFilename'))]:
            if identity:
                deployed[kind] = deploy_file(commands, args.adb, args.device, identity,
                                             f'{relative}/{name}', identity['sha256'])
                deployed[kind]['absolutePath'] = f'{private}/{relative}/{name}'
        report['deployedFiles'] = deployed
        for requested in plan['runs']:
            backend, context = requested['backend'], requested['context']
            folder = output / f'{backend}-{context}'
            folder.mkdir()
            command = flutter_test_command(args.flutter, args.device, backend, context,
                       deployed['model']['absolutePath'],
                       deployed.get('image', {}).get('absolutePath'), deployed.get('audio', {}).get('absolutePath'))
            print(f'Running {backend} / {context}; evidence: {folder}', flush=True)
            stopped = threading.Event()
            sampler = threading.Thread(target=memory_worker,
                args=(commands, args.adb, args.device, folder, stopped, args.sample_seconds), daemon=True)
            logcat_command = adb_command(args.adb, args.device, 'logcat', '-v', 'threadtime', '-T', '1', f'--uid={uid}')
            with (folder / 'logcat.log').open('wb') as stdout, (folder / 'logcat-stderr.log').open('wb') as stderr:
                logcat = subprocess.Popen(logcat_command, stdout=stdout, stderr=stderr,
                                          start_new_session=(os.name == 'posix'))
                sampler.start()
                try:
                    result = run_logged(command, folder, args.timeout_seconds, cwd=ROOT / 'example')
                finally:
                    stopped.set()
                    sampler.join(timeout=60)
                    logcat_active_at_end = logcat.poll() is None
                    stop_process(logcat)
                if sampler.is_alive():
                    raise ValidationError('Memory sampler did not stop; preserve evidence and inspect adb')
            rows, parse_errors, seen, stdout_rows = [], [], set(), []
            for filename in ['stdout.log', 'logcat.log']:
                parsed, errors = parse_reports((folder / filename).read_text(errors='replace'))
                parse_errors.extend({'source': filename, **error} for error in errors)
                if filename == 'stdout.log':
                    stdout_rows = parsed
                for row in parsed:
                    identity = json.dumps(row, sort_keys=True, ensure_ascii=False)
                    if identity not in seen:
                        seen.add(identity)
                        rows.append(row)
            write_json(folder / 'reports.json', rows)
            result.update(evaluate_run(stdout_rows, result['exitCode'], backend, context,
                                      requested_media=[kind for kind in ['image', 'audio'] if kind in deployed]))
            result.update({'backend': backend, 'context': context, 'reportParseErrors': parse_errors,
                           'logcatCommand': logcat_command, 'logcatExitCode': logcat.returncode,
                           'logcatActiveAtEnd': logcat_active_at_end, 'memorySampling': sampling_summary(folder),
                           'sampleScope': 'Flutter build/startup and native test, with raw timestamps',
                           'reportSourceForAcceptance': 'stdout.log; logcat reports retained but may include an older last line',
                           'apk': file_identity(apk)})
            if any(error['source'] == 'stdout.log' for error in parse_errors):
                result['automatedStatus'] = 'incomplete' if result['exitCode'] == 0 else 'failed'
            write_json(folder / 'result.json', result)
            report['runs'].append(result)
            write_json(output / 'validation.json', report)
        report['status'] = 'automated_passed_native_trace_and_manual_pending' if all(
            run['automatedStatus'] == 'passed' for run in report['runs']) else 'failed_or_incomplete'
    except BaseException as error:
        report['status'], report['error'] = 'blocked_or_interrupted', str(error)
        raise
    finally:
        report['finishedUtc'] = utc_now()
        write_json(output / 'validation.json', report)
    return 0 if report['status'] == 'automated_passed_native_trace_and_manual_pending' else 1


def context_value(value):
    aliases = {'4k': 4096, '8k': 8192, '16k': 16384, '32k': 32768}
    try:
        context = aliases[value.lower()] if value.lower() in aliases else int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError('Use 4096/8192/16384/32768 or 4K/8K/16K/32K') from error
    if context not in CONTEXTS:
        raise argparse.ArgumentTypeError('Unsupported context tier')
    return context


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--plan', action='store_true', help='Print JSON plan; never invoke adb or Flutter')
    mode.add_argument('--run', action='store_true', help='Build/install debug APK, deploy exact files and collect evidence')
    parser.add_argument('--manifest', type=Path, default=ROOT / 'tool/models/gemma-4-e2b.json')
    parser.add_argument('--model', type=Path)
    parser.add_argument('--model-image', type=Path)
    parser.add_argument('--model-audio', type=Path)
    parser.add_argument('--device', help='Exact adb serial; no automatic device selection')
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--flutter', default='flutter')
    parser.add_argument('--backends', nargs='+', choices=['cpu', 'gpu'], default=['cpu', 'gpu'])
    parser.add_argument('--contexts', nargs='+', type=context_value, default=list(CONTEXTS))
    parser.add_argument('--output', default=str(ROOT / 'build/android-validation' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')))
    parser.add_argument('--sample-seconds', type=float, default=1.0)
    parser.add_argument('--timeout-seconds', type=float, default=3000)
    args = parser.parse_args(argv)
    if any(not math.isfinite(v) or v <= 0 for v in [args.sample_seconds, args.timeout_seconds]):
        parser.error('Sampling interval and timeout must be positive finite numbers')
    if len(set(args.backends)) != len(args.backends) or len(set(args.contexts)) != len(args.contexts):
        parser.error('Duplicate backend/context runs are not allowed')
    try:
        plan = make_plan(args)
        if args.plan:
            print(json.dumps(plan, indent=2, ensure_ascii=False))
            return 0
        return execute(args, plan)
    except KeyboardInterrupt:
        print('Validation interrupted; completed evidence retained', file=sys.stderr)
        return 130
    except (ValidationError, OSError, ValueError) as error:
        print(f'Validation blocked: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
