import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_theme.dart';

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

  bool _startsConversation(int index) {
    final id = controller.transcript[index].conversationId;
    return id != null &&
        (index == 0 || controller.transcript[index - 1].conversationId != id);
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return RefreshIndicator(
      onRefresh: controller.refreshAll,
      child: ListView(
        padding: const EdgeInsets.all(28),
        children: <Widget>[
          ScreenHeader(
            eyebrow: 'TIMELINE',
            title: 'Your day, in context',
            description:
                'Original-language transcript evidence stays chronological. Conversation and speaker boundaries appear as local processing completes.',
            trailing: controller.cachedData
                ? const Chip(label: Text('Cached'))
                : null,
          ),
          const SizedBox(height: 24),
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
            for (
              var index = 0;
              index < controller.transcript.length;
              index++
            ) ...<Widget>[
              if (_startsConversation(index))
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 10),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.forum_outlined, color: palette.accent),
                      const SizedBox(width: 9),
                      Text(
                        'Conversation · ${_conversation(controller.transcript[index].conversationId)?['state'] ?? 'processing'}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const Spacer(),
                      Text(
                        MaterialLocalizations.of(context).formatShortDate(
                          controller.transcript[index].startedAt.toLocal(),
                        ),
                        style: TextStyle(color: palette.textMuted),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GlassSurface(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      CircleAvatar(
                        backgroundColor: palette.accentSoft,
                        child: Text(
                          (controller.transcript[index].speaker ?? '?')
                              .substring(0, 1),
                        ),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Text(
                                  controller.transcript[index].speaker ??
                                      'Unassigned speaker',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  TimeOfDay.fromDateTime(
                                    controller.transcript[index].startedAt
                                        .toLocal(),
                                  ).format(context),
                                  style: TextStyle(
                                    color: palette.textMuted,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              controller.transcript[index].text,
                              style: const TextStyle(height: 1.45),
                            ),
                            if (controller.transcript[index].language != null)
                              Text(
                                controller.transcript[index].language!
                                    .toUpperCase(),
                                style: TextStyle(
                                  color: palette.textMuted,
                                  fontSize: 10,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
        ],
      ),
    );
  }
}
