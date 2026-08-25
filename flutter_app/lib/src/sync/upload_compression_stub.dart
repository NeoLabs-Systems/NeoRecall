import 'dart:typed_data';

class UploadPayload {
  const UploadPayload(this.bytes, {this.contentEncoding});

  final Uint8List bytes;
  final String? contentEncoding;
}

Future<UploadPayload> prepareAudioUpload(
  Uint8List bytes, {
  bool allowCompression = false,
}) async => UploadPayload(bytes);
