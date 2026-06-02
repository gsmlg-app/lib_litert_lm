import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lib_litert_lm/lib_litert_lm.dart';

void main() {
  runApp(const LiteRtLmExampleApp());
}

class LiteRtLmExampleApp extends StatelessWidget {
  const LiteRtLmExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LiteRT-LM',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF336C5A)),
        useMaterial3: true,
      ),
      home: const LiteRtLmExampleScreen(),
    );
  }
}

class LiteRtLmExampleScreen extends StatefulWidget {
  const LiteRtLmExampleScreen({super.key});

  @override
  State<LiteRtLmExampleScreen> createState() => _LiteRtLmExampleScreenState();
}

class _LiteRtLmExampleScreenState extends State<LiteRtLmExampleScreen> {
  final _promptController = TextEditingController(
    text: 'Write a concise answer about on-device language models.',
  );
  final _dispatchDirController = TextEditingController();

  LiteRtLm? _client;
  LiteRtLmEngine? _engine;
  LiteRtLmSession? _session;
  StreamSubscription<LiteRtLmEvent>? _subscription;

  String? _modelPath;
  String _backend = 'cpu';
  String _output = '';
  String _status = 'No model loaded';
  var _loading = false;
  var _generating = false;

  @override
  void dispose() {
    _subscription?.cancel();
    _session?.dispose();
    _engine?.dispose();
    _client?.dispose();
    _promptController.dispose();
    _dispatchDirController.dispose();
    super.dispose();
  }

  Future<void> _pickModel() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['litertlm'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null) {
      return;
    }
    setState(() {
      _modelPath = path;
      _status = 'Model selected';
      _output = '';
    });
  }

  Future<void> _loadModel() async {
    final modelPath = _modelPath;
    if (modelPath == null) {
      setState(() => _status = 'Pick a .litertlm file first');
      return;
    }

    setState(() {
      _loading = true;
      _status = 'Loading model';
      _output = '';
    });

    await _subscription?.cancel();
    await _session?.dispose();
    await _engine?.dispose();
    await _client?.dispose();

    final clientResult = await LiteRtLm.create();
    final client = clientResult.valueOrNull;
    if (client == null) {
      _showError(clientResult.errorOrNull);
      return;
    }

    final engineResult = await client.loadEngine(
      LiteRtLmEngineConfig(
        modelPath: modelPath,
        backend: _backend,
        litertDispatchLibDir:
            _backend == 'npu' && _dispatchDirController.text.trim().isNotEmpty
            ? _dispatchDirController.text.trim()
            : null,
        maxNumTokens: 4096,
      ),
    );
    final engine = engineResult.valueOrNull;
    if (engine == null) {
      await client.dispose();
      _showError(engineResult.errorOrNull);
      return;
    }

    setState(() {
      _client = client;
      _engine = engine;
      _session = null;
      _loading = false;
      _status = 'Model loaded';
    });
  }

  Future<void> _generate() async {
    final engine = _engine;
    if (engine == null) {
      setState(() => _status = 'Load a model first');
      return;
    }

    await _subscription?.cancel();
    await _session?.dispose();

    final sessionResult = await engine.createSession(
      params: const LiteRtLmGenerationParams(
        temperature: 0.8,
        topK: 40,
        maxTokens: 256,
      ),
    );
    final session = sessionResult.valueOrNull;
    if (session == null) {
      _showError(sessionResult.errorOrNull);
      return;
    }

    setState(() {
      _session = session;
      _output = '';
      _generating = true;
      _status = 'Generating';
    });

    _subscription = session.generateStream(_promptController.text).listen((
      event,
    ) {
      switch (event) {
        case LiteRtLmToken(:final text):
          setState(() => _output += text);
        case LiteRtLmCompleted(:final text):
          setState(() {
            _output = text;
            _generating = false;
            _status = 'Complete';
          });
          unawaited(_session?.dispose());
          _session = null;
        case LiteRtLmFailed(:final error):
          _showError(error);
          unawaited(_session?.dispose());
          _session = null;
        case LiteRtLmCancelledEvent():
          setState(() {
            _generating = false;
            _status = 'Cancelled';
          });
          unawaited(_session?.dispose());
          _session = null;
      }
    });
  }

  Future<void> _cancel() async {
    await _subscription?.cancel();
    await _session?.cancel();
    await _session?.dispose();
    setState(() {
      _generating = false;
      _status = 'Cancelled';
      _session = null;
    });
  }

  void _showError(LiteRtLmFailure? error) {
    setState(() {
      _loading = false;
      _generating = false;
      _status = error == null
          ? 'Unknown error'
          : '${error.code}: ${error.message}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final modelName = _modelPath?.split('/').last ?? 'No file selected';
    return Scaffold(
      appBar: AppBar(
        title: const Text('LiteRT-LM'),
        actions: [
          IconButton(
            onPressed: _loading || _generating ? null : _pickModel,
            icon: const Icon(Icons.folder_open),
            tooltip: 'Pick model',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    modelName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _loading || _generating ? null : _loadModel,
                  icon: _loading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.memory),
                  label: const Text('Load'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              key: const ValueKey('backendSelector'),
              segments: const [
                ButtonSegment(
                  value: 'cpu',
                  icon: Icon(Icons.developer_board),
                  label: Text('CPU'),
                ),
                ButtonSegment(
                  value: 'gpu',
                  icon: Icon(Icons.bolt),
                  label: Text('GPU'),
                ),
                ButtonSegment(
                  value: 'npu',
                  icon: Icon(Icons.memory),
                  label: Text('NPU'),
                ),
              ],
              selected: {_backend},
              onSelectionChanged: _loading || _generating
                  ? null
                  : (values) => setState(() => _backend = values.single),
            ),
            if (_backend == 'npu') ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('npuDispatchDirField'),
                controller: _dispatchDirController,
                enabled: !_loading && !_generating,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'NPU dispatch library directory',
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _promptController,
              enabled: !_generating,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Prompt',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _generating || _loading ? null : _generate,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Generate'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _generating ? _cancel : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Cancel'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _status,
              key: const ValueKey('statusText'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const Divider(height: 32),
            SelectableText(
              _output.isEmpty ? ' ' : _output,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
