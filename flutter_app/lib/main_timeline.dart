import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_processing_status.dart';
import 'main_shared.dart';
import 'main_theme.dart';
import 'src/models/timeline_moment.dart';
import 'src/models/transcript.dart';

class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  final Set<String> _expanded = <String>{};

  NeoRecallController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    final moments = widget.controller.moments;
    // Day headers are drawn from the moments themselves; a moment never spans
    // a day boundary in a way that matters here, so its start decides.
    DateTime dayOf(TimelineMoment moment) {
      final local = moment.startedAt.toLocal();
      return DateTime(local.year, local.month, local.day);
    }
    return RefreshIndicator(
      onRefresh: controller.refreshAll,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 48),
        children: <Widget>[
          ScreenHeader(
            eyebrow: 'TIMELINE',
            title: 'Your day, at a glance',
            description:
                'A compact stream of conversations. Expand only the moments you want to read in full.',
            trailing: moments.isEmpty
                ? null
                : _TimelineCount(
                    conversations: moments.length,
                    segments: moments.fold<int>(
                      0,
                      (total, moment) => total + moment.segmentCount,
                    ),
                  ),
          ),
          const SizedBox(height: 18),
          ProcessingStatusCard(
            issues: controller.processingIssues,
            audioStillOnDevice: controller.audioStillOnDevice,
          ),
          if (moments.isEmpty)
            // Only claim there is nothing here when there is genuinely nothing
            // here. If something is holding recordings up, the card above has
            // already said so, and telling someone who recorded all day to
            // "start a recording" is the message that makes them think their
            // audio was lost.
            GlassSurface(
              child: EmptyState(
                icon: Icons.view_timeline_outlined,
                title: controller.processingIssues.isEmpty
                    ? 'No transcript yet'
                    : 'Nothing to show yet',
                message: controller.processingIssues.isEmpty
                    ? 'Start a recording or import audio. Persisted segments will appear here.'
                    : 'Your recordings are safe. They will appear here once the above is sorted out.',
              ),
            )
          else
            GlassSurface(
              padding: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  for (var index = 0; index < moments.length; index++) ...<Widget>[
                    if (index == 0 ||
                        dayOf(moments[index - 1]) != dayOf(moments[index]))
                      _DayHeader(
                        day: dayOf(moments[index]),
                        groupCount: moments
                            .where((moment) => dayOf(moment) == dayOf(moments[index]))
                            .length,
                      ),
                    _TimelineEntry(
                      moment: moments[index],
                      expanded: _expanded.contains(moments[index].key),
                      lastInDay:
                          index == moments.length - 1 ||
                          dayOf(moments[index + 1]) != dayOf(moments[index]),
                      busy: controller.reprocessingMomentId == moments[index].id,
                      onReprocess: moments[index].canReprocess
                          ? () => controller.reprocessMoment(moments[index].id!)
                          : null,
                      loadedSegments:
                          controller.momentTranscripts[moments[index].id],
                      loadingSegments: controller.loadingMomentTranscripts
                          .contains(moments[index].id),
                      onToggle: () {
                        setState(() {
                          if (!_expanded.add(moments[index].key)) {
                            _expanded.remove(moments[index].key);
                          }
                        });
                        if (_expanded.contains(moments[index].key)) {
                          controller.openMomentTranscript(moments[index]);
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
          // A long history does not fit in one page, and the reader needs to
          // know where in it they are standing rather than watching a list
          // grow without end.
          if (controller.hasOlderMoments || controller.hasNewerMoments) ...<Widget>[
            const SizedBox(height: 20),
            _TimelinePager(controller: controller),
          ],
        ],
      ),
    );
  }
}

class _TimelineCount extends StatelessWidget {
  const _TimelineCount({required this.conversations, required this.segments});

  final int conversations;
  final int segments;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: palette.bgSecondary,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$conversations moments · $segments segments',
        style: TextStyle(
          color: palette.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.groupCount});

  final DateTime day;
  final int groupCount;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final today = DateUtils.isSameDay(day, DateTime.now());
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 11),
      decoration: BoxDecoration(
        color: palette.bgSecondary.withValues(alpha: 0.72),
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.calendar_today_outlined, size: 15, color: palette.accent),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              today
                  ? 'Today'
                  : MaterialLocalizations.of(context).formatFullDate(day),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            '$groupCount ${groupCount == 1 ? 'moment' : 'moments'}',
            style: TextStyle(color: palette.textMuted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({
    required this.moment,
    required this.expanded,
    required this.lastInDay,
    required this.busy,
    required this.onToggle,
    this.loadedSegments,
    this.loadingSegments = false,
    this.onReprocess,
  });

  final TimelineMoment moment;
  final bool expanded;
  final bool lastInDay;
  final bool busy;
  final VoidCallback onToggle;
  final List<TranscriptSegment>? loadedSegments;
  final bool loadingSegments;
  final VoidCallback? onReprocess;

  /// Where this moment stands, in the reader's terms. Null when it simply
  /// stands finished and there is nothing to say.
  String? _statusLabel() {
    if (moment.isPending) return 'Being sorted';
    if (moment.isSetAside) return 'Waiting on a summary';
    // Waiting for the model is one state, whether this is the first write-up
    // or a repeat: nothing on the record distinguishes them, so the label does
    // not claim to.
    if (moment.awaitsWriteUp) return 'Summary on the way';
    return null;
  }

  String _durationLabel() {
    final duration = moment.endedAt.difference(moment.startedAt);
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    }
    if (duration.inMinutes > 0) return '${duration.inMinutes} min';
    return '${duration.inSeconds.clamp(1, 59)} sec';
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    // The page carries a preview; the full transcript arrives when the moment
    // is opened.
    final segments = loadedSegments ?? moment.segments;
    final speakers = segments
        .map((segment) => segment.speaker ?? 'Unassigned')
        .toSet()
        .toList();
    final visible = expanded ? segments : segments.take(2).toList();
    final hidden = (moment.segmentCount - visible.length).clamp(0, moment.segmentCount);
    // A conversation that is still being recorded carries a provisional
    // account of itself so it can be read before it ends; it is refined once
    // the conversation closes.
    final provisional = moment.isLive && moment.insightState == 'provisional';
    final generatedTitle = moment.titleEn?.trim();
    final generatedSummary = moment.summaryEn?.trim();
    final topics = moment.topics.take(3).toList();
    final compact = MediaQuery.sizeOf(context).width < 680;

    final timeLabel = TimeOfDay.fromDateTime(
      moment.startedAt.toLocal(),
    ).format(context);
    final endLabel = TimeOfDay.fromDateTime(
      moment.endedAt.toLocal(),
    ).format(context);

    return Container(
      decoration: BoxDecoration(
        border: lastInDay
            ? null
            : Border(bottom: BorderSide(color: palette.border)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (!compact)
              SizedBox(
                width: 78,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Text(
                        timeLabel,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _durationLabel(),
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            SizedBox(
              width: 28,
              child: Stack(
                alignment: Alignment.topCenter,
                children: <Widget>[
                  Positioned(
                    top: 0,
                    bottom: 0,
                    child: Container(width: 1, color: palette.borderLight),
                  ),
                  Positioned(
                    top: 18,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: palette.accent,
                        border: Border.all(color: palette.bgCard, width: 2),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: palette.accent.withValues(alpha: 0.28),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(compact ? 8 : 6, 13, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            moment.isPending
                                ? 'Just recorded'
                                : generatedTitle?.isNotEmpty == true
                                ? generatedTitle!
                                : 'Conversation',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (provisional) ...<Widget>[
                          const SizedBox(width: 6),
                          _LiveInsightBadge(palette: palette),
                        ],
                        if (!provisional && _statusLabel() != null) ...<Widget>[
                          const SizedBox(width: 6),
                          _MomentStatus(
                            label: _statusLabel()!,
                            palette: palette,
                          ),
                        ],
                        if (compact)
                          Text(
                            '$timeLabel–$endLabel',
                            style: TextStyle(
                              color: palette.textMuted,
                              fontSize: 10.5,
                            ),
                          ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.graphic_eq_rounded,
                          size: 15,
                          color: palette.textMuted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${moment.segmentCount}',
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    if (generatedSummary?.isNotEmpty == true) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        generatedSummary!,
                        maxLines: expanded ? null : 2,
                        overflow: expanded
                            ? TextOverflow.visible
                            : TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.textSecondary,
                          height: 1.38,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                    if (topics.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 6,
                        runSpacing: 5,
                        children: topics
                            .map(
                              (topic) => _TopicChip(
                                label: topic,
                                palette: palette,
                              ),
                            )
                            .toList(),
                      ),
                    ],
                    if (speakers.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 6,
                        runSpacing: 5,
                        children: speakers
                            .take(4)
                            .map(
                              (speaker) => _SpeakerChip(
                                label: speaker,
                                palette: palette,
                              ),
                            )
                            .toList(),
                      ),
                    ],
                    const SizedBox(height: 9),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: Column(
                        children: <Widget>[
                          for (
                            var index = 0;
                            index < visible.length;
                            index++
                          ) ...<Widget>[
                            _TranscriptLine(segment: visible[index]),
                            if (index < visible.length - 1)
                              const SizedBox(height: 7),
                          ],
                        ],
                      ),
                    ),
                    if (expanded && loadingSegments) ...<Widget>[
                      const SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Loading the rest of this moment',
                            style: TextStyle(
                              color: palette.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (expanded &&
                        !loadingSegments &&
                        segments.length < moment.segmentCount) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        'Showing the first ${segments.length} of ${moment.segmentCount} lines.',
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                    if (hidden > 0 || expanded) ...<Widget>[
                      const SizedBox(height: 5),
                      Row(
                        children: <Widget>[
                          TextButton.icon(
                            onPressed: onToggle,
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                            ),
                            icon: Icon(
                              expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 17,
                            ),
                            label: Text(
                              expanded
                                  ? 'Show less'
                                  : '$hidden more ${hidden == 1 ? 'line' : 'lines'}',
                            ),
                          ),
                          const Spacer(),
                          // Offered only once a moment is open: it acts on what
                          // the reader is looking at, and it is not something to
                          // trip over while scanning the day.
                          if (expanded && onReprocess != null)
                            TextButton.icon(
                              onPressed: busy ? null : onReprocess,
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                              icon: busy
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.auto_awesome, size: 15),
                              label: Text(
                                busy
                                    ? 'Writing up'
                                    : moment.hasWriteUp
                                    ? 'Write up again'
                                    : 'Write up now',
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Marks a title and summary that describe a conversation which is still being
/// recorded, so a reader knows the account is current rather than final.
class _LiveInsightBadge extends StatelessWidget {
  const _LiveInsightBadge({required this.palette});

  final NeoRecallPalette palette;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: palette.accent.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: palette.accent.withValues(alpha: 0.3)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: palette.accent,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          'Recording',
          style: TextStyle(
            color: palette.accent,
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ],
    ),
  );
}

class _TopicChip extends StatelessWidget {
  const _TopicChip({required this.label, required this.palette});

  final String label;
  final NeoRecallPalette palette;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: palette.secondary.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: palette.secondary.withValues(alpha: 0.18)),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: palette.textSecondary,
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _SpeakerChip extends StatelessWidget {
  const _SpeakerChip({required this.label, required this.palette});

  final String label;
  final NeoRecallPalette palette;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: palette.accentSoft,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: palette.accentHover,
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _TranscriptLine extends StatelessWidget {
  const _TranscriptLine({required this.segment});

  final TranscriptSegment segment;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final speaker = segment.speaker ?? 'Unassigned';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 3,
          height: 17,
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            color: palette.secondary.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(99),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(
                  text: '$speaker  ',
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                TextSpan(
                  text: segment.text,
                  style: TextStyle(
                    color: palette.textPrimary,
                    height: 1.42,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Moves through the timeline a page at a time, newest first.
class _TimelinePager extends StatelessWidget {
  const _TimelinePager({required this.controller});

  final NeoRecallController controller;

  @override
  Widget build(BuildContext context) {
    final busy = controller.isPagingMoments;
    return GlassSurface(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          TextButton.icon(
            onPressed: busy || !controller.hasNewerMoments
                ? null
                : controller.showNewerMoments,
            icon: const Icon(Icons.chevron_left),
            label: const Text('Newer'),
          ),
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Text(
              'Page ${controller.momentPage + 1}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          TextButton.icon(
            onPressed: busy || !controller.hasOlderMoments
                ? null
                : controller.showOlderMoments,
            icon: const Icon(Icons.chevron_right),
            label: const Text('Older'),
            iconAlignment: IconAlignment.end,
          ),
        ],
      ),
    );
  }
}

/// A short note on a moment's state, next to its title.
class _MomentStatus extends StatelessWidget {
  const _MomentStatus({required this.label, required this.palette});

  final String label;
  final NeoRecallPalette palette;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: palette.bgSecondary,
      border: Border.all(color: palette.border),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: palette.textMuted,
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
