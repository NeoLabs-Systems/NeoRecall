import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/sync/ledger_seal.dart';

void main() {
  test('sealed bytes hide plaintext and unwrap to the original', () async {
    LedgerSeal.debugKey = Uint8List.fromList(List<int>.filled(32, 7));
    final seal = await LedgerSeal.instance();
    final plain = Uint8List.fromList('RIFF WAVE secret-speech'.codeUnits);
    final stored = await seal.seal(plain);
    expect(LedgerSeal.looksSealed(stored), isTrue);
    expect(String.fromCharCodes(stored).contains('secret-speech'), isFalse);
    expect(await seal.unseal(stored), plain);
    expect(await seal.unseal(plain), plain);
  });
}
