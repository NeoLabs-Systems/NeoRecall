import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_theme.dart';

class MemoriesScreen extends StatelessWidget {
  const MemoriesScreen({super.key, required this.controller});
  final NeoRecallController controller;
  IconData _icon(String kind) => switch (kind) {
    'task' => Icons.task_alt,
    'promise' => Icons.handshake_outlined,
    'person' => Icons.person_outline,
    'event' => Icons.event_outlined,
    'location' => Icons.place_outlined,
    'relationship' => Icons.hub_outlined,
    _ => Icons.lightbulb_outline,
  };
  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return RefreshIndicator(
      onRefresh: controller.refreshAll,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 48),
        children: <Widget>[
          ScreenHeader(
            eyebrow: 'MEMORIES',
            title: 'What your day became',
            description:
                'Episodic memories and atomic facts are generated in English by a budgeted consolidation call.',
            trailing: OutlinedButton.icon(
              onPressed: controller.consolidateNow,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Consolidate if eligible'),
            ),
          ),
          const SizedBox(height: 24),
          if (controller.dailySummaries.isNotEmpty) ...<Widget>[
            GlassSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        'DAILY SUMMARY',
                        style: sectionEyebrowStyle(palette),
                      ),
                      const Spacer(),
                      Chip(
                        label: Text(
                          controller.dailySummaries.first['state'] as String,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    controller.dailySummaries.first['local_date'] as String,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    controller.dailySummaries.first['summary_en'] as String,
                    style: TextStyle(color: palette.textSoft, height: 1.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          if (controller.memories.isEmpty)
            const GlassSurface(
              child: EmptyState(
                icon: Icons.auto_awesome_outlined,
                title: 'No consolidated memories',
                message:
                    'Enough closed conversation material and the configured interval are required.',
              ),
            )
          else
            ...controller.memories.map(
              (memory) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: GlassSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Chip(label: Text(memory.type.replaceAll('_', ' '))),
                          const Spacer(),
                          Text(
                            '${memory.importance.toStringAsFixed(1)}/10',
                            style: TextStyle(
                              color: palette.accentStrong,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        memory.title,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        memory.summary,
                        style: TextStyle(color: palette.textSoft, height: 1.5),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 10),
          Text('MINI-MEMORIES', style: sectionEyebrowStyle(palette)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: controller.miniMemories
                .map(
                  (mini) => ActionChip(
                    avatar: Icon(_icon(mini.kind), size: 17),
                    label: Text(mini.text),
                    onPressed:
                        <String>{'task', 'promise'}.contains(mini.kind) &&
                            mini.status == 'open'
                        ? () =>
                              controller.updateMiniMemory(mini.id, 'completed')
                        : null,
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}
