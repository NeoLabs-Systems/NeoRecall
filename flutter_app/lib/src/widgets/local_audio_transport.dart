import 'package:flutter/material.dart';

import '../../main_spacing.dart';
import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';

/// Play, skip, and scrub for a local recording — the same chrome on Moments
/// and on the queued-audio review sheet.
class LocalAudioTransport extends StatelessWidget {
  const LocalAudioTransport({
    super.key,
    required this.playing,
    required this.loading,
    required this.position,
    required this.duration,
    this.scrubMs,
    this.onPlayPause,
    this.onSkipBack,
    this.onSkipForward,
    this.onScrub,
    this.onScrubEnd,
  });

  static const Duration skip = Duration(seconds: 10);

  final bool playing;
  final bool loading;
  final Duration position;
  final Duration duration;
  final double? scrubMs;
  final VoidCallback? onPlayPause;
  final VoidCallback? onSkipBack;
  final VoidCallback? onSkipForward;
  final ValueChanged<double>? onScrub;
  final ValueChanged<double>? onScrubEnd;

  static String clock(Duration duration) {
    final totalSeconds = duration.inSeconds.clamp(0, 359999);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds ~/ 60).remainder(60);
    final seconds = totalSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final maxMs = duration.inMilliseconds <= 0
        ? 1.0
        : duration.inMilliseconds.toDouble();
    final shown = Duration(
      milliseconds: (scrubMs ?? position.inMilliseconds.toDouble())
          .clamp(0.0, maxMs)
          .round(),
    );
    final canScrub = !loading && onScrub != null && onScrubEnd != null;
    return Column(
      children: <Widget>[
        Slider(
          value: shown.inMilliseconds.toDouble().clamp(0.0, maxMs),
          max: maxMs,
          onChanged: canScrub ? onScrub : null,
          onChangeEnd: canScrub ? onScrubEnd : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: <Widget>[
              Text(
                clock(shown),
                style: TextStyle(color: palette.textMuted, fontSize: 10.5),
              ),
              const Spacer(),
              Text(
                clock(duration),
                style: TextStyle(color: palette.textMuted, fontSize: 10.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            IconButton(
              tooltip: AppL10n.of(context).audioBack10,
              onPressed: loading ? null : onSkipBack,
              icon: const Icon(Icons.replay_10_rounded),
            ),
            const SizedBox(width: AppSpacing.sm),
            SizedBox(
              width: 56,
              height: 56,
              child: IconButton.filled(
                tooltip: playing
                    ? AppL10n.of(context).actionPause
                    : AppL10n.of(context).actionPlay,
                onPressed: loading ? null : onPlayPause,
                icon: loading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 28,
                      ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            IconButton(
              tooltip: AppL10n.of(context).audioForward10,
              onPressed: loading ? null : onSkipForward,
              icon: const Icon(Icons.forward_10_rounded),
            ),
          ],
        ),
      ],
    );
  }
}
