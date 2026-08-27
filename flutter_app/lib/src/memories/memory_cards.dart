import 'package:flutter/material.dart';

import '../../main_shared.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import '../models/memory.dart';
import 'memory_filters.dart';
import 'memory_formatting.dart';

class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.onChanged,
  });

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

class MemoriesTabBar extends StatelessWidget {
  const MemoriesTabBar({
    super.key,
    required this.tab,
    required this.momentsCount,
    required this.highlightsCount,
    required this.onChanged,
  });

  final MemoriesTab tab;
  final int momentsCount;
  final int highlightsCount;
  final ValueChanged<MemoriesTab> onChanged;

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
            child: TabChip(
              label: 'Moments',
              count: momentsCount,
              selected: tab == MemoriesTab.moments,
              onTap: () => onChanged(MemoriesTab.moments),
            ),
          ),
          Expanded(
            child: TabChip(
              label: 'Highlights',
              count: highlightsCount,
              selected: tab == MemoriesTab.highlights,
              onTap: () => onChanged(MemoriesTab.highlights),
            ),
          ),
        ],
      ),
    );
  }
}

class TabChip extends StatelessWidget {
  const TabChip({
    super.key,
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

class FilterRow extends StatelessWidget {
  const FilterRow({
    super.key,
    required this.filter,
    required this.openTasks,
    required this.onChanged,
  });

  final MemoryFilter filter;
  final int openTasks;
  final ValueChanged<MemoryFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final chips = <(MemoryFilter, String)>[
      (MemoryFilter.all, 'All'),
      (MemoryFilter.pinned, 'Pinned'),
      (MemoryFilter.thisWeek, 'This week'),
      (MemoryFilter.meetings, 'Meetings'),
      (MemoryFilter.decisions, 'Decisions'),
      (
        MemoryFilter.openTasks,
        openTasks > 0 ? 'Open tasks ($openTasks)' : 'Open tasks',
      ),
      (MemoryFilter.archived, 'Archived'),
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

class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
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
                ActionIcon(
                  tooltip: 'Merge',
                  icon: Icons.merge_type_rounded,
                  onPressed: onMerge,
                ),
              if (onRename != null)
                ActionIcon(
                  tooltip: 'Rename',
                  icon: Icons.drive_file_rename_outline_rounded,
                  onPressed: enabled ? onRename : null,
                ),
              ActionIcon(
                tooltip: 'Pin',
                icon: Icons.push_pin_outlined,
                onPressed: enabled ? onPin : null,
              ),
              ActionIcon(
                tooltip: 'Unpin',
                icon: Icons.push_pin,
                onPressed: enabled ? onUnpin : null,
              ),
              ActionIcon(
                tooltip: archiveLabel,
                icon: archiveLabel == 'Restore'
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
                onPressed: enabled ? onArchive : null,
              ),
              ActionIcon(
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

class ActionIcon extends StatelessWidget {
  const ActionIcon({
    super.key,
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

class DailySummaryCard extends StatelessWidget {
  const DailySummaryCard({super.key, required this.summary});

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

class MemoryCard extends StatelessWidget {
  const MemoryCard({
    super.key,
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
    final date = formatDateTime(memory.startedAt);
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
                        SoftPill(label: memory.typeLabel),
                        if (memory.miniCount > 0)
                          SoftPill(
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

class SoftPill extends StatelessWidget {
  const SoftPill({super.key, required this.label});

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

class MiniFilterHint extends StatelessWidget {
  const MiniFilterHint({
    super.key,
    required this.openTasks,
    required this.filter,
    required this.onShowOpenTasks,
    required this.onShowAll,
  });

  final int openTasks;
  final MemoryFilter filter;
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
            selected: filter != MemoryFilter.openTasks,
            showCheckmark: false,
            onSelected: (_) => onShowAll(),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: Text(
              openTasks > 0 ? 'Open tasks ($openTasks)' : 'Open tasks',
            ),
            selected: filter == MemoryFilter.openTasks,
            showCheckmark: false,
            onSelected: (_) => onShowOpenTasks(),
          ),
        ],
      ),
    );
  }
}

class MiniTimeline extends StatelessWidget {
  const MiniTimeline({
    super.key,
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
      final key = formatDay(at);
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
              MiniTimelineRow(
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

class MiniTimelineRow extends StatelessWidget {
  const MiniTimelineRow({
    super.key,
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
    final time = mini.timelineAt != null ? formatTime(mini.timelineAt!) : '';
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
                                SoftPill(label: mini.kindLabel),
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
                                    'Due ${formatShortDate(mini.dueAt!)}',
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
