import 'package:flutter/widgets.dart';

/// Loads one detail payload when a sheet opens and exposes its list fields.
///
/// The memory and mini-memory sheets each carried an identical copy: the same
/// three fields, the same `initState` fetch, the same success/failure
/// `setState`, and the same defensive list readers for a payload that is
/// untyped JSON.
mixin DetailSheetMixin<T extends StatefulWidget> on State<T> {
  Map<String, dynamic>? _detail;
  Object? _error;
  bool _loading = true;

  Map<String, dynamic>? get detail => _detail;
  Object? get loadError => _error;
  bool get loading => _loading;

  /// Fetches the payload this sheet displays.
  Future<Map<String, dynamic>> fetchDetail();

  @override
  void initState() {
    super.initState();
    loadDetail();
  }

  Future<void> loadDetail() async {
    try {
      final loaded = await fetchDetail();
      if (!mounted) return;
      setState(() {
        _detail = loaded;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  /// Reads a list of objects from the payload, tolerating a missing or
  /// wrongly-typed field rather than throwing inside `build`.
  List<Map<String, dynamic>> listField(String key, {String? fallbackKey}) {
    final raw =
        _detail?[key] ?? (fallbackKey == null ? null : _detail?[fallbackKey]);
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  /// Transcript-backed rows only: entries whose `text` is blank carry no
  /// evidence and would render as empty lines.
  List<Map<String, dynamic>> get sources => listField('sources')
      .where((row) => (row['text'] as String?)?.trim().isNotEmpty == true)
      .toList();

  List<Map<String, dynamic>> get miniMemories =>
      listField('miniMemories', fallbackKey: 'mini_memories');

  List<Map<String, dynamic>> get entities => listField('entities');
}
