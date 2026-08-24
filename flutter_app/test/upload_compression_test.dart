import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/sync/upload_compression.dart';

void main() {
  test('losslessly compresses a silent PCM-sized payload', () async {
    final original = Uint8List(128 * 1024);
    final upload = await prepareAudioUpload(original);

    expect(upload.contentEncoding, 'gzip');
    expect(upload.bytes.length, lessThan(original.length));
    expect(Uint8List.fromList(gzip.decode(upload.bytes)), original);
  });

  test('does not spend compression overhead on tiny payloads', () async {
    final original = Uint8List(1024);
    final upload = await prepareAudioUpload(original);

    expect(upload.contentEncoding, isNull);
    expect(upload.bytes, same(original));
  });
}
