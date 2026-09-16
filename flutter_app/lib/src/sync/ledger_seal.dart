import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// AES-256-GCM wrap for durable client audio and context files.
///
/// The key lives in platform secure storage so a copied support directory is
/// not playable audio. Legacy plaintext files still unwrap as themselves.
class LedgerSeal {
  LedgerSeal._(this._key);

  static const _storageKey = 'neorecall.ledger.seal.v1';
  static const _magic = [0x4e, 0x52, 0x4c, 0x31]; // NRL1
  static const _header = 4 + 12 + 16;

  static LedgerSeal? _instance;
  static Uint8List? debugKey;

  final SecretKey _key;
  final AesGcm _algorithm = AesGcm.with256bits();

  static Future<LedgerSeal> instance() async {
    final existing = _instance;
    if (existing != null) return existing;
    final bytes = debugKey ?? await _loadOrCreateKey();
    return _instance = LedgerSeal._(SecretKey(bytes));
  }

  static Future<Uint8List> _loadOrCreateKey() async {
    const storage = FlutterSecureStorage();
    final stored = await storage.read(key: _storageKey);
    if (stored != null && stored.isNotEmpty) {
      return Uint8List.fromList(base64Decode(stored));
    }
    final secretKey = await AesGcm.with256bits().newSecretKey();
    final bytes = Uint8List.fromList(await secretKey.extractBytes());
    await storage.write(key: _storageKey, value: base64Encode(bytes));
    return bytes;
  }

  static bool looksSealed(Uint8List bytes) {
    if (bytes.length < _header) return false;
    for (var i = 0; i < _magic.length; i += 1) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  Future<Uint8List> seal(Uint8List plain) async {
    final box = await _algorithm.encrypt(plain, secretKey: _key);
    return Uint8List.fromList([
      ..._magic,
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  Future<Uint8List> unseal(Uint8List stored) async {
    if (!looksSealed(stored)) return stored;
    final nonce = stored.sublist(4, 16);
    final mac = Mac(stored.sublist(stored.length - 16));
    final cipherText = stored.sublist(16, stored.length - 16);
    return Uint8List.fromList(
      await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: _key,
      ),
    );
  }
}
