import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_processing_status.dart';
import 'main_shared.dart';
import 'main_theme.dart';
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

  Map<String, dynamic>? _conversation(String? id) {
    if (id == null) return null;
    for (final conversation in controller.conversations) {
      if (conversation['id'] == id) return conversation;
    }
    return null;
  }

  List<_TimelineGroup> get _groups {
    final ordered = [...controller.transcript]
      ..sort((left, right) => right.startedAt.compareTo(left.startedAt));
    final groups = <String, _TimelineGroup>{};
    for (final segment in ordered) {
      final local = segment.startedAt.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      final key = segment.conversationId == null
          ? 'loose:${segment.id}'
          : '${day.toIso8601String()}:${segment.conversationId}';
      groups.putIfAbsent(
        key,
        () => _TimelineGroup(
          key: key,
          day: day,
          conversationId: segment.conversationId,
          segments: <TranscriptSegment>[],
        ),
      );
      groups[key]!.segments.add(segment);
    }
    for (final group in groups.values) {
      group.segments.sort(
        (left, right) => left.startedAt.compareTo(right.startedAt),
      );
    }
    return groups.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
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
            trailing: groups.isEmpty
                ? null
                : _TimelineCount(
                    conversations: groups.length,
                    segments: controller.transcript.length,
                  ),
          ),
          const SizedBox(height: 18),
          ProcessingStatusCard(
            issues: controller.processingIssues,
            audioStillOnDevice: controller.audioStillOnDevice,
          ),
          if (groups.isEmpty)
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
                  for (
                    var index = 0;
                    index < groups.length;
                    index++
                  ) ...<Widget>[
                    if (index == 0 ||
                        groups[index - 1].day != groups[index].day)
                      _DayHeader(
                        day: groups[index].day,
                        groupCount: groups
                            .where((group) => group.day == groups[index].day)
                            .length,
                      ),
                    _TimelineEntry(
                      group: groups[index],
                      conversation: _conversation(groups[index].conversationId),
                      expanded: _expanded.contains(groups[index].key),
                      lastInDay:
                          index == groups.length - 1 ||
                          groups[index + 1].day != groups[index].day,
                      onToggle: () => setState(() {
                        if (!_expanded.add(groups[index].key)) {
                          _expanded.remove(groups[index].key);
                        }
                      }),
                    ),
                  ],
                ],
              ),
            ),
          // A long history does not fit in one page. The most recent
          // recordings come first, and older days are one tap away rather
          // than silently cut off.
          if (controller.hasOlderTranscript) ...<Widget>[
            const SizedBox(height: 18),
            Center(
              child: TextButton.icon(
                onPressed: controller.isLoadingOlderTranscript
                    ? null
                    : () => controller.loadOlderTranscript(),
                icon: controller.isLoadingOlderTranscript
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.history),
                label: Text(
                  controller.isLoadingOlderTranscript
                      ? 'Loading earlier recordings'
                      : 'Show earlier recordings',
                ),
              ),
            ),
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
    required this.group,
    required this.conversation,
    required this.expanded,
    required this.lastInDay,
    required this.onToggle,
  });

  final _TimelineGroup group;
  final Map<String, dynamic>? conversation;
  final bool expanded;
  final bool lastInDay;
  final VoidCallback onToggle;

  String _durationLabel() {
    final duration = group.segments.last.endedAt.difference(
      group.segments.first.startedAt,
    );
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    }
    if (duration.inMinutes > 0) return '${duration.inMinutes} min';
    return '${duration.inSeconds.clamp(1, 59)} sec';
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final first = group.segments.first;
    final last = group.segments.last;
    final speakers = group.segments
        .map((segment) => segment.speaker ?? 'Unassigned')
        .toSet()
        .toList();
    final visible = expanded ? group.segments : group.segments.take(2).toList();
    final remaining = group.segments.length - visible.length;
    final state = conversation?['state']?.toString();
    // A conversation that is still being recorded carries a provisional insight
    // so it can be read before it ends; the title and summary are refined once
    // it closes and becomes a memory. A closed conversation can also hold a
    // provisional insight — that is a description, not a live recording, so it
    // gets no badge.
    final provisional = state == 'open' && conversation?['insight_state']?.toString() == 'provisional';
    final generatedTitle = conversation?['title_en']?.toString().trim();
    final generatedSummary = conversation?['summary_en']?.toString().trim();
    final topics = ((conversation?['topics'] as List?) ?? const <dynamic>[])
        .map((topic) => topic.toString())
        .where((topic) => topic.trim().isNotEmpty)
        .take(3)
        .toList();
    final compact = MediaQuery.sizeOf(context).width < 680;

    final timeLabel = TimeOfDay.fromDateTime(
      first.startedAt.toLocal(),
    ).format(context);
    final endLabel = TimeOfDay.fromDateTime(
      last.endedAt.toLocal(),
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
                            group.conversationId == null
                                ? 'Unsorted transcript'
                                : generatedTitle?.isNotEmpty == true
                                ? generatedTitle!
                                : 'Conversation${state == null ? '' : ' · $state'}',
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
                          '${group.segments.length}',
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
                    if (remaining > 0 || expanded) ...<Widget>[
                      const SizedBox(height: 5),
                      TextButton.icon(
                        onPressed: onToggle,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
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
                              : '$remaining more ${remaining == 1 ? 'segment' : 'segments'}',
                        ),
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

class _TimelineGroup {
  _TimelineGroup({
    required this.key,
    required this.day,
    required this.conversationId,
    required this.segments,
  });

  final String key;
  final DateTime day;
  final String? conversationId;
  final List<TranscriptSegment> segments;
}
