import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/install/local_runtime_app.dart';

void main() {
  // The desktop installer verifies with its own copy of the release key; if it
  // drifts from the server's, every desktop install would be refused.
  test('the installer trusts the key the server releases are signed with', () {
    final released = File('../internal/signing/public_key.txt');
    expect(neoRecallRuntimeApp.publicKey, released.readAsStringSync().trim());
  });
}
