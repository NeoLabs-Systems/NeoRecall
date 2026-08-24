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
    required this.onDismissMeeting,
    this.meetingActivity,
    this.meetingEnded = false,
  });

  final NeoRecallController controller;
  final MeetingActivity? meetingActivity;
  final bool meetingEnded;
  final VoidCallback onOpenLibrary;
  final VoidCallback onHide;
  final VoidCallback onDismissMeeting;

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
    final accepted =
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
              'Tell everyone that NeoRecall is recording and make sure you are '
              'allowed to capture the conversation. Recording is always visibly '
              'indicated.',
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
      return widget.meetingEnded
          ? 'Meeting ended?'
          : 'Listening in the background';
    }
    final activity = widget.meetingActivity;
    if (activity != null) return '${activity.application} meeting detected';
    return 'Ready when the conversation starts';
  }

  String get _supportingText {
    final issue = _operationError ?? widget.controller.warning;
    if (issue?.trim().isNotEmpty == true) return issue!.trim();
    if (widget.controller.isRecording) {
      return widget.meetingEnded
          ? 'Stop when everyone is done. Your audio stays queued until its transcript is safely persisted.'
          : '$_activeSourceLabel · private, visible capture';
    }
    if (widget.meetingActivity != null) {
      return 'Capture both sides without adding a bot to the call.';
    }
    return 'NeoRecall is watching for meeting apps.';
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

  List<Widget> _sourceBadges(bool recording) {
    final capability = widget.controller.capability;
    final showMicrophone = !recording || capability?.microphone == true;
    final showSystemAudio = !recording || capability?.systemAudio == true;
    return <Widget>[
      if (showMicrophone)
        const _SourceBadge(icon: Icons.mic_none_rounded, label: 'Mic'),
      if (showMicrophone && showSystemAudio) const SizedBox(width: 6),
      if (showSystemAudio)
        const _SourceBadge(
          icon: Icons.volume_up_outlined,
          label: 'Device audio',
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final palette = neoRecallPaletteOf(context);
    final recording = controller.isRecording;
    final attention = widget.meetingEnded || widget.meetingActivity != null;
    final tint = recording ? palette.secondary : palette.accent;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: const EdgeInsets.all(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.bgCard,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: palette.borderLight),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Column(
              children: <Widget>[
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => windowManager.startDragging(),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
                    child: Row(
                      children: <Widget>[
                        const BrandLockup(logoSize: 24),
                        const Spacer(),
                        _WindowAction(
                          tooltip: 'Open notes library',
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
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                    child: Column(
                      children: <Widget>[
                        Expanded(
                          child: Row(
                            children: <Widget>[
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 220),
                                width: 76,
                                height: 58,
                                decoration: BoxDecoration(
                                  color: tint.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: CustomPaint(
                                  painter: _WaveformPainter(
                                    level: recording
                                        ? controller.audioLevel
                                        : 0.08,
                                    color: tint,
                                    active: recording,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 13),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Row(
                                      children: <Widget>[
                                        if (recording)
                                          Container(
                                            width: 7,
                                            height: 7,
                                            margin: const EdgeInsets.only(
                                              right: 7,
                                            ),
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
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: -0.3,
                                            ),
                                          ),
                                        ),
                                        if (recording)
                                          Text(
                                            _elapsed,
                                            style: TextStyle(
                                              color: palette.textPrimary,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                              fontFeatures: const <FontFeature>[
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      _supportingText,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: _operationError != null
                                            ? palette.secondary
                                            : palette.textMuted,
                                        fontSize: 11.5,
                                        height: 1.3,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (attention && !recording)
                                IconButton(
                                  tooltip: 'Dismiss',
                                  onPressed: widget.onDismissMeeting,
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 17,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Row(
                          children: <Widget>[
                            ..._sourceBadges(recording),
                            const Spacer(),
                            SizedBox(
                              width: 150,
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: recording
                                      ? palette.secondary
                                      : palette.textPrimary,
                                  foregroundColor: palette.bgCard,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 12,
                                  ),
                                ),
                                onPressed: _changingRecordingState
                                    ? null
                                    : _toggleRecording,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: <Widget>[
                                    if (_changingRecordingState)
                                      const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    else
                                      Icon(
                                        recording
                                            ? Icons.stop_rounded
                                            : Icons.fiber_manual_record_rounded,
                                        size: 17,
                                      ),
                                    const SizedBox(width: 7),
                                    Flexible(
                                      child: Text(
                                        _changingRecordingState
                                            ? recording
                                                  ? 'Finishing…'
                                                  : 'Starting…'
                                            : recording
                                            ? 'Finish'
                                            : widget.meetingActivity != null
                                            ? 'Record meeting'
                                            : 'Record',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
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
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    onPressed: onPressed,
    icon: Icon(icon, size: 17),
  );
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: palette.bgSecondary,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: palette.textMuted),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
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
