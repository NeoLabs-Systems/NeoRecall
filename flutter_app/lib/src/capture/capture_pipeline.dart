import 'dart:async';
import 'dart:typed_data';

import '../recording/audio_frame.dart';
import '../recording/audio_mixer.dart';
import 'capture_source.dart';

class CapturePipelineInterruption {
  const CapturePipelineInterruption({
    required this.sourceId,
    required this.sourceKind,
    required this.reason,
  });

  final String sourceId;
  final String sourceKind;
  final String reason;
}

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
    this.flushInterval = const Duration(seconds: 1),
    this.partialInterval = const Duration(seconds: 2),
    this.sourceStallTimeout = const Duration(seconds: 5),
  });

  final List<CaptureSource> sources;
  final int chunkMs;
  final int overlapMs;
  final int sampleRate;
  final Duration flushInterval;
  final Duration partialInterval;
  final Duration sourceStallTimeout;

  final StreamController<RecordedAudioChunk> chunks =
      StreamController<RecordedAudioChunk>.broadcast(sync: true);
  final StreamController<RecordedAudioChunk> partials =
      StreamController<RecordedAudioChunk>.broadcast(sync: true);
  final StreamController<String> warnings =
      StreamController<String>.broadcast();
  final StreamController<double> levels = StreamController<double>.broadcast();
  final StreamController<CapturePipelineInterruption> interruptions =
      StreamController<CapturePipelineInterruption>.broadcast();

  final Map<String, List<int>> _buffers = <String, List<int>>{};
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];
  final List<CaptureSource> _activeSources = <CaptureSource>[];
  final Map<String, DateTime> _lastDataAt = <String, DateTime>{};
  final Set<String> _drainingSources = <String>{};
  final Set<String> _excludedSources = <String>{};
  final Set<String> _reportedInterruptions = <String>{};
  Timer? _chunkTimer;
  Timer? _partialTimer;
  DateTime? _startedAt;
  int _offsetMs = 0;
  bool _running = false;
  bool _stopping = false;

  bool get isRunning => _running;
  List<CaptureSource> get activeSources =>
      List<CaptureSource>.unmodifiable(_activeSources);

  Future<RecorderCapability> start() async {
    if (_running) throw StateError('Capture pipeline is already running.');
    if (sources.isEmpty) throw StateError('No capture sources configured.');
    if (chunkMs <= 0 ||
        overlapMs < 0 ||
        overlapMs >= chunkMs ||
        sampleRate <= 0 ||
        flushInterval <= Duration.zero ||
        partialInterval <= Duration.zero ||
        sourceStallTimeout <= Duration.zero) {
      throw ArgumentError('Invalid capture timing configuration.');
    }
    if (sources.length > 2) {
      throw StateError(
        'A capture pipeline supports at most two synchronized audio sources.',
      );
    }

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
        _lastDataAt[source.id] = DateTime.now();
        _activeSources.add(source);
        _subscriptions.add(
          source.pcm16Stream.listen(
            (pcm) {
              if (pcm.isEmpty) return;
              if (_excludedSources.remove(source.id)) {
                _buffers[source.id]?.clear();
                warnings.add('${source.kind} stream resumed.');
              }
              _drainingSources.remove(source.id);
              _lastDataAt[source.id] = DateTime.now();
              _buffers[source.id]?.addAll(pcm);
            },
            onError: (Object error) {
              warnings.add('${source.kind} stream error: $error');
              _markInterrupted(source, error.toString());
            },
            onDone: () {
              warnings.add(
                '${source.kind} stream ended; continuing with remaining sources when possible.',
              );
              _markInterrupted(source, 'audio stream ended');
            },
          ),
        );
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
    _chunkTimer = Timer.periodic(flushInterval, (_) {
      _checkSourceHealth();
      _flushComplete();
    });
    _partialTimer = Timer.periodic(partialInterval, (_) => _emitPartial());

    final hasMic = _activeSources.any((source) => source.kind == 'microphone');
    final hasSystem = _activeSources.any((source) => source.kind == 'system');
    final hasWearable = _activeSources.any(
      (source) => source.kind == 'wearable',
    );
    return RecorderCapability(
      microphone: hasMic || hasWearable,
      systemAudio: hasSystem,
      persistentStorage: true,
      sampleRate: sampleRate,
      sourceKind: hasWearable
          ? 'wearable'
          : hasMic && hasSystem
          ? 'combined'
          : hasSystem
          ? 'system'
          : 'microphone',
      warning: warning,
    );
  }

  int get _bytesPerMs => sampleRate * 2 ~/ 1000;

  List<String> get _participatingIds => _buffers.keys
      .where((id) => !_excludedSources.contains(id))
      .toList(growable: false);

  int get _availableBytes {
    final ids = _participatingIds;
    if (ids.isEmpty) return 0;
    final lengths = ids.map((id) => _buffers[id]!.length);
    if (ids.any(_drainingSources.contains)) {
      return lengths.reduce((left, right) => left > right ? left : right);
    }
    return lengths.reduce((left, right) => left < right ? left : right);
  }

  void _checkSourceHealth() {
    if (!_running || _stopping) return;
    final now = DateTime.now();
    for (final source in _activeSources) {
      if (_excludedSources.contains(source.id) ||
          _drainingSources.contains(source.id)) {
        continue;
      }
      final lastDataAt = _lastDataAt[source.id];
      if (lastDataAt != null &&
          now.difference(lastDataAt) >= sourceStallTimeout) {
        warnings.add(
          '${source.kind} stopped delivering audio; its aligned tail will be finalized and remaining sources will continue.',
        );
        _markInterrupted(source, 'audio stream stalled');
      }
    }
  }

  void _markInterrupted(CaptureSource source, String reason) {
    if (!_running || _stopping || _drainingSources.contains(source.id)) return;
    _drainingSources.add(source.id);
    final hasHealthySibling = _participatingIds.any(
      (id) => id != source.id && !_drainingSources.contains(id),
    );
    if (hasHealthySibling || !_reportedInterruptions.add(source.id)) return;
    if (!interruptions.isClosed) {
      interruptions.add(
        CapturePipelineInterruption(
          sourceId: source.id,
          sourceKind: source.kind,
          reason: reason,
        ),
      );
    }
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
    final ids = _participatingIds;
    if (ids.isEmpty) {
      throw StateError('No active audio buffer is available.');
    }
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

    final overlap = chunkStartOffset > 0 ? overlapMs : 0;
    if (consume) {
      final advanceMs = isFinal ? durationMs : (durationMs - overlapMs);
      final remove = (_bytesPerMs * advanceMs).clamp(0, sourceBytes);
      for (final buffer in _buffers.values) {
        final end = remove.clamp(0, buffer.length);
        if (end > 0) buffer.removeRange(0, end);
      }
      for (final id in ids.where(_drainingSources.contains)) {
        _buffers[id]?.clear();
        _drainingSources.remove(id);
        _excludedSources.add(id);
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
    while (_availableBytes >= needed && !chunks.isClosed) {
      chunks.add(_build(chunkMs, isFinal: false, consume: true));
    }
  }

  void _emitPartial() {
    final durationMs = _availableBytes ~/ _bytesPerMs;
    if (durationMs <= 0 || partials.isClosed) return;
    partials.add(_build(durationMs, isFinal: true, consume: false));
  }

  Future<void> stop() async {
    if (!_running) return;
    _stopping = true;
    _chunkTimer?.cancel();
    _partialTimer?.cancel();
    _chunkTimer = null;
    _partialTimer = null;
    // Stop producers before detaching consumers. Native audio APIs can deliver
    // a final buffer while stopping, and cancelling first silently loses it.
    for (final source in _activeSources) {
      await source.stop();
    }
    await Future<void>.delayed(Duration.zero);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _drainingSources.addAll(_participatingIds);
    while (_availableBytes > 0 && !chunks.isClosed) {
      final durationMs = _availableBytes ~/ _bytesPerMs;
      if (durationMs <= 0) break;
      chunks.add(_build(durationMs, isFinal: true, consume: true));
    }
    for (final buffer in _buffers.values) {
      buffer.clear();
    }
    _activeSources.clear();
    _lastDataAt.clear();
    _drainingSources.clear();
    _excludedSources.clear();
    _reportedInterruptions.clear();
    _running = false;
    _stopping = false;
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
    await interruptions.close();
  }
}
