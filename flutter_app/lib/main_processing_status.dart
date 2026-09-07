import 'package:flutter/material.dart';

import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'src/sync/processing_status.dart';
import 'l10n/gen/app_l10n.dart';

/// Tells the user what is happening to recordings that have not turned into
/// anything they can see yet.
///
/// It exists because the opposite was worse than useless. A day of recording
/// that stalled anywhere — a transcription service nobody had configured, a
/// language model rejecting every request, a worker that was not running —
/// produced a timeline saying "No transcript yet. Start a recording", which is
/// both untrue and the one message that makes someone assume their audio is
/// gone.
///
/// So the first thing every issue does is say where the audio is. Nothing here
/// mentions jobs, chunks or error codes: the server phrases these for the person
/// who did the recording, and this only lays them out.
class ProcessingStatusCard extends StatelessWidget {
  const ProcessingStatusCard({
    super.key,
    required this.issues,
    this.audioStillOnDevice = 0,
  });

  final List<Map<String, dynamic>> issues;
  final int audioStillOnDevice;

  @override
  Widget build(BuildContext context) {
    if (issues.isEmpty) return const SizedBox.shrink();
    final palette = neoRecallPaletteOf(context);
    // A blocked pipeline is not going to fix itself, so it is coloured as the
    // problem it is; anything else is still moving and reads as a caution.
    final blocked = issues.any((issue) => issue['severity'] == 'blocked');
    final tint = blocked ? palette.danger : palette.warning;

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: AppPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  blocked ? Icons.error_outline : Icons.info_outline,
                  size: 18,
                  color: tint,
                ),
                const SizedBox(width: 8),
                Text(
                  blocked
                      ? AppL10n.of(context).processingSomethingNeedsAttention
                      : AppL10n.of(context).processingStillWorking,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: tint,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            if (audioStillOnDevice > 0) ...<Widget>[
              const SizedBox(height: 8),
              // Said before any explanation, because it is the question actually
              // being asked: is my recording gone?
              Text(
                AppL10n.of(context).processingDeviceHolding(audioStillOnDevice),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            for (final issue in issues) ...<Widget>[
              const SizedBox(height: 14),
              Text(
                issue['title']?.toString() ?? '',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                issue['detail']?.toString() ?? '',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if ((issue['action']?.toString() ?? '').isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  issue['action']!.toString(),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: tint),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// A quiet line saying that a recording is moving through the pipeline right
/// now, shown above the lists where its result will appear.
///
/// It answers one question — "is something still coming?" — so it only appears
/// while audio is actually in motion: arriving from a device, uploading, or
/// being transcribed. Waiting in a queue is not motion, the write-up a model
/// produces afterwards is not what this promises, and during a recording the
/// record screen already says everything there is to say. In every one of
/// those states this is nothing at all, because a spinner that is always on
/// screen stops meaning anything.
class ProcessingActivityBanner extends StatelessWidget {
  const ProcessingActivityBanner({
    super.key,
    required this.status,
    this.isRecording = false,
  });

  final ProcessingStatusSnapshot status;
  final bool isRecording;

  static String _eta(Duration duration, AppL10n l10n) {
    if (duration.inSeconds < 45) return l10n.processingUnderMinuteLeft;
    if (duration.inMinutes < 60) {
      return l10n.processingEtaMinutesLeft((duration.inSeconds / 60).ceil());
    }
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    return minutes < 10
        ? l10n.processingEtaHoursLeft(hours)
        : l10n.processingEtaHoursMinutesLeft(hours, minutes);
  }

  String? _label(AppL10n l10n) {
    if (isRecording) return null;
    switch (status.activeStage) {
      case ProcessingPipelineStage.watchTransfer:
        return l10n.processingGettingAudio;
      case ProcessingPipelineStage.upload:
        return l10n.processingUploadingCount(status.uploading);
      case ProcessingPipelineStage.transcription:
        return l10n.processingTranscribingCount(status.transcribing);
      case ProcessingPipelineStage.phoneQueue:
      case ProcessingPipelineStage.serverQueue:
      case ProcessingPipelineStage.finalizing:
      case ProcessingPipelineStage.complete:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final label = _label(strings);
    if (label == null) return const SizedBox.shrink();
    final palette = neoRecallPaletteOf(context);
    final eta = status.eta;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: palette.accent.withValues(alpha: 0.08),
          border: Border.all(color: palette.accent.withValues(alpha: 0.24)),
          borderRadius: BorderRadius.circular(AppRadius.panel),
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: palette.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (eta != null && eta > Duration.zero) ...<Widget>[
              const SizedBox(width: 10),
              Text(
                _eta(eta, strings),
                style: TextStyle(color: palette.textMuted, fontSize: 11.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
