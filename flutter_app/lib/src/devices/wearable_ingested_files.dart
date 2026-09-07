import 'package:shared_preferences/shared_preferences.dart';

/// File ids already captured live (or imported) for a wearable, so a later
/// drain does not upload the same take again after a BLE reconnect.
class WearableIngestedFiles {
  WearableIngestedFiles._();

  static final Map<String, Set<String>> _memory = <String, Set<String>>{};

  static String _key(String deviceId) => 'wearableLiveIngested:$deviceId';

  static Set<String> ids(String deviceId) =>
      _memory.putIfAbsent(deviceId, () => <String>{});

  static void resetForTest() => _memory.clear();

  static Future<void> hydrate(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      ids(
        deviceId,
      ).addAll(prefs.getStringList(_key(deviceId)) ?? const <String>[]);
    } catch (_) {
      // Tests and a missing plugin still keep the in-memory set for this process.
    }
  }

  static Future<void> remember(String deviceId, String fileId) async {
    if (fileId.isEmpty || !ids(deviceId).add(fileId)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key(deviceId), ids(deviceId).toList());
    } catch (_) {}
  }
}
