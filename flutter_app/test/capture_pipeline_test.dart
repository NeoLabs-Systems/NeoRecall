import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/capture/capture_pipeline.dart';
import 'package:neorecall/src/capture/capture_source.dart';

class _FakeSource implements CaptureSource {
  _FakeSource(this.id, this.kind, {this.tailMsOnStop = 0});
  @override
  final String id;
  @override
  final String kind;
  final StreamController<Uint8List> _pcm =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<double> _levels = StreamController<double>.broadcast();
  final StreamController<String> _warnings =
      StreamController<String>.broadcast();
  bool _active = false;
  final int tailMsOnStop;

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
    if (tailMsOnStop > 0) pushSilenceMs(tailMsOnStop);
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

  Future<void> endPcm() => _pcm.close();

  void failPcm(Object error) => _pcm.addError(error);
}

void main() {
  test(
    'pipeline emits independently decodable chunks from dual sources',
    () async {
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
    },
  );

  test('pipeline waits for a temporarily lagging sibling source', () async {
    final mic = _FakeSource('mic', 'microphone');
    final sys = _FakeSource('sys', 'system');
    final pipeline = CapturePipeline(
      sources: <CaptureSource>[mic, sys],
      chunkMs: 100,
      overlapMs: 0,
      sampleRate: 16000,
      flushInterval: const Duration(milliseconds: 10),
      partialInterval: const Duration(seconds: 10),
      sourceStallTimeout: const Duration(seconds: 1),
    );
    final chunks = <int>[];
    final sub = pipeline.chunks.stream.listen(
      (chunk) => chunks.add(chunk.durationMs),
    );
    await pipeline.start();

    mic.pushSilenceMs(120);
    sys.pushSilenceMs(40);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(chunks, isEmpty);

    sys.pushSilenceMs(80);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(chunks, <int>[100]);

    await pipeline.stop();
    await sub.cancel();
    await pipeline.dispose();
  });

  test(
    'pipeline finalizes a failed source tail and keeps its sibling running',
    () async {
      final mic = _FakeSource('mic', 'microphone');
      final sys = _FakeSource('sys', 'system');
      final pipeline = CapturePipeline(
        sources: <CaptureSource>[mic, sys],
        chunkMs: 100,
        overlapMs: 0,
        sampleRate: 16000,
        flushInterval: const Duration(milliseconds: 10),
        partialInterval: const Duration(seconds: 10),
        sourceStallTimeout: const Duration(milliseconds: 30),
      );
      final layouts = <String>[];
      final sub = pipeline.chunks.stream.listen(
        (chunk) => layouts.add(chunk.channelLayout),
      );
      await pipeline.start();

      mic.pushSilenceMs(220);
      sys.pushSilenceMs(40);
      await sys.endPcm();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(layouts, <String>['microphone_left_system_right', 'mono']);
      await pipeline.stop();
      await sub.cancel();
      await pipeline.dispose();
    },
  );

  test(
    'single-source stalls are reported instead of recording silence forever',
    () async {
      final mic = _FakeSource('mic', 'microphone');
      final pipeline = CapturePipeline(
        sources: <CaptureSource>[mic],
        chunkMs: 100,
        overlapMs: 0,
        sampleRate: 16000,
        flushInterval: const Duration(milliseconds: 10),
        partialInterval: const Duration(seconds: 10),
        sourceStallTimeout: const Duration(milliseconds: 30),
      );
      final interruptions = <CapturePipelineInterruption>[];
      final sub = pipeline.interruptions.stream.listen(interruptions.add);

      await pipeline.start();
      await Future<void>.delayed(const Duration(milliseconds: 70));

      expect(interruptions, hasLength(1));
      expect(interruptions.single.sourceKind, 'microphone');
      expect(interruptions.single.reason, contains('stalled'));
      await pipeline.stop();
      await sub.cancel();
      await pipeline.dispose();
    },
  );

  test('source errors produce one typed interruption', () async {
    final mic = _FakeSource('mic', 'microphone');
    final pipeline = CapturePipeline(
      sources: <CaptureSource>[mic],
      chunkMs: 100,
      overlapMs: 0,
      sampleRate: 16000,
      flushInterval: const Duration(milliseconds: 10),
      partialInterval: const Duration(seconds: 10),
      sourceStallTimeout: const Duration(seconds: 1),
    );
    final interruptions = <CapturePipelineInterruption>[];
    final sub = pipeline.interruptions.stream.listen(interruptions.add);
    await pipeline.start();

    mic.failPcm(StateError('recorder failed'));
    await Future<void>.delayed(Duration.zero);

    expect(interruptions, hasLength(1));
    expect(interruptions.single.reason, contains('recorder failed'));
    await pipeline.stop();
    await sub.cancel();
    await pipeline.dispose();
  });

  test(
    'PCM delivered while a source stops is included in the final chunk',
    () async {
      final mic = _FakeSource('mic', 'microphone', tailMsOnStop: 40);
      final pipeline = CapturePipeline(
        sources: <CaptureSource>[mic],
        chunkMs: 100,
        overlapMs: 0,
        sampleRate: 16000,
        flushInterval: const Duration(seconds: 10),
        partialInterval: const Duration(seconds: 10),
        sourceStallTimeout: const Duration(seconds: 1),
      );
      final durations = <int>[];
      final sub = pipeline.chunks.stream.listen(
        (chunk) => durations.add(chunk.durationMs),
      );
      await pipeline.start();

      await pipeline.stop();

      expect(durations, <int>[40]);
      await sub.cancel();
      await pipeline.dispose();
    },
  );
}
