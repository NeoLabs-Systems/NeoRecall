import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ClientDiagnosticLog {
  ClientDiagnosticLog._();

  static final ClientDiagnosticLog instance = ClientDiagnosticLog._();
  // Deep enough to hold a full connect → sync → import → transcription session
  // across several devices, so a report captures the whole failing flow.
  static const int _maximumEntries = 800;
  static const int _maximumTextLength = 500;

  final List<Map<String, Object?>> _entries = <Map<String, Object?>>[];
  Future<void> _writeChain = Future<void>.value();
  SharedPreferences? _preferences;
  String? _accountId;

  String? get _storageKey =>
      _accountId == null ? null : 'diagnostic_events_v1:$_accountId';

  Future<void> bindAccount(String? accountId) async {
    await _writeChain;
    _preferences ??= await SharedPreferences.getInstance();
    _accountId = accountId;
    _entries.clear();
    final key = _storageKey;
    if (key == null) return;
    final stored = _preferences!.getString(key);
    if (stored == null) return;
    try {
      final decoded = jsonDecode(stored) as List;
      _entries.addAll(
        decoded
            .whereType<Map>()
            .map((entry) => Map<String, Object?>.from(entry))
            .take(_maximumEntries),
      );
    } catch (_) {
      await _preferences!.remove(key);
    }
  }

  void record(
    String component,
    String event, {
    String level = 'info',
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    _entries.add(<String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': level,
      'component': _safeText(component),
      'event': _safeText(event),
      if (details.isNotEmpty) 'details': _sanitizeMap(details),
    });
    if (_entries.length > _maximumEntries) {
      _entries.removeRange(0, _entries.length - _maximumEntries);
    }
    final key = _storageKey;
    if (key != null) {
      final encoded = jsonEncode(_entries);
      _writeChain = _writeChain
          .then((_) => _persist(key, encoded))
          .catchError((_) {});
      unawaited(_writeChain);
    }
  }

  List<Map<String, Object?>> snapshot() => _entries
      .map((entry) => Map<String, Object?>.from(entry))
      .toList(growable: false);

  /// The most recent [count] entries, newest last — for an in-app viewer.
  List<Map<String, Object?>> recent([int count = 60]) {
    final start = _entries.length <= count ? 0 : _entries.length - count;
    return _entries
        .sublist(start)
        .map((entry) => Map<String, Object?>.from(entry))
        .toList(growable: false);
  }

  int get length => _entries.length;

  /// One readable line per event (`HH:mm:ss LEVEL component/event {details}`),
  /// for both the in-app viewer and the copied report.
  String formatLine(Map<String, Object?> entry) {
    final ts = (entry['timestamp'] as String?) ?? '';
    final time = ts.length >= 19 ? ts.substring(11, 19) : ts;
    final level = (entry['level'] as String? ?? 'info').toUpperCase();
    final component = entry['component'] ?? '?';
    final event = entry['event'] ?? '?';
    final details = entry['details'];
    final tail = details == null ? '' : ' ${jsonEncode(details)}';
    return '$time $level $component/$event$tail';
  }

  String asText() => _entries.map(formatLine).join('\n');

  Future<void> clear() async {
    await _writeChain;
    _entries.clear();
    final key = _storageKey;
    if (key != null) await _preferences?.remove(key);
  }

  Future<void> _persist(String key, String encoded) async {
    _preferences ??= await SharedPreferences.getInstance();
    await _preferences!.setString(key, encoded);
  }

  Map<String, Object?> _sanitizeMap(Map<String, Object?> value) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key: _sanitizeValue(entry.key, entry.value),
    };
  }

  Object? _sanitizeValue(String key, Object? value) {
    if (RegExp(
      r'token|password|secret|authorization|cookie|api.?key|audio|transcript|content|body',
      caseSensitive: false,
    ).hasMatch(key)) {
      return '[redacted]';
    }
    if (value == null || value is bool || value is num) return value;
    if (value is String) return _safeText(value);
    if (value is Iterable) {
      return value
          .take(50)
          .map((item) => _sanitizeValue(key, item))
          .toList(growable: false);
    }
    if (value is Map) {
      return _sanitizeMap(
        value.map((key, value) => MapEntry('$key', value)),
      );
    }
    return _safeText(value.toString());
  }

  String _safeText(String value) {
    final normalized = value.replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/\-=]+', caseSensitive: false),
      'Bearer [redacted]',
    );
    return normalized.length <= _maximumTextLength
        ? normalized
        : '${normalized.substring(0, _maximumTextLength)}…';
  }

  Map<String, Object?> clientSummary() => <String, Object?>{
    'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'events': snapshot(),
  };
}
