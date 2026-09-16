import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// How much of each device-stored take was already captured over the live
/// stream, so a later drain neither uploads the same audio twice nor deletes a
/// recording the phone never actually received.
///
/// Seconds, not a yes/no flag. A live stream that delivered one frame and then
/// died used to mark the device's whole file as captured, and the next sync
/// deleted it from the device unread — hours of a recording could disappear on
/// the strength of a moment of audio. What matters is whether the live capture
/// covers the take, and only a duration can answer that.
class WearableIngestedFiles {
  WearableIngestedFiles._();

  /// Fraction of a device file that must have arrived live before the device's
  /// own copy is treated as redundant. Below it the file is transferred; the
  /// server already discards audio it has heard from the same device.
  static const double coveredFraction = 0.9;

  /// Seconds of a take the live stream may legitimately miss. Frames start
  /// after the start command and stop before the stop command, so a healthy
  /// take is always a little shorter live than it is on the clock.
  static const int toleranceSeconds = 5;

  /// Whether live audio of [liveSeconds] accounts for a take of [takeSeconds].
  ///
  /// A null [takeSeconds] means this phone never saw the take begin — it joined
  /// a recording the device had already started, so it cannot know what came
  /// before it and must never claim to hold the whole thing. The device keeps
  /// its copy, the drain transfers it, and the server discards the overlap.
  static bool coversSpan({
    required int liveSeconds,
    required int? takeSeconds,
  }) {
    if (takeSeconds == null) return false;
    if (takeSeconds - liveSeconds <= toleranceSeconds) return true;
    return takeSeconds > 0 && liveSeconds >= takeSeconds * coveredFraction;
  }

  static final Map<String, Map<String, int>> _memory =
      <String, Map<String, int>>{};
  static final Map<String, Set<String>> _incomplete = <String, Set<String>>{};

  static String _key(String deviceId) =>
      'wearableLiveIngestedSeconds:$deviceId';
  static String _incompleteKey(String deviceId) =>
      'wearableLiveIngestedIncomplete:$deviceId';

  static Map<String, int> _forDevice(String deviceId) =>
      _memory.putIfAbsent(deviceId, () => <String, int>{});

  static Set<String> _incompleteFor(String deviceId) =>
      _incomplete.putIfAbsent(deviceId, () => <String>{});

  /// Live seconds recorded for [fileId], or null when this phone never saw it.
  /// Null and zero both mean "do not delete it unread".
  static int? seconds(String deviceId, String fileId) =>
      _forDevice(deviceId)[fileId];

  /// Whether the live stream covered enough of a device file of
  /// [durationSeconds] that the device's copy adds nothing.
  static bool covers(String deviceId, String fileId, int durationSeconds) {
    if (_incompleteFor(deviceId).contains(fileId)) return false;
    final live = seconds(deviceId, fileId);
    if (live == null || durationSeconds <= 0) return false;
    return coversSpan(liveSeconds: live, takeSeconds: durationSeconds);
  }

  static void resetForTest() {
    _memory.clear();
    _incomplete.clear();
  }

  static Future<void> hydrate(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_key(deviceId));
      if (stored != null) {
        final decoded = jsonDecode(stored);
        if (decoded is Map) {
          final device = _forDevice(deviceId);
          decoded.forEach((key, value) {
            final live = value is num ? value.toInt() : null;
            if (key is! String || live == null) return;
            final known = device[key];
            if (known == null || live > known) device[key] = live;
          });
        }
      }
      final incompleteStored = prefs.getStringList(_incompleteKey(deviceId));
      if (incompleteStored != null) {
        _incompleteFor(deviceId).addAll(incompleteStored);
      }
    } catch (_) {
      // Tests and a missing plugin still keep the in-memory map for this process.
    }
  }

  /// Records that [seconds] of [fileId] arrived live. Never shrinks: a
  /// reconnect that restarts the measurement must not erase what was already
  /// captured.
  static Future<void> remember(
    String deviceId,
    String fileId,
    int liveSeconds,
  ) async {
    if (fileId.isEmpty) return;
    final device = _forDevice(deviceId);
    final known = device[fileId];
    if (known != null && known >= liveSeconds) return;
    device[fileId] = liveSeconds;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(deviceId), jsonEncode(device));
    } catch (_) {}
  }

  /// The live stream died before stop, so the device still holds audio this
  /// phone never received. A later drain must transfer that file even if the
  /// missing tail is only a few seconds (within [toleranceSeconds]).
  static Future<void> markIncomplete(String deviceId, String fileId) async {
    if (fileId.isEmpty) return;
    final files = _incompleteFor(deviceId);
    if (!files.add(fileId)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _incompleteKey(deviceId),
        files.toList(growable: false),
      );
    } catch (_) {}
  }
}
