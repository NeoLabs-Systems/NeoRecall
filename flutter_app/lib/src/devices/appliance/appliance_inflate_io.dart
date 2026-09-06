import 'dart:io';
import 'dart:typed_data';

/// Undo the device-side zlib pass. Compression is what turns a minutes-long
/// Bluetooth transfer of speech (with its silences) into a bearable one.
Uint8List inflate(Uint8List compressed) =>
    Uint8List.fromList(ZLibDecoder().convert(compressed));
