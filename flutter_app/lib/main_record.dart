import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_theme.dart';

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
    bluetoothPreferred = _isMobile && widget.controller.preferBluetoothCapture;
    if (_isMobile) {
      systemAudio = false;
      microphone = !bluetoothPreferred;
    }
  }

  String _elapsed() {
    final started = widget.controller.recordingStartedAt;
    if (started == null) return '00:00:00';
    final duration = DateTime.now().toUtc().difference(started);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(duration.inHours)}:${two(duration.inMinutes.remainder(60))}:${two(duration.inSeconds.remainder(60))}';
  }

  Future<bool> _consent() async {
    if (widget.controller.consentAccepted) return true;
    final accepted =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
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
      await controller.stopRecording();
      return;
    }
    if (!await _consent()) return;
    try {
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

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final palette = neoRecallPaletteOf(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ScreenHeader(
            eyebrow: 'CAPTURE',
            title: 'Record what matters',
            description: _isMobile
                ? 'Mobile capture prefers a connected Bluetooth device and falls back to the phone microphone. Android keeps a foreground service alive while recording.'
                : _isDesktop
                ? 'Desktop can capture microphone and system audio together. Permissions are requested up front and recording stays visibly active.'
                : 'Browser capture supports microphone and optional tab/system audio through the browser permission flow.',
          ),
          const SizedBox(height: 24),
          if (controller.warning != null) ...<Widget>[
            InlineMessage(
              message: controller.warning!,
              icon: Icons.warning_amber_rounded,
            ),
            const SizedBox(height: 16),
          ],
          if (controller.error != null) ...<Widget>[
            InlineMessage(message: controller.error!, error: true),
            const SizedBox(height: 16),
          ],
          if (!controller.online) ...<Widget>[
            const InlineMessage(
              message:
                  'You are offline. Capture continues locally and queued audio uploads automatically when the connection returns.',
              icon: Icons.cloud_off_rounded,
            ),
            const SizedBox(height: 16),
          ],
          if (controller.needsAttentionCount > 0) ...<Widget>[
            _NeedsAttentionBanner(controller: controller),
            const SizedBox(height: 16),
          ],
          if (controller.preferredDeviceIsOfflineFirst) ...<Widget>[
            _OfflineDeviceSyncCard(controller: controller),
            const SizedBox(height: 16),
          ],
          GlassSurface(
            child: Column(
              children: <Widget>[
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: 156,
                  height: 156,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        (controller.isRecording
                                ? palette.secondary
                                : palette.surfaceMuted)
                            .withValues(alpha: .18),
                    border: Border.all(
                      color: controller.isRecording
                          ? palette.secondary
                          : palette.borderStrong,
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    controller.isRecording
                        ? Icons.graphic_eq_rounded
                        : Icons.mic_none_rounded,
                    size: 62,
                    color: controller.isRecording
                        ? palette.secondary
                        : palette.textMuted,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  controller.isRecording
                      ? 'Recording is visible and active'
                      : 'Ready to record',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (controller.isRecording) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    _elapsed(),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: 320,
                    child: LinearProgressIndicator(
                      value: controller.audioLevel.clamp(0, 1),
                      minHeight: 10,
                      borderRadius: BorderRadius.circular(10),
                      color: palette.secondary,
                      backgroundColor: palette.border,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  '${(controller.pendingAudioBytes / 1048576).toStringAsFixed(1)} MB awaiting a terminal transcript receipt',
                  style: TextStyle(color: palette.textMuted),
                ),
                const SizedBox(height: 22),
                Text(
                  _isMobile ? 'CAPTURE SOURCE' : 'CAPTURE SOURCES',
                  style: sectionEyebrowStyle(palette),
                ),
                const SizedBox(height: 10),
                if (!_isMobile)
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 10,
                    children: <Widget>[
                      FilterChip(
                        selected: microphone && !bluetoothPreferred,
                        onSelected: controller.isRecording
                            ? null
                            : (value) => setState(() {
                                microphone = value;
                                if (value) bluetoothPreferred = false;
                              }),
                        avatar: const Icon(Icons.mic_outlined),
                        label: const Text('Microphone'),
                      ),
                      FilterChip(
                        selected: systemAudio && !bluetoothPreferred,
                        onSelected: controller.isRecording
                            ? null
                            : (value) => setState(() {
                                systemAudio = value;
                                if (value) bluetoothPreferred = false;
                              }),
                        avatar: Icon(
                          _isDesktop
                              ? Icons.desktop_windows_outlined
                              : Icons.headphones_outlined,
                        ),
                        label: Text(
                          _isDesktop ? 'Device audio' : 'Tab/system audio',
                        ),
                      ),
                      FilterChip(
                        selected: bluetoothPreferred,
                        onSelected: controller.isRecording
                            ? null
                            : (value) => setState(() {
                                bluetoothPreferred = value;
                                if (value) {
                                  microphone = false;
                                  systemAudio = false;
                                }
                              }),
                        avatar: const Icon(Icons.bluetooth_connected),
                        label: const Text('Bluetooth device'),
                      ),
                    ],
                  )
                else
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 10,
                    children: <Widget>[
                      ChoiceChip(
                        selected: bluetoothPreferred,
                        onSelected: controller.isRecording
                            ? null
                            : (value) => setState(() {
                                bluetoothPreferred = true;
                                microphone = false;
                                systemAudio = false;
                              }),
                        avatar: const Icon(Icons.bluetooth_connected),
                        label: const Text('Bluetooth device'),
                      ),
                      ChoiceChip(
                        selected: !bluetoothPreferred,
                        onSelected: controller.isRecording
                            ? null
                            : (value) => setState(() {
                                bluetoothPreferred = false;
                                microphone = true;
                                systemAudio = false;
                              }),
                        avatar: const Icon(Icons.mic_none_rounded),
                        label: const Text('Phone microphone'),
                      ),
                    ],
                  ),
                if (bluetoothPreferred ||
                    controller.preferredDeviceLabel != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    controller.preferredDeviceLabel == null
                        ? 'Connect a supported Bluetooth device before starting this source.'
                        : 'Preferred device: ${controller.preferredDeviceLabel}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: palette.textSecondary,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 10,
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed:
                            controller.isRecording ||
                                controller.scanningWearables
                            ? null
                            : () async {
                                final messenger = ScaffoldMessenger.of(context);
                                try {
                                  await controller.scanForWearables();
                                } catch (error) {
                                  messenger.showSnackBar(
                                    SnackBar(content: Text(error.toString())),
                                  );
                                }
                              },
                        icon: controller.scanningWearables
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.bluetooth_searching),
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
                              : () => controller.syncDeviceStorage(),
                          icon: controller.deviceStorageSyncing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.sync_rounded),
                          label: Text(
                            controller.deviceStorageSyncing
                                ? 'Syncing…'
                                : 'Sync device recordings',
                          ),
                        ),
                    ],
                  ),
                  if (controller.discoveredWearables.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 14),
                    ...controller.discoveredWearables.map((device) {
                      final compatibilityUnknown =
                          device.metadata['compatibilityUnknown'] == true;
                      final selected =
                          controller.preferredDeviceLabel == device.displayName;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          selected
                              ? Icons.bluetooth_connected
                              : Icons.bluetooth,
                          color: selected
                              ? palette.accentHover
                              : palette.textSecondary,
                        ),
                        title: Text(device.displayName),
                        subtitle: Text(
                          compatibilityUnknown
                              ? 'Compatibility will be checked securely'
                              : '${device.metadata['type'] ?? 'wearable'} · Ready for audio',
                        ),
                        trailing: selected
                            ? const Icon(Icons.check_circle, size: 18)
                            : TextButton(
                                onPressed: controller.isRecording
                                    ? null
                                    : () async {
                                        final messenger = ScaffoldMessenger.of(
                                          context,
                                        );
                                        try {
                                          await controller
                                              .preferBluetoothDevice(device);
                                          if (!mounted) return;
                                          setState(() {
                                            bluetoothPreferred = true;
                                            microphone = false;
                                            systemAudio = false;
                                          });
                                        } catch (error) {
                                          messenger.showSnackBar(
                                            SnackBar(
                                              content: Text(error.toString()),
                                            ),
                                          );
                                        }
                                      },
                                child: Text(
                                  compatibilityUnknown ? 'Check' : 'Connect',
                                ),
                              ),
                      );
                    }),
                  ],
                ],
                if (kIsWeb && bluetoothPreferred) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    'The browser opens its Bluetooth chooser from the scan button. Capture continues only while this web app remains active.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: palette.textMuted, height: 1.4),
                  ),
                ],
                // Offline-first wearables (HeyPocket, Limitless, Plaud) record on
                // the device itself and cannot live-stream, so the live record
                // button is hidden when such a device is the chosen source — sync
                // (the card above) is the only capture path. The Stop button is
                // always kept while a recording is somehow active.
                if (controller.isRecording ||
                    !(bluetoothPreferred &&
                        controller.preferredDeviceIsOfflineFirst)) ...<Widget>[
                  const SizedBox(height: 22),
                  SizedBox(
                    width: 280,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: controller.isRecording
                            ? palette.secondary
                            : palette.accent,
                      ),
                      onPressed: _toggle,
                      icon: Icon(
                        controller.isRecording
                            ? Icons.stop_rounded
                            : Icons.fiber_manual_record_rounded,
                      ),
                      label: Text(
                        controller.isRecording
                            ? 'Stop and finalize'
                            : 'Start recording',
                      ),
                    ),
                  ),
                ] else ...<Widget>[
                  const SizedBox(height: 18),
                  Text(
                    'This device records by itself — there is no live capture. '
                    'Use “Sync device recordings” above to pull and transcribe them.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: palette.textMuted, height: 1.4),
                  ),
                ],
                if (_isDesktop) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    'System audio uses the OS screen-recording permission and captures audio only, not video frames.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: palette.textMuted, height: 1.4),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          GlassSurface(
            child: Row(
              children: <Widget>[
                const Icon(Icons.upload_file_outlined),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const <Widget>[
                      Text(
                        'Import existing audio',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        'WAV, MP3, M4A, and other ffmpeg-supported formats use the same private transcription pipeline.',
                      ),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: controller.loading ? null : _import,
                  child: const Text('Choose audio'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const InlineMessage(
            message:
                'Recording privately spoken words may require everyone’s consent. NeoRecall never hides its recording state and does not determine whether a recording is lawful.',
          ),
        ],
      ),
    );
  }
}

/// Surfaces chunks the server could not transcribe after repeated attempts, with
/// an explicit retry so a stuck queue is visible and recoverable rather than
/// silently retaining local audio forever.
class _NeedsAttentionBanner extends StatefulWidget {
  const _NeedsAttentionBanner({required this.controller});
  final NeoRecallController controller;
  @override
  State<_NeedsAttentionBanner> createState() => _NeedsAttentionBannerState();
}

class _NeedsAttentionBannerState extends State<_NeedsAttentionBanner> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await widget.controller.retryFailedUploads();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final count = widget.controller.needsAttentionCount;
    final color = palette.danger;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.input),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.sync_problem_rounded, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              count == 1
                  ? '1 recording could not be transcribed after repeated attempts. Its audio is kept locally until you retry.'
                  : '$count recordings could not be transcribed after repeated attempts. Their audio is kept locally until you retry.',
              style: TextStyle(color: palette.textSecondary, height: 1.4),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: _retrying ? null : _retry,
            child: _retrying
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

/// Primary "sync" affordance for offline-first wearables (HeyPocket, Limitless,
/// Plaud): these record on the device itself, so pulling those recordings — not
/// live capture — is the main action. Recordings also sync automatically on
/// connect; this makes the manual path obvious and explains the model.
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
      await widget.controller.syncDeviceStorage();
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
        borderRadius: BorderRadius.circular(AppRadius.input),
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
          const SizedBox(height: 14),
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
        ],
      ),
    );
  }
}
