import 'package:flutter/material.dart';

import '../../main_spacing.dart';
import '../../main_theme.dart';

/// Capture sources as tappable cards rather than bare chips: each one carries a
/// line saying what it actually records, which is the part people get wrong when
/// choosing between a microphone, system audio, and a wearable.
class SourceGroup extends StatelessWidget {
  const SourceGroup({
    super.key,required this.options});

  final List<SourceOption> options;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 520) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var index = 0; index < options.length; index += 1) ...<Widget>[
              if (index > 0) const SizedBox(height: AppSpacing.sm),
              options[index],
            ],
          ],
        );
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var index = 0; index < options.length; index += 1) ...<Widget>[
              if (index > 0) const SizedBox(width: AppSpacing.sm),
              Expanded(child: options[index]),
            ],
          ],
        ),
      );
    },
  );
}

class SourceOption extends StatelessWidget {
  const SourceOption({
    super.key,
    required this.icon,
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String description;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final tint = palette.accentHover;
    return Opacity(
      opacity: onTap == null ? 0.55 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.fromLTRB(13, 12, 13, 13),
            decoration: BoxDecoration(
              color: selected
                  ? palette.accentMuted
                  : palette.bgSecondary.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(
                color: selected
                    ? palette.accent.withValues(alpha: 0.55)
                    : palette.border,
                width: selected ? 1.4 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      icon,
                      size: 19,
                      color: selected ? tint : palette.textSecondary,
                    ),
                    const Spacer(),
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 16,
                      color: selected ? tint : palette.border,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected
                        ? palette.textPrimary
                        : palette.textSecondary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 11.5,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DeviceRow extends StatelessWidget {
  const DeviceRow({
    super.key,
    required this.name,
    required this.detail,
    required this.connected,
    required this.actionLabel,
    required this.onAction,
    this.batteryLevel,
  });

  final String name;
  final String detail;
  final bool connected;
  final String actionLabel;
  final VoidCallback? onAction;
  // Latest battery percentage for this device, if the connected wearable has
  // reported one yet.
  final int? batteryLevel;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.xs + 2),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: palette.bgSecondary.withValues(alpha: connected ? 0.7 : 0.4),
        borderRadius: BorderRadius.circular(AppRadius.input),
        border: Border.all(
          color: connected
              ? palette.success.withValues(alpha: 0.4)
              : palette.border,
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            connected ? Icons.bluetooth_connected : Icons.bluetooth,
            size: 18,
            color: connected ? palette.success : palette.textSecondary,
          ),
          const SizedBox(width: AppSpacing.sm + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.textMuted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (batteryLevel != null) ...<Widget>[
            BatteryIndicator(level: batteryLevel!, palette: palette),
            const SizedBox(width: AppSpacing.sm),
          ],
          if (connected)
            Icon(Icons.check_circle, size: 18, color: palette.success)
          else
            TextButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }
}

class BatteryIndicator extends StatelessWidget {
  const BatteryIndicator({
    super.key,required this.level, required this.palette});

  final int level;
  final NeoRecallPalette palette;

  IconData get _icon {
    if (level <= 15) return Icons.battery_alert_rounded;
    if (level <= 35) return Icons.battery_2_bar_rounded;
    if (level <= 65) return Icons.battery_4_bar_rounded;
    if (level <= 90) return Icons.battery_5_bar_rounded;
    return Icons.battery_full_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final color = level <= 15 ? palette.warning : palette.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(_icon, size: 16, color: color),
        const SizedBox(width: 2),
        Text(
          '$level%',
          style: TextStyle(
            color: color,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
