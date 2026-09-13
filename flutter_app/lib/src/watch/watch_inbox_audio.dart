import 'watch_inbox_audio_stub.dart'
    if (dart.library.io) 'watch_inbox_audio_io.dart'
    as implementation;

import 'dart:typed_data';

/// Audio for one Wear inbox row: a filesystem path from the native inbox, or
/// the bytes a test double already loaded.
Future<Uint8List> readWatchInboxAudio(Map<String, dynamic> row) =>
    implementation.readWatchInboxAudio(row);
