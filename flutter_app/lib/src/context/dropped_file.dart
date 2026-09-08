import 'dart:typed_data';

/// One file the browser handed over in a drag-and-drop gesture.
class DroppedFile {
  const DroppedFile({
    required this.name,
    required this.bytes,
    this.declaredType,
  });

  /// The file name as the operating system reported it, including extension.
  final String name;

  /// The whole file. Context uploads carry the bytes, so the drop reads them
  /// before the item is queued; a browser file handle does not survive a
  /// reload, but the queued context item does.
  final Uint8List bytes;

  /// The MIME type the browser guessed, when it guessed one. Empty for files
  /// whose extension the browser does not know.
  final String? declaredType;
}
