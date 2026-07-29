// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:js' as js;
import 'dart:js_util' as js_util;
import 'dart:typed_data';

import 'audio_frame.dart';
import 'recorder.dart';

RecallRecorder createRecorder() => WebRecallRecorder();

class WebRecallRecorder implements RecallRecorder {
  final StreamController<RecordedAudioChunk> _chunks =
      StreamController<RecordedAudioChunk>.broadcast();
  final StreamController<String> _warnings =
      StreamController<String>.broadcast();
  final StreamController<double> _levels = StreamController<double>.broadcast();
  bool _recording = false;
  @override
  Stream<RecordedAudioChunk> get chunks => _chunks.stream;
  @override
  Stream<RecordedAudioChunk> get partials =>
      const Stream<RecordedAudioChunk>.empty();
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
    final capture = js.context['NeoRecallCapture'];
    if (capture == null) {
      throw StateError('NeoRecall browser audio module did not load.');
    }
    js_util.setProperty(
      capture,
      'onChunk',
      js.allowInterop((
        dynamic byteValues,
        dynamic durationMs,
        dynamic chunkOverlapMs,
        dynamic channelLayout,
        dynamic chunkStartedAt,
        dynamic monotonicOffsetMs,
        dynamic isFinal,
      ) {
        final values = List<num>.from(js_util.dartify(byteValues) as List);
        _chunks.add(
          RecordedAudioChunk(
            bytes: Uint8List.fromList(
              values.map((value) => value.toInt()).toList(),
            ),
            durationMs: (durationMs as num).toInt(),
            overlapMs: (chunkOverlapMs as num).toInt(),
            channelLayout: channelLayout as String,
            startedAt: DateTime.parse(chunkStartedAt as String),
            monotonicOffsetMs: (monotonicOffsetMs as num).toInt(),
            isFinal: isFinal as bool,
          ),
        );
      }),
    );
    js_util.setProperty(
      capture,
      'onWarning',
      js.allowInterop((dynamic value) => _warnings.add(value.toString())),
    );
    js_util.setProperty(
      capture,
      'onLevel',
      js.allowInterop(
        (dynamic value) => _levels.add((value as num).toDouble()),
      ),
    );
    final completer = Completer<RecorderCapability>();
    capture.callMethod('start', <Object>[
      microphone,
      systemAudio,
      chunkMs,
      overlapMs,
      js.allowInterop((
        dynamic hasMicrophone,
        dynamic hasSystemAudio,
        dynamic persistentStorage,
        dynamic sampleRate,
        dynamic capabilityWarning,
      ) {
        if (!completer.isCompleted) {
          completer.complete(
            RecorderCapability(
              microphone: hasMicrophone as bool,
              systemAudio: hasSystemAudio as bool,
              persistentStorage: persistentStorage as bool,
              sampleRate: (sampleRate as num).toInt(),
              warning: capabilityWarning as String?,
            ),
          );
        }
      }),
      js.allowInterop((dynamic value) {
        if (!completer.isCompleted) {
          completer.completeError(StateError(value.toString()));
        }
      }),
    ]);
    final capability = await completer.future;
    _recording = true;
    return capability;
  }

  @override
  Future<void> stop() async {
    if (!_recording) return;
    final completer = Completer<void>();
    js.context['NeoRecallCapture'].callMethod('stop', <Object>[
      js.allowInterop((dynamic _) {
        if (!completer.isCompleted) completer.complete();
      }),
      js.allowInterop((dynamic value) {
        if (!completer.isCompleted) {
          completer.completeError(StateError(value.toString()));
        }
      }),
    ]);
    await completer.future;
    _recording = false;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _chunks.close();
    await _warnings.close();
    await _levels.close();
  }
}
