import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_theme.dart';
import 'src/capture/capture_defaults.dart';
import 'src/desktop/meeting_detector.dart';

class FloatingCaptureWindow extends StatefulWidget {
  const FloatingCaptureWindow({
    super.key,
    required this.controller,
    required this.onOpenLibrary,
    required this.onHide,
    this.onConsentVisibilityChanged,
    this.meetingActivity,
    this.meetingEnded = false,
  });

  final NeoRecallController controller;
  final MeetingActivity? meetingActivity;
  final bool meetingEnded;
  final VoidCallback onOpenLibrary;
  final VoidCallback onHide;
  final Future<void> Function(bool visible)? onConsentVisibilityChanged;

  @override
  State<FloatingCaptureWindow> createState() => _FloatingCaptureWindowState();
}

class _FloatingCaptureWindowState extends State<FloatingCaptureWindow> {
  Timer? _clock;
  late bool _wasRecording;
  bool _changingRecordingState = false;
  String? _operationError;

  @override
  void initState() {
    super.initState();
    _wasRecording = widget.controller.isRecording;
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant FloatingCaptureWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final recording = widget.controller.isRecording;
    if (_wasRecording != recording) {
      _wasRecording = recording;
      _syncClock();
    }
  }

  void _syncClock() {
    _clock?.cancel();
    _clock = widget.controller.isRecording
        ? Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() {});
          })
        : null;
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<bool> _confirmConsent() async {
    if (widget.controller.consentAccepted) return true;
    await widget.onConsentVisibilityChanged?.call(true);
    if (!mounted) {
      await widget.onConsentVisibilityChanged?.call(false);
      return false;
    }
    bool accepted;
    try {
      accepted =
          await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              scrollable: true,
              insetPadding: const EdgeInsets.all(12),
              titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              title: const Text('Before you record'),
              content: const Text(
                'Tell everyone that NeoRecall is recording and make sure you '
                'are allowed to capture the conversation. Recording is always '
                'visibly indicated.',
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
    } finally {
      await widget.onConsentVisibilityChanged?.call(false);
    }
    if (accepted) await widget.controller.acceptConsent();
    return accepted;
  }

  Future<void> _toggleRecording() async {
    if (_changingRecordingState) return;
    setState(() {
      _changingRecordingState = true;
      _operationError = null;
    });
    final controller = widget.controller;
    try {
      if (controller.isRecording) {
        await controller.stopRecording();
        return;
      }
      if (!await _confirmConsent()) return;
      const defaults = CaptureSourceSelection.desktopMeeting();
      await controller.startRecording(
        microphone: defaults.microphone,
        systemAudio: defaults.systemAudio,
        bluetooth: defaults.bluetooth,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _operationError = error.toString());
    } finally {
      if (mounted) setState(() => _changingRecordingState = false);
    }
  }

  String get _elapsed {
    final started = widget.controller.recordingStartedAt;
    if (started == null) return '00:00';
    final raw = DateTime.now().toUtc().difference(started);
    final duration = raw.isNegative ? Duration.zero : raw;
    String two(int value) => value.toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      return '${two(duration.inHours)}:${two(duration.inMinutes.remainder(60))}:'
          '${two(duration.inSeconds.remainder(60))}';
    }
    return '${two(duration.inMinutes)}:'
        '${two(duration.inSeconds.remainder(60))}';
  }

  String get _headline {
    if (widget.controller.isRecording) {
      return widget.meetingEnded ? 'Meeting ended?' : 'Recording';
    }
    final activity = widget.meetingActivity;
    if (activity != null) return '${activity.application} detected';
    return 'Ready to record';
  }

  String get _supportingText {
    final issue = _operationError ?? widget.controller.warning;
    if (issue?.trim().isNotEmpty == true) return issue!.trim();
    if (widget.controller.isRecording) {
      return widget.meetingEnded
          ? 'Finish when everyone is done'
          : _activeSourceLabel;
    }
    if (widget.meetingActivity != null) {
      return 'Mic + device audio ready';
    }
    return 'Mic + device audio · meeting detection on';
  }

  String get _activeSourceLabel {
    final capability = widget.controller.capability;
    if (capability == null) return 'Starting audio capture';
    if (capability.microphone && capability.systemAudio) {
      return 'Microphone + device audio';
    }
    if (capability.microphone) return 'Microphone';
    if (capability.systemAudio) return 'Device audio';
    return 'Audio capture';
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final palette = neoRecallPaletteOf(context);
    final recording = controller.isRecording;
    final tint = recording ? palette.secondary : palette.accent;
    final issue = _operationError ?? controller.warning;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: const EdgeInsets.all(5),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => windowManager.startDragging(),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.bgCard,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: palette.borderLight),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.20),
                  blurRadius: 18,
                  offset: const Offset(0, 7),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 7, 8),
              child: Row(
                children: <Widget>[
                  const BrandLockup(logoSize: 28, showName: false),
                  const SizedBox(width: 8),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: CustomPaint(
                      painter: _WaveformPainter(
                        level: recording ? controller.audioLevel : 0.12,
                        color: tint,
                        active: recording,
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Tooltip(
                      message: issue?.trim().isNotEmpty == true
                          ? issue!.trim()
                          : _supportingText,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              if (recording)
                                Container(
                                  width: 6,
                                  height: 6,
                                  margin: const EdgeInsets.only(right: 6),
                                  decoration: BoxDecoration(
                                    color: palette.secondary,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              Expanded(
                                child: Text(
                                  _headline,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: palette.textPrimary,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.15,
                                  ),
                                ),
                              ),
                              if (recording)
                                Text(
                                  _elapsed,
                                  style: TextStyle(
                                    color: palette.textSecondary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: const <FontFeature>[
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _supportingText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _operationError != null
                                  ? palette.secondary
                                  : palette.textMuted,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _RecordControl(
                    recording: recording,
                    busy: _changingRecordingState,
                    onPressed: _toggleRecording,
                  ),
                  const SizedBox(width: 4),
                  _WindowAction(
                    tooltip: 'Open library',
                    icon: Icons.open_in_full_rounded,
                    onPressed: widget.onOpenLibrary,
                  ),
                  _WindowAction(
                    tooltip: 'Hide',
                    icon: Icons.close_rounded,
                    onPressed: widget.onHide,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecordControl extends StatelessWidget {
  const _RecordControl({
    required this.recording,
    required this.busy,
    required this.onPressed,
  });

  final bool recording;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Tooltip(
      message: busy
          ? 'Working…'
          : recording
          ? 'Finish recording'
          : 'Record',
      child: SizedBox.square(
        dimension: 42,
        child: FilledButton(
          style: FilledButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
            backgroundColor: recording
                ? palette.secondary
                : palette.textPrimary,
            foregroundColor: palette.bgCard,
          ),
          onPressed: busy ? null : onPressed,
          child: busy
              ? const SizedBox.square(
                  dimension: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  recording
                      ? Icons.stop_rounded
                      : Icons.fiber_manual_record_rounded,
                  size: 18,
                ),
        ),
      ),
    );
  }
}

class _WindowAction extends StatelessWidget {
  const _WindowAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 30,
    child: IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
      icon: Icon(icon, size: 15),
    ),
  );
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.level,
    required this.color,
    required this.active,
  });

  final double level;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    const bars = 13;
    final normalized = level.clamp(0.04, 1).toDouble();
    for (var index = 0; index < bars; index++) {
      final position = index / (bars - 1);
      final shape = 0.22 + 0.78 * math.sin(position * math.pi);
      final variation = 0.66 + 0.34 * math.sin(index * 1.8 + normalized * 5);
      final height =
          size.height * shape * variation * (active ? normalized : 0.32);
      final x = size.width * (index + 1) / (bars + 1);
      final center = size.height / 2;
      canvas.drawLine(
        Offset(x, center - math.max(2, height / 2)),
        Offset(x, center + math.max(2, height / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) =>
      oldDelegate.level != level ||
      oldDelegate.color != color ||
      oldDelegate.active != active;
}
