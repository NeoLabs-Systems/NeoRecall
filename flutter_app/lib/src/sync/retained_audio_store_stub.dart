import 'dart:typed_data';

import 'retained_audio_store.dart';

RetainedAudioStore createRetainedAudioStore({String? rootPath}) =>
    _UnsupportedRetainedAudioStore();

class _UnsupportedRetainedAudioStore implements RetainedAudioStore {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> retain({
    required String accountId,
    required String id,
    required Uint8List bytes,
    required String mimeType,
    required String filename,
    required DateTime capturedAt,
    String? importId,
    String? sessionId,
    int sequence = 0,
    Duration duration = Duration.zero,
  }) async {}

  @override
  Future<List<RetainedAudioClip>> lookup({
    required String accountId,
    Iterable<String> importIds = const <String>[],
    Iterable<String> sessionIds = const <String>[],
  }) async => const <RetainedAudioClip>[];

  @override
  Future<bool> hasClips({
    required String accountId,
    Iterable<String> importIds = const <String>[],
    Iterable<String> sessionIds = const <String>[],
  }) async => false;

  @override
  Future<RetainedAudioClip?> getClip(String accountId, String id) async => null;

  @override
  Future<Uint8List> readBytes(RetainedAudioClip clip) async =>
      throw StateError('Raw audio is not kept on this platform.');

  @override
  Future<int> purgeExpired({
    required String accountId,
    required Duration keep,
    DateTime? now,
  }) async => 0;

  @override
  Future<int> purgeAccount(String accountId) async => 0;

  @override
  Future<void> close() async {}
}
