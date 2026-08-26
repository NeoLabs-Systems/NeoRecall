import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'src/models/memory.dart';

String _formatDay(DateTime value) {
  const months = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final local = value.toLocal();
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}

String _formatShortDate(DateTime value) {
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = value.toLocal();
  return '${months[local.month - 1]} ${local.day}';
}

String _formatTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $period';
}

String _formatDateTime(DateTime value) =>
    '${_formatShortDate(value)}, ${_formatTime(value)}';

String _formatFullDateTime(DateTime value) =>
    '${_formatDay(value)} · ${_formatTime(value)}';

enum _MemoriesTab { moments, highlights }

enum _MemoryFilter {
  all,
  pinned,
  thisWeek,
  meetings,
  decisions,
  openTasks,
  archived,
}

class MemoriesScreen extends StatefulWidget {
  const MemoriesScreen({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends State<MemoriesScreen> {
  _MemoriesTab _tab = _MemoriesTab.moments;
  _MemoryFilter _filter = _MemoryFilter.all;
  bool _selecting = false;
  final Set<String> _selected = <String>{};
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  NeoRecallController get controller => widget.controller;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<RecallMemory> get _filteredMemories {
    final now = DateTime.now();
    final weekStart = now.subtract(Duration(days: now.weekday - 1));
    final weekFloor = DateTime(weekStart.year, weekStart.month, weekStart.day);
    var items = controller.memories.toList();

    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      items = items
          .where(
            (m) =>
                m.title.toLowerCase().contains(q) ||
                m.summary.toLowerCase().contains(q) ||
                m.topics.any((t) => t.toLowerCase().contains(q)),
          )
          .toList();
    }

    switch (_filter) {
      case _MemoryFilter.all:
        items = items.where((m) => !m.archived).toList();
      case _MemoryFilter.pinned:
        items = items.where((m) => m.pinned && !m.archived).toList();
      case _MemoryFilter.thisWeek:
        items = items
            .where((m) => !m.archived && !m.startedAt.isBefore(weekFloor))
            .toList();
      case _MemoryFilter.meetings:
        items = items
            .where(
              (m) =>
                  !m.archived &&
                  (m.type == 'meeting' || m.type == 'project_discussion'),
            )
            .toList();
      case _MemoryFilter.decisions:
        items = items
            .where((m) => !m.archived && m.type == 'decision')
            .toList();
      case _MemoryFilter.openTasks:
        final openMemoryIds = controller.miniMemories
            .where((mini) => mini.isActionable && mini.isOpen)
            .map((mini) => mini.memoryId)
            .whereType<String>()
            .toSet();
        items = items
            .where((m) => !m.archived && openMemoryIds.contains(m.id))
            .toList();
      case _MemoryFilter.archived:
        items = items.where((m) => m.archived).toList();
    }
    return items;
  }

  List<MiniMemory> get _filteredMinis {
    var items = controller.miniMemories.toList();
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      items = items
          .where(
            (m) =>
                m.text.toLowerCase().contains(q) ||
                (m.memoryTitle?.toLowerCase().contains(q) ?? false),
          )
          .toList();
    }
    switch (_filter) {
      case _MemoryFilter.openTasks:
        items = items.where((m) => m.isActionable && m.isOpen).toList();
      case _MemoryFilter.all:
      case _MemoryFilter.pinned:
      case _MemoryFilter.thisWeek:
      case _MemoryFilter.meetings:
      case _MemoryFilter.decisions:
      case _MemoryFilter.archived:
        break;
    }
    items.sort((a, b) {
      final aAt =
          a.timelineAt ?? a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bAt =
          b.timelineAt ?? b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bAt.compareTo(aAt);
    });
    return items;
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

  Future<void> _bulk(String action) async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    try {
      await controller.bulkMemories(ids, action);
      if (!mounted) return;
      _exitSelect();
      final label = switch (action) {
        'delete' => 'Deleted ${ids.length} memories',
        'pin' => 'Pinned ${ids.length} memories',
        'unpin' => 'Unpinned ${ids.length} memories',
        'archive' => 'Archived ${ids.length} memories',
        'unarchive' => 'Restored ${ids.length} memories',
        _ => 'Updated ${ids.length} memories',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(label)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update memories: $error')),
      );
    }
  }

  Future<void> _renameSelected() async {
    if (_selected.length != 1) return;
    final id = _selected.first;
    RecallMemory? memory;
    for (final item in controller.memories) {
      if (item.id == id) {
        memory = item;
        break;
      }
    }
    if (memory == null) return;
    final title = await _promptRename(memory.title);
    if (title == null || title.trim().isEmpty || title == memory.title) return;
    try {
      await controller.renameMemory(id, title.trim());
      if (!mounted) return;
      _exitSelect();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not rename: $error')));
    }
  }

  Future<void> _mergeSelected() async {
    final ids = _selected.toList();
    if (ids.length < 2) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final palette = neoRecallPaletteOf(dialogContext);
        return AlertDialog(
          backgroundColor: palette.bgCard,
          title: const Text('Merge memories?'),
          content: Text(
            'Combine ${ids.length} memories into one. Highlights and conversation evidence stay; a new title and description are written for the combined moment.',
            style: TextStyle(color: palette.textSecondary, height: 1.45),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Merge'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    // Combining evidence and highlights is server-side bookkeeping and returns
    // at once; only the reworded description is left to a background job. So
    // selection closes immediately and the one message the user gets is the
    // result, rather than a spinner and a progress note it would replace.
    _exitSelect();

    try {
      final result = await controller.mergeMemories(ids);
      if (!mounted) return;
      final rewriteQueued = result['rewriteQueued'] == true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            rewriteQueued
                ? 'Memories merged. The description will update shortly.'
                : 'Memories merged.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not merge memories: $error')),
      );
    }
  }

  Future<String?> _promptRename(String current) async {
    final field = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        final palette = neoRecallPaletteOf(context);
        return AlertDialog(
          backgroundColor: palette.bgCard,
          title: const Text('Rename memory'),
          content: TextField(
            controller: field,
            autofocus: true,
            maxLength: 160,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(field.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    field.dispose();
    return result;
  }

  Future<void> _openMemory(RecallMemory memory) async {
    if (_selecting) {
      _toggleSelect(memory.id);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _MemoryDetailSheet(
        controller: controller,
        memory: memory,
        onRename: () async {
          final title = await _promptRename(memory.title);
          if (title == null || title.trim().isEmpty) return;
          await controller.renameMemory(memory.id, title.trim());
        },
      ),
    );
  }

  Future<void> _openMini(MiniMemory mini) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) =>
          _MiniDetailSheet(controller: controller, mini: mini),
    );
  }

  @override
  Widget build(BuildContext context) {
    final memories = _filteredMemories;
    final minis = _filteredMinis;
    final openTasks = controller.miniMemories
        .where((m) => m.isActionable && m.isOpen)
        .length;

    return RefreshIndicator(
      onRefresh: controller.refreshAll,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 48),
        children: <Widget>[
          ScreenHeader(
            eyebrow: 'MEMORIES',
            title: 'Moments that matter',
            description:
                'Your conversations, distilled into clear memories and actionable highlights — automatically.',
            trailing: _selecting
                ? TextButton(onPressed: _exitSelect, child: const Text('Done'))
                : TextButton.icon(
                    onPressed: memories.isEmpty ? null : () => _enterSelect(),
                    icon: const Icon(Icons.checklist_rounded, size: 18),
                    label: const Text('Select'),
                  ),
          ),
          if (controller.dailySummaries.isNotEmpty) ...<Widget>[
            _DailySummaryCard(summary: controller.dailySummaries.first),
            const SizedBox(height: 16),
          ],
          _SearchField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 14),
          _TabBar(
            tab: _tab,
            momentsCount: controller.memories.where((m) => !m.archived).length,
            highlightsCount: controller.miniMemories.length,
            onChanged: (tab) => setState(() {
              _tab = tab;
              _exitSelect();
            }),
          ),
          const SizedBox(height: 14),
          if (_tab == _MemoriesTab.moments) ...<Widget>[
            _FilterRow(
              filter: _filter,
              openTasks: openTasks,
              onChanged: (filter) => setState(() => _filter = filter),
            ),
            const SizedBox(height: 16),
            if (_selecting) ...<Widget>[
              _SelectionBar(
                count: _selected.length,
                onDelete: () => _bulk('delete'),
                onPin: () => _bulk('pin'),
                onUnpin: () => _bulk('unpin'),
                onArchive: () => _bulk(
                  _filter == _MemoryFilter.archived ? 'unarchive' : 'archive',
                ),
                onRename: _selected.length == 1 ? _renameSelected : null,
                onMerge: _selected.length >= 2 ? _mergeSelected : null,
                archiveLabel: _filter == _MemoryFilter.archived
                    ? 'Restore'
                    : 'Archive',
              ),
              const SizedBox(height: 14),
            ],
            if (memories.isEmpty)
              GlassSurface(
                child: EmptyState(
                  icon: Icons.auto_awesome_outlined,
                  title: _query.isNotEmpty || _filter != _MemoryFilter.all
                      ? 'No matching memories'
                      : 'Nothing here yet',
                  message: _query.isNotEmpty || _filter != _MemoryFilter.all
                      ? 'Try another filter or clear the search.'
                      : 'Keep recording. When a conversation ends, NeoRecall quietly turns it into a memory.',
                ),
              )
            else
              ...memories.map(
                (memory) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _MemoryCard(
                    memory: memory,
                    selected: _selected.contains(memory.id),
                    selecting: _selecting,
                    onTap: () => _openMemory(memory),
                    onLongPress: () => _enterSelect(memory.id),
                  ),
                ),
              ),
          ] else ...<Widget>[
            _MiniFilterHint(
              openTasks: openTasks,
              filter: _filter,
              onShowOpenTasks: () =>
                  setState(() => _filter = _MemoryFilter.openTasks),
              onShowAll: () => setState(() => _filter = _MemoryFilter.all),
            ),
            const SizedBox(height: 12),
            if (minis.isEmpty)
              const GlassSurface(
                child: EmptyState(
                  icon: Icons.timeline_outlined,
                  title: 'No action items yet',
                  message:
                      'Concrete assignments and commitments will appear here when a conversation creates them.',
                ),
              )
            else
              _MiniTimeline(
                items: minis,
                onTap: _openMini,
                onToggleTask: (mini) async {
                  final next = mini.isCompleted ? 'open' : 'completed';
                  await controller.updateMiniMemory(mini.id, next);
                },
              ),
          ],
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: TextStyle(color: palette.textPrimary),
      decoration: InputDecoration(
        hintText: 'Search memories…',
        prefixIcon: Icon(Icons.search_rounded, color: palette.textMuted),
        filled: true,
        fillColor: palette.bgSecondary.withValues(alpha: 0.72),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.input),
          borderSide: BorderSide(color: palette.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.input),
          borderSide: BorderSide(color: palette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.input),
          borderSide: BorderSide(color: palette.accent.withValues(alpha: 0.55)),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tab,
    required this.momentsCount,
    required this.highlightsCount,
    required this.onChanged,
  });

  final _MemoriesTab tab;
  final int momentsCount;
  final int highlightsCount;
  final ValueChanged<_MemoriesTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.bgSecondary.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _TabChip(
              label: 'Moments',
              count: momentsCount,
              selected: tab == _MemoriesTab.moments,
              onTap: () => onChanged(_MemoriesTab.moments),
            ),
          ),
          Expanded(
            child: _TabChip(
              label: 'Highlights',
              count: highlightsCount,
              selected: tab == _MemoriesTab.highlights,
              onTap: () => onChanged(_MemoriesTab.highlights),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? palette.bgCard.withValues(alpha: 0.95)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            boxShadow: selected
                ? <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? palette.textPrimary : palette.textMuted,
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$count',
                style: TextStyle(
                  color: selected ? palette.accentHover : palette.textMuted,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.filter,
    required this.openTasks,
    required this.onChanged,
  });

  final _MemoryFilter filter;
  final int openTasks;
  final ValueChanged<_MemoryFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final chips = <(_MemoryFilter, String)>[
      (_MemoryFilter.all, 'All'),
      (_MemoryFilter.pinned, 'Pinned'),
      (_MemoryFilter.thisWeek, 'This week'),
      (_MemoryFilter.meetings, 'Meetings'),
      (_MemoryFilter.decisions, 'Decisions'),
      (
        _MemoryFilter.openTasks,
        openTasks > 0 ? 'Open tasks ($openTasks)' : 'Open tasks',
      ),
      (_MemoryFilter.archived, 'Archived'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (final chip in chips)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(chip.$2),
                selected: filter == chip.$1,
                onSelected: (_) => onChanged(chip.$1),
                showCheckmark: false,
              ),
            ),
        ],
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onDelete,
    required this.onPin,
    required this.onUnpin,
    required this.onArchive,
    required this.archiveLabel,
    this.onRename,
    this.onMerge,
  });

  final int count;
  final VoidCallback onDelete;
  final VoidCallback onPin;
  final VoidCallback onUnpin;
  final VoidCallback onArchive;
  final String archiveLabel;
  final VoidCallback? onRename;
  final VoidCallback? onMerge;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final enabled = count > 0;
    return GlassSurface(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 6,
        children: <Widget>[
          Text(
            count == 0 ? 'Select memories' : '$count selected',
            style: TextStyle(
              color: palette.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          Wrap(
            children: <Widget>[
              if (onMerge != null)
                _ActionIcon(
                  tooltip: 'Merge',
                  icon: Icons.merge_type_rounded,
                  onPressed: onMerge,
                ),
              if (onRename != null)
                _ActionIcon(
                  tooltip: 'Rename',
                  icon: Icons.drive_file_rename_outline_rounded,
                  onPressed: enabled ? onRename : null,
                ),
              _ActionIcon(
                tooltip: 'Pin',
                icon: Icons.push_pin_outlined,
                onPressed: enabled ? onPin : null,
              ),
              _ActionIcon(
                tooltip: 'Unpin',
                icon: Icons.push_pin,
                onPressed: enabled ? onUnpin : null,
              ),
              _ActionIcon(
                tooltip: archiveLabel,
                icon: archiveLabel == 'Restore'
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
                onPressed: enabled ? onArchive : null,
              ),
              _ActionIcon(
                tooltip: 'Delete',
                icon: Icons.delete_outline_rounded,
                danger: true,
                onPressed: enabled ? onDelete : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
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

class _DailySummaryCard extends StatelessWidget {
  const _DailySummaryCard({required this.summary});

  final Map summary;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final date = summary['local_date'] as String? ?? '';
    final text = summary['summary_en'] as String? ?? '';
    return GlassSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.accentMuted,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Text('☀️', style: TextStyle(fontSize: 20)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Today’s story',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      date,
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(text, style: TextStyle(color: palette.textSoft, height: 1.5)),
        ],
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({
    required this.memory,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final RecallMemory memory;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final date = _formatDateTime(memory.startedAt);
    final preview = memory.summary.length > 140
        ? '${memory.summary.substring(0, 140).trimRight()}…'
        : memory.summary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.panel),
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: palette.panelGradient,
            borderRadius: BorderRadius.circular(AppRadius.panel),
            border: Border.all(
              color: selected
                  ? palette.accent.withValues(alpha: 0.55)
                  : palette.glassBorder,
              width: selected ? 1.5 : 1,
            ),
            boxShadow: softPanelShadow(palette),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (selecting) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 10, right: 10),
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color: selected ? palette.accent : palette.textMuted,
                    size: 22,
                  ),
                ),
              ],
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.bgSecondary.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: palette.border),
                ),
                child: Text(memory.emoji, style: const TextStyle(fontSize: 26)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            memory.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: 16.5,
                              fontWeight: FontWeight.w800,
                              height: 1.25,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                        if (memory.pinned)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Icon(
                              Icons.push_pin_rounded,
                              size: 15,
                              color: palette.accentHover,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.textSoft,
                        height: 1.45,
                        fontSize: 13.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Text(
                          date,
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        _SoftPill(label: memory.typeLabel),
                        if (memory.miniCount > 0)
                          _SoftPill(
                            label: memory.miniCount == 1
                                ? '1 highlight'
                                : '${memory.miniCount} highlights',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!selecting)
                Padding(
                  padding: const EdgeInsets.only(left: 4, top: 14),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: palette.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SoftPill extends StatelessWidget {
  const _SoftPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: palette.bgTertiary.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: palette.border),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: palette.textMuted,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _MiniFilterHint extends StatelessWidget {
  const _MiniFilterHint({
    required this.openTasks,
    required this.filter,
    required this.onShowOpenTasks,
    required this.onShowAll,
  });

  final int openTasks;
  final _MemoryFilter filter;
  final VoidCallback onShowOpenTasks;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          FilterChip(
            label: const Text('All highlights'),
            selected: filter != _MemoryFilter.openTasks,
            showCheckmark: false,
            onSelected: (_) => onShowAll(),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: Text(
              openTasks > 0 ? 'Open tasks ($openTasks)' : 'Open tasks',
            ),
            selected: filter == _MemoryFilter.openTasks,
            showCheckmark: false,
            onSelected: (_) => onShowOpenTasks(),
          ),
        ],
      ),
    );
  }
}

class _MiniTimeline extends StatelessWidget {
  const _MiniTimeline({
    required this.items,
    required this.onTap,
    required this.onToggleTask,
  });

  final List<MiniMemory> items;
  final ValueChanged<MiniMemory> onTap;
  final ValueChanged<MiniMemory> onToggleTask;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final groups = <String, List<MiniMemory>>{};
    final order = <String>[];
    for (final mini in items) {
      final at = (mini.timelineAt ?? mini.createdAt ?? DateTime.now())
          .toLocal();
      final key = _formatDay(at);
      groups.putIfAbsent(key, () {
        order.add(key);
        return <MiniMemory>[];
      });
      groups[key]!.add(mini);
    }

    return GlassSurface(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: <Widget>[
          for (final day in order) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
              child: Row(
                children: <Widget>[
                  Text(
                    day,
                    style: TextStyle(
                      color: palette.accentHover,
                      fontWeight: FontWeight.w800,
                      fontSize: 12.5,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Divider(color: palette.border, height: 1)),
                ],
              ),
            ),
            for (var i = 0; i < groups[day]!.length; i++)
              _MiniTimelineRow(
                mini: groups[day]![i],
                isLast: i == groups[day]!.length - 1 && day == order.last,
                onTap: () => onTap(groups[day]![i]),
                onToggle: groups[day]![i].isActionable
                    ? () => onToggleTask(groups[day]![i])
                    : null,
              ),
          ],
        ],
      ),
    );
  }
}

class _MiniTimelineRow extends StatelessWidget {
  const _MiniTimelineRow({
    required this.mini,
    required this.isLast,
    required this.onTap,
    this.onToggle,
  });

  final MiniMemory mini;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final time = mini.timelineAt != null ? _formatTime(mini.timelineAt!) : '';
    final completed = mini.isCompleted;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 28,
            child: Column(
              children: <Widget>[
                Container(
                  width: 12,
                  height: 12,
                  margin: const EdgeInsets.only(top: 14),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: completed
                        ? palette.success.withValues(alpha: 0.85)
                        : palette.accent.withValues(alpha: 0.85),
                    border: Border.all(color: palette.bgCard, width: 2),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      color: palette.borderLight,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 8, 4, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        mini.kindEmoji,
                        style: const TextStyle(fontSize: 18),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                _SoftPill(label: mini.kindLabel),
                                if (time.isNotEmpty) ...<Widget>[
                                  const SizedBox(width: 8),
                                  Text(
                                    time,
                                    style: TextStyle(
                                      color: palette.textMuted,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                                if (mini.dueAt != null &&
                                    mini.isOpen) ...<Widget>[
                                  const SizedBox(width: 8),
                                  Text(
                                    'Due ${_formatShortDate(mini.dueAt!)}',
                                    style: TextStyle(
                                      color: palette.warning,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              mini.text,
                              style: TextStyle(
                                color: completed
                                    ? palette.textMuted
                                    : palette.textPrimary,
                                height: 1.4,
                                fontSize: 14,
                                decoration: completed
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                            if (mini.memoryTitle != null) ...<Widget>[
                              const SizedBox(height: 6),
                              Text(
                                '${mini.memoryEmoji ?? '💭'} ${mini.memoryTitle}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (onToggle != null)
                        IconButton(
                          tooltip: completed ? 'Reopen' : 'Mark done',
                          onPressed: onToggle,
                          icon: Icon(
                            completed
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            color: completed
                                ? palette.success
                                : palette.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoryDetailSheet extends StatefulWidget {
  const _MemoryDetailSheet({
    required this.controller,
    required this.memory,
    required this.onRename,
  });

  final NeoRecallController controller;
  final RecallMemory memory;
  final Future<void> Function() onRename;

  @override
  State<_MemoryDetailSheet> createState() => _MemoryDetailSheetState();
}

class _MemoryDetailSheetState extends State<_MemoryDetailSheet> {
  Map<String, dynamic>? _detail;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final detail = await widget.controller.loadMemoryDetail(widget.memory.id);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _sources {
    final raw = _detail?['sources'];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .where((row) => (row['text'] as String?)?.trim().isNotEmpty == true)
        .toList();
  }

  List<Map<String, dynamic>> get _minis {
    final raw = _detail?['miniMemories'] ?? _detail?['mini_memories'];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  List<Map<String, dynamic>> get _entities {
    final raw = _detail?['entities'];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final memory = widget.memory;
    final height = MediaQuery.sizeOf(context).height * 0.88;

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: palette.bgPrimary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: palette.borderLight),
      ),
      child: Column(
        children: <Widget>[
          const SizedBox(height: 10),
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: palette.borderLight,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: palette.bgSecondary,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: palette.border),
                  ),
                  child: Text(
                    memory.emoji,
                    style: const TextStyle(fontSize: 28),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        memory.title,
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _formatFullDateTime(memory.startedAt),
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) async {
                    final navigator = Navigator.of(context);
                    switch (value) {
                      case 'rename':
                        await widget.onRename();
                        if (mounted) navigator.pop();
                      case 'pin':
                        await widget.controller.updateMemory(
                          memory.id,
                          pinned: !memory.pinned,
                        );
                        if (mounted) navigator.pop();
                      case 'archive':
                        await widget.controller.updateMemory(
                          memory.id,
                          archived: !memory.archived,
                        );
                        if (mounted) navigator.pop();
                      case 'delete':
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('Delete memory?'),
                            content: const Text(
                              'This removes the memory and its highlights. Transcripts stay available on the timeline.',
                            ),
                            actions: <Widget>[
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(dialogContext).pop(false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.of(dialogContext).pop(true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) {
                          await widget.controller.deleteMemory(memory.id);
                          if (mounted) navigator.pop();
                        }
                    }
                  },
                  itemBuilder: (context) => <PopupMenuEntry<String>>[
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(
                      value: 'pin',
                      child: Text(memory.pinned ? 'Unpin' : 'Pin'),
                    ),
                    PopupMenuItem(
                      value: 'archive',
                      child: Text(memory.archived ? 'Restore' : 'Archive'),
                    ),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Could not load details.\n$_error',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: palette.textMuted),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
                    children: <Widget>[
                      Text(
                        memory.summary,
                        style: TextStyle(
                          color: palette.textSoft,
                          height: 1.55,
                          fontSize: 15,
                        ),
                      ),
                      if (memory.topics.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: memory.topics
                              .map((topic) => _SoftPill(label: topic))
                              .toList(),
                        ),
                      ],
                      if (_entities.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 22),
                        Text('People & things', style: _sectionStyle(palette)),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _entities.map((entity) {
                            final name =
                                entity['display_name'] as String? ??
                                entity['canonical_name_en'] as String? ??
                                'Unknown';
                            final kind = entity['kind'] as String? ?? '';
                            final emoji = switch (kind) {
                              'person' => '👤',
                              'organization' => '🏢',
                              'project' => '📁',
                              'location' => '📍',
                              _ => '🏷️',
                            };
                            return _SoftPill(label: '$emoji $name');
                          }).toList(),
                        ),
                      ],
                      if (_minis.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 22),
                        Text('Highlights', style: _sectionStyle(palette)),
                        const SizedBox(height: 10),
                        for (final mini in _minis)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: palette.bgSecondary.withValues(
                                  alpha: 0.7,
                                ),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: palette.border),
                              ),
                              child: Text(
                                mini['text_en'] as String? ?? '',
                                style: TextStyle(
                                  color: palette.textPrimary,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ),
                      ],
                      const SizedBox(height: 22),
                      Text(
                        'From the conversation',
                        style: _sectionStyle(palette),
                      ),
                      const SizedBox(height: 10),
                      if (_sources.isEmpty)
                        Text(
                          'No transcript excerpts are linked to this memory.',
                          style: TextStyle(
                            color: palette.textMuted,
                            height: 1.4,
                          ),
                        )
                      else
                        for (final source in _sources)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: palette.bgSecondary.withValues(
                                  alpha: 0.55,
                                ),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: palette.border),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  if (source['started_at'] != null)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: Text(
                                        _formatTime(
                                          DateTime.parse(
                                            source['started_at'] as String,
                                          ),
                                        ),
                                        style: TextStyle(
                                          color: palette.accentHover,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  Text(
                                    source['text'] as String? ?? '',
                                    style: TextStyle(
                                      color: palette.textSoft,
                                      height: 1.5,
                                      fontSize: 13.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  TextStyle _sectionStyle(NeoRecallPalette palette) => TextStyle(
    color: palette.textPrimary,
    fontWeight: FontWeight.w800,
    fontSize: 15,
  );
}

class _MiniDetailSheet extends StatefulWidget {
  const _MiniDetailSheet({required this.controller, required this.mini});

  final NeoRecallController controller;
  final MiniMemory mini;

  @override
  State<_MiniDetailSheet> createState() => _MiniDetailSheetState();
}

class _MiniDetailSheetState extends State<_MiniDetailSheet> {
  Map<String, dynamic>? _detail;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final detail = await widget.controller.loadMiniMemoryDetail(
        widget.mini.id,
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _sources {
    final raw = _detail?['sources'];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .where((row) => (row['text'] as String?)?.trim().isNotEmpty == true)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final mini = widget.mini;
    final height = MediaQuery.sizeOf(context).height * 0.72;

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: palette.bgPrimary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: palette.borderLight),
      ),
      child: Column(
        children: <Widget>[
          const SizedBox(height: 10),
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: palette.borderLight,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(
              children: <Widget>[
                Text(mini.kindEmoji, style: const TextStyle(fontSize: 28)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        mini.kindLabel,
                        style: TextStyle(
                          color: palette.accentHover,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        mini.text,
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                if (mini.isActionable)
                  IconButton(
                    tooltip: mini.isCompleted ? 'Reopen' : 'Mark done',
                    onPressed: () async {
                      final navigator = Navigator.of(context);
                      final next = mini.isCompleted ? 'open' : 'completed';
                      await widget.controller.updateMiniMemory(mini.id, next);
                      if (mounted) navigator.pop();
                    },
                    icon: Icon(
                      mini.isCompleted
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      color: mini.isCompleted
                          ? palette.success
                          : palette.textMuted,
                    ),
                  ),
                IconButton(
                  tooltip: 'Delete',
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    await widget.controller.deleteMiniMemory(mini.id);
                    if (mounted) navigator.pop();
                  },
                  icon: Icon(Icons.delete_outline, color: palette.danger),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Text(
                      'Could not load highlight.\n$_error',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: palette.textMuted),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
                    children: <Widget>[
                      if (mini.memoryTitle != null) ...<Widget>[
                        Text(
                          'From ${mini.memoryEmoji ?? '💭'} ${mini.memoryTitle}',
                          style: TextStyle(
                            color: palette.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (mini.dueAt != null) ...<Widget>[
                        Text(
                          'Due ${_formatFullDateTime(mini.dueAt!)}',
                          style: TextStyle(
                            color: palette.warning,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      Text(
                        'Evidence',
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (_sources.isEmpty)
                        Text(
                          'No transcript excerpts linked.',
                          style: TextStyle(color: palette.textMuted),
                        )
                      else
                        for (final source in _sources)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: palette.bgSecondary.withValues(
                                  alpha: 0.55,
                                ),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: palette.border),
                              ),
                              child: Text(
                                source['text'] as String? ?? '',
                                style: TextStyle(
                                  color: palette.textSoft,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
