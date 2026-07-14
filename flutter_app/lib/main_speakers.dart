import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_theme.dart';

class SpeakersScreen extends StatelessWidget {
  const SpeakersScreen({super.key, required this.controller});
  final NeoRecallController controller;
  Future<void> _rename(BuildContext context, String id, String current) async {
    final field = TextEditingController(text: current);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Name recurring speaker'),
        content: TextField(
          controller: field,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Display name'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    field.dispose();
    if (value?.isNotEmpty ?? false) await controller.renameSpeaker(id, value!);
  }

  Future<void> _merge(BuildContext context, String targetId) async {
    final sourceId = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Merge another voice into this speaker'),
        children: controller.speakers
            .where((speaker) => speaker.id != targetId)
            .map(
              (speaker) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, speaker.id),
                child: Text(speaker.name ?? 'Unnamed recurring speaker'),
              ),
            )
            .toList(),
      ),
    );
    if (sourceId != null) await controller.mergeSpeaker(targetId, sourceId);
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return RefreshIndicator(
      onRefresh: controller.refreshAll,
      child: ListView(
        padding: const EdgeInsets.all(28),
        children: <Widget>[
          const ScreenHeader(
            eyebrow: 'SPEAKERS',
            title: 'Recurring voices',
            description:
                'Voiceprints stay isolated per user. Anonymous labels remain conversation-local until you choose a name.',
          ),
          const SizedBox(height: 24),
          if (controller.speakers.isEmpty)
            const GlassSurface(
              child: EmptyState(
                icon: Icons.record_voice_over_outlined,
                title: 'No recurring speakers yet',
                message:
                    'Diarized speech and a confident cross-recording match are required.',
              ),
            )
          else
            for (final speaker in controller.speakers)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GlassSurface(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: <Widget>[
                      CircleAvatar(
                        backgroundColor: palette.accentSoft,
                        child: const Icon(Icons.person_outline),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              speaker.name ?? 'Unnamed recurring speaker',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${speaker.occurrences} stored turns',
                              style: TextStyle(color: palette.textMuted),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: speaker.matchingEnabled,
                        onChanged: (value) =>
                            controller.setSpeakerMatching(speaker.id, value),
                      ),
                      IconButton(
                        tooltip: 'Name speaker',
                        onPressed: () =>
                            _rename(context, speaker.id, speaker.name ?? ''),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      if (controller.speakers.length > 1)
                        IconButton(
                          tooltip: 'Merge another voice into this speaker',
                          onPressed: () => _merge(context, speaker.id),
                          icon: const Icon(Icons.merge_outlined),
                        ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
