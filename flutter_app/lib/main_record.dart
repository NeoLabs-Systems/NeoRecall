import 'dart:async';
import 'dart:math' as math;

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
            _OfflineDeviceSyncCard(controller: controller),
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
                  _ImportCard(
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
          _SourceGroup(
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
                      ? const _ButtonSpinner()
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
                        ? const _ButtonSpinner()
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
            const _Footnote(
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
            child: _StatusDot(
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
    return _DeviceRow(
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

  List<_SourceOption> _desktopOptions(bool locked) => <_SourceOption>[
    _SourceOption(
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
    _SourceOption(
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
    _SourceOption(
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

  List<_SourceOption> _mobileOptions(bool locked) => <_SourceOption>[
    _SourceOption(
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
    _SourceOption(
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
  static const int ticks = 64;
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
        if (_history.length > ticks) _history.removeAt(0);
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
            builder: (context, _) => _CaptureOrb(
              recording: recording,
              level: widget.level,
              phase: _pulse.value,
              history: _history,
              revision: _revision,
              palette: palette,
            ),
          ),
          const SizedBox(height: AppSpacing.lg - 4),
          _StatusPill(
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
            _RecordButton(recording: recording, onPressed: widget.onToggle),
            const SizedBox(height: AppSpacing.md),
          ],
          _ProcessingStatusPanel(
            status: widget.processing,
            onRetry: widget.onRetry,
            onUploadWithMobileData: widget.onUploadWithMobileData,
            onReview: widget.onReview,
          ),
          if (widget.footnote != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            _Footnote(widget.footnote!, center: true),
          ],
        ],
      ),
    );
  }
}

class _ProcessingStatusPanel extends StatefulWidget {
  const _ProcessingStatusPanel({
    required this.status,
    required this.onRetry,
    required this.onUploadWithMobileData,
    required this.onReview,
  });

  final ProcessingStatusSnapshot status;
  final Future<void> Function() onRetry;
  final Future<void> Function() onUploadWithMobileData;
  final VoidCallback onReview;

  @override
  State<_ProcessingStatusPanel> createState() => _ProcessingStatusPanelState();
}

class _ProcessingStatusPanelState extends State<_ProcessingStatusPanel> {
  bool _expanded = false;
  bool _retrying = false;
  bool _uploadingWithMobileData = false;

  String _eta(Duration duration) {
    if (duration.inSeconds < 45) return 'under a minute';
    if (duration.inMinutes < 60) {
      return 'about ${(duration.inSeconds / 60).ceil()} min';
    }
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    return minutes < 10 ? 'about $hours hr' : 'about $hours hr $minutes min';
  }

  String _headline(ProcessingStatusSnapshot status) {
    if (status.hasIssues &&
        status.activeStage == ProcessingPipelineStage.phoneQueue) {
      return 'Processing needs attention';
    }
    return switch (status.activeStage) {
      ProcessingPipelineStage.watchTransfer => 'Downloading from watch',
      ProcessingPipelineStage.phoneQueue => 'Queued securely on this device',
      ProcessingPipelineStage.upload => 'Uploading to server',
      ProcessingPipelineStage.serverQueue => 'Waiting in transcription queue',
      ProcessingPipelineStage.transcription => 'Transcribing on server',
      ProcessingPipelineStage.finalizing => 'Finalizing secure receipts',
      ProcessingPipelineStage.complete => 'Everything is processed',
    };
  }

  IconData _icon(ProcessingStatusSnapshot status) {
    if (status.hasIssues) return Icons.sync_problem_rounded;
    return switch (status.activeStage) {
      ProcessingPipelineStage.watchTransfer => Icons.watch_rounded,
      ProcessingPipelineStage.phoneQueue => Icons.phone_android_rounded,
      ProcessingPipelineStage.upload => Icons.cloud_upload_rounded,
      ProcessingPipelineStage.serverQueue => Icons.hourglass_top_rounded,
      ProcessingPipelineStage.transcription => Icons.graphic_eq_rounded,
      ProcessingPipelineStage.finalizing => Icons.verified_user_outlined,
      ProcessingPipelineStage.complete => Icons.verified_rounded,
    };
  }

  List<_ProcessingStepData> _steps(ProcessingStatusSnapshot status) {
    final watchDetail = status.watchPendingSeconds > 0
        ? '${_shortDuration(Duration(seconds: status.watchPendingSeconds))} of audio waiting'
        : status.watchTransferActive
        ? 'Receiving encrypted audio'
        : status.watchPending > 0
        ? '${status.watchPending} item${status.watchPending == 1 ? '' : 's'} waiting'
        : 'No watch backlog';
    final serverTotal = status.serverQueued + status.transcribing;
    return <_ProcessingStepData>[
      _ProcessingStepData(
        icon: Icons.watch_rounded,
        title: 'Watch transfer',
        detail: watchDetail,
        count: status.watchPending,
        active: status.watchTransferActive || status.watchPending > 0,
        fraction: status.watchFraction,
      ),
      _ProcessingStepData(
        icon: Icons.phone_android_rounded,
        title: 'Stored on phone',
        detail: status.phoneQueued == 0
            ? 'No recordings waiting locally'
            : '${status.phoneQueued} ready for upload',
        count: status.phoneQueued,
        active: status.phoneQueued > 0,
      ),
      _ProcessingStepData(
        icon: Icons.cloud_upload_rounded,
        title: 'Server upload',
        detail: status.uploading == 0
            ? 'No upload currently in flight'
            : '${status.uploading} uploading now',
        count: status.uploading,
        active: status.uploading > 0,
      ),
      _ProcessingStepData(
        icon: Icons.graphic_eq_rounded,
        title: 'Server transcription',
        detail: status.transcribing > 0
            ? '${status.transcribing} transcribing · ${status.serverQueued} queued'
            : serverTotal > 0
            ? '$serverTotal waiting for a worker'
            : 'Server queue is clear',
        count: serverTotal,
        active: serverTotal > 0,
      ),
      _ProcessingStepData(
        icon: Icons.verified_user_outlined,
        title: 'Safe completion',
        detail: status.complete
            ? 'Transcript persisted; audio released'
            : status.finalizing > 0
            ? '${status.finalizing} verifying persistence and deletion'
            : 'Waiting for earlier stages',
        count: status.finalizing,
        active: status.finalizing > 0,
        complete: status.complete,
      ),
    ];
  }

  String _shortDuration(Duration duration) {
    if (duration.inMinutes < 1) return '${duration.inSeconds}s';
    if (duration.inHours < 1) return '${duration.inMinutes}m';
    return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
  }

  String _audioDuration(Duration duration) {
    if (duration.inMinutes < 1) return '${duration.inSeconds}s audio';
    if (duration.inHours < 1) {
      final seconds = duration.inSeconds.remainder(60);
      return seconds == 0
          ? '${duration.inMinutes}m audio'
          : '${duration.inMinutes}m ${seconds}s audio';
    }
    final minutes = duration.inMinutes.remainder(60);
    return minutes == 0
        ? '${duration.inHours}h audio'
        : '${duration.inHours}h ${minutes}m audio';
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _uploadWithMobileData() async {
    setState(() => _uploadingWithMobileData = true);
    try {
      await widget.onUploadWithMobileData();
    } finally {
      if (mounted) setState(() => _uploadingWithMobileData = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final status = widget.status;
    final color = status.hasIssues
        ? palette.warning
        : status.complete
        ? palette.success
        : palette.accent;
    final facts = <String>[
      if (status.totalPending + status.watchPending > 0)
        '${status.totalPending + status.watchPending} pending',
      if (status.totalAudioDuration > Duration.zero)
        _audioDuration(status.totalAudioDuration),
      if (status.pendingBytes > 0)
        '${(status.pendingBytes / 1048576).toStringAsFixed(1)} MB protected',
      if (status.eta != null) 'ETA ${_eta(status.eta!)}',
      if (status.eta == null && status.etaCalibrating) 'ETA calibrating',
    ];
    final steps = _steps(status);

    return Semantics(
      button: true,
      expanded: _expanded,
      label: '${_headline(status)}. ${facts.join(', ')}',
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.075),
          borderRadius: BorderRadius.circular(AppRadius.input),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Column(
          children: <Widget>[
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.input),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(13, 12, 10, 11),
                child: Column(
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.14),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(_icon(status), size: 19, color: color),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                _headline(status),
                                style: TextStyle(
                                  color: palette.textPrimary,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (facts.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 2),
                                Text(
                                  facts.join(' · '),
                                  style: TextStyle(
                                    color: palette.textMuted,
                                    fontSize: 11.5,
                                    height: 1.3,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Icon(
                          _expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          color: palette.textMuted,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        for (
                          var index = 0;
                          index < steps.length;
                          index++
                        ) ...<Widget>[
                          Expanded(
                            child: Tooltip(
                              message: steps[index].title,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 220),
                                height: 4,
                                decoration: BoxDecoration(
                                  color: steps[index].complete
                                      ? palette.success
                                      : steps[index].active
                                      ? color
                                      : palette.border,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                          if (index != steps.length - 1)
                            const SizedBox(width: 4),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (status.waitingForUnmeteredNetwork)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey<String>('upload-with-mobile-data'),
                    onPressed: _uploadingWithMobileData
                        ? null
                        : _uploadWithMobileData,
                    icon: _uploadingWithMobileData
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_cell_rounded, size: 18),
                    label: const Text('Upload once with mobile data'),
                  ),
                ),
              ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 180),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  children: <Widget>[
                    Divider(height: 1, color: palette.border),
                    const SizedBox(height: 6),
                    for (final step in steps)
                      _ProcessingStep(step: step, tint: color),
                    if (status.totalPending > 0) ...<Widget>[
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          key: const ValueKey<String>('pending-audio-review'),
                          onPressed: widget.onReview,
                          icon: const Icon(Icons.headphones_rounded, size: 18),
                          label: const Text('Review queued audio'),
                        ),
                      ),
                    ],
                    if (status.issues.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 7),
                      for (final issue in status.issues)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Icon(
                                Icons.info_outline_rounded,
                                size: 16,
                                color: palette.warning,
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  issue.count > 1
                                      ? '${issue.count} recordings · ${issue.message}'
                                      : issue.message,
                                  style: TextStyle(
                                    color: palette.textSecondary,
                                    fontSize: 11.5,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (status.canRetry)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _retrying ? null : _retry,
                            icon: _retrying
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh_rounded, size: 17),
                            label: const Text('Retry failed'),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProcessingStepData {
  const _ProcessingStepData({
    required this.icon,
    required this.title,
    required this.detail,
    required this.count,
    required this.active,
    this.fraction,
    this.complete = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final int count;
  final bool active;
  final double? fraction;
  final bool complete;
}

class _ProcessingStep extends StatelessWidget {
  const _ProcessingStep({required this.step, required this.tint});
  final _ProcessingStepData step;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final color = step.complete
        ? palette.success
        : step.active
        ? tint
        : palette.textMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(width: 25, child: Icon(step.icon, size: 17, color: color)),
          const SizedBox(width: 5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  step.title,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  step.detail,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
                if (step.fraction != null) ...<Widget>[
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: step.fraction,
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(2),
                    backgroundColor: palette.border,
                    color: color,
                  ),
                ],
              ],
            ),
          ),
          if (step.count > 0)
            Container(
              constraints: const BoxConstraints(minWidth: 24),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                '${step.count}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Circular level meter. The ring segments are driven by the rolling history, so
/// the orb literally draws the last few seconds of audio; idle falls back to a
/// static resting profile rather than a dead circle.
class _CaptureOrb extends StatelessWidget {
  const _CaptureOrb({
    required this.recording,
    required this.level,
    required this.phase,
    required this.history,
    required this.revision,
    required this.palette,
  });

  static const double _size = 188;

  final bool recording;
  final double level;
  final double phase;
  final List<double> history;
  final int revision;
  final NeoRecallPalette palette;

  @override
  Widget build(BuildContext context) {
    final tint = recording ? palette.secondary : palette.accent;
    return SizedBox(
      width: _size,
      height: _size,
      child: CustomPaint(
        painter: _OrbPainter(
          recording: recording,
          level: level.clamp(0, 1).toDouble(),
          phase: phase,
          history: history,
          revision: revision,
          tint: tint,
          core: palette.bgCard,
          coreEdge: palette.borderLight,
        ),
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: Icon(
              recording ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
              key: ValueKey<bool>(recording),
              size: 44,
              color: recording ? tint : palette.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  const _OrbPainter({
    required this.recording,
    required this.level,
    required this.phase,
    required this.history,
    required this.revision,
    required this.tint,
    required this.core,
    required this.coreEdge,
  });

  final bool recording;
  final double level;
  final double phase;
  final List<double> history;
  final int revision;
  final Color tint;
  final Color core;
  final Color coreEdge;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    final ringRadius = outer * 0.62;
    final maxTick = outer * 0.32;

    // Ambient glow: the whole orb brightens with the incoming level.
    canvas.drawCircle(
      center,
      outer,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            tint.withValues(alpha: (recording ? 0.20 : 0.09) + 0.20 * level),
            tint.withValues(alpha: 0),
          ],
          stops: const <double>[0.30, 1],
        ).createShader(Rect.fromCircle(center: center, radius: outer)),
    );

    if (recording) {
      for (var index = 0; index < 3; index += 1) {
        final progress = (phase + index / 3) % 1;
        final alpha = (1 - progress) * (0.10 + 0.32 * level);
        if (alpha < 0.012) continue;
        canvas.drawCircle(
          center,
          ringRadius + (outer - ringRadius) * progress,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = tint.withValues(alpha: alpha),
        );
      }
    }

    final strong = recording ? tint : tint.withValues(alpha: 0.42);
    final faded = tint.withValues(alpha: recording ? 0.45 : 0.18);
    final segments = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.8
      ..shader =
          SweepGradient(
            colors: <Color>[strong, faded, strong],
            transform: GradientRotation(phase * 2 * math.pi - math.pi / 2),
          ).createShader(
            Rect.fromCircle(center: center, radius: ringRadius + maxTick),
          );

    for (var index = 0; index < _CaptureStageState.ticks; index += 1) {
      final angle =
          -math.pi / 2 + index * 2 * math.pi / _CaptureStageState.ticks;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + direction * ringRadius,
        center + direction * (ringRadius + maxTick * _segment(index)),
        segments,
      );
    }

    final coreRadius = ringRadius - 11 + (recording ? 4 * level : 0);
    canvas.drawCircle(
      center,
      coreRadius,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            Color.lerp(core, tint, recording ? 0.18 : 0.07)!,
            core,
          ],
        ).createShader(Rect.fromCircle(center: center, radius: coreRadius)),
    );
    canvas.drawCircle(
      center,
      coreRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = recording ? tint.withValues(alpha: 0.5) : coreEdge,
    );
  }

  /// Segment length for ring position [index]: the newest sample sits at the end
  /// of the buffer, so the pattern sweeps around as audio arrives. Positions the
  /// history has not reached yet keep the resting profile, so a recording that
  /// just started shows a complete ring lighting up rather than a half-built one.
  double _segment(int index) {
    final resting = 0.18 + 0.10 * math.sin(index * math.pi / 8);
    if (!recording) return resting;
    final offset = _CaptureStageState.ticks - history.length;
    if (index < offset) return resting;
    return 0.12 + 0.88 * history[index - offset];
  }

  @override
  bool shouldRepaint(covariant _OrbPainter oldDelegate) =>
      oldDelegate.recording != recording ||
      oldDelegate.level != level ||
      oldDelegate.phase != phase ||
      oldDelegate.revision != revision ||
      oldDelegate.tint != tint ||
      oldDelegate.core != core;
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.tint, required this.label, this.pulse});

  final Color tint;
  final String label;
  final Animation<double>? pulse;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final animation = pulse;
    final dot = _StatusDot(color: tint, size: 8);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: tint.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (animation == null)
            dot
          else
            AnimatedBuilder(
              animation: animation,
              builder: (context, child) => Opacity(
                opacity:
                    0.35 +
                    0.65 *
                        (0.5 + 0.5 * math.sin(animation.value * 2 * math.pi)),
                child: child,
              ),
              child: dot,
            ),
          const SizedBox(width: 8),
          Text(
            label,
            style: sectionEyebrowStyle(
              palette,
            ).copyWith(color: tint, fontSize: 10, letterSpacing: 1.9),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color, this.size = 7});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      boxShadow: <BoxShadow>[
        BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 7),
      ],
    ),
  );
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.recording, required this.onPressed});

  final bool recording;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final color = recording ? palette.secondary : palette.accent;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: color.withValues(alpha: 0.32),
              blurRadius: 24,
              offset: const Offset(0, 9),
            ),
          ],
        ),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: color,
              foregroundColor: palette.onAccent,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 17),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
              ),
              textStyle: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.1,
              ),
            ),
            onPressed: onPressed,
            icon: Icon(
              recording
                  ? Icons.stop_rounded
                  : Icons.fiber_manual_record_rounded,
              size: 20,
            ),
            label: Text(recording ? 'Stop and finalize' : 'Start recording'),
          ),
        ),
      ),
    );
  }
}

/// Capture sources as tappable cards rather than bare chips: each one carries a
/// line saying what it actually records, which is the part people get wrong when
/// choosing between a microphone, system audio, and a wearable.
class _SourceGroup extends StatelessWidget {
  const _SourceGroup({required this.options});

  final List<_SourceOption> options;

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

class _SourceOption extends StatelessWidget {
  const _SourceOption({
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

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
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
            _BatteryIndicator(level: batteryLevel!, palette: palette),
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

class _BatteryIndicator extends StatelessWidget {
  const _BatteryIndicator({required this.level, required this.palette});

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

class _ImportCard extends StatelessWidget {
  const _ImportCard({required this.busy, required this.onPressed});

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
          ? const _ButtonSpinner()
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

class _Footnote extends StatelessWidget {
  const _Footnote(this.text, {this.center = false});

  final String text;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final style = TextStyle(
      color: palette.textMuted,
      fontSize: 12.5,
      height: 1.4,
    );
    final align = center ? TextAlign.center : TextAlign.start;
    return Text(text, textAlign: align, style: style);
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 16,
    height: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}

/// Primary "sync" affordance for offline-first wearables (HeyPocket): these
/// record on the device itself, so pulling those recordings — not live capture
/// — is the main action. Recordings also sync automatically on connect; this
/// makes the manual path obvious and explains the model.
class _OfflineDeviceSyncCard extends StatefulWidget {
  const _OfflineDeviceSyncCard({required this.controller});
  final NeoRecallController controller;
  @override
  State<_OfflineDeviceSyncCard> createState() => _OfflineDeviceSyncCardState();
}

class _OfflineDeviceSyncCardState extends State<_OfflineDeviceSyncCard> {
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
