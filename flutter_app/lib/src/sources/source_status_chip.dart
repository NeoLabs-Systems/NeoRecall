import 'package:flutter/material.dart';

import '../../l10n/gen/app_l10n.dart';

class SourceStatusChip extends StatelessWidget {
  const SourceStatusChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  // The label is resolved by the caller rather than stored: these factories are
  // the only place the four status words appear, and they need the translations
  // the caller's context carries.
  factory SourceStatusChip.connected(AppL10n l10n) => SourceStatusChip(
    label: l10n.sourceStatusConnected,
    color: Colors.green.shade600,
  );

  factory SourceStatusChip.error(AppL10n l10n) =>
      SourceStatusChip(label: l10n.sourceStatusError, color: Colors.red);

  factory SourceStatusChip.unavailable(AppL10n l10n) => SourceStatusChip(
    label: l10n.sourceStatusNotConfigured,
    color: Colors.grey.shade600,
  );

  factory SourceStatusChip.disabled(AppL10n l10n) => SourceStatusChip(
    label: l10n.sourceStatusPaused,
    color: Colors.orange.shade700,
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
