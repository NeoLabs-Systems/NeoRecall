import 'dart:typed_data';

/// Platform-agnostic continuous audio source.
///
/// Implementations must be independently stoppable and must never discard
/// already-captured PCM when a sibling source fails.
abstract class CaptureSource {
  String get id;
  String get kind;
  bool get isActive;

  Stream<Uint8List> get pcm16Stream;
  Stream<double> get levelStream;
  Stream<String> get warningStream;

  Future<bool> ensurePermission();
  Future<void> start({required int sampleRate, required int channels});
  Future<void> stop();
  Future<void> dispose();
}

class CaptureSourceCapability {
  const CaptureSourceCapability({
    required this.id,
    required this.kind,
    required this.available,
    this.warning,
  });

  final String id;
  final String kind;
  final bool available;
  final String? warning;
}
