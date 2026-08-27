import 'package:flutter/material.dart';

import 'main_shared.dart';
import 'main_theme.dart';

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
      child: GlassSurface(
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
                  blocked ? 'Something needs attention' : 'Still working on it',
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
                audioStillOnDevice == 1
                    ? 'Your device is still holding 1 recording, so nothing has been lost.'
                    : 'Your device is still holding $audioStillOnDevice recordings, so nothing has been lost.',
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
