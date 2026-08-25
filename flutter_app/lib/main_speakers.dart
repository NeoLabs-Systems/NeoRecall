import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_theme.dart';
import 'src/models/speaker.dart';

class SpeakersScreen extends StatefulWidget {
  const SpeakersScreen({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<SpeakersScreen> createState() => _SpeakersScreenState();
}

class _SpeakersScreenState extends State<SpeakersScreen> {
  AudioPlayer? _player;
  StreamSubscription<void>? _completeSubscription;
  String? _playingSpeakerId;
  bool _loadingPreview = false;
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  NeoRecallController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _completeSubscription?.cancel();
    final player = _player;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = AudioPlayer();
    _player = player;
    _completeSubscription = player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingSpeakerId = null);
    });
    return player;
  }

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

  Future<void> _merge(
    BuildContext context,
    String targetId,
    List<RecallSpeaker> speakers,
  ) async {
    final sourceId = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Merge another voice into this speaker'),
        children: speakers
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

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _enterSelect([String? id]) {
    HapticFeedback.selectionClick();
    setState(() {
      _selecting = true;
      if (id != null) _selected.add(id);
    });
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Delete ${ids.length} speaker${ids.length == 1 ? '' : 's'}?',
        ),
        content: const Text(
          'This will permanently delete these speaker profiles. Associated transcript segments will no longer identify them.',
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
    if (confirm != true) return;
    try {
      await controller.bulkDeleteSpeakers(ids);
      if (!mounted) return;
      _exitSelect();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deleted ${ids.length} speakers')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete speakers: $error')),
      );
    }
  }

  Future<void> _mergeSelected() async {
    final ids = _selected.toList();
    if (ids.length < 2) return;
    final selectedSpeakers = controller.speakers
        .where((speaker) => ids.contains(speaker.id))
        .toList();
    final targetId = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Combine into which speaker?'),
        children: selectedSpeakers
            .map(
              (speaker) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, speaker.id),
                child: Text(speaker.name ?? 'Unnamed recurring speaker'),
              ),
            )
            .toList(),
      ),
    );
    if (targetId == null || !mounted) return;
    final sourceIds = ids.where((id) => id != targetId).toList();
    try {
      await controller.mergeSpeakers(targetId, sourceIds);
      if (!mounted) return;
      _exitSelect();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Combined ${sourceIds.length + 1} speakers')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not combine speakers: $error')),
      );
    }
  }

  Future<void> _togglePreview(RecallSpeaker speaker) async {
    if (_loadingPreview || !speaker.hasPreview) return;
    final player = _ensurePlayer();
    if (_playingSpeakerId == speaker.id) {
      if (player.state == PlayerState.playing) {
        await player.pause();
        if (mounted) setState(() {});
        return;
      }
      if (player.state == PlayerState.paused) {
        await player.resume();
        if (mounted) setState(() {});
        return;
      }
    }
    setState(() {
      _loadingPreview = true;
      _playingSpeakerId = speaker.id;
    });
    try {
      await player.stop();
      await player.play(
        BytesSource(
          await controller.api.speakerPreview(speaker.id),
          mimeType: 'audio/wav',
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _playingSpeakerId = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Preview failed: $error')));
    } finally {
      if (mounted) setState(() => _loadingPreview = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final visibleSpeakers = controller.speakers
        .where(
          (speaker) =>
              speaker.totalDurationMs != null &&
              speaker.totalDurationMs! >= 5000,
        )
        .toList();
    return RefreshIndicator(
      onRefresh: controller.refreshAll,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 48),
        children: <Widget>[
          ScreenHeader(
            eyebrow: 'SPEAKERS',
            title: 'Recurring voices',
            description:
                'Recognize a voice with a short clean sample, then name or merge its recurring profile.',
            trailing: _selecting
                ? TextButton(onPressed: _exitSelect, child: const Text('Done'))
                : TextButton.icon(
                    onPressed: visibleSpeakers.isEmpty
                        ? null
                        : () => _enterSelect(),
                    icon: const Icon(Icons.checklist_rounded, size: 18),
                    label: const Text('Select'),
                  ),
          ),
          const SizedBox(height: 20),
          if (_selecting) ...<Widget>[
            _SpeakerSelectionBar(
              count: _selected.length,
              onDelete: _deleteSelected,
              onMerge: _selected.length >= 2 ? _mergeSelected : null,
            ),
            const SizedBox(height: 14),
          ],
          if (visibleSpeakers.isEmpty)
            const GlassSurface(
              child: EmptyState(
                icon: Icons.record_voice_over_outlined,
                title: 'No recurring speakers yet',
                message:
                    'Diarized speech and a confident cross-recording match are required.',
              ),
            )
          else
            GlassSurface(
              padding: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  for (
                    var index = 0;
                    index < visibleSpeakers.length;
                    index++
                  ) ...<Widget>[
                    _SpeakerRow(
                      speaker: visibleSpeakers[index],
                      palette: palette,
                      selecting: _selecting,
                      selected: _selected.contains(visibleSpeakers[index].id),
                      onTap: _selecting
                          ? () => _toggleSelect(visibleSpeakers[index].id)
                          : null,
                      onLongPress: () =>
                          _enterSelect(visibleSpeakers[index].id),
                      playing:
                          _playingSpeakerId == visibleSpeakers[index].id &&
                          _player?.state == PlayerState.playing,
                      loading:
                          _loadingPreview &&
                          _playingSpeakerId == visibleSpeakers[index].id,
                      onPreview: () =>
                          _togglePreview(visibleSpeakers[index]),
                      onMatchingChanged: (value) =>
                          controller.setSpeakerMatching(
                            visibleSpeakers[index].id,
                            value,
                          ),
                      onRename: () => _rename(
                        context,
                        visibleSpeakers[index].id,
                        visibleSpeakers[index].name ?? '',
                      ),
                      onMerge: visibleSpeakers.length > 1
                          ? () => _merge(
                                context,
                                visibleSpeakers[index].id,
                                visibleSpeakers,
                              )
                          : null,
                      onDelete: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Delete speaker?'),
                            content: const Text(
                              'This will permanently delete this speaker profile. Associated transcript segments will no longer identify this speaker.',
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
                        if (confirm == true) {
                          await controller.deleteSpeaker(visibleSpeakers[index].id);
                        }
                      },
                    ),
                    if (index < visibleSpeakers.length - 1)
                      Divider(height: 1, color: palette.border),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SpeakerRow extends StatelessWidget {
  const _SpeakerRow({
    required this.speaker,
    required this.palette,
    required this.selecting,
    required this.selected,
    this.onTap,
    required this.onLongPress,
    required this.playing,
    required this.loading,
    required this.onPreview,
    required this.onMatchingChanged,
    required this.onRename,
    this.onMerge,
    required this.onDelete,
  });

  final RecallSpeaker speaker;
  final NeoRecallPalette palette;
  final bool selecting;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;
  final bool playing;
  final bool loading;
  final VoidCallback onPreview;
  final ValueChanged<bool> onMatchingChanged;
  final VoidCallback onRename;
  final VoidCallback? onMerge;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final label = speaker.name ?? 'Unnamed recurring speaker';
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;
        final identity = Row(
          children: <Widget>[
            if (selecting) ...<Widget>[
              Icon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: selected ? palette.accent : palette.textMuted,
                size: 22,
              ),
              const SizedBox(width: 13),
            ],
            CircleAvatar(
              radius: 20,
              backgroundColor: palette.accentSoft,
              child: Text(
                label.characters.first.toUpperCase(),
                style: TextStyle(
                  color: palette.accentHover,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    speaker.hasPreview
                        ? '${speaker.occurrences} stored turns · ${(speaker.previewDurationMs! / 1000).toStringAsFixed(1)} s clean preview'
                        : '${speaker.occurrences} stored turns · Preview pending a clean sample',
                    style: TextStyle(color: palette.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        );
        final actions = selecting
            ? <Widget>[]
            : <Widget>[
          Tooltip(
            message: speaker.hasPreview
                ? (playing ? 'Pause voice preview' : 'Play voice preview')
                : 'A clean 1–10 second sample is needed',
            child: IconButton.filledTonal(
              onPressed: speaker.hasPreview ? onPreview : null,
              icon: loading
                  ? const SizedBox.square(
                      dimension: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    ),
            ),
          ),
          Switch(value: speaker.matchingEnabled, onChanged: onMatchingChanged),
          IconButton(
            tooltip: 'Name speaker',
            onPressed: onRename,
            icon: const Icon(Icons.edit_outlined),
          ),
            if (onMerge != null)
              IconButton(
                tooltip: 'Merge another voice into this speaker',
                onPressed: onMerge,
                icon: const Icon(Icons.merge_outlined),
              ),
            IconButton(
              tooltip: 'Delete speaker',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ];
        return Material(
          color: selected ? palette.accentSoft.withValues(alpha: 0.25) : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 13, 10, 13),
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        identity,
                        if (actions.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: actions,
                            ),
                          ),
                        ],
                      ],
                    )
                  : Row(
                      children: <Widget>[
                        Expanded(child: identity),
                        const SizedBox(width: 10),
                        ...actions,
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _SpeakerSelectionBar extends StatelessWidget {
  const _SpeakerSelectionBar({
    required this.count,
    required this.onDelete,
    this.onMerge,
  });

  final int count;
  final VoidCallback onDelete;
  final VoidCallback? onMerge;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final enabled = count > 0;
    return GlassSurface(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          Text(
            count == 0 ? 'Select speakers' : '$count selected',
            style: TextStyle(
              color: palette.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const Spacer(),
          _SpeakerSelectionAction(
            tooltip: 'Combine into one speaker',
            icon: Icons.merge_type_rounded,
            onPressed: onMerge,
          ),
          _SpeakerSelectionAction(
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

class _SpeakerSelectionAction extends StatelessWidget {
  const _SpeakerSelectionAction({
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
