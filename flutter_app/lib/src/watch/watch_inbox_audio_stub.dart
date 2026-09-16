import 'dart:typed_data';

Future<Uint8List> readWatchInboxAudio(Map<String, dynamic> row) async {
  final bytes = row['bytes'];
  if (bytes is Uint8List) return bytes;
  throw const FormatException('Wear OS audio payload is not binary.');
}
