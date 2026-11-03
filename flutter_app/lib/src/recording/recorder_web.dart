import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
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
    final capture = globalContext['NeoRecallCapture'] as JSObject?;
    if (capture == null) {
      throw StateError('NeoRecall browser audio module did not load.');
    }
    final usesCallbackProtocol = capture['protocolVersion'].dartify() == 2;
    capture['onChunk'] = usesCallbackProtocol
        ? ((
            JSAny? byteValues,
            JSAny? durationMs,
            JSAny? chunkOverlapMs,
            JSAny? channelLayout,
            JSAny? chunkStartedAt,
            JSAny? monotonicOffsetMs,
            JSAny? isFinal,
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
          }).toJS
        : ((JSAny? byteValues, JSObject metadata) {
            _addChunk(
              byteValues,
              metadata['durationMs'],
              metadata['overlapMs'],
              metadata['channelLayout'],
              metadata['startedAt'],
              metadata['monotonicOffsetMs'],
              metadata['isFinal'],
            );
          }).toJS;
    capture['onWarning'] = ((JSAny? value) {
      _warnings.add(value.toString());
    }).toJS;
    capture['onLevel'] = ((JSAny? value) {
      _levels.add((value.dartify() as num).toDouble());
    }).toJS;
    final completer = Completer<RecorderCapability>();
    void completeCapability(
      JSAny? hasMicrophone,
      JSAny? hasSystemAudio,
      JSAny? persistentStorage,
      JSAny? sampleRate,
      JSAny? capabilityWarning,
    ) {
      if (completer.isCompleted) return;
      final microphoneGranted = hasMicrophone.dartify() as bool;
      final systemAudioGranted = hasSystemAudio.dartify() as bool;
      completer.complete(
        RecorderCapability(
          microphone: microphoneGranted,
          systemAudio: systemAudioGranted,
          persistentStorage: persistentStorage.dartify() as bool,
          sampleRate: (sampleRate.dartify() as num).toInt(),
          sourceKind: systemAudioGranted
              ? microphoneGranted
                    ? 'combined'
                    : 'system'
              : 'microphone',
          warning: capabilityWarning.dartify() as String?,
        ),
      );
    }

    final completeError = ((JSAny? value) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(value.toString()));
      }
    }).toJS;
    if (usesCallbackProtocol) {
      capture.callMethodVarArgs<JSAny?>('start'.toJS, <JSAny?>[
        microphone.toJS,
        systemAudio.toJS,
        chunkMs.toJS,
        overlapMs.toJS,
        completeCapability.toJS,
        completeError,
      ]);
    } else {
      final result = capture.callMethod<JSAny?>(
        'start'.toJS,
        <String, Object>{
          'microphone': microphone,
          'systemAudio': systemAudio,
          'chunkMs': chunkMs,
          'overlapMs': overlapMs,
        }.jsify(),
      );
      _then(
        result,
        ((JSObject capability) {
          completeCapability(
            capability['microphone'],
            capability['systemAudio'],
            capability['persistentStorage'],
            capability['sampleRate'],
            capability['warning'],
          );
        }).toJS,
        completeError,
        completer,
      );
    }
    final capability = await completer.future;
    _recording = true;
    return capability;
  }

  void _addChunk(
    JSAny? byteValues,
    JSAny? durationMs,
    JSAny? chunkOverlapMs,
    JSAny? channelLayout,
    JSAny? chunkStartedAt,
    JSAny? monotonicOffsetMs,
    JSAny? isFinal,
  ) {
    final values = List<num>.from(byteValues.dartify() as List);
    _chunks.add(
      RecordedAudioChunk(
        bytes: Uint8List.fromList(
          values.map((value) => value.toInt()).toList(),
        ),
        durationMs: (durationMs.dartify() as num).toInt(),
        overlapMs: (chunkOverlapMs.dartify() as num).toInt(),
        channelLayout: channelLayout.dartify() as String,
        startedAt: DateTime.parse(chunkStartedAt.dartify() as String),
        monotonicOffsetMs: (monotonicOffsetMs.dartify() as num).toInt(),
        isFinal: isFinal.dartify() as bool,
      ),
    );
  }

  void _then<T>(
    JSAny? result,
    JSFunction onSuccess,
    JSFunction onError,
    Completer<T> completer,
  ) {
    if (result == null || !(result as JSObject).has('then')) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('NeoRecall browser audio module returned no operation.'),
        );
      }
      return;
    }
    result.callMethod<JSAny?>('then'.toJS, onSuccess, onError);
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
    final capture = globalContext['NeoRecallCapture'] as JSObject?;
    if (capture == null) {
      throw StateError('NeoRecall browser audio module did not load.');
    }
    final completer = Completer<void>();
    final complete = (([JSAny? _]) {
      if (!completer.isCompleted) completer.complete();
    }).toJS;
    final completeError = ((JSAny? value) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(value.toString()));
      }
    }).toJS;
    if (capture['protocolVersion'].dartify() == 2) {
      capture.callMethod<JSAny?>('stop'.toJS, complete, completeError);
    } else {
      final result = capture.callMethod<JSAny?>('stop'.toJS);
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
