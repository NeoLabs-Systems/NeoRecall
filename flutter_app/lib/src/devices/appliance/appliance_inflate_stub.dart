import 'dart:typed_data';

/// The web build has no zlib, and no Desk drain either: pulling a recording
/// over BLE is a phone feature. This stub keeps the import graph honest.
Uint8List inflate(Uint8List compressed) =>
    throw UnsupportedError('Bluetooth drain is not available on this platform.');
