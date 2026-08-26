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
import 'src/sync/processing_status.dart';

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
    bluetoothPreferred = defaults.bluetooth;
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

  Future<void> _toggle() async {
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

  String get _headerDescription => _isMobile
      ? 'Mobile capture prefers a connected Bluetooth device and falls back to the phone microphone. Android keeps a foreground service alive while recording.'
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

        final stage = _CaptureStage(
          recording: controller.isRecording,
          level: controller.audioLevel,
          startedAt: controller.recordingStartedAt,
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
    return SectionCard(
      eyebrow: _isMobile ? 'CAPTURE SOURCE' : 'CAPTURE SOURCES',
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
            options: _isMobile
                ? _mobileOptions(locked)
                : _desktopOptions(locked),
          ),
          if (bluetoothPreferred ||
              controller.preferredDeviceLabel != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            _deviceStatusLine(palette),
            const SizedBox(height: AppSpacing.sm + 2),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: locked || controller.scanningWearables
                      ? null
                      : _scan,
                  icon: controller.scanningWearables
                      ? const ButtonSpinner()
                      : const Icon(Icons.bluetooth_searching, size: 18),
                  label: Text(
                    controller.scanningWearables
                        ? 'Scanning…'
                        : 'Scan for wearables',
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
          ],
          if (kIsWeb && bluetoothPreferred) ...<Widget>[
            const SizedBox(height: AppSpacing.sm + 2),
            const Footnote(
              'The browser opens its Bluetooth chooser from the scan button. '
              'Capture continues only while this web app remains active.',
            ),
          ],
        ],
      ),
    );
  }

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
                  ? 'Connect a supported Bluetooth device before starting this source.'
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
      selected: microphone && !bluetoothPreferred,
      onTap: locked
          ? null
          : () => setState(() {
              final next = !(microphone && !bluetoothPreferred);
              microphone = next;
              if (next) bluetoothPreferred = false;
            }),
    ),
    SourceOption(
      icon: _isDesktop
          ? Icons.desktop_windows_outlined
          : Icons.headphones_outlined,
      label: _isDesktop ? 'Device audio' : 'Tab/system audio',
      description: _isDesktop
          ? 'Everything this machine plays'
          : 'Audio from the shared tab',
      selected: systemAudio && !bluetoothPreferred,
      onTap: locked
          ? null
          : () => setState(() {
              final next = !(systemAudio && !bluetoothPreferred);
              systemAudio = next;
              if (next) bluetoothPreferred = false;
            }),
    ),
    SourceOption(
      icon: Icons.bluetooth_connected,
      label: 'Bluetooth device',
      description: 'Stream from a paired wearable',
      selected: bluetoothPreferred,
      onTap: locked
          ? null
          : () => setState(() {
              final next = !bluetoothPreferred;
              bluetoothPreferred = next;
              if (next) {
                microphone = false;
                systemAudio = false;
              }
            }),
    ),
  ];

  List<SourceOption> _mobileOptions(bool locked) => <SourceOption>[
    SourceOption(
      icon: Icons.bluetooth_connected,
      label: 'Bluetooth device',
      description: 'Preferred when a wearable is linked',
      selected: bluetoothPreferred,
      onTap: locked
          ? null
          : () {
              setState(() {
                bluetoothPreferred = true;
                microphone = false;
                systemAudio = false;
              });
              unawaited(widget.controller.setPreferBluetoothCapture(true));
            },
    ),
    SourceOption(
      icon: Icons.mic_none_rounded,
      label: 'Phone microphone',
      description: 'Always-available fallback',
      selected: !bluetoothPreferred,
      onTap: locked
          ? null
          : () {
              setState(() {
                bluetoothPreferred = false;
                microphone = true;
                systemAudio = false;
              });
              // Source selection is an immediate runtime preference, not just
              // a choice deferred until Record is pressed. This stops an idle
              // wearable reconnect (and its status UI) while phone capture is
              // selected.
              unawaited(widget.controller.setPreferBluetoothCapture(false));
            },
    ),
  ];
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

