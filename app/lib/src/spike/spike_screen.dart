// SPDX-License-Identifier: GPL-3.0-or-later
// Milestone 1 latency spike screen. Spec: docs/specs/latency-spike.md
import 'dart:async';
import 'dart:convert';

import 'package:dena_android/dena_android.dart';
import 'package:material_ui/material_ui.dart';

enum CompositionPath { texture, surfaceView }

class SpikeScreen extends StatefulWidget {
  const SpikeScreen({super.key, this.api, this.romPath, this.title});

  /// Game to run; the bundled latency test ROM when null.
  final String? romPath;

  /// App bar title; 'Latency spike' when null.
  final String? title;

  /// Injectable for tests; defaults to the platform implementation.
  final SpikeHostApi? api;

  @override
  State<SpikeScreen> createState() => _SpikeScreenState();
}

class _SpikeScreenState extends State<SpikeScreen> {
  late final SpikeHostApi api = widget.api ?? SpikeHostApi();
  CompositionPath path = CompositionPath.surfaceView;
  bool running = false;
  int? textureId;
  Map<String, dynamic>? metrics;
  String? error;
  Timer? poll;

  // GBA screen; the native side scales nothing, Flutter scales the view.
  static const int gbaWidth = 240, gbaHeight = 160;

  Future<void> _start() async {
    final err = await api.start(widget.romPath);
    if (err != null) {
      setState(() => error = err);
      return;
    }
    if (path == CompositionPath.texture) {
      textureId = await api.attachTexture(gbaWidth, gbaHeight);
    }
    poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final json = await api.metrics();
      if (mounted) {
        setState(() => metrics = jsonDecode(json) as Map<String, dynamic>);
      }
    });
    setState(() {
      running = true;
      error = null;
    });
  }

  Future<void> _stop() async {
    poll?.cancel();
    poll = null;
    await api.stop();
    setState(() {
      running = false;
      textureId = null;
    });
  }

  @override
  void dispose() {
    poll?.cancel();
    if (running) api.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title ?? 'Latency spike')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<CompositionPath>(
                segments: const [
                  ButtonSegment(
                    value: CompositionPath.surfaceView,
                    label: Text('SurfaceView'),
                  ),
                  ButtonSegment(
                    value: CompositionPath.texture,
                    label: Text('Texture'),
                  ),
                ],
                selected: {path},
                onSelectionChanged: running
                    ? null
                    : (s) => setState(() => path = s.first),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: gbaWidth / gbaHeight,
                    child: ColoredBox(
                      color: Colors.black,
                      child: !running
                          ? const SizedBox.shrink()
                          : path == CompositionPath.surfaceView
                          ? const EmulatorSurfaceView()
                          : textureId == null
                          ? const SizedBox.shrink()
                          : Texture(
                              textureId: textureId!,
                              filterQuality: FilterQuality.none,
                            ),
                    ),
                  ),
                ),
              ),
              if (error != null)
                Text(
                  error!,
                  style: text.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              _MetricsView(metrics: metrics),
              const SizedBox(height: 8),
              FilledButton.tonal(
                autofocus: true,
                onPressed: running ? _stop : _start,
                child: Text(
                  running
                      ? 'Stop'
                      : (widget.romPath == null
                            ? 'Start latency test ROM'
                            : 'Start'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricsView extends StatelessWidget {
  const _MetricsView({required this.metrics});

  final Map<String, dynamic>? metrics;

  String _dist(Object? v) {
    if (v is! Map) return '–';
    final keys = v.keys.where((k) => k != 'max').toList();
    final parts = keys.map((k) => '$k ${(v[k] as num).toStringAsFixed(1)}');
    return '${parts.join(' · ')} · max ${(v['max'] as num).toStringAsFixed(1)} ms';
  }

  @override
  Widget build(BuildContext context) {
    final m = metrics;
    final style = Theme.of(context).textTheme.bodySmall;
    if (m == null) {
      return Text(
        'Press A (gamepad) or X (keyboard): the screen turns white.',
        style: style,
      );
    }
    return Text(
      'Input → post: ${_dist(m['input_to_post_ms'])}\n'
      'Frame interval: ${_dist(m['frame_interval_ms'])}, missed ${m['missed_frames']}\n'
      'Audio: ${m['audio_rate']} Hz, buffer ${(m['audio_buffer_ms'] as num).toStringAsFixed(0)} ms, '
      'xruns ${m['audio_xruns']}, underruns ${m['audio_underruns']}',
      style: style,
    );
  }
}
