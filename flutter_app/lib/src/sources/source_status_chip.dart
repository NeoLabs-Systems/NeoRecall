import 'package:flutter/material.dart';

class SourceStatusChip extends StatelessWidget {
  const SourceStatusChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  factory SourceStatusChip.connected() =>
      SourceStatusChip(label: 'Connected', color: Colors.green.shade600);

  factory SourceStatusChip.error() =>
      const SourceStatusChip(label: 'Error', color: Colors.red);

  factory SourceStatusChip.unavailable() =>
      SourceStatusChip(label: 'Not configured', color: Colors.grey.shade600);

  factory SourceStatusChip.disabled() =>
      SourceStatusChip(label: 'Paused', color: Colors.orange.shade700);

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
