import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keeps the administrator API key of each NeoRecall server this app installed,
/// so provider settings stay reachable from the app after the first run.
class AdminKeyStore {
  const AdminKeyStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  final FlutterSecureStorage _storage;

  static String _key(String backendUrl) {
    final normalized = backendUrl.trim().replaceFirst(RegExp(r'/$'), '');
    return 'adminApiKey:${base64Url.encode(utf8.encode(normalized))}';
  }

  Future<void> save(String backendUrl, String apiKey) =>
      _storage.write(key: _key(backendUrl), value: apiKey);

  Future<String?> read(String backendUrl) async {
    final value = await _storage.read(key: _key(backendUrl));
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> clear(String backendUrl) =>
      _storage.delete(key: _key(backendUrl));
}
