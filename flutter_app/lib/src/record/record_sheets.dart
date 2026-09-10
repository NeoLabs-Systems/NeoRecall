import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../capture/capture_defaults.dart';
import '../../main_device_diagnostics.dart';
import '../../main_shared.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import '../devices/appliance/ui/appliance_capture_section.dart';
import '../devices/audio_device_adapter.dart';
import 'record_controls.dart';
import 'sync_cards.dart';
import '../../l10n/gen/app_l10n.dart';

/// Everything the two sheets need from the Record screen.
///
/// The screen owns the capture-source state machine; the sheets only read it
/// and report back what the reader chose. Passing one object keeps the two
/// call sites from drifting into different argument lists.
class RecordSheetActions {
  const RecordSheetActions({
    required this.controller,
    required this.isMobile,
    required this.isDesktop,
    required this.onSelectSource,
    required this.onPhoneInputsChanged,
    required this.onImport,
    required this.onScan,
    required this.onSyncDeviceStorage,
    required this.onAddDesk,
    required this.onConnectDevice,
    required this.selectedDeskId,
    required this.onSelectDesk,
  });

  final NeoRecallController controller;
  final bool isMobile;
  final bool isDesktop;

  final void Function(CaptureSource source) onSelectSource;
  final void Function({required bool microphone, required bool systemAudio})
  onPhoneInputsChanged;
  final Future<void> Function() onImport;
  final Future<void> Function() onScan;
  final Future<void> Function() onSyncDeviceStorage;
  final Future<void> Function() onAddDesk;
  final Future<void> Function(AudioDeviceDescriptor device) onConnectDevice;

  /// Which Desk the Record screen is pointed at, so the sheet can mark it.
  final String? selectedDeskId;
  final void Function(ApplianceDevice desk) onSelectDesk;
}

/// A Desk's name, falling back to the product name when the device has none.
String applianceName(ApplianceDevice desk) {
  final name = desk['name'];
  return name is String && name.trim().isNotEmpty ? name : 'NeoRecall Desk';
}

/// The chip in the Record header that stands for the device you record with.
///
/// Charge is drawn as an arc around the glyph rather than written out twice,
/// and the live dot is the only thing that claims a connection — a remembered
/// device that is not linked right now must not read as connected.
///
/// A Desk counts as a device here. Reading only the preferred *wearable* told
/// somebody who owns a Desk and nothing else that they had no device at all.
class DeviceChip extends StatelessWidget {
  /// A stable handle for the header's device affordance. Both the chip and the
  /// source line under the record button name the device, so callers that mean
  /// "the chip" have to be able to say so.
  static const ValueKey<String> chipKey = ValueKey<String>(
    'record-device-chip',
  );

  const DeviceChip({
    super.key,
    required this.controller,
    required this.onTap,
    required this.preferDesk,
    this.onLongPress,
  });

  final NeoRecallController controller;
  final VoidCallback onTap;

  /// True when the Desk is the chosen source, so the chip stands for the Desk
  /// even if a wearable is also paired.
  final bool preferDesk;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final desks = visibleAppliances(controller.devices, controller.appliance);
    final wearable = controller.preferredDeviceLabel;
    final showDesk = desks.isNotEmpty && (preferDesk || wearable == null);

    final String? label;
    final bool connected;
    final int? battery;
    if (showDesk) {
      final name = desks.first['name'];
      label = name is String && name.trim().isNotEmpty
          ? name
          : 'NeoRecall Desk';
      connected = controller.appliance.status != null;
      battery = null;
    } else {
      label = wearable;
      connected = label != null && controller.deviceConnected;
      battery = connected ? controller.preferredDeviceBatteryLevel : null;
    }

    final Widget body;
    if (label == null) {
      body = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.add_rounded, size: 17, color: palette.textSecondary),
          const SizedBox(width: 7),
          Text(
            AppL10n.of(context).deviceAddDevice,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    } else {
      body = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _DeviceGlyph(
            charge: battery == null ? null : battery / 100,
            connected: connected,
            icon: showDesk
                ? Icons.speaker_group_outlined
                : Icons.mic_none_rounded,
          ),
          const SizedBox(width: 9),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                battery != null
                    ? '$battery%'
                    : connected
                    ? AppL10n.of(context).deviceConnected
                    : AppL10n.of(context).deviceNotConnected,
                style: monoMetricStyle(palette, size: 10),
              ),
            ],
          ),
        ],
      );
    }

    return Semantics(
      button: true,
      label: label == null
          ? AppL10n.of(context).deviceAddDeviceSemantics
          : AppL10n.of(context).deviceManageSemantics(label),
      child: Material(
        key: chipKey,
        color: palette.bgTertiary,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 7, 12, 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(color: palette.borderLight),
            ),
            child: body,
          ),
        ),
      ),
    );
  }
}

/// The device mark: a microphone inside a ring that carries its charge.
class _DeviceGlyph extends StatelessWidget {
  const _DeviceGlyph({
    required this.charge,
    required this.connected,
    this.size = 26,
    this.icon = Icons.mic_none_rounded,
  });

  final double? charge;
  final bool connected;
  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: CustomPaint(
              painter: _ChargeRingPainter(
                charge: charge,
                track: palette.borderLight,
                fill: connected ? palette.accentAlt : palette.textMuted,
                stroke: size < 40 ? 1.5 : 2.5,
              ),
            ),
          ),
          Center(
            child: Icon(icon, size: size * 0.5, color: palette.textPrimary),
          ),
          if (connected)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: palette.bgTertiary,
                  shape: BoxShape.circle,
                ),
                child: StatusDot(color: palette.success, size: 7),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChargeRingPainter extends CustomPainter {
  const _ChargeRingPainter({
    required this.charge,
    required this.track,
    required this.fill,
    required this.stroke,
  });

  final double? charge;
  final Color track;
  final Color fill;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = (size.shortestSide - stroke) / 2;
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawCircle(center, radius, base);
    final value = charge;
    if (value == null || value <= 0) return;
    final sweep = 2 * 3.1415926535 * value.clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -3.1415926535 / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = fill,
    );
  }

  @override
  bool shouldRepaint(_ChargeRingPainter old) =>
      old.charge != charge || old.fill != fill || old.track != track;
}

/// Opens the device sheet: everything about the wearable in one place.
///
/// This replaces the status line, the battery pill, the offline-sync card and
/// the undiscoverable long-press diagnostics that were spread across the
/// Record page.
Future<void> showDeviceSheet(
  BuildContext context,
  RecordSheetActions actions,
) => showAppSheet<void>(
  context,
  builder: (context) => _DeviceSheet(actions: actions),
);

class _DeviceSheet extends StatelessWidget {
  const _DeviceSheet({required this.actions});

  final RecordSheetActions actions;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return AnimatedBuilder(
      animation: actions.controller,
      builder: (context, _) {
        final controller = actions.controller;
        final label = controller.preferredDeviceLabel;
        final connected = label != null && controller.deviceConnected;
        final battery = connected
            ? controller.preferredDeviceBatteryLevel
            : null;
        final desks = visibleAppliances(
          controller.devices,
          controller.appliance,
        );

        if (label == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                AppL10n.of(context).deviceNoneTitle,
                style: heroTitleStyle(palette, size: 18),
              ),
              const SizedBox(height: 6),
              Text(
                AppL10n.of(context).deviceNoneBody,
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: AppSpacing.md + 2),
              FilledButton.icon(
                onPressed: controller.scanningWearables
                    ? null
                    : () => unawaited(actions.onScan()),
                icon: controller.scanningWearables
                    ? const ButtonSpinner()
                    : const Icon(Icons.bluetooth_searching_rounded, size: 18),
                label: Text(
                  controller.scanningWearables
                      ? AppL10n.of(context).deviceScanning
                      : AppL10n.of(context).deviceScanForWearables,
                ),
              ),
              _WearableDiscoveries(
                controller: controller,
                onConnect: actions.onConnectDevice,
              ),
              const SizedBox(height: AppSpacing.xs),
              HairlineRow(
                showDivider: false,
                minHeight: 48,
                leading: Icon(
                  Icons.speaker_group_outlined,
                  size: 18,
                  color: palette.textMuted,
                ),
                title: AppL10n.of(context).deviceSetUpDesk,
                trailing: const RowChevron(),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(actions.onAddDesk());
                },
              ),
            ],
          );
        }

        final progress = controller.deviceStorageSyncProgress;
        final stranded = controller.appliance.hasStrandedRecordings;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                _DeviceGlyph(
                  charge: battery == null ? null : battery / 100,
                  connected: connected,
                  size: 54,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(label, style: heroTitleStyle(palette, size: 18)),
                      const SizedBox(height: 5),
                      Row(
                        children: <Widget>[
                          StatusDot(
                            color: connected
                                ? palette.success
                                : palette.textMuted,
                          ),
                          const SizedBox(width: 7),
                          Flexible(
                            child: Text(
                              connected
                                  ? AppL10n.of(context).deviceConnected
                                  : AppL10n.of(context).deviceRemembered,
                              style: TextStyle(
                                color: palette.textSecondary,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg - 4),
            Row(
              children: <Widget>[
                Expanded(
                  child: _Stat(
                    label: AppL10n.of(context).deviceStatBattery,
                    value: battery == null ? '—' : '$battery',
                    unit: battery == null ? null : '%',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Stat(
                    label: AppL10n.of(context).deviceStatSynced,
                    value: '${controller.deviceStorageSyncedCount}',
                    unit: AppL10n.of(context).deviceStatSyncedUnit,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Stat(
                    label: AppL10n.of(context).deviceStatLeft,
                    value: progress == null || progress.pendingSeconds <= 0
                        ? '0'
                        : DeviceSyncStatusView.formatDuration(
                            progress.pendingSeconds,
                          ),
                    unit: progress == null || progress.pendingSeconds <= 0
                        ? AppL10n.of(context).deviceStatQueued
                        : null,
                  ),
                ),
              ],
            ),
            // Why there is no live capture, said where the sync action is.
            if (controller.preferredDeviceIsOfflineFirst) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              Text(
                controller.preferredDeviceStreamsLive
                    ? AppL10n.of(context).deviceOfflineFirstStreams
                    : AppL10n.of(context).deviceOfflineFirstOnly,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ],
            if (stranded) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              InlineMessage(
                icon: Icons.cloud_off_rounded,
                message: AppL10n.of(context).deviceStranded,
              ),
            ],
            // What the transfer is actually doing. An indeterminate spinner
            // over a multi-minute ring pull is indistinguishable from a hang.
            if (controller.deviceStorageSyncing ||
                (progress != null && progress.pendingSeconds > 0)) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              DeviceSyncStatusView(controller: controller),
            ],
            if (controller.deviceStorageSyncAvailable) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: controller.deviceStorageSyncing
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        unawaited(actions.onSyncDeviceStorage());
                      },
                icon: controller.deviceStorageSyncing
                    ? const ButtonSpinner()
                    : const Icon(Icons.download_rounded, size: 18),
                label: Text(
                  controller.deviceStorageSyncing
                      ? AppL10n.of(context).deviceMovingRecordings
                      : AppL10n.of(context).deviceMoveRecordings,
                ),
              ),
            ],
            if (controller.deviceStorageSyncError != null) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              InlineMessage(
                error: true,
                message: controller.deviceStorageSyncError!,
              ),
            ],
            const SizedBox(height: AppSpacing.xs),
            HairlineRow(
              showDivider: false,
              minHeight: 48,
              leading: Icon(
                Icons.bluetooth_searching_rounded,
                size: 18,
                color: palette.textMuted,
              ),
              title: controller.scanningWearables
                  ? AppL10n.of(context).deviceScanning
                  : AppL10n.of(context).deviceScanAnother,
              trailing: controller.scanningWearables
                  ? const ButtonSpinner()
                  : const RowChevron(),
              onTap: controller.scanningWearables
                  ? null
                  : () => unawaited(actions.onScan()),
            ),
            _WearableDiscoveries(
              controller: controller,
              onConnect: actions.onConnectDevice,
            ),
            HairlineRow(
              minHeight: 48,
              leading: Icon(
                Icons.troubleshoot_rounded,
                size: 18,
                color: palette.textMuted,
              ),
              title: AppL10n.of(context).deviceDiagnostics,
              trailing: const RowChevron(),
              onTap: () {
                Navigator.of(context).pop();
                showDeviceDiagnosticsSheet(context, controller);
              },
            ),
            HairlineRow(
              minHeight: 48,
              titleColor: palette.danger,
              leading: Icon(
                Icons.link_off_rounded,
                size: 18,
                color: palette.danger,
              ),
              title: AppL10n.of(context).deviceForget,
              onTap: controller.isRecording
                  ? null
                  : () {
                      Navigator.of(context).pop();
                      unawaited(controller.clearPreferredBluetoothDevice());
                    },
            ),
            if (desks.isEmpty)
              HairlineRow(
                minHeight: 48,
                leading: Icon(
                  Icons.speaker_group_outlined,
                  size: 18,
                  color: palette.textMuted,
                ),
                title: AppL10n.of(context).deviceSetUpDesk,
                trailing: const RowChevron(),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(actions.onAddDesk());
                },
              ),
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.unit});

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.bgTertiary,
        borderRadius: BorderRadius.circular(AppRadius.card - 2),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label.toUpperCase(), style: sectionEyebrowStyle(palette)),
          const SizedBox(height: 7),
          RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              text: value,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
              children: <InlineSpan>[
                if (unit != null)
                  TextSpan(
                    text: unit!.length <= 1 ? unit! : ' ${unit!}',
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the source sheet: one radio list, because only one source records at
/// a time. Returns once the reader dismisses it.
Future<void> showSourceSheet(
  BuildContext context, {
  required RecordSheetActions actions,
  required CaptureSource selected,
  required bool microphone,
  required bool systemAudio,
}) => showAppSheet<void>(
  context,
  builder: (context) => _SourceSheet(
    actions: actions,
    initialSelection: selected,
    initialMicrophone: microphone,
    initialSystemAudio: systemAudio,
  ),
);

class _SourceSheet extends StatefulWidget {
  const _SourceSheet({
    required this.actions,
    required this.initialSelection,
    required this.initialMicrophone,
    required this.initialSystemAudio,
  });

  final RecordSheetActions actions;
  final CaptureSource initialSelection;
  final bool initialMicrophone;
  final bool initialSystemAudio;

  @override
  State<_SourceSheet> createState() => _SourceSheetState();
}

class _SourceSheetState extends State<_SourceSheet> {
  late CaptureSource _selected = widget.initialSelection;
  late bool _microphone = widget.initialMicrophone;
  late bool _systemAudio = widget.initialSystemAudio;

  RecordSheetActions get actions => widget.actions;
  NeoRecallController get controller => actions.controller;

  void _select(CaptureSource source) {
    setState(() => _selected = source);
    actions.onSelectSource(source);
  }

  void _setPhoneInputs({bool? microphone, bool? systemAudio}) {
    setState(() {
      _microphone = microphone ?? _microphone;
      _systemAudio = systemAudio ?? _systemAudio;
      if (!_microphone && !_systemAudio) _microphone = true;
    });
    actions.onPhoneInputsChanged(
      microphone: _microphone,
      systemAudio: _systemAudio,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final locked = controller.isRecording;
        final desks = visibleAppliances(
          controller.devices,
          controller.appliance,
        );
        final deviceLabel = controller.preferredDeviceLabel;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              AppL10n.of(context).sourceRecordFrom,
              style: heroTitleStyle(palette, size: 18),
            ),
            const SizedBox(height: 6),
            Text(
              locked
                  ? AppL10n.of(context).sourceLockedWhileRecording
                  : AppL10n.of(context).sourceOneAtATime,
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
            const SizedBox(height: AppSpacing.md + 2),

            _SourceOptionTile(
              icon: Icons.smartphone_rounded,
              title: actions.isMobile
                  ? AppL10n.of(context).recordSourcePhoneMicrophone
                  : AppL10n.of(context).sourceThisComputer,
              subtitle: actions.isMobile
                  ? AppL10n.of(context).sourcePhoneSubtitle
                  : AppL10n.of(context).sourceComputerSubtitle,
              selected: _selected == CaptureSource.phone,
              onTap: locked ? null : () => _select(CaptureSource.phone),
            ),
            // Desktop and web can mix inputs, so the two toggles belong to the
            // phone option rather than to the list.
            if (!actions.isMobile &&
                _selected == CaptureSource.phone) ...<Widget>[
              const SizedBox(height: 4),
              _InputToggle(
                label: AppL10n.of(context).recordSourceMicrophone,
                value: _microphone,
                onChanged: locked
                    ? null
                    : (value) => _setPhoneInputs(microphone: value),
              ),
              _InputToggle(
                label: actions.isDesktop
                    ? AppL10n.of(context).sourceDeviceAudioDesktop
                    : AppL10n.of(context).sourceTabOrSystemAudio,
                value: _systemAudio,
                onChanged: locked
                    ? null
                    : (value) => _setPhoneInputs(systemAudio: value),
              ),
            ],
            const SizedBox(height: 8),

            _SourceOptionTile(
              icon: Icons.bluetooth_rounded,
              title: deviceLabel ?? AppL10n.of(context).recordSourceWearable,
              subtitle: deviceLabel == null
                  ? AppL10n.of(context).sourceNoWearable
                  : controller.deviceConnected
                  ? (controller.preferredDeviceBatteryLevel == null
                        ? AppL10n.of(context).deviceConnected
                        : AppL10n.of(context).sourceConnectedWithBattery(
                            controller.preferredDeviceBatteryLevel!,
                          ))
                  : AppL10n.of(context).deviceRemembered,
              selected: _selected == CaptureSource.wearable,
              enabled: deviceLabel != null,
              trailingAction: (
                label: controller.scanningWearables
                    ? AppL10n.of(context).deviceScanning
                    : AppL10n.of(context).sourceScan,
                onTap: controller.scanningWearables || locked
                    ? null
                    : () => unawaited(actions.onScan()),
              ),
              onTap: locked || deviceLabel == null
                  ? null
                  : () => _select(CaptureSource.wearable),
            ),
            _WearableDiscoveries(
              controller: controller,
              onConnect: actions.onConnectDevice,
              locked: locked,
            ),
            const SizedBox(height: 8),

            // Every Desk on the account, not just the first: an owner with two
            // rooms has to be able to pick the other one.
            if (desks.isEmpty)
              _SourceOptionTile(
                icon: Icons.speaker_group_outlined,
                title: AppL10n.of(context).recordSourceDesk,
                subtitle: AppL10n.of(context).sourceDeskNotSetUp,
                selected: false,
                enabled: false,
                trailingAction: (
                  label: AppL10n.of(context).sourceSetUp,
                  onTap: () {
                    Navigator.of(context).pop();
                    unawaited(actions.onAddDesk());
                  },
                ),
                onTap: null,
              )
            else
              for (var index = 0; index < desks.length; index += 1) ...<Widget>[
                if (index > 0) const SizedBox(height: 8),
                _SourceOptionTile(
                  icon: Icons.speaker_group_outlined,
                  title: applianceName(desks[index]),
                  subtitle: AppL10n.of(context).sourceDeskSubtitle,
                  selected:
                      _selected == CaptureSource.desk &&
                      actions.selectedDeskId == desks[index]['id'],
                  onTap: locked
                      ? null
                      : () {
                          actions.onSelectDesk(desks[index]);
                          _select(CaptureSource.desk);
                        },
                ),
              ],

            const SizedBox(height: AppSpacing.md),
            Container(height: 1, color: palette.border),
            HairlineRow(
              showDivider: false,
              minHeight: 48,
              leading: Icon(
                Icons.file_upload_outlined,
                size: 18,
                color: palette.textMuted,
              ),
              title: AppL10n.of(context).sourceImportAudio,
              trailing: const RowChevron(),
              onTap: controller.loading
                  ? null
                  : () {
                      Navigator.of(context).pop();
                      unawaited(actions.onImport());
                    },
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              AppL10n.of(context).sourceConsentNote,
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 11.5,
                height: 1.45,
              ),
            ),
            if (kIsWeb) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Text(
                AppL10n.of(context).sourceWebBluetoothNote,
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 11.5,
                  height: 1.45,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Devices found by a scan that is still on this sheet.
///
/// Scan used to pop the sheet first, so the list that results belong on was
/// already gone. Both the source sheet and the device sheet keep the scan in
/// place and render through this, including the empty-scan explanation.
class _WearableDiscoveries extends StatelessWidget {
  const _WearableDiscoveries({
    required this.controller,
    required this.onConnect,
    this.locked = false,
  });

  final NeoRecallController controller;
  final Future<void> Function(AudioDeviceDescriptor device) onConnect;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final found = controller.discoveredWearables;
    final notice = controller.wearableScanNotice;
    if (found.isEmpty && notice == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (found.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.md + 2),
          SectionLabel(label: AppL10n.of(context).sourceFoundNearby),
          for (final device in found)
            HairlineRow(
              minHeight: 52,
              title: device.displayName,
              subtitle: AppL10n.of(context).sourceReadyForAudio(
                '${device.metadata['type'] ?? AppL10n.of(context).sourceWearableFallback}',
              ),
              trailing: TextButton(
                onPressed: locked ? null : () => unawaited(onConnect(device)),
                child: Text(
                  controller.preferredDeviceLabel == device.displayName
                      ? AppL10n.of(context).sourceReconnect
                      : AppL10n.of(context).sourceConnect,
                ),
              ),
            ),
        ],
        if (found.isEmpty && notice != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          InlineMessage(message: notice),
        ],
      ],
    );
  }
}

/// One radio row in the source sheet. An unavailable source stays visible and
/// dimmed with the action that would enable it, rather than disappearing.
class _SourceOptionTile extends StatelessWidget {
  const _SourceOptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    this.trailingAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;
  final bool enabled;
  final ({String label, VoidCallback? onTap})? trailingAction;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final action = trailingAction;
    // A source that can be chosen keeps its radio even when it also carries an
    // action (Scan on a paired wearable). An unavailable source shows only the
    // action that would make it available.
    final showSelector = action == null || onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: selected ? palette.accentMuted : palette.bgTertiary,
        borderRadius: BorderRadius.circular(AppRadius.card),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(
                color: selected
                    ? palette.accent.withValues(alpha: 0.32)
                    : palette.border,
              ),
            ),
            child: Row(
              children: <Widget>[
                Icon(icon, size: 20, color: palette.textSecondary),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (action != null)
                  TextButton(
                    onPressed: action.onTap,
                    child: Text(action.label),
                  ),
                if (action != null && showSelector) const SizedBox(width: 4),
                if (showSelector)
                  Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: selected ? palette.accent : palette.textMuted,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InputToggle extends StatelessWidget {
  const _InputToggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: palette.textSecondary, fontSize: 12.5),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}
