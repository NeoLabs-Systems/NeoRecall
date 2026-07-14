import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:desktop_audio_capture/audio_capture.dart';
import 'package:record/record.dart';

import 'audio_frame.dart';
import 'audio_mixer.dart';
import 'recorder.dart';

RecallRecorder createRecorder() => DesktopRecallRecorder();

class DesktopRecallRecorder implements RecallRecorder {
  final AudioRecorder _microphone = AudioRecorder();
  final SystemAudioCapture _system = SystemAudioCapture(
    config: SystemAudioConfig(sampleRate: 16000, channels: 1),
  );
  final StreamController<RecordedAudioChunk> _chunks =
      StreamController<RecordedAudioChunk>.broadcast();
  final StreamController<RecordedAudioChunk> _partials =
      StreamController<RecordedAudioChunk>.broadcast();
  final StreamController<String> _warnings =
      StreamController<String>.broadcast();
  final StreamController<double> _levels = StreamController<double>.broadcast();
  final List<int> _mic = <int>[];
  final List<int> _sys = <int>[];
  StreamSubscription<Uint8List>? _micSubscription;
  StreamSubscription<Uint8List>? _systemSubscription;
  Timer? _timer;
  Timer? _partialTimer;
  bool _recording = false;
  bool _useMic = true;
  bool _useSystem = false;
  int _targetMs = 30000;
  int _overlapMs = 2000;
  int _offsetMs = 0;
  DateTime? _startedAt;
  DateTime _lastLevelAt = DateTime.fromMillisecondsSinceEpoch(0);
  @override
  Stream<RecordedAudioChunk> get chunks => _chunks.stream;
  @override
  Stream<RecordedAudioChunk> get partials => _partials.stream;
  @override
  Stream<String> get warnings => _warnings.stream;
  @override
  Stream<double> get levels => _levels.stream;
  @override
  bool get isRecording => _recording;

  @override
  Future<RecorderCapability> start({
    required bool microphone,
    required bool systemAudio,
    required int chunkMs,
    required int overlapMs,
  }) async {
    if (_recording) throw StateError('Recorder is already active.');
    _useMic = microphone;
    _useSystem = systemAudio;
    _targetMs = chunkMs;
    _overlapMs = overlapMs;
    _offsetMs = 0;
    _startedAt = DateTime.now().toUtc();
    String? warning;
    if (microphone) {
      if (!await _microphone.hasPermission()) {
        throw StateError('Microphone permission was not granted.');
      }
      final stream = await _microphone.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
        ),
      );
      _micSubscription = stream.listen((data) {
        _mic.addAll(data);
        _emitLevel(data);
      });
    }
    if (systemAudio) {
      try {
        await _system.startCapture();
        _systemSubscription = _system.audioStream?.listen((data) {
          _sys.addAll(data);
          _emitLevel(data);
        });
      } catch (error) {
        _useSystem = false;
        warning =
            'System audio permission or capture was unavailable. Recording continues with the microphone only.';
      }
    }
    if (!_useMic && !_useSystem) {
      throw StateError('No audio source is available.');
    }
    _recording = true;
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _flushComplete(),
    );
    _partialTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _emitPartial(),
    );
    return RecorderCapability(
      microphone: _useMic,
      systemAudio: _useSystem,
      persistentStorage: true,
      sampleRate: 16000,
      warning: warning,
    );
  }

  void _emitLevel(Uint8List data) {
    final now = DateTime.now();
    if (now.difference(_lastLevelAt).inMilliseconds < 100 || data.length < 2) {
      return;
    }
    _lastLevelAt = now;
    final bytes = ByteData.sublistView(data);
    var energy = 0.0;
    var samples = 0;
    for (var offset = 0; offset + 1 < data.length; offset += 8) {
      final value = bytes.getInt16(offset, Endian.little) / 32768;
      energy += value * value;
      samples += 1;
    }
    _levels.add(samples == 0 ? 0 : math.sqrt(energy / samples).clamp(0, 1));
  }

  void _flushComplete() {
    final bytesPerSecond = 16000 * 2;
    final available = _availableBytes;
    if (available < bytesPerSecond * _targetMs ~/ 1000) return;
    _emit(_targetMs, false);
  }

  void _emitPartial() {
    final available = _availableBytes;
    final durationMs = available * 1000 ~/ (16000 * 2);
    if (durationMs > 0) _partials.add(_buildChunk(durationMs, true));
  }

  int get _availableBytes {
    if (_useMic && _useSystem) {
      // Native capture streams do not arrive in lockstep. Use the leading
      // monotonic stream as the clock and pad bounded underruns with silence.
      return _mic.length > _sys.length ? _mic.length : _sys.length;
    }
    return _useMic ? _mic.length : _sys.length;
  }

  Uint8List _channelBytes(List<int> input, int length) {
    final output = Uint8List(length);
    final available = input.length < length ? input.length : length;
    output.setRange(0, available, input.take(available));
    return output;
  }

  RecordedAudioChunk _buildChunk(int durationMs, bool finalChunk) {
    final sourceBytes = 16000 * 2 * durationMs ~/ 1000;
    late Uint8List pcm;
    late String layout;
    if (_useMic && _useSystem) {
      pcm = AudioMixer.stereoPcm16(
        _channelBytes(_mic, sourceBytes),
        _channelBytes(_sys, sourceBytes),
      );
      layout = 'microphone_left_system_right';
    } else {
      pcm = _channelBytes(_useMic ? _mic : _sys, sourceBytes);
      layout = 'mono';
    }
    return RecordedAudioChunk(
      bytes: AudioMixer.wav(pcm, channels: layout == 'mono' ? 1 : 2),
      durationMs: durationMs,
      overlapMs: _offsetMs == 0 ? 0 : _overlapMs,
      channelLayout: layout,
      startedAt: _startedAt!.add(Duration(milliseconds: _offsetMs)),
      monotonicOffsetMs: _offsetMs,
      isFinal: finalChunk,
    );
  }

  void _emit(int durationMs, bool finalChunk) {
    _chunks.add(_buildChunk(durationMs, finalChunk));
    final consume = 16000 * 2 * (durationMs - _overlapMs) ~/ 1000;
    if (_useMic) _mic.removeRange(0, consume.clamp(0, _mic.length));
    if (_useSystem) _sys.removeRange(0, consume.clamp(0, _sys.length));
    _offsetMs += durationMs - _overlapMs;
  }

  @override
  Future<void> stop() async {
    if (!_recording) return;
    _timer?.cancel();
    _timer = null;
    _partialTimer?.cancel();
    _partialTimer = null;
    await _micSubscription?.cancel();
    await _systemSubscription?.cancel();
    if (_useMic) await _microphone.stop();
    if (_useSystem) await _system.stopCapture();
    final available = _availableBytes;
    final durationMs = available * 1000 ~/ (16000 * 2);
    if (durationMs > 0) _emit(durationMs, true);
    _mic.clear();
    _sys.clear();
    _recording = false;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _microphone.dispose();
    await _chunks.close();
    await _partials.close();
    await _warnings.close();
    await _levels.close();
  }
}
