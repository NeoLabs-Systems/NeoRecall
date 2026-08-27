import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../main_shared.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';

class CaptureStatusPill extends StatelessWidget {
  const CaptureStatusPill({
    super.key,
    required this.tint,
    required this.label,
    this.pulse,
  });

  final Color tint;
  final String label;
  final Animation<double>? pulse;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final animation = pulse;
    final dot = StatusDot(color: tint, size: 8);
    return TintedSurface(
      tint: tint,
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

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 7});

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

class RecordButton extends StatelessWidget {
  const RecordButton({
    super.key,
    required this.recording,
    required this.onPressed,
  });

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
class Footnote extends StatelessWidget {
  const Footnote(this.text, {super.key, this.center = false});

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

class ButtonSpinner extends StatelessWidget {
  const ButtonSpinner({super.key});

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
