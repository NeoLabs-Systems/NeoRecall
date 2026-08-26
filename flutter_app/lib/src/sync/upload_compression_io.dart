import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

class UploadPayload {
  const UploadPayload(this.bytes, {this.contentEncoding});

  final Uint8List bytes;
  final String? contentEncoding;
}

/// Central transport policy. Compression is lossless and is used only when the
/// result is materially smaller, avoiding CPU/battery cost for tiny or already
/// compressed wearable formats.
const int _minimumCompressionInputBytes = 32 * 1024;
const double _maximumCompressedRatio = 0.9;

Future<UploadPayload> prepareAudioUpload(
  Uint8List bytes, {
  bool allowCompression = false,
}) async {
  if (!allowCompression) return UploadPayload(bytes);
  if (bytes.length < _minimumCompressionInputBytes) return UploadPayload(bytes);
  final compressed = await Isolate.run(
    () => Uint8List.fromList(gzip.encode(bytes)),
  );
  if (compressed.length / bytes.length > _maximumCompressedRatio) {
    return UploadPayload(bytes);
  }
  return UploadPayload(compressed, contentEncoding: 'gzip');
}
