import 'package:flutter/material.dart';

import '../../../../main_shared.dart';
import '../../../../main_spacing.dart';
import '../../../../main_theme.dart';
import '../../../record/record_controls.dart';
import '../../../record/source_picker.dart';
import '../appliance_controller.dart';
import '../appliance_protocol.dart';
import 'appliance_settings_sheet.dart';
import 'appliance_sheet_scaffold.dart';

/// The appliance's page: one screen that answers "is it recording?" before
/// anything else, and hides everything that is not a decision the user makes.
///
/// The device has no display, so this sheet is the only place its state is
/// visible. That is why the recording indicator is the orb from the record
/// screen rather than a line of text — the same visual language, in the same
/// colours, meaning the same thing.
Future<void> showApplianceSheet(
  BuildContext context,
  ApplianceController controller, {
  String deviceName = 'NeoRecall Desk',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) =>
        ApplianceSheet(controller: controller, deviceName: deviceName),
  );
}

class ApplianceSheet extends StatefulWidget {
  const ApplianceSheet({
    super.key,
    required this.controller,
    this.deviceName = 'NeoRecall Desk',
  });

  final ApplianceController controller;
  final String deviceName;

  @override
  State<ApplianceSheet> createState() => _ApplianceSheetState();
}

class _ApplianceSheetState extends State<ApplianceSheet>
    with SingleTickerProviderStateMixin {
  // Created here rather than lazily. A `late final` controller is only built
  // when something first reads it, and once the resting device stopped reading
  // it the first read happened in dispose() — which creates a ticker against an
  // element that is already gone.
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ApplianceSheetScaffold(
      controller: controller,
      title: widget.deviceName,
      // The summary, minus what the status line below already says: a header
      // reading "Ready" above a pill reading READY was the page repeating
      // itself. What survives is the part with information — the queue, the
      // headset, "Sending 3 recordings".
      subtitle: () {
        final ApplianceStatus? status = controller.status;
        if (status == null) return 'Connecting…';
        final String summary = status.summary;
        if (summary == 'Ready') return null;
        if (summary.startsWith('Recording ·')) return null;
        return summary;
      },
      trailing: () => IconButton(
        tooltip: 'Device settings',
        icon: const Icon(Icons.tune_rounded),
        onPressed: controller.status == null
            ? null
            : () => showApplianceSettingsSheet(
                context,
                controller,
                deviceName: widget.deviceName,
              ),
      ),
      children: (BuildContext context, NeoRecallPalette palette) {
        // Read here, not in the enclosing build. The scaffold rebuilds this
        // callback on every notification; a status captured outside it would be
        // the one the sheet opened with, and the page would stop moving.
        final status = controller.status;
        return <Widget>[
          _statusLine(palette, status),
          if (!controller.isConnected) _outOfRange,
          if (status != null && status.error.isNotEmpty)
            InlineMessage(message: status.error, error: true),
          _soundSection(palette, status),
          _headphonesSection(palette, status),
        ];
      },
    );
  }

  /// The unambiguous answer to "is it recording?", in a form that needs no
  /// reading: the same orb, the same rose tint, as the record screen.
  /// What the device is doing, in one line. Deliberately not a second place to
  /// start or stop it.
  ///
  /// This page used to carry a full recording stage — an orb, an elapsed clock
  /// and a record button — which is the same control the Record screen already
  /// owns. Two controls meant two readings of the same state, and they drifted:
  /// one said recording while the other said ready. Recording belongs on the
  /// Record screen, next to every other source; this page is the device and its
  /// settings.
  Widget _statusLine(NeoRecallPalette palette, ApplianceStatus? status) {
    final bool recording = status?.isRecording ?? false;
    final controller = widget.controller;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        CaptureStatusPill(
          tint: recording ? palette.secondary : palette.accent,
          label: recording ? 'RECORDING' : 'READY',
          // The pulse is a claim about *now*. Out of range there is no now,
          // only the last thing the device said, so it stops.
          pulse: recording && controller.isConnected ? _pulse : null,
        ),
        if (!controller.isConnected)
          CaptureStatusPill(tint: palette.textMuted, label: 'OUT OF RANGE'),
        if (recording)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              formatElapsed(status?.recordingElapsed ?? Duration.zero),
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
    );
  }

  Widget get _outOfRange => const InlineMessage(
      icon: Icons.bluetooth_disabled_rounded,
      // Deliberately reassuring and true: the appliance keeps recording and
      // uploading with the phone nowhere near it.
      message:
          'Out of range. This page shows what the device last reported. '
          'A recording already running is not affected — the device keeps '
          'recording and sending on its own.',
  );

  /// Where the sound goes, and where it comes from — as two labelled choices.
  ///
  /// These used to be a row of read-only pills above a single chooser, with
  /// "Speaker" appearing twice: once as the current output and once as the
  /// option. The microphone was not choosable here at all; that switch lived in
  /// settings, two taps away from the output it belongs beside.
  Widget _soundSection(NeoRecallPalette palette, ApplianceStatus? status) {
    final controller = widget.controller;
    final bool headphonesAvailable = status?.headsetConnected ?? false;
    final bool live = status != null && controller.isConnected;
    return SectionCard(
      eyebrow: 'SOUND',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _choiceLabel(palette, 'Plays out of'),
          const SizedBox(height: 8),
          SegmentedButton<ApplianceOutput>(
            segments: <ButtonSegment<ApplianceOutput>>[
              const ButtonSegment<ApplianceOutput>(
                value: ApplianceOutput.speaker,
                label: Text('Speaker'),
                icon: Icon(Icons.speaker_rounded, size: 18),
              ),
              ButtonSegment<ApplianceOutput>(
                value: ApplianceOutput.headphones,
                label: Text(
                  headphonesAvailable && (status?.headsetName ?? '').isNotEmpty
                      ? status!.headsetName
                      : 'Headphones',
                ),
                icon: const Icon(Icons.headphones_rounded, size: 18),
                enabled: headphonesAvailable,
              ),
            ],
            selected: <ApplianceOutput>{
              status?.output ?? ApplianceOutput.speaker,
            },
            showSelectedIcon: false,
            onSelectionChanged: live
                ? (Set<ApplianceOutput> selection) =>
                      controller.useOutput(selection.first)
                : null,
          ),
          const SizedBox(height: AppSpacing.md),
          _choiceLabel(palette, 'Records with'),
          const SizedBox(height: 8),
          SegmentedButton<ApplianceMicSource>(
            segments: <ButtonSegment<ApplianceMicSource>>[
              const ButtonSegment<ApplianceMicSource>(
                value: ApplianceMicSource.builtIn,
                label: Text('Its own microphones'),
                icon: Icon(Icons.mic_rounded, size: 18),
              ),
              ButtonSegment<ApplianceMicSource>(
                value: ApplianceMicSource.headset,
                label: const Text('Headset'),
                icon: const Icon(Icons.headset_mic_rounded, size: 18),
                enabled: headphonesAvailable,
              ),
            ],
            selected: <ApplianceMicSource>{
              status?.micSource ?? ApplianceMicSource.builtIn,
            },
            showSelectedIcon: false,
            onSelectionChanged: live
                ? (Set<ApplianceMicSource> selection) =>
                      controller.useHeadsetMicrophone(
                        selection.first == ApplianceMicSource.headset,
                      )
                : null,
          ),
          if (status?.micSource == ApplianceMicSource.headset) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            // The honest version. This is a property of Bluetooth itself, not
            // something a future release will fix, and the owner is about to
            // hear the difference.
            const Footnote(
              'While recording, what you hear drops in quality — that is how '
              'Bluetooth headsets work.',
            ),
          ],
        ],
      ),
    );
  }

  Widget _choiceLabel(NeoRecallPalette palette, String text) => Text(
    text,
    style: TextStyle(
      color: palette.textMuted,
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _headphonesSection(NeoRecallPalette palette, ApplianceStatus? status) {
    final controller = widget.controller;
    // A scan is how you find *new* headphones. The pair the device is using
    // right now has to be visible whether or not anyone has scanned, and it has
    // to offer the way back out.
    final found = <ApplianceHeadphone>[
      ...controller.headphones,
      if ((status?.headsetConnected ?? false) &&
          !controller.headphones.any(
            (ApplianceHeadphone other) => other.name == status!.headsetName,
          ))
        ApplianceHeadphone(
          address: '',
          name: status!.headsetName,
          paired: true,
          connected: true,
          battery: status.headsetBattery,
        ),
    ];
    return SectionCard(
      eyebrow: 'HEADPHONES',
      trailing: TextButton.icon(
        onPressed: !controller.isConnected || controller.isLookingForHeadphones
            ? null
            : controller.lookForHeadphones,
        icon: controller.isLookingForHeadphones
            ? const ButtonSpinner()
            : const Icon(Icons.search_rounded, size: 18),
        label: Text(controller.isLookingForHeadphones ? 'Looking…' : 'Find'),
      ),
      child: found.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No headphones yet. Put yours in pairing mode and tap Find.',
                style: TextStyle(color: palette.textMuted, fontSize: 13),
              ),
            )
          : Column(
              children: <Widget>[
                for (final ApplianceHeadphone headphone in found)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DeviceRow(
                      name: headphone.name,
                      detail: headphone.connected
                          ? 'Connected'
                          : (headphone.paired ? 'Paired' : 'In range'),
                      connected: headphone.connected,
                      batteryLevel: headphone.battery,
                      actionLabel: headphone.connected
                          ? 'Disconnect'
                          : 'Connect',
                      connectedActionLabel: 'Disconnect',
                      onAction: headphone.address.isEmpty
                          ? null
                          : () => headphone.connected
                                ? controller.disconnectHeadphones(
                                    headphone.address,
                                  )
                                : controller.connectHeadphones(
                                    headphone.address,
                                  ),
                    ),
                  ),
              ],
            ),
    );
  }
}
