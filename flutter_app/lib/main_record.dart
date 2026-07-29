import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
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
