import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../main_spacing.dart';
import '../../../../main_theme.dart';
import '../../../record/record_controls.dart';
import '../appliance_controller.dart';
import '../appliance_link.dart';
import '../appliance_protocol.dart';
import 'appliance_sheet.dart';

typedef ApplianceDevice = Map<String, dynamic>;

/// The operational entry point for NeoRecall Desk on the Record screen.
///
/// A Desk is not a live Bluetooth input for the phone: it records, stores, and
/// uploads independently. Keeping it beside (but visually separate from) the
/// app's capture-source picker makes that distinction clear without inventing a
/// second top-level device area.
class ApplianceCaptureSection extends StatelessWidget {
  const ApplianceCaptureSection({
    super.key,
    required this.controller,
    required this.devices,
    required this.onAdd,
  });

  final ApplianceController controller;
  final List<ApplianceDevice> devices;
  final Future<void> Function() onAdd;

  @override
  Widget build(BuildContext context) {
    final desks = visibleAppliances(devices, controller);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (desks.isEmpty)
          _DeskIntroduction(onAdd: onAdd)
        else ...<Widget>[
          for (var index = 0; index < desks.length; index += 1) ...<Widget>[
            if (index > 0) const SizedBox(height: AppSpacing.sm),
            ApplianceDeviceTile(
              controller: controller,
              device: desks[index],
              onTap: () =>
                  openApplianceDevice(context, controller, desks[index]),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey<String>('add-neorecall-desk'),
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add another'),
            ),
          ),
        ],
      ],
    );
  }
}

class _DeskIntroduction extends StatelessWidget {
  const _DeskIntroduction({required this.onAdd});

  final Future<void> Function() onAdd;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Material(
      color: palette.bgSecondary.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        key: const ValueKey<String>('neorecall-desk-introduction'),
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onAdd,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: palette.accentMuted,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.speaker_group_outlined,
                  color: palette.accentHover,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Set up a Desk recorder',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Connect it to your account and Wi-Fi from here. No server address or access key to copy.',
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(Icons.chevron_right_rounded, color: palette.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// One reusable Desk row, shared by Record and account device management.
/// Live Bluetooth status wins while the app is nearby; otherwise server state
/// keeps an active recording visible from anywhere.
class ApplianceDeviceTile extends StatefulWidget {
  const ApplianceDeviceTile({
    super.key,
    required this.controller,
    required this.device,
    required this.onTap,
  });

  final ApplianceController controller;
  final ApplianceDevice device;
  final VoidCallback onTap;

  @override
  State<ApplianceDeviceTile> createState() => _ApplianceDeviceTileState();
}

class _ApplianceDeviceTileState extends State<ApplianceDeviceTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant ApplianceDeviceTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    _syncPulse();
  }

  void _changed() {
    if (!mounted) return;
    _syncPulse();
    setState(() {});
  }

  void _syncPulse() {
    final recording = applianceIsRecording(widget.device, widget.controller);
    if (recording && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!recording && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final recording = applianceIsRecording(widget.device, widget.controller);
    final name = widget.device['name'];
    final displayName = name is String && name.trim().isNotEmpty
        ? name
        : 'NeoRecall Desk';
    final radius = BorderRadius.circular(AppRadius.card);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey<String>(
          'appliance-${widget.device['id'] ?? displayName}',
        ),
        borderRadius: radius,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            color: palette.bgSecondary.withValues(alpha: 0.52),
            borderRadius: radius,
            border: Border.all(
              color: recording
                  ? palette.secondary.withValues(alpha: 0.45)
                  : palette.border,
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.speaker_group_outlined,
                color: recording ? palette.secondary : palette.accent,
              ),
              const SizedBox(width: 12),
              _statusDot(palette, recording),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      displayName,
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
                      applianceSummary(widget.device, widget.controller),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: recording
                            ? palette.secondary
                            : palette.textMuted,
                        fontSize: 11.5,
                        fontWeight: recording
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Open',
                style: TextStyle(
                  color: palette.accentHover,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: palette.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusDot(NeoRecallPalette palette, bool recording) {
    if (!recording) {
      return StatusDot(
        color: applianceIsReachable(widget.device, widget.controller)
            ? palette.success
            : palette.textMuted,
      );
    }
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => Opacity(
        opacity:
            0.45 + 0.55 * (0.5 - 0.5 * math.cos(_pulse.value * 2 * math.pi)),
        child: child,
      ),
      child: StatusDot(color: palette.secondary, size: 9),
    );
  }
}

List<ApplianceDevice> visibleAppliances(
  List<ApplianceDevice> devices,
  ApplianceController controller,
) {
  final active = devices
      .where(
        (device) =>
            device['kind'] == 'appliance' && device['revoked_at'] == null,
      )
      .toList(growable: true);
  final liveId = controller.boundDeviceId;
  if (liveId != null &&
      !devices.any((device) => device['id'] == liveId) &&
      !(controller.status?.deviceRevoked ?? false)) {
    active.add(<String, dynamic>{
      'id': liveId,
      'name': 'NeoRecall Desk',
      'kind': 'appliance',
      'revoked_at': null,
    });
  }
  return active;
}

ApplianceStatus? applianceLiveStatus(
  ApplianceDevice device,
  ApplianceController controller,
) {
  if (!controller.isConnected) return null;
  final id = device['id'];
  return id is String && controller.isBoundTo(id) ? controller.status : null;
}

bool applianceIsRecording(
  ApplianceDevice device,
  ApplianceController controller,
) {
  final status = applianceLiveStatus(device, controller);
  if (status != null) return status.isRecording;
  return device['active_session_id'] != null;
}

bool applianceIsReachable(
  ApplianceDevice device,
  ApplianceController controller,
) =>
    applianceLiveStatus(device, controller) != null ||
    device['active_session_id'] != null;

String applianceSummary(
  ApplianceDevice device,
  ApplianceController controller,
) {
  final status = applianceLiveStatus(device, controller);
  if (status != null) return status.summary;

  final startedAt = device['active_session_started_at'];
  if (startedAt is String) {
    final started = DateTime.tryParse(startedAt);
    if (started != null) {
      final elapsed = DateTime.now().toUtc().difference(started.toUtc());
      if (!elapsed.isNegative) return 'Recording · ${formatElapsed(elapsed)}';
    }
    return 'Recording';
  }

  final heartbeat = device['last_heartbeat_at'];
  if (heartbeat is! String) return 'Not seen yet';
  final seen = DateTime.tryParse(heartbeat);
  if (seen == null) return 'Not seen yet';
  final ago = DateTime.now().toUtc().difference(seen.toUtc());
  if (ago.inMinutes < 10) return 'Ready';
  if (ago.inHours < 1) return 'Last seen ${ago.inMinutes} minutes ago';
  if (ago.inDays < 1) {
    return 'Last seen ${ago.inHours} ${ago.inHours == 1 ? "hour" : "hours"} ago';
  }
  return 'Last seen ${ago.inDays} ${ago.inDays == 1 ? "day" : "days"} ago';
}

Future<void> openApplianceDevice(
  BuildContext context,
  ApplianceController controller,
  ApplianceDevice device,
) async {
  final id = device['id'];
  if (!controller.isConnected || (id is String && !controller.isBoundTo(id))) {
    unawaited(_reconnect(controller, id is String ? id : null));
  }
  final name = device['name'];
  await showApplianceSheet(
    context,
    controller,
    deviceName: name is String && name.trim().isNotEmpty
        ? name
        : 'NeoRecall Desk',
  );
}

Future<void> _reconnect(
  ApplianceController controller,
  String? expectedDeviceId,
) async {
  // Try the device we already know before looking for one. A scan takes seconds
  // and is only needed to *find* an address; this one is remembered, so opening
  // a Desk that is switched on and in range no longer waits for a search whose
  // answer is already on disk.
  await controller.reconnectToRemembered();
  if (controller.isConnected &&
      (expectedDeviceId == null || controller.isBoundTo(expectedDeviceId))) {
    return;
  }

  await controller.scanForAppliances(timeout: const Duration(seconds: 6));
  final candidates = List<ApplianceCandidate>.of(controller.candidates);
  for (final candidate in candidates) {
    final connected = await controller.connectTo(candidate);
    if (!connected) continue;
    if (expectedDeviceId == null || controller.isBoundTo(expectedDeviceId)) {
      return;
    }
    await controller.disconnect();
  }
}
