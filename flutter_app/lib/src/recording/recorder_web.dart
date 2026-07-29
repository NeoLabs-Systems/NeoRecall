// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:js' as js;
import 'dart:js_util' as js_util;
import 'dart:typed_data';

import '../capture/bluetooth_capture_source.dart';
import '../capture/capture_pipeline.dart';
import '../devices/audio_device_adapter.dart';
import 'audio_frame.dart';
import 'recorder.dart';

RecallRecorder createRecorder() => WebRecallRecorder();

class WebRecallRecorder implements RecallRecorder {
  final StreamController<RecordedAudioChunk> _chunks =
      StreamController<RecordedAudioChunk>.broadcast();
  final StreamController<String> _warnings =
      StreamController<String>.broadcast();
  final StreamController<double> _levels = StreamController<double>.broadcast();
  CapturePipeline? _bluetoothPipeline;
  final List<StreamSubscription<dynamic>> _bluetoothSubscriptions =
      <StreamSubscription<dynamic>>[];
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
    ExternalAudioCaptureDevice? externalDevice,
  }) async {
    if (externalDevice != null) {
      if (microphone || systemAudio) {
        throw StateError(
          'Browser Bluetooth capture is an alternative source; disable browser microphone and tab audio first.',
        );
      }
      final pipeline = CapturePipeline(
        sources: <BluetoothCaptureSource>[
          BluetoothCaptureSource(
            adapter: externalDevice.adapter,
            device: externalDevice.descriptor,
            connectOnStart: false,
          ),
        ],
        chunkMs: chunkMs,
        overlapMs: overlapMs,
      );
      _bluetoothSubscriptions
        ..add(pipeline.chunks.stream.listen(_chunks.add))
        ..add(pipeline.warnings.stream.listen(_warnings.add))
        ..add(pipeline.levels.stream.listen(_levels.add));
      try {
        final capability = await pipeline.start();
        _bluetoothPipeline = pipeline;
        _recording = true;
        return capability;
      } catch (_) {
        await pipeline.dispose();
        for (final subscription in _bluetoothSubscriptions) {
          await subscription.cancel();
        }
        _bluetoothSubscriptions.clear();
        rethrow;
      }
    }
    final capture = js_util.getProperty<Object?>(
      js_util.globalThis,
      'NeoRecallCapture',
    );
    if (capture == null) {
      throw StateError('NeoRecall browser audio module did not load.');
    }
    final protocolVersion = js_util.getProperty<Object?>(
      capture,
      'protocolVersion',
    );
    final usesCallbackProtocol = protocolVersion == 2;
    js_util.setProperty(
      capture,
      'onChunk',
      usesCallbackProtocol
          ? js.allowInterop((
              dynamic byteValues,
              dynamic durationMs,
              dynamic chunkOverlapMs,
              dynamic channelLayout,
              dynamic chunkStartedAt,
              dynamic monotonicOffsetMs,
              dynamic isFinal,
            ) {
              _addChunk(
                byteValues,
                durationMs,
                chunkOverlapMs,
                channelLayout,
                chunkStartedAt,
                monotonicOffsetMs,
                isFinal,
              );
            })
          : js.allowInterop((dynamic byteValues, dynamic metadata) {
              _addChunk(
                byteValues,
                js_util.getProperty<Object>(metadata, 'durationMs'),
                js_util.getProperty<Object>(metadata, 'overlapMs'),
                js_util.getProperty<Object>(metadata, 'channelLayout'),
                js_util.getProperty<Object>(metadata, 'startedAt'),
                js_util.getProperty<Object>(metadata, 'monotonicOffsetMs'),
                js_util.getProperty<Object>(metadata, 'isFinal'),
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
    final completeCapability = js.allowInterop((
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
            sourceKind: hasSystemAudio
                ? hasMicrophone
                      ? 'combined'
                      : 'system'
                : 'microphone',
            warning: capabilityWarning as String?,
          ),
        );
      }
    });
    final completeError = js.allowInterop((dynamic value) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(value.toString()));
      }
    });
    if (usesCallbackProtocol) {
      js_util.callMethod<Object?>(capture, 'start', <Object>[
        microphone,
        systemAudio,
        chunkMs,
        overlapMs,
        completeCapability,
        completeError,
      ]);
    } else {
      final result = js_util.callMethod<Object?>(capture, 'start', <Object>[
        js_util.jsify(<String, Object>{
          'microphone': microphone,
          'systemAudio': systemAudio,
          'chunkMs': chunkMs,
          'overlapMs': overlapMs,
        }),
      ]);
      _then(
        result,
        js.allowInterop((dynamic capability) {
          completeCapability(
            js_util.getProperty<Object>(capability, 'microphone'),
            js_util.getProperty<Object>(capability, 'systemAudio'),
            js_util.getProperty<Object>(capability, 'persistentStorage'),
            js_util.getProperty<Object>(capability, 'sampleRate'),
            js_util.getProperty<Object?>(capability, 'warning'),
          );
        }),
        completeError,
        completer,
      );
    }
    final capability = await completer.future;
    _recording = true;
    return capability;
  }

  void _addChunk(
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
  }

  void _then<T>(
    Object? result,
    Object onSuccess,
    Object onError,
    Completer<T> completer,
  ) {
    if (result == null || !js_util.hasProperty(result, 'then')) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('NeoRecall browser audio module returned no operation.'),
        );
      }
      return;
    }
    js_util.callMethod<Object?>(result, 'then', <Object>[onSuccess, onError]);
  }

  @override
  Future<void> stop() async {
    if (!_recording) return;
    final bluetoothPipeline = _bluetoothPipeline;
    if (bluetoothPipeline != null) {
      _bluetoothPipeline = null;
      await bluetoothPipeline.stop();
      await bluetoothPipeline.dispose();
      for (final subscription in _bluetoothSubscriptions) {
        await subscription.cancel();
      }
      _bluetoothSubscriptions.clear();
      _recording = false;
      return;
    }
    final capture = js_util.getProperty<Object?>(
      js_util.globalThis,
      'NeoRecallCapture',
    );
    if (capture == null) {
      throw StateError('NeoRecall browser audio module did not load.');
    }
    final completer = Completer<void>();
    final complete = js.allowInterop(([dynamic _]) {
      if (!completer.isCompleted) completer.complete();
    });
    final completeError = js.allowInterop((dynamic value) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(value.toString()));
      }
    });
    if (js_util.getProperty<Object?>(capture, 'protocolVersion') == 2) {
      js_util.callMethod<Object?>(capture, 'stop', <Object>[
        complete,
        completeError,
      ]);
    } else {
      final result = js_util.callMethod<Object?>(capture, 'stop', const []);
      _then(result, complete, completeError, completer);
    }
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
