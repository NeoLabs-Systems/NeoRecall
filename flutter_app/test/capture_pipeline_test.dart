import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/capture/capture_pipeline.dart';
import 'package:neorecall/src/capture/capture_source.dart';

class _FakeSource implements CaptureSource {
  _FakeSource(this.id, this.kind);
  @override
  final String id;
  @override
  final String kind;
  final StreamController<Uint8List> _pcm = StreamController<Uint8List>.broadcast();
  final StreamController<double> _levels = StreamController<double>.broadcast();
  final StreamController<String> _warnings = StreamController<String>.broadcast();
  bool _active = false;

  @override
  bool get isActive => _active;
  @override
  Stream<Uint8List> get pcm16Stream => _pcm.stream;
  @override
  Stream<double> get levelStream => _levels.stream;
  @override
  Stream<String> get warningStream => _warnings.stream;
  @override
  Future<bool> ensurePermission() async => true;
  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    _active = true;
  }
  @override
  Future<void> stop() async {
    _active = false;
  }
  @override
  Future<void> dispose() async {
    await stop();
    await _pcm.close();
    await _levels.close();
    await _warnings.close();
  }

  void pushSilenceMs(int ms, {int sampleRate = 16000}) {
    final bytes = Uint8List(sampleRate * 2 * ms ~/ 1000);
    _pcm.add(bytes);
  }
}

void main() {
  test('pipeline emits independently decodable chunks from dual sources', () async {
    final mic = _FakeSource('mic', 'microphone');
    final sys = _FakeSource('sys', 'system');
    final pipeline = CapturePipeline(
      sources: <CaptureSource>[mic, sys],
      chunkMs: 1000,
      overlapMs: 200,
      sampleRate: 16000,
    );
    final chunks = <int>[];
    final sub = pipeline.chunks.stream.listen((chunk) {
      chunks.add(chunk.bytes.length);
      expect(chunk.channelLayout, 'microphone_left_system_right');
      expect(chunk.bytes.length, greaterThan(44));
    });

    final capability = await pipeline.start();
    expect(capability.microphone, isTrue);
    expect(capability.systemAudio, isTrue);

    mic.pushSilenceMs(1200);
    sys.pushSilenceMs(1200);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await pipeline.stop();
    await sub.cancel();
    await pipeline.dispose();

    expect(chunks, isNotEmpty);
  });
}
