import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'src/models/speaker.dart';
import 'src/widgets/selection_mixin.dart';

class SpeakersScreen extends StatefulWidget {
  const SpeakersScreen({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<SpeakersScreen> createState() => _SpeakersScreenState();
}

class _SpeakersScreenState extends State<SpeakersScreen>
    with SelectionMixin<SpeakersScreen> {
  AudioPlayer? _player;
  StreamSubscription<void>? _completeSubscription;
  String? _playingSpeakerId;
  bool _loadingPreview = false;
  bool _reevaluating = false;

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

  Future<void> _deleteSelected() async {
    final ids = selectedIds;
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
    await runBulkAction(
      controller.bulkDeleteSpeakers,
      success: (deleted) => 'Deleted ${deleted.length} speakers',
      failure: (error) => 'Could not delete speakers: $error',
    );
  }

  Future<void> _mergeSelected() async {
    final ids = selectedIds;
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
    await runBulkAction(
      (_) => controller.mergeSpeakers(targetId, sourceIds),
      success: (_) => 'Combined ${sourceIds.length + 1} speakers',
      failure: (error) => 'Could not combine speakers: $error',
    );
  }

  Future<void> _reevaluateSpeakers() async {
    if (_reevaluating) return;
    setState(() => _reevaluating = true);
    try {
      final result = await controller.reevaluateSpeakers();
      if (!mounted) return;
      final merged = result['mergedCount'] as int? ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            merged == 0
                ? 'Speaker profiles are already up to date'
                : 'Merged $merged matching speaker profile${merged == 1 ? '' : 's'}',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not re-evaluate speakers: $error')),
      );
    } finally {
      if (mounted) setState(() => _reevaluating = false);
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
    final visibleSpeakers = controller.speakers;
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
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Tooltip(
                  message: 'Re-evaluate and merge matching speakers',
                  child: IconButton.filledTonal(
                    onPressed: selecting || _reevaluating
                        ? null
                        : _reevaluateSpeakers,
                    icon: _reevaluating
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_rounded, size: 18),
                  ),
                ),
                const SizedBox(width: 6),
                if (selecting)
                  TextButton(onPressed: exitSelect, child: const Text('Done'))
                else
                  TextButton.icon(
                    onPressed: visibleSpeakers.isEmpty
                        ? null
                        : () => enterSelect(),
                    icon: const Icon(Icons.checklist_rounded, size: 18),
                    label: const Text('Select'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (selecting) ...<Widget>[
            _SpeakerSelectionBar(
              count: selectedCount,
              onDelete: _deleteSelected,
              onMerge: selectedCount >= 2 ? _mergeSelected : null,
            ),
            const SizedBox(height: 14),
          ],
          if (visibleSpeakers.isEmpty)
            const GlassSurface(
              child: EmptyState(
                icon: Icons.record_voice_over_outlined,
                title: 'No recurring speakers yet',
                message:
                    'A speaker appears after a full 10-second clean voice preview is available.',
              ),
            )
          else
            GlassSurface(
              padding: EdgeInsets.zero,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.panel - 1),
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
                        selecting: selecting,
                        selected: isSelected(visibleSpeakers[index].id),
                        onTap: selecting
                            ? () => toggleSelect(visibleSpeakers[index].id)
                            : null,
                        onLongPress: () =>
                            enterSelect(visibleSpeakers[index].id),
                        playing:
                            _playingSpeakerId == visibleSpeakers[index].id &&
                            _player?.state == PlayerState.playing,
                        loading:
                            _loadingPreview &&
                            _playingSpeakerId == visibleSpeakers[index].id,
                        onPreview: () => _togglePreview(visibleSpeakers[index]),
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
                                  onPressed: () =>
                                      Navigator.pop(context, false),
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
                            await controller.deleteSpeaker(
                              visibleSpeakers[index].id,
                            );
                          }
                        },
                      ),
                      if (index < visibleSpeakers.length - 1)
                        Divider(height: 1, color: palette.border),
                    ],
                  ],
                ),
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
                      : 'A full clean voice preview is needed',
                  child: IconButton.filledTonal(
                    onPressed: speaker.hasPreview ? onPreview : null,
                    icon: loading
                        ? const SizedBox.square(
                            dimension: 17,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                  ),
                ),
                Switch(
                  value: speaker.matchingEnabled,
                  onChanged: onMatchingChanged,
                ),
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
          color: selected
              ? palette.accentSoft.withValues(alpha: 0.25)
              : Colors.transparent,
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
