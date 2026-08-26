import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'capture_source.dart';

/// The plumbing every [CaptureSource] needs: the three streams, the active
/// flag, RMS level metering, and one shared way to report a capture that has
/// failed.
///
/// Each source used to carry its own copy. That was harmless for the stream
/// declarations and not harmless for failure handling, which had drifted:
/// the microphone marked itself inactive and forwarded the fault into the PCM
/// stream, while system audio did neither — so a dead system-audio capture went
/// on looking healthy to the pipeline.
abstract class CaptureSourceBase implements CaptureSource {
  /// [broadcastPcm] false gives a single-subscription controller, which queues
  /// frames produced between native start-up and the pipeline attaching instead
  /// of dropping them. Sources with exactly one consumer want that.
  CaptureSourceBase({bool broadcastPcm = true})
    : _pcm = broadcastPcm
          ? StreamController<Uint8List>.broadcast()
          : StreamController<Uint8List>(sync: true);

  final StreamController<Uint8List> _pcm;
  final StreamController<double> _levels = StreamController<double>.broadcast();
  final StreamController<String> _warnings =
      StreamController<String>.broadcast();
  bool _active = false;

  @override
  bool get isActive => _active;
  @override
  Stream<Uint8List> get pcm16Stream => _pcm.stream;
  @override
  Stream<double> get levelStream => _levels.stream;
  @override
  Stream<String> get warningStream => _warnings.stream;

  @protected
  bool get pcmClosed => _pcm.isClosed;

  @protected
  set active(bool value) => _active = value;

  /// Publishes one PCM frame and its level.
  @protected
  void emitPcm(Uint8List data) {
    if (_pcm.isClosed) return;
    _pcm.add(data);
    emitLevel(data);
  }

  @protected
  void warn(String message) {
    if (!_warnings.isClosed) _warnings.add(message);
  }

  /// Reports a capture that has stopped producing audio for a reason the user
  /// did not ask for.
  ///
  /// Marks the source inactive and forwards the fault to the PCM stream so the
  /// pipeline can react, unless the stop was deliberate — during a requested
  /// stop the stream ending is the expected outcome, not a fault.
  @protected
  void failCapture(String message, Object error, {bool stopping = false}) {
    _active = false;
    warn(message);
    if (!stopping && !_pcm.isClosed) _pcm.addError(error);
  }

  /// Root-mean-square level of a 16-bit little-endian PCM frame, 0..1.
  ///
  /// Samples every fourth frame — enough for a meter, and cheap enough to run
  /// on every buffer.
  @protected
  void emitLevel(Uint8List data) {
    if (data.length < 2 || _levels.isClosed) return;
    final view = ByteData.sublistView(data);
    var energy = 0.0;
    var samples = 0;
    for (var offset = 0; offset + 1 < data.length; offset += 8) {
      final value = view.getInt16(offset, Endian.little) / 32768.0;
      energy += value * value;
      samples += 1;
    }
    if (samples > 0) {
      _levels.add(math.sqrt(energy / samples).clamp(0.0, 1.0));
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _pcm.close();
    await _levels.close();
    await _warnings.close();
  }
}
