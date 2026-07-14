import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_theme.dart';

class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key, required this.controller});
  final NeoRecallController controller;
  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  bool microphone = true;
  bool systemAudio = false;

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
    if (widget.controller.isRecording) {
      await widget.controller.stopRecording();
      return;
    }
    if (!await _consent()) return;
    try {
      await widget.controller.startRecording(
        microphone: microphone,
        systemAudio: systemAudio,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
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
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const ScreenHeader(
            eyebrow: 'CAPTURE',
            title: 'Record what matters',
            description:
                'Microphone and optional device audio are chunked into a durable offline queue. Audio leaves this device only for local server transcription.',
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
                    width: 260,
                    child: LinearProgressIndicator(
                      value: controller.audioLevel.clamp(0, 1),
                      minHeight: 7,
                      borderRadius: BorderRadius.circular(8),
                      color: palette.secondary,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  '${(controller.pendingAudioBytes / 1048576).toStringAsFixed(1)} MB awaiting a terminal transcript receipt',
                  style: TextStyle(color: palette.textMuted),
                ),
                const SizedBox(height: 22),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 10,
                  children: <Widget>[
                    FilterChip(
                      selected: microphone,
                      onSelected: controller.isRecording
                          ? null
                          : (value) => setState(() => microphone = value),
                      avatar: const Icon(Icons.mic_outlined),
                      label: const Text('Microphone'),
                    ),
                    FilterChip(
                      selected: systemAudio,
                      onSelected: controller.isRecording
                          ? null
                          : (value) => setState(() => systemAudio = value),
                      avatar: const Icon(Icons.desktop_windows_outlined),
                      label: const Text('Device audio'),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: 260,
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
                    children: <Widget>[
                      const Text(
                        'Import existing audio',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        'WAV, MP3, M4A, and other ffmpeg-supported formats use the same private transcription pipeline.',
                        style: TextStyle(color: palette.textMuted),
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
