import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../main_theme.dart';

/// Circular level meter. The ring segments are driven by the rolling history, so
/// the orb literally draws the last few seconds of audio; idle falls back to a
/// static resting profile rather than a dead circle.
class CaptureOrb extends StatelessWidget {
  /// Ring positions around the orb. Also the length of the level history the
  /// caller feeds in, which is why it lives with the painter that consumes it
  /// rather than with the widget that samples audio.
  static const int ticks = 64;

  const CaptureOrb({
    super.key,
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

    for (var index = 0; index < CaptureOrb.ticks; index += 1) {
      final angle = -math.pi / 2 + index * 2 * math.pi / CaptureOrb.ticks;
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
    final offset = CaptureOrb.ticks - history.length;
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

/// Capture state: a coloured dot, optionally pulsing, beside a short label.
