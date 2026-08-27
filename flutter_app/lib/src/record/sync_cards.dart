import 'dart:async';

import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import 'record_controls.dart';

class ImportCard extends StatelessWidget {
  const ImportCard({super.key, required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final leading = Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: palette.accentMuted,
        borderRadius: BorderRadius.circular(AppRadius.input),
        border: Border.all(color: palette.borderLight),
      ),
      child: Icon(
        Icons.upload_file_outlined,
        size: 20,
        color: palette.accentHover,
      ),
    );
    final button = OutlinedButton.icon(
      onPressed: onPressed,
      icon: busy
          ? const ButtonSpinner()
          : const Icon(Icons.folder_open_outlined, size: 18),
      label: const Text('Choose audio'),
    );
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'Import existing audio',
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'WAV, MP3, M4A, and other ffmpeg-supported formats use the same private transcription pipeline.',
          style: TextStyle(color: palette.textSecondary, height: 1.4),
        ),
      ],
    );

    return GlassSurface(
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth < 520
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      leading,
                      const SizedBox(width: AppSpacing.md - 2),
                      Expanded(child: copy),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  button,
                ],
              )
            : Row(
                children: <Widget>[
                  leading,
                  const SizedBox(width: AppSpacing.md - 2),
                  Expanded(child: copy),
                  const SizedBox(width: AppSpacing.md),
                  button,
                ],
              ),
      ),
    );
  }
}

class OfflineDeviceSyncCard extends StatefulWidget {
  const OfflineDeviceSyncCard({super.key, required this.controller});
  final NeoRecallController controller;
  @override
  State<OfflineDeviceSyncCard> createState() => _OfflineDeviceSyncCardState();
}

class _OfflineDeviceSyncCardState extends State<OfflineDeviceSyncCard> {
  bool _syncing = false;

  Future<void> _sync() async {
    setState(() => _syncing = true);
    try {
      await widget.controller.syncDeviceStorage(userInitiated: true);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final controller = widget.controller;
    final available = controller.deviceStorageSyncAvailable;
    final busy = _syncing || controller.deviceStorageSyncing;
    final label = controller.preferredDeviceLabel ?? 'This device';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: palette.accent.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.download_for_offline_outlined, color: palette.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$label records on its own',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Press record and stop on the device itself. When it is connected, '
            'your recordings sync here automatically — or pull them now.',
            style: TextStyle(color: palette.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 12),
          DeviceSyncStatusView(controller: controller),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: palette.accent),
              onPressed: !available || busy ? null : _sync,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.sync_rounded),
              label: Text(
                busy
                    ? 'Syncing…'
                    : available
                    ? 'Sync device recordings'
                    : 'Connect the device to sync',
              ),
            ),
          ),
          if (controller.deviceStorageSyncError != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.error_outline_rounded,
                  size: 16,
                  color: palette.danger,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    controller.deviceStorageSyncError!,
                    style: TextStyle(
                      color: palette.danger,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Shows what a wearable sync is actually doing: how far the current transfer
/// has got and how much audio is still held on the device.
///
/// A full ring can take minutes to pull, and an indeterminate spinner over that
/// span is indistinguishable from a hang — which is exactly how a stalled sync
/// used to present. Both numbers come from the device itself (the transfer's
/// announced packet count, and the ring's unread count), so they are real rather
/// than estimated from elapsed time.
class DeviceSyncStatusView extends StatelessWidget {
  const DeviceSyncStatusView({super.key, required this.controller});

  final NeoRecallController controller;

  static String formatDuration(int seconds) {
    if (seconds <= 0) return 'nothing';
    if (seconds < 60) return '${seconds}s of audio';
    final minutes = (seconds / 60).round();
    if (minutes < 60) return '$minutes min of audio';
    final hours = seconds / 3600;
    return '${hours.toStringAsFixed(hours < 10 ? 1 : 0)} h of audio';
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final progress = controller.deviceStorageSyncProgress;
    final pendingSeconds = controller.deviceStoragePendingSeconds;
    final syncing = controller.deviceStorageSyncing;

    // Nothing known and nothing running: stay out of the way entirely.
    if (!syncing &&
        pendingSeconds <= 0 &&
        controller.deviceStorageSyncedCount == 0) {
      return const SizedBox.shrink();
    }

    final fraction = progress?.fraction;
    final String headline;
    if (syncing && fraction != null) {
      headline =
          'Transferring ${(fraction * 100).round()}% · '
          '${formatDuration(progress!.pendingSeconds)} left';
    } else if (syncing) {
      headline = 'Transferring from the device…';
    } else if (pendingSeconds > 0) {
      headline = '${formatDuration(pendingSeconds)} waiting on the device';
    } else {
      headline = '${controller.deviceStorageSyncedCount} recording(s) synced';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(
              syncing
                  ? Icons.sync_rounded
                  : pendingSeconds > 0
                  ? Icons.schedule_rounded
                  : Icons.check_circle_outline_rounded,
              size: 16,
              color: palette.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                headline,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (syncing) ...<Widget>[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            // A determinate bar once the device has announced the transfer size;
            // indeterminate only for the brief moment before that arrives.
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 5,
              backgroundColor: palette.surfaceMuted,
              color: palette.accent,
            ),
          ),
          if (controller.deviceStorageSyncedCount > 0) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '${controller.deviceStorageSyncedCount} recording(s) imported so far',
              style: TextStyle(color: palette.textMuted, fontSize: 12),
            ),
          ],
        ],
      ],
    );
  }
}
