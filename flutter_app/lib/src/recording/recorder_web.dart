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
      js.allowInterop((dynamic byteValues, dynamic metadataValue) {
        final values = List<num>.from(js_util.dartify(byteValues) as List);
        final metadata = Map<String, dynamic>.from(
          js_util.dartify(metadataValue) as Map,
        );
        _chunks.add(
          RecordedAudioChunk(
            bytes: Uint8List.fromList(
              values.map((value) => value.toInt()).toList(),
            ),
            durationMs: metadata['durationMs'] as int,
            overlapMs: metadata['overlapMs'] as int,
            channelLayout: metadata['channelLayout'] as String,
            startedAt: DateTime.parse(metadata['startedAt'] as String),
            monotonicOffsetMs: metadata['monotonicOffsetMs'] as int,
            isFinal: metadata['isFinal'] as bool,
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
    final result = Map<String, dynamic>.from(
      js_util.dartify(
            await js_util.promiseToFuture<Object?>(
              capture.callMethod('start', <Object>[
                <String, Object>{
                  'microphone': microphone,
                  'systemAudio': systemAudio,
                  'chunkMs': chunkMs,
                  'overlapMs': overlapMs,
                },
              ]),
            ),
          )
          as Map,
    );
    _recording = true;
    return RecorderCapability(
      microphone: result['microphone'] as bool,
      systemAudio: result['systemAudio'] as bool,
      persistentStorage: result['persistentStorage'] as bool,
      sampleRate: result['sampleRate'] as int,
      warning: result['warning'] as String?,
    );
  }

  @override
  Future<void> stop() async {
    if (!_recording) return;
    await js_util.promiseToFuture<Object?>(
      js.context['NeoRecallCapture'].callMethod('stop'),
    );
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
