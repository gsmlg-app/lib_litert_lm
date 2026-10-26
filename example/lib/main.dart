import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lib_litert_lm/lib_litert_lm.dart';

void main() {
  runApp(const LiteRtLmExampleApp());
}

class LiteRtLmExampleApp extends StatelessWidget {
  const LiteRtLmExampleApp({super.key, this.createClient});
  final Future<LiteRtLmResult<LiteRtLm>> Function()? createClient;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LiteRT-LM',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF336C5A)),
        useMaterial3: true,
      ),
      home: LiteRtLmExampleScreen(createClient: createClient),
    );
  }
}

class LiteRtLmExampleScreen extends StatefulWidget {
  const LiteRtLmExampleScreen({super.key, this.createClient});
  final Future<LiteRtLmResult<LiteRtLm>> Function()? createClient;

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
  LiteRtLmConversation? _conversation;
  LiteRtLmModelInfo? _modelInfo;
  StreamSubscription<LiteRtLmEvent>? _subscription;
  String? _modelPath;
  String _backend = 'cpu';
  int _contextTokens = 4096;
  int? _loadedContextTokens;
  String _output = '';
  String _status = 'No model loaded';
  var _loading = false;
  var _generating = false;
  var _needsReload = false;
  var _enableVision = false;
  var _enableAudio = false;
  Uint8List? _imageBytes;
  Uint8List? _audioBytes;
  String? _imageName;
  String? _audioName;

  @override
  void dispose() {
    unawaited(_closeCurrent());
    _promptController.dispose();
    _dispatchDirController.dispose();
    super.dispose();
  }

  Future<void> _closeCurrent() async {
    final subscription = _subscription;
    final conversation = _conversation;
    final engine = _engine;
    final client = _client;
    _subscription = null;
    _conversation = null;
    _engine = null;
    _client = null;
    await subscription?.cancel();
    await conversation?.dispose();
    await engine?.dispose();
    await client?.dispose();
  }

  void _configure(VoidCallback change) {
    setState(() {
      change();
      _needsReload = _engine != null;
      if (_needsReload) _status = 'Settings changed; reload model';
    });
  }

  Future<void> _pickModel() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['litertlm'],
        allowMultiple: false,
      );
      if (!mounted) return;
      final path = result?.files.single.path;
      if (path == null) return;
      setState(() {
        _modelPath = path;
        _needsReload = _engine != null;
        _status = 'Model selected; load to use it';
        _output = '';
      });
    } catch (error) {
      _showError(LiteRtLmInvalidArgument('Could not pick model: $error'));
    }
  }

  Future<void> _pickAttachment({required bool image}) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: image ? const ['png', 'jpg', 'jpeg'] : const ['wav'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || !mounted) return;
      final file = result.files.single;
      var bytes = file.bytes;
      if (bytes == null && file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        _showError(
          const LiteRtLmInvalidArgument(
            'No readable attachment bytes; pick a local file',
          ),
        );
        return;
      }
      final png =
          bytes.length >= 8 &&
          listEquals(bytes.sublist(0, 8), const [
            137,
            80,
            78,
            71,
            13,
            10,
            26,
            10,
          ]);
      final jpeg =
          bytes.length >= 3 &&
          bytes[0] == 255 &&
          bytes[1] == 216 &&
          bytes[2] == 255;
      final wav =
          bytes.length >= 12 &&
          listEquals(bytes.sublist(0, 4), const [82, 73, 70, 70]) &&
          listEquals(bytes.sublist(8, 12), const [87, 65, 86, 69]);
      if (image ? !(png || jpeg) : !wav) {
        _showError(
          LiteRtLmInvalidArgument(
            image
                ? 'Pick a valid PNG or JPEG image'
                : 'Pick a valid WAV audio file',
          ),
        );
        return;
      }
      setState(() {
        if (image) {
          _imageBytes = bytes;
          _imageName = file.name;
        } else {
          _audioBytes = bytes;
          _audioName = file.name;
        }
        _status = '${file.name} attached to the next turn';
      });
    } catch (error) {
      _showError(LiteRtLmInvalidArgument('Could not read attachment: $error'));
    }
  }

  Future<void> _loadModel() async {
    final modelPath = _modelPath;
    if (modelPath == null) {
      setState(() => _status = 'Pick a .litertlm file first');
      return;
    }
    final config = LiteRtLmEngineConfig(
      modelPath: modelPath,
      backend: _backend,
      visionBackend: _enableVision ? 'cpu' : null,
      audioBackend: _enableAudio ? 'cpu' : null,
      litertDispatchLibDir:
          _backend == 'npu' && _dispatchDirController.text.trim().isNotEmpty
          ? _dispatchDirController.text.trim()
          : null,
      maxNumTokens: _contextTokens,
    );
    setState(() {
      _loading = true;
      _status = 'Loading model';
      _output = '';
      _modelInfo = null;
    });
    await _closeCurrent();
    if (!mounted) return;
    final clientResult =
        await (widget.createClient?.call() ?? LiteRtLm.create());
    final client = clientResult.valueOrNull;
    if (!mounted) {
      await client?.dispose();
      return;
    }
    if (client == null) {
      _showError(clientResult.errorOrNull);
      return;
    }
    final engineResult = await client.loadEngine(config);
    final engine = engineResult.valueOrNull;
    if (!mounted) {
      await client.dispose();
      return;
    }
    if (engine == null) {
      await client.dispose();
      _showError(engineResult.errorOrNull);
      return;
    }
    final info = await engine.getInfo();
    if (!mounted) {
      await client.dispose();
      return;
    }
    setState(() {
      _client = client;
      _engine = engine;
      _modelInfo = info.valueOrNull;
      _loadedContextTokens = config.maxNumTokens;
      _needsReload = false;
      _loading = false;
      _status = info.isErr
          ? 'Model loaded; model info unavailable'
          : 'Model loaded';
    });
  }

  Future<void> _generate() async {
    final engine = _engine;
    if (engine == null) {
      setState(() => _status = 'Load a model first');
      return;
    }
    if (_needsReload) {
      setState(() => _status = 'Settings changed; reload model');
      return;
    }
    final contents = <LiteRtLmContent>[
      LiteRtLmContent.text(_promptController.text),
      if (_enableVision && _imageBytes != null)
        LiteRtLmContent.image(_imageBytes!),
      if (_enableAudio && _audioBytes != null)
        LiteRtLmContent.audio(_audioBytes!),
    ];
    setState(() {
      _output = '';
      _generating = true;
      _status = 'Generating';
    });
    var conversation = _conversation;
    if (conversation == null) {
      final result = await engine.createConversation(
        params: const LiteRtLmGenerationParams(
          temperature: 0.8,
          topK: 40,
          maxTokens: 256,
        ),
      );
      conversation = result.valueOrNull;
      if (!mounted) {
        await conversation?.dispose();
        return;
      }
      if (conversation == null) {
        _showError(result.errorOrNull);
        return;
      }
      _conversation = conversation;
    }
    _subscription = conversation
        .sendStream(LiteRtLmMessage(role: 'user', contents: contents))
        .listen(
          (event) {
            if (!mounted) return;
            switch (event) {
              case LiteRtLmToken(:final text):
                setState(() => _output += text);
              case LiteRtLmCompleted(:final text):
                setState(() {
                  _output = text;
                  _generating = false;
                  _status = 'Complete';
                  _imageBytes = null;
                  _imageName = null;
                  _audioBytes = null;
                  _audioName = null;
                });
              case LiteRtLmFailed(:final error):
                _showError(error);
              case LiteRtLmCancelledEvent():
                setState(() {
                  _generating = false;
                  _status = 'Cancelled';
                });
            }
          },
          onError: (Object error) =>
              _showError(LiteRtLmGenerationFailure('$error')),
          onDone: () {
            _subscription = null;
            if (mounted && _generating) {
              _showError(
                const LiteRtLmGenerationFailure(
                  'Stream ended without completion',
                ),
              );
            }
          },
        );
  }

  Future<void> _cancel() async {
    await _conversation?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    if (!mounted) return;
    setState(() {
      _generating = false;
      _status = 'Cancelled';
    });
  }

  Future<void> _newConversation() async {
    final conversation = _conversation;
    _conversation = null;
    await _subscription?.cancel();
    _subscription = null;
    await conversation?.dispose();
    if (!mounted) return;
    setState(() {
      _output = '';
      _status = _engine == null ? 'No model loaded' : 'New conversation';
    });
  }

  void _showError(LiteRtLmFailure? error) {
    if (!mounted) return;
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
                  : (values) => _configure(() => _backend = values.single),
            ),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              key: const ValueKey('contextSelector'),
              segments: const [
                ButtonSegment(value: 4096, label: Text('4K')),
                ButtonSegment(value: 8192, label: Text('8K')),
                ButtonSegment(value: 16384, label: Text('16K')),
                ButtonSegment(value: 32768, label: Text('32K')),
              ],
              selected: {_contextTokens},
              onSelectionChanged: _loading || _generating
                  ? null
                  : (values) =>
                        _configure(() => _contextTokens = values.single),
            ),
            SwitchListTile(
              key: const ValueKey('visionToggle'),
              title: const Text('Enable vision (CPU)'),
              subtitle: const Text('Configure before loading the model'),
              value: _enableVision,
              onChanged: _loading || _generating
                  ? null
                  : (value) => _configure(() => _enableVision = value),
            ),
            SwitchListTile(
              key: const ValueKey('audioToggle'),
              title: const Text('Enable audio (CPU)'),
              subtitle: const Text('Configure before loading the model'),
              value: _enableAudio,
              onChanged: _loading || _generating
                  ? null
                  : (value) => _configure(() => _enableAudio = value),
            ),
            if (_engine != null)
              Text(
                'Context requested: ${_modelInfo?.requestedContextTokens ?? _loadedContextTokens} · effective: ${_modelInfo?.effectiveContextTokens ?? 'unavailable'}',
                key: const ValueKey('engineInfo'),
              ),
            if (_modelInfo != null)
              Text(
                'Runtime: ${_modelInfo!.runtimeVersion} (${_modelInfo!.runtimeCommit})',
              ),
            if (_backend == 'npu') ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('npuDispatchDirField'),
                controller: _dispatchDirController,
                onChanged: (_) => _configure(() {}),
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
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  key: const ValueKey('pickImage'),
                  onPressed: _enableVision && !_loading && !_generating
                      ? () => _pickAttachment(image: true)
                      : null,
                  icon: const Icon(Icons.image),
                  label: Text(_imageName ?? 'Pick image (PNG/JPEG)'),
                ),
                if (_imageBytes != null)
                  IconButton(
                    tooltip: 'Remove image',
                    onPressed: _generating
                        ? null
                        : () => setState(() {
                            _imageBytes = null;
                            _imageName = null;
                          }),
                    icon: const Icon(Icons.close),
                  ),
                TextButton.icon(
                  key: const ValueKey('pickAudio'),
                  onPressed: _enableAudio && !_loading && !_generating
                      ? () => _pickAttachment(image: false)
                      : null,
                  icon: const Icon(Icons.audiotrack),
                  label: Text(_audioName ?? 'Pick audio (WAV)'),
                ),
                if (_audioBytes != null)
                  IconButton(
                    tooltip: 'Remove audio',
                    onPressed: _generating
                        ? null
                        : () => setState(() {
                            _audioBytes = null;
                            _audioName = null;
                          }),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _generating || _loading ? null : _generate,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Generate'),
                ),
                OutlinedButton.icon(
                  onPressed: _generating ? _cancel : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Cancel'),
                ),
                OutlinedButton.icon(
                  onPressed: _generating || _loading ? null : _newConversation,
                  icon: const Icon(Icons.add_comment),
                  label: const Text('New conversation'),
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
