import 'package:flutter/material.dart';

import '../../main_spacing.dart';
import '../../main_theme.dart';

/// One connected-device row, shared by the appliance sheet and anything else
/// that lists hardware. The capture-source picker that used to live here moved
/// into the record sheets when sources stopped being laid out on the page.

class DeviceRow extends StatelessWidget {
  const DeviceRow({
    super.key,
    required this.name,
    required this.detail,
    required this.connected,
    required this.actionLabel,
    required this.onAction,
    this.batteryLevel,
    this.connectedActionLabel,
  });

  final String name;
  final String detail;
  final bool connected;
  final String actionLabel;
  final VoidCallback? onAction;

  /// Action offered while the device is already connected, e.g. "Disconnect".
  ///
  /// Wearables only ever need connecting, so the default stays a plain
  /// confirmation tick. A device the user actively switches between — the
  /// appliance's headphones — needs a way back out, and that is what this adds
  /// without giving every other caller a button it has no use for.
  final String? connectedActionLabel;
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
          if (connected && connectedActionLabel == null)
            Icon(Icons.check_circle, size: 18, color: palette.success)
          else
            TextButton(
              onPressed: onAction,
              child: Text(connected ? connectedActionLabel! : actionLabel),
            ),
        ],
      ),
    );
  }
}

class BatteryIndicator extends StatelessWidget {
  const BatteryIndicator({
    super.key,
    required this.level,
    required this.palette,
  });

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
