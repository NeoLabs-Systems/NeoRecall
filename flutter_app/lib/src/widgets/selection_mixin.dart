import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Multi-select for a list screen: which rows are picked, and whether the
/// screen is in selection mode at all.
///
/// The memories and speakers screens each carried an identical copy of this,
/// down to the haptic on entering the mode and dropping out of it when the last
/// row is deselected.
mixin SelectionMixin<T extends StatefulWidget> on State<T> {
  final Set<String> _selected = <String>{};
  bool _selecting = false;

  bool get selecting => _selecting;
  Set<String> get selected => Set<String>.unmodifiable(_selected);
  int get selectedCount => _selected.length;
  List<String> get selectedIds => _selected.toList();
  bool isSelected(String id) => _selected.contains(id);

  /// Adds or removes one row, leaving selection mode when the last one goes.
  void toggleSelect(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  /// Enters selection mode, optionally with the row that triggered it.
  void enterSelect([String? id]) {
    HapticFeedback.selectionClick();
    setState(() {
      _selecting = true;
      if (id != null) _selected.add(id);
    });
  }

  void exitSelect() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  /// Runs a bulk action over the current selection and reports the outcome.
  ///
  /// Every caller had written the same shape by hand: bail on an empty
  /// selection, leave selection mode on success, and show either [success] or
  /// the error against a still-mounted context.
  Future<void> runBulkAction(
    Future<void> Function(List<String> ids) action, {
    required String Function(List<String> ids) success,
    required String Function(Object error) failure,
  }) async {
    final ids = selectedIds;
    if (ids.isEmpty) return;
    try {
      await action(ids);
      if (!mounted) return;
      exitSelect();
      _show(success(ids));
    } catch (error) {
      if (!mounted) return;
      _show(failure(error));
    }
  }

  void _show(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
