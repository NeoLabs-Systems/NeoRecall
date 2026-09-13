import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readWatchInboxAudio(Map<String, dynamic> row) async {
  final path = row['path'];
  if (path is String && path.isNotEmpty) {
    return File(path).readAsBytes();
  }
  final bytes = row['bytes'];
  if (bytes is Uint8List) return bytes;
  throw const FormatException('Wear OS audio payload is not binary.');
}
