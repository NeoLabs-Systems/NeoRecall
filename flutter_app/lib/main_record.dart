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
import 'src/record/sync_cards.dart';
import 'src/record/record_controls.dart';
import 'src/record/source_picker.dart';
import 'src/devices/audio_device_adapter.dart';
import 'src/devices/appliance/ui/appliance_capture_section.dart';
import 'src/devices/appliance/ui/appliance_setup_flow.dart';
import 'src/sync/processing_status.dart';
import 'src/models/recording_context.dart';

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

/// What the record button acts on.
///
/// One value, not a set of booleans that can disagree with each other. The Desk
/// is a peer here rather than a section of its own: it is another answer to
/// "where does this recording come from", and giving it a parallel block of its
/// own is what made this page read as two products stapled together.
enum _CaptureSource { phone, wearable, desk }

class _RecordScreenState extends State<RecordScreen> {
  bool microphone = true;
  bool systemAudio = false;
  bool bluetoothPreferred = true;
  _CaptureSource _source = _CaptureSource.phone;

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
    // The phone is the source that always works, so it is where this page
    // starts. A wearable is preselected only when the owner actually has one
    // chosen from an earlier session — "prefer Bluetooth" with no device behind
    // it left people looking at a scan button they never asked for.
    final bool hasWearable = widget.controller.preferredDeviceLabel != null;
    _source = defaults.bluetooth && hasWearable
        ? _CaptureSource.wearable
        : _CaptureSource.phone;
    bluetoothPreferred = _source == _CaptureSource.wearable;
    if (_source == _CaptureSource.phone && !microphone && !systemAudio) {
      microphone = true;
    }
  }

  /// Move to a source. One place changes the selection, so the flags below it
  /// cannot drift out of step with what the page is showing.
  void _select(_CaptureSource source) {
    setState(() {
      _source = source;
      bluetoothPreferred = source == _CaptureSource.wearable;
      if (source != _CaptureSource.phone) {
        microphone = false;
        systemAudio = false;
      } else if (!microphone && !systemAudio) {
        microphone = true;
      }
    });
    if (source != _CaptureSource.desk) {
      // An immediate runtime preference, not a choice deferred until Record is
      // pressed: it stops an idle wearable reconnect while the phone is chosen.
      unawaited(
        widget.controller.setPreferBluetoothCapture(
          source == _CaptureSource.wearable,
        ),
      );
    }
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
    if (_source == _CaptureSource.desk) {
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
      builder: (dialogContext) {
        final input = TextEditingController();
        return AlertDialog(
          title: const Text('Add a note'),
          content: TextField(
            controller: input,
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
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, input.text),
              child: const Text('Save note'),
            ),
          ],
        );
      },
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

  String get _headerDescription => _isMobile
      ? 'Mobile capture can use a connected streaming wearable or the phone microphone. Android keeps a foreground service alive while recording.'
      : _isDesktop
      ? 'Desktop can capture microphone and system audio together. Permissions are requested up front and recording stays visibly active.'
      : 'Browser capture supports microphone and optional tab/system audio through the browser permission flow.';

  /// Offline-first wearables (HeyPocket) record on the device itself and cannot
  /// live-stream, so the live record button is hidden when such a device is the
  /// chosen source — sync is the only capture path. The stop control is always
  /// kept while a recording is somehow active.
  bool get _showRecordButton =>
      widget.controller.isRecording ||
      !(bluetoothPreferred && widget.controller.preferredDeviceIsOfflineFirst);

  String? get _stageFootnote {
    if (!_showRecordButton) {
      return 'This device records by itself — there is no live capture. '
          'Use “Sync device recordings” to pull and transcribe them.';
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
    final palette = neoRecallPaletteOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < AppBreakpoints.mobile;
        // Side by side once both halves stay readable, which keeps the record
        // button and the source picker on screen together in a default desktop
        // window (1180px less the 276px sidebar). Narrower than that they stack
        // and the page scrolls.
        final split = constraints.maxWidth >= 880;
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
          if (bluetoothPreferred && controller.preferredDeviceIsOfflineFirst)
            OfflineDeviceSyncCard(controller: controller),
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
        final bool deskChosen = _source == _CaptureSource.desk;
        final stage = _CaptureStage(
          recording: deskChosen ? _deskIsRecording : controller.isRecording,
          level: controller.audioLevel,
          startedAt: deskChosen
              ? _deskStartedAt(controller)
              : controller.recordingStartedAt,
          processing: controller.processingStatus,
          showRecordButton: _showRecordButton,
          onToggle: _toggle,
          onRetry: controller.retryFailedUploads,
          onUploadWithMobileData: controller.uploadQueuedAudioOnMobileDataOnce,
          onReview: () => showPendingAudioReviewSheet(context, controller),
          footnote: _stageFootnote,
        );
        final sources = _sourcesCard(palette);

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
                  ScreenHeader(
                    eyebrow: 'CAPTURE',
                    title: 'Record what matters',
                    description: _headerDescription,
                  ),
                  for (final alert in alerts) ...<Widget>[
                    alert,
                    const SizedBox(height: AppSpacing.md),
                  ],
                  if (split)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(flex: 5, child: stage),
                        const SizedBox(width: AppSpacing.md + 2),
                        Expanded(flex: 6, child: sources),
                      ],
                    )
                  else ...<Widget>[
                    stage,
                    const SizedBox(height: AppSpacing.md + 2),
                    sources,
                  ],
                  const SizedBox(height: AppSpacing.md + 2),
                  ImportCard(
                    busy: controller.loading,
                    onPressed: controller.loading ? null : _import,
                  ),
                  const SizedBox(height: AppSpacing.md + 2),
                  const InlineMessage(
                    message:
                        'Recording privately spoken words may require everyone’s consent. NeoRecall never hides its recording state and does not determine whether a recording is lawful.',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _sourcesCard(NeoRecallPalette palette) {
    final controller = widget.controller;
    final locked = controller.isRecording;
    final desks = visibleAppliances(controller.devices, controller.appliance);
    return SectionCard(
      eyebrow: 'WHERE TO RECORD',
      trailing: locked
          ? Text(
              'Locked while recording',
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SourceGroup(
            options: <SourceOption>[
              ...(_isMobile ? _mobileOptions(locked) : _desktopOptions(locked)),
              if (desks.isNotEmpty) _deskOption(locked, desks.first),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Only the chosen source explains itself. Showing every source's
          // controls at once was what made this page feel like two products in
          // one card, and it put the same device in front of people twice.
          _sourceDetail(palette, locked, desks),
        ],
      ),
    );
  }

  SourceOption _deskOption(bool locked, ApplianceDevice desk) {
    final name = desk['name'];
    return SourceOption(
      icon: Icons.speaker_group_outlined,
      label: name is String && name.trim().isNotEmpty ? name : 'NeoRecall Desk',
      description: 'Records the room on its own',
      selected: _source == _CaptureSource.desk,
      onTap: locked ? null : () => _select(_CaptureSource.desk),
    );
  }

  Widget _sourceDetail(
    NeoRecallPalette palette,
    bool locked,
    List<ApplianceDevice> desks,
  ) {
    switch (_source) {
      case _CaptureSource.phone:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Footnote(
              'Nothing to connect. This app records with the microphone the '
              'phone already uses for calls.',
            ),
            if (desks.isEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              _addDeskAction(palette),
            ],
          ],
        );
      case _CaptureSource.wearable:
        return _wearableDetail(palette, locked, desks);
      case _CaptureSource.desk:
        return _deskDetail();
    }
  }

  Widget _wearableDetail(
    NeoRecallPalette palette,
    bool locked,
    List<ApplianceDevice> desks,
  ) {
    final controller = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _deviceStatusLine(palette),
        const SizedBox(height: AppSpacing.sm + 2),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: locked || controller.scanningWearables ? null : _scan,
              icon: controller.scanningWearables
                  ? const ButtonSpinner()
                  : const Icon(Icons.bluetooth_searching, size: 18),
              label: Text(
                controller.scanningWearables ? 'Scanning…' : 'Scan for wearables',
              ),
            ),
            if (controller.deviceStorageSyncAvailable)
              OutlinedButton.icon(
                onPressed: controller.deviceStorageSyncing
                    ? null
                    : _syncDeviceStorage,
                icon: controller.deviceStorageSyncing
                    ? const ButtonSpinner()
                    : const Icon(Icons.sync_rounded, size: 18),
                label: Text(
                  controller.deviceStorageSyncing
                      ? 'Syncing…'
                      : 'Sync device recordings',
                ),
              ),
          ],
        ),
        if (controller.discoveredWearables.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          for (final device in controller.discoveredWearables)
            _wearableRow(device),
        ],
        if (kIsWeb) ...<Widget>[
          const SizedBox(height: AppSpacing.sm + 2),
          const Footnote(
            'The browser opens its Bluetooth chooser from the scan button. '
            'Capture continues only while this web app remains active.',
          ),
        ],
        if (desks.isEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          _addDeskAction(palette),
        ],
      ],
    );
  }

  Widget _deskDetail() {
    final controller = widget.controller;
    final appliance = controller.appliance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ApplianceCaptureSection(
          controller: appliance,
          devices: controller.devices,
          onAdd: _addDesk,
        ),
        // Only when recordings are genuinely stuck: the Desk has audio and no
        // network to send it with. This is the same sweep the wearables use —
        // pull over Bluetooth, store on the phone, upload per the app's own
        // settings — so there is nothing new for the user to learn here.
        if (appliance.hasStrandedRecordings) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          InlineMessage(
            icon: Icons.cloud_off_rounded,
            message:
                'The device has recordings but no Wi-Fi. You can move them '
                'to this phone over Bluetooth; they upload from here later.',
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: controller.deviceStorageSyncing
                  ? null
                  : _syncDeviceStorage,
              icon: controller.deviceStorageSyncing
                  ? const ButtonSpinner()
                  : const Icon(Icons.download_rounded, size: 18),
              label: Text(
                controller.deviceStorageSyncing
                    ? 'Moving recordings…'
                    : 'Move recordings to this phone',
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// One quiet line, not a block: somebody without a Desk should not have a
  /// second product advertised at them every time they open this page.
  Widget _addDeskAction(NeoRecallPalette palette) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      key: const ValueKey<String>('add-neorecall-desk'),
      onPressed: _addDesk,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text('Set up a NeoRecall Desk'),
      style: TextButton.styleFrom(foregroundColor: palette.accent),
    ),
  );

  /// Long-press opens device & sync diagnostics. Deliberately unadvertised:
  /// this stays a consumer product, so the troubleshooting surface has no
  /// visible affordance and is only reached when support asks for it.
  Widget _deviceStatusLine(NeoRecallPalette palette) {
    final controller = widget.controller;
    final linked = controller.preferredDeviceLabel != null;
    final connected = linked && controller.deviceConnected;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () {
        HapticFeedback.mediumImpact();
        showDeviceDiagnosticsSheet(context, controller);
      },
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: StatusDot(
              color: connected
                  ? palette.success
                  : linked
                  ? palette.accentHover
                  : palette.textMuted,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              controller.preferredDeviceLabel == null
                  ? 'Connect a supported wearable before starting this source.'
                  : 'Preferred device: ${controller.preferredDeviceLabel}',
              style: TextStyle(color: palette.textSecondary, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wearableRow(AudioDeviceDescriptor device) {
    final controller = widget.controller;
    final compatibilityUnknown =
        device.metadata['compatibilityUnknown'] == true;
    // "Preferred" = this is the saved device; "connected" = it is actually
    // linked right now. Only the latter shows a connected indicator, so this
    // never contradicts the sync card (which also keys off the live connection
    // state).
    final preferred = controller.preferredDeviceLabel == device.displayName;
    final connected = preferred && controller.deviceConnected;
    final type = device.metadata['type'] ?? 'wearable';
    return DeviceRow(
      name: device.displayName,
      detail: compatibilityUnknown
          ? 'Compatibility will be checked securely'
          : connected
          ? '$type · Connected'
          : preferred
          ? '$type · Preferred — not connected'
          : '$type · Ready for audio',
      connected: connected,
      batteryLevel: connected ? controller.preferredDeviceBatteryLevel : null,
      actionLabel: compatibilityUnknown
          ? 'Check'
          : preferred
          ? 'Reconnect'
          : 'Connect',
      onAction: controller.isRecording
          ? null
          : () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await controller.preferBluetoothDevice(device);
                if (!mounted) return;
                setState(() {
                  bluetoothPreferred = true;
                  microphone = false;
                  systemAudio = false;
                });
              } catch (error) {
                messenger.showSnackBar(
                  SnackBar(content: Text(error.toString())),
                );
              }
            },
    );
  }

  List<SourceOption> _desktopOptions(bool locked) => <SourceOption>[
    SourceOption(
      icon: Icons.mic_none_rounded,
      label: 'Microphone',
      description: 'Built-in or connected input',
      selected: _source == _CaptureSource.phone && microphone,
      onTap: locked
          ? null
          : () {
              final bool next = !(microphone && _source == _CaptureSource.phone);
              _select(_CaptureSource.phone);
              setState(() => microphone = next);
            },
    ),
    SourceOption(
      icon: _isDesktop
          ? Icons.desktop_windows_outlined
          : Icons.headphones_outlined,
      label: _isDesktop ? 'Device audio' : 'Tab/system audio',
      description: _isDesktop
          ? 'Everything this machine plays'
          : 'Audio from the shared tab',
      selected: _source == _CaptureSource.phone && systemAudio,
      onTap: locked
          ? null
          : () {
              final bool next = !(systemAudio && _source == _CaptureSource.phone);
              _select(_CaptureSource.phone);
              setState(() => systemAudio = next);
            },
    ),
    SourceOption(
      icon: Icons.bluetooth_connected,
      label: 'Wearable',
      description: 'Streams audio into this app',
      selected: _source == _CaptureSource.wearable,
      onTap: locked ? null : () => _select(_CaptureSource.wearable),
    ),
  ];

  List<SourceOption> _mobileOptions(bool locked) => <SourceOption>[
    SourceOption(
      icon: Icons.mic_none_rounded,
      label: 'Phone microphone',
      description: 'Always available, nothing to connect',
      selected: _source == _CaptureSource.phone,
      onTap: locked ? null : () => _select(_CaptureSource.phone),
    ),
    SourceOption(
      icon: Icons.bluetooth_connected,
      label: 'Wearable',
      description: 'Streams audio into this app',
      selected: _source == _CaptureSource.wearable,
      onTap: locked ? null : () => _select(_CaptureSource.wearable),
    ),
  ];
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
                eyebrow: 'LIVE CAPTURE',
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
    return GlassSurface(
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

    return GlassSurface(
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
