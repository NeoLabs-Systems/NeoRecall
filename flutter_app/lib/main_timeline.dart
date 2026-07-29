import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_theme.dart';
import 'src/models/transcript.dart';

class TimelineScreen extends StatelessWidget {
  const TimelineScreen({super.key, required this.controller});

  final NeoRecallController controller;

  Map<String, dynamic>? _conversation(String? id) {
    if (id == null) return null;
    for (final conversation in controller.conversations) {
      if (conversation['id'] == id) return conversation;
    }
    return null;
  }

  List<_TranscriptGroup> get _groups {
    final groups = <_TranscriptGroup>[];
    for (final segment in controller.transcript) {
      if (groups.isEmpty ||
          groups.last.conversationId != segment.conversationId) {
        groups.add(
          _TranscriptGroup(
            conversationId: segment.conversationId,
            segments: <TranscriptSegment>[segment],
          ),
        );
      } else {
        groups.last.segments.add(segment);
      }
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: controller.refreshAll,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 48),
        children: <Widget>[
          ScreenHeader(
            eyebrow: 'TIMELINE',
            title: 'Your day, in context',
            description:
                'Original-language transcript evidence stays chronological. Related segments share one calm conversation surface.',
            trailing: controller.cachedData
                ? const Chip(label: Text('Cached'))
                : null,
          ),
          const SizedBox(height: 16),
          if (controller.transcript.isEmpty)
            const GlassSurface(
              child: EmptyState(
                icon: Icons.view_timeline_outlined,
                title: 'No transcript yet',
                message:
                    'Start a recording or import audio. Persisted segments will appear here.',
              ),
            )
          else
            for (final group in _groups)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: _ConversationCard(
                  group: group,
                  conversation: _conversation(group.conversationId),
                ),
              ),
        ],
      ),
    );
  }
}

class _ConversationCard extends StatelessWidget {
  const _ConversationCard({required this.group, required this.conversation});

  final _TranscriptGroup group;
  final Map<String, dynamic>? conversation;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final first = group.segments.first;
    final state = conversation?['state']?.toString();
    return GlassSurface(
      padding: EdgeInsets.zero,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 12),
            child: Row(
              children: <Widget>[
                Icon(
                  group.conversationId == null
                      ? Icons.notes_rounded
                      : Icons.forum_outlined,
                  size: 18,
                  color: palette.accent,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    group.conversationId == null
                        ? 'Transcript'
                        : 'Conversation${state == null ? '' : ' · $state'}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  MaterialLocalizations.of(
                    context,
                  ).formatShortDate(first.startedAt.toLocal()),
                  style: TextStyle(color: palette.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.border),
          for (
            var index = 0;
            index < group.segments.length;
            index++
          ) ...<Widget>[
            _TranscriptRow(segment: group.segments[index]),
            if (index < group.segments.length - 1)
              Padding(
                padding: const EdgeInsets.only(left: 60),
                child: Divider(height: 1, color: palette.border),
              ),
          ],
        ],
      ),
    );
  }
}

class _TranscriptRow extends StatelessWidget {
  const _TranscriptRow({required this.segment});

  final TranscriptSegment segment;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final speaker = segment.speaker ?? 'Unassigned speaker';
    final initial = speaker.trim().isEmpty
        ? '?'
        : speaker.characters.first.toUpperCase();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CircleAvatar(
            radius: 16,
            backgroundColor: palette.accentSoft,
            child: Text(
              initial,
              style: TextStyle(
                color: palette.accentHover,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        speaker,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      TimeOfDay.fromDateTime(
                        segment.startedAt.toLocal(),
                      ).format(context),
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(segment.text, style: const TextStyle(height: 1.45)),
                if (segment.language != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    segment.language!.toUpperCase(),
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 9.5,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TranscriptGroup {
  _TranscriptGroup({required this.conversationId, required this.segments});

  final String? conversationId;
  final List<TranscriptSegment> segments;
}
