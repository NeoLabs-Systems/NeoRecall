import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main_controller.dart';
import 'main_device_diagnostics.dart';
import 'main_pending_audio.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'src/capture/capture_defaults.dart';
import 'src/record/capture_orb.dart';
import 'src/record/processing_panel.dart';
import 'src/record/record_controls.dart';
import 'src/record/record_sheets.dart';
import 'src/devices/audio_device_adapter.dart';
import 'src/devices/appliance/ui/appliance_capture_section.dart';
import 'src/devices/appliance/ui/appliance_sheet.dart';
import 'src/devices/appliance/ui/appliance_setup_flow.dart';
import 'src/sync/processing_status.dart';
import 'src/models/recording_context.dart';
import 'src/models/timeline_moment.dart';

bool shouldRequestSystemAudio({
  required bool selected,
  required bool web,
  required bool desktop,
}) => selected && (web || desktop);

class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key, required this.controller});
  final NeoRecallController controller;
  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  bool microphone = true;
  bool systemAudio = false;
  bool bluetoothPreferred = true;
  CaptureSource _source = CaptureSource.phone;

  /// Which Desk the record button acts on. Null until one is chosen or one is
  /// the only Desk there is.
  String? _selectedDeskId;

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  void initState() {
    super.initState();
    final defaults = CaptureSourceSelection.forPlatform(
      web: kIsWeb,
      platform: defaultTargetPlatform,
      preferBluetooth: widget.controller.preferBluetoothCapture,
    );
    microphone = defaults.microphone;
    systemAudio = defaults.systemAudio;
    _selectedDeskId = widget.controller.rememberedCaptureDeskId;
    _source = _openingSource(defaults);
    bluetoothPreferred = _source == CaptureSource.wearable;
    if (_source != CaptureSource.phone) {
      microphone = false;
      systemAudio = false;
    } else if (!microphone && !systemAudio) {
      microphone = true;
    }
  }

  /// Where the page opens.
  ///
  /// The source the owner last chose, provided it still exists — a remembered
  /// wearable that has since been forgotten, or a Desk that was removed, falls
  /// back rather than opening on a source that cannot record. Only when there
  /// is nothing remembered does the platform default decide, and the phone is
  /// what that lands on, because it always works.
  CaptureSource _openingSource(CaptureSourceSelection defaults) {
    final controller = widget.controller;
    final bool hasWearable = controller.preferredDeviceLabel != null;
    final bool hasDesk = visibleAppliances(
      controller.devices,
      controller.appliance,
    ).isNotEmpty;

    switch (controller.rememberedCaptureSource) {
      case CaptureSource.wearable:
        if (hasWearable) return CaptureSource.wearable;
      case CaptureSource.desk:
        if (hasDesk) return CaptureSource.desk;
      case CaptureSource.phone:
        return CaptureSource.phone;
      case null:
        break;
    }
    return defaults.bluetooth && hasWearable
        ? CaptureSource.wearable
        : CaptureSource.phone;
  }

  /// Move to a source. One place changes the selection, so the flags below it
  /// cannot drift out of step with what the page is showing.
  void _select(CaptureSource source) {
    setState(() {
      _source = source;
      bluetoothPreferred = source == CaptureSource.wearable;
      if (source != CaptureSource.phone) {
        microphone = false;
        systemAudio = false;
      } else if (!microphone && !systemAudio) {
        microphone = true;
      }
    });
    if (source != CaptureSource.desk) {
      // An immediate runtime preference, not a choice deferred until Record is
      // pressed: it stops an idle wearable reconnect while the phone is chosen.
      unawaited(
        widget.controller.setPreferBluetoothCapture(
          source == CaptureSource.wearable,
        ),
      );
    }
    unawaited(
      widget.controller.rememberCaptureSource(
        source,
        deskId: source == CaptureSource.desk ? _effectiveDeskId : null,
      ),
    );
  }

  Future<bool> _consent() async {
    if (widget.controller.consentAccepted) return true;
    final palette = neoRecallPaletteOf(context);
    final accepted =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            icon: Icon(Icons.shield_outlined, color: palette.accentHover),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.panel),
              side: BorderSide(color: palette.borderLight),
            ),
            title: const Text('Recording consent and visible use'),
            content: const Text(
              'NeoRecall records privately spoken words. Record only when everyone has been informed and you are legally permitted to do so. Recording always remains visibly indicated; NeoRecall has no covert mode.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('I understand'),
              ),
            ],
          ),
        ) ??
        false;
    if (accepted) await widget.controller.acceptConsent();
    return accepted;
  }

  /// True while the appliance itself is recording.
  ///
  /// The Desk records without this app, so its state is read from the device
  /// rather than from anything the phone is doing.
  bool get _deskIsRecording =>
      widget.controller.appliance.status?.isRecording ?? false;

  Future<void> _toggle() async {
    if (_source == CaptureSource.desk) {
      await _toggleDesk();
      return;
    }
    final controller = widget.controller;
    if (controller.isRecording) {
      if (_isMobile) unawaited(HapticFeedback.mediumImpact());
      await controller.stopRecording();
      return;
    }
    if (!await _consent()) return;
    try {
      if (_isMobile) unawaited(HapticFeedback.mediumImpact());
      await controller.setPreferBluetoothCapture(bluetoothPreferred);
      await controller.startRecording(
        microphone: microphone,
        systemAudio: shouldRequestSystemAudio(
          selected: systemAudio,
          web: kIsWeb,
          desktop: _isDesktop,
        ),
        bluetooth: bluetoothPreferred,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  /// Start or stop the Desk. The button on the device does the same thing, and
  /// so does its own detail page — one command, three ways to reach it.
  Future<void> _toggleDesk() async {
    if (!await _consent()) return;
    final appliance = widget.controller.appliance;
    final bool ok = _deskIsRecording
        ? await appliance.stopRecording()
        : await appliance.startRecording();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            appliance.message.isEmpty
                ? 'The device did not answer.'
                : appliance.message,
          ),
        ),
      );
    }
  }

  /// When the Desk started, derived from how long it says it has been running.
  DateTime? _deskStartedAt(NeoRecallController controller) {
    final Duration? elapsed = controller.appliance.status?.recordingElapsed;
    if (elapsed == null || !_deskIsRecording) return null;
    return DateTime.now().subtract(elapsed);
  }

  Future<void> _import() async {
    final selection = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.audio,
    );
    final file = selection?.files.single;
    if (file?.bytes == null) return;
    await widget.controller.importAudio(
      file!.bytes!,
      file.name,
      file.extension == 'wav'
          ? 'audio/wav'
          : 'audio/${file.extension ?? 'mpeg'}',
    );
  }

  Future<void> _addHighlight() async {
    final sessionId = widget.controller.activeRecordingSessionId;
    if (sessionId == null) return;
    await _runContextAction(
      () => widget.controller.addRecordingHighlight(sessionId),
    );
  }

  Future<void> _runContextAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _addNote() async {
    final sessionId = widget.controller.activeRecordingSessionId;
    if (sessionId == null) return;
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => const _RecordingNoteDialog(),
    );
    if (text?.trim().isNotEmpty == true) {
      await _runContextAction(
        () => widget.controller.addRecordingNote(sessionId, text!),
      );
    }
  }

  Future<void> _addContextFile({required bool imageOnly}) async {
    final sessionId = widget.controller.activeRecordingSessionId;
    if (sessionId == null) return;
    final selection = await FilePicker.platform.pickFiles(
      withData: true,
      type: imageOnly ? FileType.image : FileType.any,
    );
    final file = selection?.files.single;
    if (file?.bytes == null) return;
    final extension = (file!.extension ?? '').toLowerCase();
    final contentType = imageOnly
        ? 'image/${extension == 'jpg'
              ? 'jpeg'
              : extension.isEmpty
              ? 'jpeg'
              : extension}'
        : switch (extension) {
            'pdf' => 'application/pdf',
            'docx' =>
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'txt' => 'text/plain',
            'md' => 'text/markdown',
            'csv' => 'text/csv',
            'json' => 'application/json',
            'png' ||
            'jpg' ||
            'jpeg' ||
            'webp' => 'image/${extension == 'jpg' ? 'jpeg' : extension}',
            _ => 'application/octet-stream',
          };
    await _runContextAction(
      () => widget.controller.addRecordingFile(
        sessionId: sessionId,
        bytes: file.bytes!,
        name: file.name,
        contentType: contentType,
      ),
    );
  }

  Future<void> _scan() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.controller.scanForWearables();
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _syncDeviceStorage() async {
    final controller = widget.controller;
    final messenger = ScaffoldMessenger.of(context);
    await controller.syncDeviceStorage(userInitiated: true);
    // The sweep reports its outcome on the controller; without surfacing it here
    // the button looks like it did nothing at all.
    final failure = controller.deviceStorageSyncError;
    if (failure != null && mounted) {
      messenger.showSnackBar(SnackBar(content: Text(failure)));
    }
  }

  Future<void> _addDesk() async {
    final completed = await showApplianceSetupFlow(
      context,
      widget.controller.appliance,
    );
    if (!completed || !mounted) return;
    // Registration happens on the appliance after provisioning. Refreshing the
    // account view here makes the new Desk appear without requiring a trip to
    // Settings or a manual reload; the live controller fills the brief gap if
    // the first heartbeat is still on its way.
    await widget.controller.refreshAll();
  }

  /// Offline-only wearables (HeyPocket, Plaud) hide the live record button
  /// because they have no stream. A hybrid like Memoket still syncs stored
  /// files but also live-captures, so the button stays. Stop is always kept
  /// while a recording is active — including one started from the hardware.
  bool get _showRecordButton =>
      widget.controller.isRecording ||
      !(bluetoothPreferred &&
          widget.controller.preferredDeviceIsOfflineFirst &&
          !widget.controller.preferredDeviceStreamsLive);

  String? get _stageFootnote {
    if (!_showRecordButton) {
      return 'This device records by itself — there is no live capture. '
          'Use “Sync device recordings” to pull and transcribe them.';
    }
    if (bluetoothPreferred &&
        widget.controller.preferredDeviceIsOfflineFirst &&
        widget.controller.preferredDeviceStreamsLive) {
      return 'Start from the app or the device. Either side can stop. '
          'Recordings made while you were away still sync from the device.';
    }
    if (_isDesktop) {
      return 'System audio uses the OS screen-recording permission and captures '
          'audio only, not video frames.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < AppBreakpoints.mobile;
        final gutter = compact ? AppSpacing.md : 28.0;

        final alerts = <Widget>[
          if (controller.warning != null)
            InlineMessage(
              message: controller.warning!,
              icon: Icons.warning_amber_rounded,
            ),
          if (controller.error != null)
            InlineMessage(message: controller.error!, error: true),
          if (!controller.online)
            const InlineMessage(
              message:
                  'You are offline. Capture continues locally and queued audio uploads automatically when the connection returns.',
              icon: Icons.cloud_off_rounded,
            ),
        ];

        if (controller.isRecording) {
          return _ActiveRecordingWorkspace(
            controller: controller,
            alerts: alerts,
            compact: compact,
            gutter: gutter,
            onStop: _toggle,
            onHighlight: _addHighlight,
            onNote: _addNote,
            onPhoto: () => _addContextFile(imageOnly: true),
            onFile: () => _addContextFile(imageOnly: false),
          );
        }

        // The button reflects whatever it will act on. With the Desk chosen it
        // shows the *device's* state, which is the honest answer even when this
        // app has been closed the whole time it was recording.
        final bool deskChosen = _source == CaptureSource.desk;
        return _IdleWorkspace(
          controller: controller,
          alerts: alerts,
          gutter: gutter,
          compact: compact,
          recording: deskChosen ? _deskIsRecording : controller.isRecording,
          startedAt: deskChosen
              ? _deskStartedAt(controller)
              : controller.recordingStartedAt,
          showRecordButton: _showRecordButton,
          sourceLabel: _sourceLabel,
          footnote: _stageFootnote,
          onToggle: _toggle,
          deskChosen: deskChosen,
          onOpenDevice: _openDeviceSheet,
          onOpenSource: _openSourceSheet,
          onOpenLibrary: () => controller.selectLibraryTab(LibraryTab.moments),
          onRetry: controller.retryFailedUploads,
          onUploadWithMobileData: controller.uploadQueuedAudioOnMobileDataOnce,
          onReview: () => showPendingAudioReviewSheet(context, controller),
        );
      },
    );
  }

  /// Everything the sheets need. Built fresh on each open so they always read
  /// the current selection rather than a snapshot from first build.
  RecordSheetActions get _sheetActions => RecordSheetActions(
    controller: widget.controller,
    isMobile: _isMobile,
    isDesktop: _isDesktop,
    onSelectSource: _select,
    onPhoneInputsChanged: ({required microphone, required systemAudio}) {
      setState(() {
        this.microphone = microphone;
        this.systemAudio = systemAudio;
      });
    },
    onImport: _import,
    onScan: _scan,
    onSyncDeviceStorage: _syncDeviceStorage,
    onAddDesk: _addDesk,
    onConnectDevice: _connectDevice,
    selectedDeskId: _effectiveDeskId,
    onSelectDesk: (desk) {
      final id = desk['id'];
      setState(() => _selectedDeskId = id is String ? id : null);
      unawaited(
        widget.controller.rememberCaptureSource(
          CaptureSource.desk,
          deskId: _selectedDeskId,
        ),
      );
    },
  );

  /// The Desk in play: the one that was chosen, or the only one on the account.
  String? get _effectiveDeskId {
    final desks = visibleAppliances(
      widget.controller.devices,
      widget.controller.appliance,
    );
    if (desks.isEmpty) return null;
    for (final desk in desks) {
      if (desk['id'] == _selectedDeskId) return _selectedDeskId;
    }
    final first = desks.first['id'];
    return first is String ? first : null;
  }

  /// The chosen Desk's record, or null when the account has none.
  ApplianceDevice? get _selectedDesk {
    final desks = visibleAppliances(
      widget.controller.devices,
      widget.controller.appliance,
    );
    for (final desk in desks) {
      if (desk['id'] == _effectiveDeskId) return desk;
    }
    return desks.isEmpty ? null : desks.first;
  }

  Future<void> _connectDevice(AudioDeviceDescriptor device) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.controller.preferBluetoothDevice(device);
      if (!mounted) return;
      setState(() {
        bluetoothPreferred = true;
        microphone = false;
        systemAudio = false;
        _source = CaptureSource.wearable;
      });
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  /// Tapping the device chip. A Desk opens its own sheet; anything else opens
  /// the wearable sheet, which also covers "you have no device yet".
  Future<void> _openDeviceSheet() async {
    final desk = _selectedDesk;
    // The chip stands for whatever the header is showing, so it has to open
    // that device's own sheet rather than always the wearable one.
    final bool chipShowsDesk =
        desk != null &&
        (_source == CaptureSource.desk ||
            widget.controller.preferredDeviceLabel == null);
    if (chipShowsDesk) {
      await showApplianceSheet(
        context,
        widget.controller.appliance,
        deviceName: applianceName(desk),
      );
      return;
    }
    await showDeviceSheet(context, _sheetActions);
  }

  Future<void> _openSourceSheet() => showSourceSheet(
    context,
    actions: _sheetActions,
    selected: _source,
    microphone: microphone,
    systemAudio: systemAudio,
  );

  /// What the caption under the record button names as the source.
  String get _sourceLabel {
    final controller = widget.controller;
    switch (_source) {
      case CaptureSource.wearable:
        return controller.preferredDeviceLabel ?? 'Wearable';
      case CaptureSource.desk:
        final desk = _selectedDesk;
        return desk == null ? 'NeoRecall Desk' : applianceName(desk);
      case CaptureSource.phone:
        if (_isMobile) return 'Phone microphone';
        if (microphone && systemAudio) return 'Microphone and device audio';
        return systemAudio ? 'Device audio' : 'Microphone';
    }
  }
}

/// Owns the note field so a parent rebuild — audio-level ticks rebuild the
/// whole app — cannot throw away the controller and steal focus mid-typing.
class _RecordingNoteDialog extends StatefulWidget {
  const _RecordingNoteDialog();

  @override
  State<_RecordingNoteDialog> createState() => _RecordingNoteDialogState();
}

class _RecordingNoteDialogState extends State<_RecordingNoteDialog> {
  late final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a note'),
      content: TextField(
        controller: _input,
        autofocus: true,
        minLines: 3,
        maxLines: 8,
        decoration: const InputDecoration(
          hintText:
              'Names, context, decisions, or anything the transcript may miss…',
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _input.text),
          child: const Text('Save note'),
        ),
      ],
    );
  }
}

/// A ticking elapsed clock, used when something other than this app is doing
/// the recording — a Desk that has been running since before the app opened.
///
/// The time is derived from the start instant on every tick rather than
/// counted up, so a dropped frame or a suspended app can never make it drift.
/// The timer exists only while it is on screen, so an idle Record page still
/// settles.
class _ElapsedClock extends StatefulWidget {
  const _ElapsedClock({required this.startedAt});

  final DateTime startedAt;

  @override
  State<_ElapsedClock> createState() => _ElapsedClockState();
}

class _ElapsedClockState extends State<_ElapsedClock> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String get _label {
    final raw = DateTime.now().toUtc().difference(widget.startedAt.toUtc());
    final span = raw.isNegative ? Duration.zero : raw;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(span.inHours)}:${two(span.inMinutes.remainder(60))}:'
        '${two(span.inSeconds.remainder(60))}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Text(
      _label,
      style: monoMetricStyle(
        palette,
        size: 26,
        color: palette.textPrimary,
        weight: FontWeight.w400,
      ),
    );
  }
}

/// The idle Record screen.
///
/// Three parts and nothing else: who and what is capturing, the one control
/// that starts it, and what today has produced so far. Every machine concern —
/// source, device, sync, import, diagnostics — is one tap away in a sheet
/// rather than laid out on the page.
class _IdleWorkspace extends StatelessWidget {
  const _IdleWorkspace({
    required this.controller,
    required this.alerts,
    required this.gutter,
    required this.compact,
    required this.recording,
    required this.startedAt,
    required this.showRecordButton,
    required this.sourceLabel,
    required this.deskChosen,
    required this.footnote,
    required this.onToggle,
    required this.onOpenDevice,
    required this.onOpenSource,
    required this.onOpenLibrary,
    required this.onRetry,
    required this.onUploadWithMobileData,
    required this.onReview,
  });

  final NeoRecallController controller;
  final List<Widget> alerts;
  final double gutter;
  final bool compact;
  final bool recording;
  final DateTime? startedAt;
  final bool showRecordButton;
  final String sourceLabel;
  final bool deskChosen;
  final String? footnote;
  final VoidCallback onToggle;
  final Future<void> Function() onOpenDevice;
  final Future<void> Function() onOpenSource;
  final VoidCallback onOpenLibrary;
  final Future<void> Function() onRetry;
  final Future<void> Function() onUploadWithMobileData;
  final VoidCallback onReview;

  static const List<String> _months = <String>[
    'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
    'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
  ];
  static const List<String> _weekdays = <String>[
    'MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY',
    'FRIDAY', 'SATURDAY', 'SUNDAY',
  ];

  /// A greeting keyed to the clock, not to a name we may not have.
  static String greetingFor(DateTime now) {
    if (now.hour < 5) return 'Still up';
    if (now.hour < 12) return 'Good morning';
    if (now.hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  static String dateLineFor(DateTime now) =>
      '${_weekdays[now.weekday - 1]} · ${now.day} ${_months[now.month - 1]}';

  /// Today's moments, newest first. The Record page shows a handful; the rest
  /// of the history is Library's job.
  List<TimelineMoment> _today() {
    final now = DateTime.now();
    final floor = DateTime(now.year, now.month, now.day);
    final items =
        controller.moments
            .where((moment) => !moment.startedAt.toLocal().isBefore(floor))
            .toList()
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return items;
  }

  static String _clock(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  static String _durationLabel(TimelineMoment moment) {
    final span = moment.endedAt.difference(moment.startedAt);
    if (span.inMinutes < 1) return 'under a minute';
    if (span.inMinutes < 60) return '${span.inMinutes} min';
    final hours = span.inHours;
    final minutes = span.inMinutes.remainder(60);
    return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final now = DateTime.now();
    final moments = _today();
    final visible = moments.take(4).toList();

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(gutter, compact ? 20 : 28, gutter, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          dateLineFor(now),
                          style: sectionEyebrowStyle(palette),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          greetingFor(now),
                          style: heroTitleStyle(palette, size: 22),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  DeviceChip(
                    controller: controller,
                    preferDesk: deskChosen,
                    onTap: () => unawaited(onOpenDevice()),
                    // Kept as a second way in: support has been telling people
                    // to long-press this for years.
                    onLongPress: () {
                      HapticFeedback.mediumImpact();
                      showDeviceDiagnosticsSheet(context, controller);
                    },
                  ),
                ],
              ),
              for (final alert in alerts) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                alert,
              ],
              SizedBox(height: compact ? 56 : 64),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      recording ? 'LIVE' : 'STANDBY',
                      style: sectionEyebrowStyle(palette).copyWith(
                        letterSpacing: 2.2,
                        color: recording ? palette.secondary : palette.textMuted,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg + 2),
                    if (showRecordButton)
                      RecordDial(recording: recording, onPressed: onToggle)
                    else
                      Icon(
                        Icons.cloud_sync_outlined,
                        size: 44,
                        color: palette.textMuted,
                      ),
                    const SizedBox(height: AppSpacing.lg - 2),
                    Text(
                      showRecordButton
                          ? (recording ? 'Recording' : 'Ready to record')
                          // The device's own name is the sync card's line to
                          // say; repeating it here printed it twice.
                          : 'Recordings sync from the device',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (recording && startedAt != null) ...<Widget>[
                      const SizedBox(height: 8),
                      _ElapsedClock(startedAt: startedAt!),
                    ],
                    const SizedBox(height: 7),
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Text(
                          sourceLabel,
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 12.5,
                          ),
                        ),
                        Text(
                          ' · ',
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 12.5,
                          ),
                        ),
                        InkWell(
                          onTap: () => unawaited(onOpenSource()),
                          borderRadius: BorderRadius.circular(AppRadius.tag),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Text(
                              'change',
                              style: TextStyle(
                                color: palette.accentHover,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (footnote != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.sm),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Footnote(footnote!, center: true),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              ProcessingStatusPanel(
                status: controller.processingStatus,
                onRetry: onRetry,
                onUploadWithMobileData: onUploadWithMobileData,
                onReview: onReview,
              ),
              SizedBox(height: compact ? 40 : 48),
              SectionLabel(
                label: 'Today',
                emphasized: true,
                trailing: moments.isEmpty
                    ? null
                    : '${moments.length} '
                          '${moments.length == 1 ? 'moment' : 'moments'}',
              ),
              if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    'Nothing recorded yet today.',
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 12.5,
                    ),
                  ),
                )
              else
                for (var index = 0; index < visible.length; index++)
                  HairlineRow(
                    showDivider: index > 0,
                    minHeight: 52,
                    leading: SizedBox(
                      width: 38,
                      child: Text(
                        _clock(visible[index].startedAt),
                        style: monoMetricStyle(palette),
                      ),
                    ),
                    title:
                        visible[index].titleEn?.trim().isNotEmpty == true
                        ? visible[index].titleEn!
                        : 'Untitled moment',
                    subtitle:
                        '${_durationLabel(visible[index])} · '
                        '${visible[index].segmentCount} '
                        '${visible[index].segmentCount == 1 ? 'segment' : 'segments'}',
                    trailing: const RowChevron(),
                    onTap: onOpenLibrary,
                  ),
              if (moments.length > visible.length) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: onOpenLibrary,
                    child: const Text('All moments →'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ActiveRecordingWorkspace extends StatelessWidget {
  const _ActiveRecordingWorkspace({
    required this.controller,
    required this.alerts,
    required this.compact,
    required this.gutter,
    required this.onStop,
    required this.onHighlight,
    required this.onNote,
    required this.onPhoto,
    required this.onFile,
  });

  final NeoRecallController controller;
  final List<Widget> alerts;
  final bool compact;
  final double gutter;
  final Future<void> Function() onStop;
  final Future<void> Function() onHighlight;
  final Future<void> Function() onNote;
  final Future<void> Function() onPhoto;
  final Future<void> Function() onFile;

  @override
  Widget build(BuildContext context) {
    final stage = _CaptureStage(
      recording: true,
      level: controller.audioLevel,
      startedAt: controller.recordingStartedAt,
      processing: controller.processingStatus,
      showRecordButton: true,
      onToggle: onStop,
      onRetry: controller.retryFailedUploads,
      onUploadWithMobileData: controller.uploadQueuedAudioOnMobileDataOnce,
      onReview: () => showPendingAudioReviewSheet(context, controller),
      footnote:
          'Add context as it happens. Every item is stored locally before it is synchronized.',
    );
    final contextPanel = _RecordingContextPanel(
      items: controller.activeRecordingContext,
      onHighlight: onHighlight,
      onNote: onNote,
      onPhoto: onPhoto,
      onFile: onFile,
    );
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        gutter,
        compact ? AppSpacing.lg : 28,
        gutter,
        48,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1240),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const ScreenHeader(
                title: 'Recording in progress',
                description:
                    'Mark important moments and add notes, images, or documents without leaving the recording.',
              ),
              for (final alert in alerts) ...<Widget>[
                alert,
                const SizedBox(height: AppSpacing.md),
              ],
              if (compact) ...<Widget>[
                stage,
                const SizedBox(height: AppSpacing.md + 2),
                contextPanel,
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(flex: 5, child: stage),
                    const SizedBox(width: AppSpacing.md + 2),
                    Expanded(flex: 6, child: contextPanel),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecordingContextPanel extends StatelessWidget {
  const _RecordingContextPanel({
    required this.items,
    required this.onHighlight,
    required this.onNote,
    required this.onPhoto,
    required this.onFile,
  });

  final List<RecordingContextItem> items;
  final Future<void> Function() onHighlight;
  final Future<void> Function() onNote;
  final Future<void> Function() onPhoto;
  final Future<void> Function() onFile;

  String _time(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    return '${duration.inMinutes.toString().padLeft(2, '0')}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    Widget action(
      String key,
      IconData icon,
      String label,
      Future<void> Function() callback,
    ) => OutlinedButton.icon(
      key: ValueKey<String>(key),
      onPressed: () => unawaited(callback()),
      icon: Icon(icon),
      label: Text(label),
    );
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Recording context',
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'These sources help NeoRecall understand what matters and improve the final memory.',
            style: TextStyle(color: palette.textMuted, height: 1.4),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              action(
                'recording-context-highlight',
                Icons.flag_outlined,
                'Highlight',
                onHighlight,
              ),
              action(
                'recording-context-note',
                Icons.edit_note_rounded,
                'Note',
                onNote,
              ),
              action(
                'recording-context-photo',
                Icons.add_a_photo_outlined,
                'Photo',
                onPhoto,
              ),
              action(
                'recording-context-file',
                Icons.attach_file_rounded,
                'File',
                onFile,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (items.isEmpty)
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: palette.bgSecondary.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                'No context added yet.',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textMuted),
              ),
            )
          else
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: palette.bgSecondary.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: palette.border),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _time(item.capturedOffsetMs),
                        style: TextStyle(
                          color: palette.accentHover,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          item.noteText ??
                              item.originalName ??
                              'Highlighted moment',
                          style: TextStyle(color: palette.textPrimary),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        item.state == LocalContextState.synced
                            ? Icons.cloud_done_outlined
                            : item.state == LocalContextState.failed
                            ? Icons.cloud_off_outlined
                            : Icons.cloud_upload_outlined,
                        size: 17,
                        color: item.state == LocalContextState.failed
                            ? palette.danger
                            : palette.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// The capture stage: an audio-reactive orb, the live clock, and the primary
/// record control.
///
/// Animation and level sampling run only while recording. Idle is completely
/// static — an always-on recorder should not burn frames while parked, and a
/// permanently animating screen never settles for widget tests.
class _CaptureStage extends StatefulWidget {
  const _CaptureStage({
    required this.recording,
    required this.level,
    required this.startedAt,
    required this.processing,
    required this.showRecordButton,
    required this.onToggle,
    required this.onRetry,
    required this.onUploadWithMobileData,
    required this.onReview,
    this.footnote,
  });

  final bool recording;
  final double level;
  final DateTime? startedAt;
  final ProcessingStatusSnapshot processing;
  final bool showRecordButton;
  final VoidCallback onToggle;
  final Future<void> Function() onRetry;
  final Future<void> Function() onUploadWithMobileData;
  final VoidCallback onReview;
  final String? footnote;

  @override
  State<_CaptureStage> createState() => _CaptureStageState();
}

class _CaptureStageState extends State<_CaptureStage>
    with SingleTickerProviderStateMixin {
  /// One ring segment per history sample, so the orb draws roughly the last
  /// four seconds of audio as a circular waveform.
  static const Duration _samplePeriod = Duration(milliseconds: 70);

  final List<double> _history = <double>[];
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  Timer? _sampler;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    if (widget.recording) _startLive();
  }

  @override
  void didUpdateWidget(covariant _CaptureStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.recording == oldWidget.recording) return;
    if (widget.recording) {
      _startLive();
    } else {
      _stopLive();
    }
  }

  @override
  void dispose() {
    _sampler?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  void _startLive() {
    _pulse.repeat();
    // The clock and the ring both advance from this tick, so neither depends on
    // audio callbacks arriving: a silent or stalled source still reads as live
    // rather than freezing the elapsed time mid-recording.
    _sampler ??= Timer.periodic(_samplePeriod, (_) {
      if (!mounted) return;
      setState(() {
        _history.add(widget.level.clamp(0, 1).toDouble());
        if (_history.length > CaptureOrb.ticks) _history.removeAt(0);
        _revision += 1;
      });
    });
  }

  void _stopLive() {
    _sampler?.cancel();
    _sampler = null;
    _pulse
      ..stop()
      ..value = 0;
    _history.clear();
    _revision += 1;
  }

  String get _elapsed {
    final started = widget.startedAt;
    if (started == null) return '00:00:00';
    final raw = DateTime.now().toUtc().difference(started);
    final duration = raw.isNegative ? Duration.zero : raw;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(duration.inHours)}:${two(duration.inMinutes.remainder(60))}:'
        '${two(duration.inSeconds.remainder(60))}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final recording = widget.recording;
    final tint = recording ? palette.secondary : palette.accent;

    return AppPanel(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 22),
      child: Column(
        children: <Widget>[
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => CaptureOrb(
              recording: recording,
              level: widget.level,
              phase: _pulse.value,
              history: _history,
              revision: _revision,
              palette: palette,
            ),
          ),
          const SizedBox(height: AppSpacing.lg - 4),
          CaptureStatusPill(
            tint: tint,
            label: recording ? 'LIVE' : 'STANDBY',
            pulse: recording ? _pulse : null,
          ),
          const SizedBox(height: AppSpacing.sm + 2),
          Text(
            recording ? 'Recording is visible and active' : 'Ready to record',
            textAlign: TextAlign.center,
            style: heroTitleStyle(palette, size: 19),
          ),
          if (recording) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Text(
              _elapsed,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 34,
                fontWeight: FontWeight.w300,
                letterSpacing: 1.5,
                height: 1,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
          SizedBox(height: widget.showRecordButton ? AppSpacing.lg - 2 : 14),
          if (widget.showRecordButton) ...<Widget>[
            RecordButton(recording: recording, onPressed: widget.onToggle),
            const SizedBox(height: AppSpacing.md),
          ],
          ProcessingStatusPanel(
            status: widget.processing,
            onRetry: widget.onRetry,
            onUploadWithMobileData: widget.onUploadWithMobileData,
            onReview: widget.onReview,
          ),
          if (widget.footnote != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Footnote(widget.footnote!, center: true),
          ],
        ],
      ),
    );
  }
}
