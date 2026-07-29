import 'dart:async';
import 'dart:typed_data';

import '../recording/audio_frame.dart';
import '../recording/audio_mixer.dart';
import 'capture_source.dart';

/// Multi-source capture pipeline with durable chunk emission.
///
/// Sources can fail independently. When one source drops, remaining sources
/// continue and a warning is emitted. Chunk timing always advances from the
/// leading available PCM stream so temporary underruns do not stall capture.
class CapturePipeline {
  CapturePipeline({
    required this.sources,
    required this.chunkMs,
    required this.overlapMs,
    this.sampleRate = 16000,
  });

  final List<CaptureSource> sources;
  final int chunkMs;
  final int overlapMs;
  final int sampleRate;

  final StreamController<RecordedAudioChunk> chunks =
      StreamController<RecordedAudioChunk>.broadcast();
  final StreamController<RecordedAudioChunk> partials =
      StreamController<RecordedAudioChunk>.broadcast();
  final StreamController<String> warnings =
      StreamController<String>.broadcast();
  final StreamController<double> levels = StreamController<double>.broadcast();

  final Map<String, List<int>> _buffers = <String, List<int>>{};
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];
  final List<CaptureSource> _activeSources = <CaptureSource>[];
  Timer? _chunkTimer;
  Timer? _partialTimer;
  DateTime? _startedAt;
  int _offsetMs = 0;
  bool _running = false;

  bool get isRunning => _running;
  List<CaptureSource> get activeSources =>
      List<CaptureSource>.unmodifiable(_activeSources);

  Future<RecorderCapability> start() async {
    if (_running) throw StateError('Capture pipeline is already running.');
    if (sources.isEmpty) throw StateError('No capture sources configured.');

    String? warning;
    for (final source in sources) {
      try {
        final allowed = await source.ensurePermission();
        if (!allowed) {
          final message = '${source.kind} permission was not granted.';
          warning = message;
          warnings.add(message);
          continue;
        }
        await source.start(sampleRate: sampleRate, channels: 1);
        _buffers[source.id] = <int>[];
        _activeSources.add(source);
        _subscriptions.add(source.pcm16Stream.listen((pcm) {
          _buffers[source.id]?.addAll(pcm);
        }, onError: (Object error) {
          warnings.add('${source.kind} stream error: $error');
        }, onDone: () {
          warnings.add('${source.kind} stream ended; continuing with remaining sources when possible.');
        }));
        _subscriptions.add(source.levelStream.listen(levels.add));
        _subscriptions.add(source.warningStream.listen(warnings.add));
      } catch (error) {
        final message = '${source.kind} unavailable: $error';
        warning = message;
        warnings.add(message);
      }
    }
    if (_activeSources.isEmpty) {
      throw StateError(warning ?? 'No audio source is available.');
    }

    _startedAt = DateTime.now().toUtc();
    _offsetMs = 0;
    _running = true;
    _chunkTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _flushComplete());
    _partialTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _emitPartial());

    final hasMic = _activeSources.any((source) => source.kind == 'microphone');
    final hasSystem = _activeSources.any((source) => source.kind == 'system');
    final hasWearable = _activeSources.any((source) => source.kind == 'wearable');
    return RecorderCapability(
      microphone: hasMic || hasWearable,
      systemAudio: hasSystem,
      persistentStorage: true,
      sampleRate: sampleRate,
      warning: warning,
    );
  }

  int get _bytesPerMs => sampleRate * 2 ~/ 1000;

  int get _availableBytes {
    if (_buffers.isEmpty) return 0;
    return _buffers.values
        .map((buffer) => buffer.length)
        .reduce((left, right) => left > right ? left : right);
  }

  Uint8List _takeOrPad(List<int> input, int length) {
    final output = Uint8List(length);
    final available = input.length < length ? input.length : length;
    if (available > 0) output.setRange(0, available, input.take(available));
    return output;
  }

  RecordedAudioChunk _build(
    int durationMs, {
    required bool isFinal,
    required bool consume,
  }) {
    final sourceBytes = _bytesPerMs * durationMs;
    final chunkStartOffset = _offsetMs;
    final startedAt = _startedAt!.add(Duration(milliseconds: chunkStartOffset));
    final ids = _buffers.keys.toList(growable: false);
    late Uint8List pcm;
    late String layout;

    if (ids.length >= 2) {
      // Keep stable ordering: microphone-like first, system second when present.
      CaptureSource? byId(String id) {
        for (final source in _activeSources) {
          if (source.id == id) return source;
        }
        return null;
      }

      int rank(CaptureSource? source) {
        switch (source?.kind) {
          case 'microphone':
            return 0;
          case 'wearable':
            return 1;
          case 'system':
            return 2;
          default:
            return 3;
        }
      }

      ids.sort((a, b) => rank(byId(a)).compareTo(rank(byId(b))));
      final left = _takeOrPad(_buffers[ids[0]]!, sourceBytes);
      final right = _takeOrPad(_buffers[ids[1]]!, sourceBytes);
      pcm = AudioMixer.stereoPcm16(left, right);
      layout = 'microphone_left_system_right';
    } else {
      final only = ids.single;
      pcm = _takeOrPad(_buffers[only]!, sourceBytes);
      layout = 'mono';
    }

    final overlap = (!isFinal && chunkStartOffset > 0) ? overlapMs : 0;
    if (consume) {
      final advanceMs = isFinal ? durationMs : (durationMs - overlapMs);
      final remove = (_bytesPerMs * advanceMs).clamp(0, sourceBytes);
      for (final buffer in _buffers.values) {
        final end = remove.clamp(0, buffer.length);
        if (end > 0) buffer.removeRange(0, end);
      }
      _offsetMs = chunkStartOffset + advanceMs;
    }

    return RecordedAudioChunk(
      bytes: AudioMixer.wav(
        pcm,
        channels: layout == 'mono' ? 1 : 2,
        sampleRate: sampleRate,
      ),
      durationMs: durationMs,
      overlapMs: overlap,
      channelLayout: layout,
      startedAt: startedAt,
      monotonicOffsetMs: chunkStartOffset,
      isFinal: isFinal,
    );
  }

  void _flushComplete() {
    final needed = _bytesPerMs * chunkMs;
    if (_availableBytes < needed) return;
    if (chunks.isClosed) return;
    chunks.add(_build(chunkMs, isFinal: false, consume: true));
  }

  void _emitPartial() {
    final durationMs = _availableBytes ~/ _bytesPerMs;
    if (durationMs <= 0 || partials.isClosed) return;
    partials.add(_build(durationMs, isFinal: true, consume: false));
  }

  Future<void> stop() async {
    if (!_running) return;
    _chunkTimer?.cancel();
    _partialTimer?.cancel();
    _chunkTimer = null;
    _partialTimer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    for (final source in _activeSources) {
      await source.stop();
    }
    final durationMs = _availableBytes ~/ _bytesPerMs;
    if (durationMs > 0 && !chunks.isClosed) {
      chunks.add(_build(durationMs, isFinal: true, consume: true));
    }
    for (final buffer in _buffers.values) {
      buffer.clear();
    }
    _activeSources.clear();
    _running = false;
  }

  Future<void> dispose() async {
    await stop();
    for (final source in sources) {
      await source.dispose();
    }
    await chunks.close();
    await partials.close();
    await warnings.close();
    await levels.close();
  }
}
