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
            'Add device',
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
            icon: showDesk ? Icons.speaker_group_outlined : Icons.mic_none_rounded,
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
                    ? 'Connected'
                    : 'Not connected',
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
          ? 'Add a device'
          : 'Manage $label',
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
        final battery = connected ? controller.preferredDeviceBatteryLevel : null;
        final desks = visibleAppliances(
          controller.devices,
          controller.appliance,
        );

        if (label == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('No device yet', style: heroTitleStyle(palette, size: 18)),
              const SizedBox(height: 6),
              Text(
                'NeoRecall records with the phone microphone until you connect '
                'a wearable or set up a Desk.',
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
                    : () {
                        Navigator.of(context).pop();
                        unawaited(actions.onScan());
                      },
                icon: controller.scanningWearables
                    ? const ButtonSpinner()
                    : const Icon(Icons.bluetooth_searching_rounded, size: 18),
                label: Text(
                  controller.scanningWearables
                      ? 'Scanning…'
                      : 'Scan for wearables',
                ),
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
                title: 'Set up a NeoRecall Desk',
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
                                  ? 'Connected'
                                  : 'Remembered — not connected right now',
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
                    label: 'Battery',
                    value: battery == null ? '—' : '$battery',
                    unit: battery == null ? null : '%',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Stat(
                    label: 'Synced',
                    value: '${controller.deviceStorageSyncedCount}',
                    unit: 'recordings',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Stat(
                    label: 'Left',
                    value: progress == null || progress.pendingSeconds <= 0
                        ? '0'
                        : DeviceSyncStatusView.formatDuration(
                            progress.pendingSeconds,
                          ),
                    unit: progress == null || progress.pendingSeconds <= 0
                        ? 'queued'
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
                    ? 'This device can record on its own as well. Anything it '
                          'captured while you were away syncs here when it '
                          'connects, or you can pull it now.'
                    : 'This device records on its own — press record and stop '
                          'on the device itself. Recordings sync here when it '
                          'connects, or you can pull them now.',
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ],
            if (stranded) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              const InlineMessage(
                icon: Icons.cloud_off_rounded,
                message:
                    'The device has recordings but no Wi-Fi. They can move to '
                    'this phone over Bluetooth and upload from here later.',
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
                      ? 'Moving recordings…'
                      : 'Move recordings to this phone',
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
              title: 'Scan for another wearable',
              trailing: const RowChevron(),
              onTap: controller.scanningWearables
                  ? null
                  : () {
                      Navigator.of(context).pop();
                      unawaited(actions.onScan());
                    },
            ),
            HairlineRow(
              minHeight: 48,
              leading: Icon(
                Icons.troubleshoot_rounded,
                size: 18,
                color: palette.textMuted,
              ),
              title: 'Device and sync diagnostics',
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
              title: 'Forget this device',
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
                title: 'Set up a NeoRecall Desk',
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
            Text('Record from', style: heroTitleStyle(palette, size: 18)),
            const SizedBox(height: 6),
            Text(
              locked
                  ? 'The source is locked while a recording is running.'
                  : 'Only one source records at a time. The choice sticks '
                        'until you change it.',
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
            const SizedBox(height: AppSpacing.md + 2),

            _SourceOptionTile(
              icon: Icons.smartphone_rounded,
              title: actions.isMobile ? 'Phone microphone' : 'This computer',
              subtitle: actions.isMobile
                  ? 'Always available, nothing to connect'
                  : 'Microphone, and system audio if you want it',
              selected: _selected == CaptureSource.phone,
              onTap: locked ? null : () => _select(CaptureSource.phone),
            ),
            // Desktop and web can mix inputs, so the two toggles belong to the
            // phone option rather than to the list.
            if (!actions.isMobile && _selected == CaptureSource.phone) ...<Widget>[
              const SizedBox(height: 4),
              _InputToggle(
                label: 'Microphone',
                value: _microphone,
                onChanged: locked
                    ? null
                    : (value) => _setPhoneInputs(microphone: value),
              ),
              _InputToggle(
                label: actions.isDesktop
                    ? 'Device audio — everything this machine plays'
                    : 'Tab or system audio',
                value: _systemAudio,
                onChanged: locked
                    ? null
                    : (value) => _setPhoneInputs(systemAudio: value),
              ),
            ],
            const SizedBox(height: 8),

            _SourceOptionTile(
              icon: Icons.bluetooth_rounded,
              title: deviceLabel ?? 'Wearable',
              subtitle: deviceLabel == null
                  ? 'No wearable connected yet'
                  : controller.deviceConnected
                  ? 'Connected${controller.preferredDeviceBatteryLevel == null ? '' : ' · ${controller.preferredDeviceBatteryLevel}%'}'
                  : 'Remembered — not connected right now',
              selected: _selected == CaptureSource.wearable,
              enabled: deviceLabel != null,
              trailingAction: deviceLabel == null
                  ? (label: 'Scan', onTap: () {
                      Navigator.of(context).pop();
                      unawaited(actions.onScan());
                    })
                  : null,
              onTap: locked || deviceLabel == null
                  ? null
                  : () => _select(CaptureSource.wearable),
            ),
            const SizedBox(height: 8),

            // Every Desk on the account, not just the first: an owner with two
            // rooms has to be able to pick the other one.
            if (desks.isEmpty)
              _SourceOptionTile(
                icon: Icons.speaker_group_outlined,
                title: 'NeoRecall Desk',
                subtitle: 'Not set up',
                selected: false,
                enabled: false,
                trailingAction: (label: 'Set up', onTap: () {
                  Navigator.of(context).pop();
                  unawaited(actions.onAddDesk());
                }),
                onTap: null,
              )
            else
              for (var index = 0; index < desks.length; index += 1) ...<Widget>[
                if (index > 0) const SizedBox(height: 8),
                _SourceOptionTile(
                  icon: Icons.speaker_group_outlined,
                  title: applianceName(desks[index]),
                  subtitle: 'Records the room on its own',
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

            // Discovered wearables only appear while a scan has actually found
            // something; an empty list is not a section.
            if (controller.discoveredWearables.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.md + 2),
              const SectionLabel(label: 'Found nearby'),
              for (final device in controller.discoveredWearables)
                HairlineRow(
                  minHeight: 52,
                  title: device.displayName,
                  subtitle:
                      '${device.metadata['type'] ?? 'wearable'} · ready for audio',
                  trailing: TextButton(
                    onPressed: locked
                        ? null
                        : () => unawaited(actions.onConnectDevice(device)),
                    child: Text(
                      controller.preferredDeviceLabel == device.displayName
                          ? 'Reconnect'
                          : 'Connect',
                    ),
                  ),
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
              title: 'Import an audio file',
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
              'Recording privately spoken words may require everyone’s consent. '
              'NeoRecall never hides that it is recording.',
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 11.5,
                height: 1.45,
              ),
            ),
            if (kIsWeb) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'The browser opens its own Bluetooth chooser, and capture '
                'continues only while this tab stays active.',
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
  final ({String label, VoidCallback onTap})? trailingAction;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
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
                if (trailingAction != null)
                  TextButton(
                    onPressed: trailingAction!.onTap,
                    child: Text(trailingAction!.label),
                  )
                else
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
