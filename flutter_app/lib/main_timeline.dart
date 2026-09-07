import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_moment_audio.dart';
import 'main_processing_status.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'src/models/timeline_moment.dart';
import 'src/models/transcript.dart';
import 'src/widgets/selection_mixin.dart';

class TimelineScreen extends StatefulWidget {
  const TimelineScreen({
    super.key,
    required this.controller,
    this.embedded = false,
  });

  final NeoRecallController controller;

  /// True when Library owns the page title and the surrounding padding. The
  /// screen then contributes only its list.
  final bool embedded;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen>
    with SelectionMixin<TimelineScreen> {
  final Set<String> _expanded = <String>{};

  NeoRecallController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // The page a reader paged back to belongs to the visit they paged in.
    // Opening the list again should show the newest moments, not the middle
    // of last week. Deferred past this frame because it refetches and
    // notifies, which cannot happen while the page is still being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      controller.showNewestMoments();
    });
  }

  Future<bool> _confirmDelete(int count) async {
    if (count < 1) return false;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          count == 1 ? 'Delete this moment?' : 'Delete $count moments?',
        ),
        content: Text(
          count == 1
              ? 'This will permanently delete this conversation and its transcript. A memory that came only from this conversation will be removed too.'
              : 'This will permanently delete these conversations and their transcripts. Memories that came only from them will be removed too.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirm == true;
  }

  Future<void> _deleteSelected() async {
    final ids = selectedIds;
    if (!await _confirmDelete(ids.length)) return;
    if (!mounted) return;
    await runBulkAction(
      controller.bulkDeleteMoments,
      success: (deleted) =>
          'Deleted ${deleted.length} moment${deleted.length == 1 ? '' : 's'}',
      failure: (error) => 'Could not delete moments: $error',
    );
  }

  Future<void> _swipeDelete(TimelineMoment moment) async {
    final id = moment.id;
    if (id == null) return;
    try {
      await controller.deleteMoment(id);
      if (!mounted) return;
      if (isSelected(id)) toggleSelect(id);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Deleted 1 moment')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete moments: $error')),
      );
    }
  }

  /// Select and Done — kept in one place so the standalone header and
  /// Library's row cannot diverge.
  Widget _actions() => selecting
      ? TextButton(onPressed: exitSelect, child: const Text('Done'))
      : TextButton.icon(
          onPressed: controller.moments.isEmpty ? null : () => enterSelect(),
          icon: const Icon(Icons.checklist_rounded, size: 18),
          label: const Text('Select'),
        );

  Widget _headerTrailing(List<TimelineMoment> moments) {
    final actions = _actions();
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile;
    if (!wide || moments.isEmpty || selecting) return actions;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _TimelineCount(
          conversations: moments.length,
          segments: moments.fold<int>(
            0,
            (total, moment) => total + moment.segmentCount,
          ),
        ),
        const SizedBox(width: 8),
        actions,
      ],
    );
  }

  Widget _momentTile(TimelineMoment moment, {required bool lastInDay}) {
    final id = moment.id;
    final entry = _TimelineEntry(
      moment: moment,
      expanded: _expanded.contains(moment.key),
      lastInDay: lastInDay,
      busy: controller.reprocessingMomentId == moment.id,
      hasAudio: controller.momentsWithRetainedAudio.contains(moment.key),
      selecting: selecting,
      selected: id != null && isSelected(id),
      onTap: selecting && id != null ? () => toggleSelect(id) : null,
      onLongPress: id == null ? null : () => enterSelect(id),
      onPlay: selecting
          ? null
          : () => showMomentAudioSheet(context, controller, moment),
      onReprocess: moment.canReprocess
          ? () => controller.reprocessMoment(moment.id!)
          : null,
      loadedSegments: controller.momentTranscripts[moment.id],
      loadingSegments: controller.loadingMomentTranscripts.contains(moment.id),
      onToggle: () {
        setState(() {
          if (!_expanded.add(moment.key)) {
            _expanded.remove(moment.key);
          }
        });
        if (_expanded.contains(moment.key)) {
          controller.openMomentTranscript(moment);
        }
      },
    );
    if (selecting || id == null) return entry;
    return Dismissible(
      key: ValueKey<String>('moment-$id'),
      direction: DismissDirection.endToStart,
      background: const _MomentDismissBackground(),
      confirmDismiss: (_) => _confirmDelete(1),
      onDismissed: (_) => _swipeDelete(moment),
      child: entry,
    );
  }

  @override
  Widget build(BuildContext context) {
    final moments = widget.controller.moments;
    final selectableIds = moments
        .map((moment) => moment.id)
        .whereType<String>()
        .toList();
    final allMomentsSelected =
        selectableIds.isNotEmpty && selectableIds.every((id) => isSelected(id));
    // Day headers are drawn from the moments themselves; a moment never spans
    // a day boundary in a way that matters here, so its start decides.
    DateTime dayOf(TimelineMoment moment) {
      final local = moment.startedAt.toLocal();
      return DateTime(local.year, local.month, local.day);
    }

    return RefreshIndicator(
      onRefresh: controller.refreshAll,
      child: ListView(
        padding: widget.embedded
            ? const EdgeInsets.only(bottom: 40)
            : const EdgeInsets.fromLTRB(24, 24, 24, 48),
        children: <Widget>[
          if (widget.embedded)
            Align(alignment: Alignment.centerRight, child: _actions())
          else ...<Widget>[
            ScreenHeader(
              title: 'Moments',
              description:
                  'A compact stream of conversations. Expand only the ones you want to read in full.',
              trailing: _headerTrailing(moments),
            ),
            const SizedBox(height: 18),
          ],
          ProcessingActivityBanner(
            status: controller.processingStatus,
            isRecording: controller.isRecording,
          ),
          ProcessingStatusCard(
            issues: controller.processingIssues,
            audioStillOnDevice: controller.audioStillOnDevice,
          ),
          if (selecting) ...<Widget>[
            _MomentSelectionBar(
              count: selectedCount,
              onSelectAll: allMomentsSelected
                  ? null
                  : () => selectAll(selectableIds),
              onDelete: _deleteSelected,
            ),
            const SizedBox(height: 14),
          ],
          if (moments.isEmpty)
            // Only claim there is nothing here when there is genuinely nothing
            // here. If something is holding recordings up, the card above has
            // already said so, and telling someone who recorded all day to
            // "start a recording" is the message that makes them think their
            // audio was lost.
            AppPanel(
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
            AppPanel(
              padding: EdgeInsets.zero,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.panel),
                child: Column(
                  children: <Widget>[
                    for (
                      var index = 0;
                      index < moments.length;
                      index++
                    ) ...<Widget>[
                      if (index == 0 ||
                          dayOf(moments[index - 1]) != dayOf(moments[index]))
                        _DayHeader(
                          day: dayOf(moments[index]),
                          groupCount: moments
                              .where(
                                (moment) =>
                                    dayOf(moment) == dayOf(moments[index]),
                              )
                              .length,
                        ),
                      _momentTile(
                        moments[index],
                        lastInDay:
                            index == moments.length - 1 ||
                            dayOf(moments[index + 1]) != dayOf(moments[index]),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          // A long history does not fit in one page, and the reader needs to
          // know where in it they are standing rather than watching a list
          // grow without end.
          if (controller.hasOlderMoments ||
              controller.hasNewerMoments) ...<Widget>[
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
    this.hasAudio = false,
    this.onPlay,
    this.selecting = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
  });

  final TimelineMoment moment;
  final bool expanded;
  final bool lastInDay;
  final bool busy;
  final VoidCallback onToggle;
  final List<TranscriptSegment>? loadedSegments;
  final bool loadingSegments;
  final VoidCallback? onReprocess;
  final bool hasAudio;
  final VoidCallback? onPlay;
  final bool selecting;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

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

  List<Widget> _titleMeta({
    required NeoRecallPalette palette,
    required bool provisional,
    required bool compact,
    required String timeLabel,
    required String endLabel,
  }) {
    final status = _statusLabel();
    return <Widget>[
      if (provisional) _LiveInsightBadge(palette: palette),
      if (!provisional && status != null)
        _MomentStatus(label: status, palette: palette),
      if (hasAudio && onPlay != null)
        IconButton(
          tooltip: 'Listen',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: onPlay,
          icon: const Icon(Icons.play_arrow_rounded, size: 20),
        ),
      if (compact)
        Text(
          '$timeLabel–$endLabel',
          style: TextStyle(color: palette.textMuted, fontSize: 10.5),
        ),
      Icon(Icons.graphic_eq_rounded, size: 15, color: palette.textMuted),
      Text(
        '${moment.segmentCount}',
        style: TextStyle(color: palette.textMuted, fontSize: 11),
      ),
    ];
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
    final hidden = (moment.segmentCount - visible.length).clamp(
      0,
      moment.segmentCount,
    );
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

    return Material(
      color: selected
          ? palette.accentSoft.withValues(alpha: 0.25)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            border: lastInDay
                ? null
                : Border(bottom: BorderSide(color: palette.border)),
          ),
          // The rail is drawn behind the row rather than as a stretched
          // column of it. An IntrinsicHeight here used to fix this tile's
          // height to what its children measure, while the transcript's
          // AnimatedSize was still animating to that height — so every
          // collapse overflowed the row for the length of the animation.
          child: Stack(
            children: <Widget>[
              Positioned(
                top: 0,
                bottom: 0,
                left: compact ? 0 : 78,
                width: 28,
                child: _MomentRail(palette: palette),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                  const SizedBox(width: 28),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(compact ? 8 : 6, 13, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              if (selecting) ...<Widget>[
                                Icon(
                                  selected
                                      ? Icons.check_circle_rounded
                                      : Icons.circle_outlined,
                                  color: selected
                                      ? palette.accent
                                      : palette.textMuted,
                                  size: 22,
                                ),
                                const SizedBox(width: 10),
                              ],
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
                              if (!selecting && !compact)
                                for (final widget in _titleMeta(
                                  palette: palette,
                                  provisional: provisional,
                                  compact: false,
                                  timeLabel: timeLabel,
                                  endLabel: endLabel,
                                )) ...<Widget>[
                                  const SizedBox(width: 6),
                                  widget,
                                ],
                            ],
                          ),
                          if (!selecting && compact) ...<Widget>[
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: _titleMeta(
                                palette: palette,
                                provisional: provisional,
                                compact: true,
                                timeLabel: timeLabel,
                                endLabel: endLabel,
                              ),
                            ),
                          ],
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
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
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
                              segments.length <
                                  moment.segmentCount) ...<Widget>[
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
                            // A Wrap rather than a Row with a Spacer: on a
                            // narrow phone "Show less" and "Write up again"
                            // together are wider than the moment, and a Row
                            // answered that by overflowing for as long as the
                            // moment stayed open.
                            SizedBox(
                              width: double.infinity,
                              child: Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                runSpacing: 2,
                                children: <Widget>[
                                  TextButton.icon(
                                    onPressed: selecting ? null : onToggle,
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
                                  // Offered only once a moment is open: it acts on what
                                  // the reader is looking at, and it is not something to
                                  // trip over while scanning the day.
                                  if (expanded &&
                                      onReprocess != null &&
                                      !selecting)
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
                                          : const Icon(
                                              Icons.auto_awesome,
                                              size: 15,
                                            ),
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
                            ),
                          ],
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
    );
  }
}

/// The vertical thread that runs behind a moment, with the dot that marks
/// where it starts. Drawn as a background layer so nothing about a tile's
/// height depends on it — and, more to the point, so the transcript inside a
/// tile can animate open and shut without the rail fixing the row's height.
class _MomentRail extends StatelessWidget {
  const _MomentRail({required this.palette});

  final NeoRecallPalette palette;

  @override
  Widget build(BuildContext context) => Stack(
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
  );
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
    return AppPanel(
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

class _MomentDismissBackground extends StatelessWidget {
  const _MomentDismissBackground();

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return ColoredBox(
      color: palette.danger,
      child: const Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Icon(Icons.delete_outline_rounded, color: Colors.white),
        ),
      ),
    );
  }
}

class _MomentSelectionBar extends StatelessWidget {
  const _MomentSelectionBar({
    required this.count,
    required this.onSelectAll,
    required this.onDelete,
  });

  final int count;
  final VoidCallback? onSelectAll;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final enabled = count > 0;
    return AppPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              count == 0 ? 'Select moments' : '$count selected',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.textSecondary,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
          _MomentSelectionAction(
            tooltip: onSelectAll == null
                ? 'All moments selected'
                : 'Select all moments',
            icon: Icons.select_all_rounded,
            onPressed: onSelectAll,
          ),
          _MomentSelectionAction(
            tooltip: 'Delete',
            icon: Icons.delete_outline_rounded,
            danger: true,
            onPressed: enabled ? onDelete : null,
          ),
        ],
      ),
    );
  }
}

class _MomentSelectionAction extends StatelessWidget {
  const _MomentSelectionAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.danger = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(
        icon,
        size: 20,
        color: onPressed == null
            ? palette.textMuted.withValues(alpha: 0.4)
            : danger
            ? palette.danger
            : palette.textSecondary,
      ),
    );
  }
}
