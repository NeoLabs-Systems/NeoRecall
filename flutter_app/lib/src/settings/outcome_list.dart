import 'package:flutter/material.dart';

import '../../main_theme.dart';

/// What an irreversible action erases and what it keeps, named rather than
/// summarised: "all your data" is easy to agree to without picturing what it
/// contains. Shown inside the confirmation dialog.
class OutcomeList extends StatelessWidget {
  const OutcomeList({
    super.key,
    required this.erased,
    this.kept = const <String>[],
  });

  final List<String> erased;
  final List<String> kept;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    Widget row(String item, bool removed) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              removed ? Icons.close_rounded : Icons.check_rounded,
              size: 16,
              color: removed ? palette.danger : palette.success,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item,
              style: TextStyle(
                color: removed ? palette.textPrimary : palette.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final item in erased) row(item, true),
        if (kept.isNotEmpty) const SizedBox(height: 6),
        for (final item in kept) row(item, false),
      ],
    );
  }
}
