import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_processing_status.dart';
import 'main_shared.dart';
import 'main_theme.dart';
import 'src/memories/memory_cards.dart';
import 'src/memories/memory_filters.dart';
import 'src/memories/memory_detail_sheets.dart';
import 'src/models/memory.dart';
import 'src/widgets/selection_mixin.dart';
import 'l10n/gen/app_l10n.dart';

class MemoriesScreen extends StatefulWidget {
  const MemoriesScreen({
    super.key,
    required this.controller,
    this.embedded = false,
    this.tab,
  });

  final NeoRecallController controller;

  /// True when Library owns the page title and padding.
  final bool embedded;

  /// Which list to show. Library drives this from its segmented control; the
  /// standalone screen keeps its own state.
  final MemoriesTab? tab;

  @override
  State<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends State<MemoriesScreen>
    with SelectionMixin<MemoriesScreen> {
  MemoriesTab _ownTab = MemoriesTab.moments;

  MemoriesTab get _tab => widget.tab ?? _ownTab;
  MemoryFilter _filter = MemoryFilter.all;
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  NeoRecallController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _consumeWidgetRequest();
  }

  @override
  void didUpdateWidget(MemoriesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _consumeWidgetRequest();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Opens what a home-screen widget was tapped on.
  ///
  /// Claimed after the frame rather than during build: the request may switch
  /// the tab and then put a sheet on top of it, neither of which can happen
  /// while the page is still being laid out.
  void _consumeWidgetRequest() {
    if (!controller.pendingWidgetHighlightsTab &&
        controller.pendingWidgetMemoryId == null &&
        controller.pendingWidgetHighlightId == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (controller.takePendingWidgetHighlightsTab() &&
          _tab != MemoriesTab.highlights) {
        // Library owns the segment when embedded, so ask the controller rather
        // than setting a tab the parent would immediately overwrite.
        if (widget.embedded) {
          controller.selectLibraryTab(LibraryTab.highlights);
        } else {
          setState(() => _ownTab = MemoriesTab.highlights);
        }
        if (mounted) setState(exitSelect);
      }
      final memoryId = controller.takePendingWidgetMemoryId();
      if (memoryId != null) {
        for (final memory in controller.memories) {
          if (memory.id != memoryId) continue;
          await _openMemory(memory);
          return;
        }
      }
      final highlightId = controller.takePendingWidgetHighlightId();
      if (highlightId == null) return;
      for (final mini in controller.miniMemories) {
        if (mini.id != highlightId) continue;
        await _openMini(mini);
        return;
      }
    });
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
      case MemoryFilter.all:
        items = items.where((m) => !m.archived).toList();
      case MemoryFilter.pinned:
        items = items.where((m) => m.pinned && !m.archived).toList();
      case MemoryFilter.thisWeek:
        items = items
            .where((m) => !m.archived && !m.startedAt.isBefore(weekFloor))
            .toList();
      case MemoryFilter.meetings:
        items = items
            .where(
              (m) =>
                  !m.archived &&
                  (m.type == 'meeting' || m.type == 'project_discussion'),
            )
            .toList();
      case MemoryFilter.decisions:
        items = items
            .where((m) => !m.archived && m.type == 'decision')
            .toList();
      case MemoryFilter.openTasks:
        final openMemoryIds = controller.miniMemories
            .where((mini) => mini.isActionable && mini.isOpen)
            .map((mini) => mini.memoryId)
            .whereType<String>()
            .toSet();
        items = items
            .where((m) => !m.archived && openMemoryIds.contains(m.id))
            .toList();
      case MemoryFilter.archived:
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
      case MemoryFilter.openTasks:
        items = items.where((m) => m.isActionable && m.isOpen).toList();
      case MemoryFilter.all:
      case MemoryFilter.pinned:
      case MemoryFilter.thisWeek:
      case MemoryFilter.meetings:
      case MemoryFilter.decisions:
      case MemoryFilter.archived:
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

  Future<void> _bulk(String action) {
    final strings = AppL10n.of(context);
    return runBulkAction(
      (ids) => controller.bulkMemories(ids, action),
      success: (ids) => switch (action) {
        'delete' => strings.memoriesBulkDeleted(ids.length),
        'pin' => strings.memoriesBulkPinned(ids.length),
        'unpin' => strings.memoriesBulkUnpinned(ids.length),
        'archive' => strings.memoriesBulkArchived(ids.length),
        'unarchive' => strings.memoriesBulkRestored(ids.length),
        _ => strings.memoriesBulkUpdated(ids.length),
      },
      failure: (error) => strings.memoriesBulkFailed(error.toString()),
    );
  }

  Future<void> _renameSelected() async {
    if (selectedCount != 1) return;
    final id = selectedIds.first;
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
      exitSelect();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppL10n.of(context).memoriesRenameFailed(error.toString()),
          ),
        ),
      );
    }
  }

  Future<void> _mergeSelected() async {
    final ids = selectedIds;
    if (ids.length < 2) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final palette = neoRecallPaletteOf(dialogContext);
        return AlertDialog(
          backgroundColor: palette.bgCard,
          title: Text(AppL10n.of(dialogContext).memoriesMergeTitle),
          content: Text(
            AppL10n.of(dialogContext).memoriesMergeBody(ids.length),
            style: TextStyle(color: palette.textSecondary, height: 1.45),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(AppL10n.of(dialogContext).actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(AppL10n.of(dialogContext).memoriesMergeConfirm),
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
    exitSelect();

    try {
      final result = await controller.mergeMemories(ids);
      if (!mounted) return;
      final rewriteQueued = result['rewriteQueued'] == true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            rewriteQueued
                ? AppL10n.of(context).memoriesMergedQueued
                : AppL10n.of(context).memoriesMerged,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppL10n.of(context).memoriesMergeFailed(error.toString()),
          ),
        ),
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
          title: Text(AppL10n.of(context).memoriesRenameDialogTitle),
          content: TextField(
            controller: field,
            autofocus: true,
            maxLength: 160,
            decoration: InputDecoration(
              labelText: AppL10n.of(context).memoriesTitleLabel,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(AppL10n.of(context).actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(field.text),
              child: Text(AppL10n.of(context).actionSave),
            ),
          ],
        );
      },
    );
    field.dispose();
    return result;
  }

  Future<void> _openMemory(RecallMemory memory) async {
    if (selecting) {
      toggleSelect(memory.id);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => MemoryDetailSheet(
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
      builder: (context) => MiniDetailSheet(controller: controller, mini: mini),
    );
  }

  @override
  Widget build(BuildContext context) {
    final memories = _filteredMemories;
    final minis = _filteredMinis;
    final openTasks = controller.miniMemories
        .where((m) => m.isActionable && m.isOpen)
        .length;
    final strings = AppL10n.of(context);

    return RefreshIndicator(
      onRefresh: controller.refreshAll,
      child: ListView(
        padding: widget.embedded
            ? const EdgeInsets.only(bottom: 40)
            : const EdgeInsets.fromLTRB(24, 24, 24, 48),
        children: <Widget>[
          if (widget.embedded)
            Align(
              alignment: Alignment.centerRight,
              child: selecting
                  ? TextButton(
                      onPressed: exitSelect,
                      child: Text(strings.actionDone),
                    )
                  : TextButton.icon(
                      onPressed: memories.isEmpty ? null : () => enterSelect(),
                      icon: const Icon(Icons.checklist_rounded, size: 18),
                      label: Text(strings.actionSelect),
                    ),
            )
          else
            ScreenHeader(
              title: strings.navMemories,
              description: strings.memoriesDescription,
              trailing: selecting
                  ? TextButton(
                      onPressed: exitSelect,
                      child: Text(strings.actionDone),
                    )
                  : TextButton.icon(
                      onPressed: memories.isEmpty ? null : () => enterSelect(),
                      icon: const Icon(Icons.checklist_rounded, size: 18),
                      label: Text(strings.actionSelect),
                    ),
            ),
          ProcessingActivityBanner(
            status: controller.processingStatus,
            isRecording: controller.isRecording,
          ),
          if (controller.dailySummaries.isNotEmpty) ...<Widget>[
            DailySummaryCard(summary: controller.dailySummaries.first),
            const SizedBox(height: 16),
          ],
          SearchField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 14),
          if (!widget.embedded) ...<Widget>[
            MemoriesTabBar(
              tab: _tab,
              momentsCount: controller.memories
                  .where((m) => !m.archived)
                  .length,
              highlightsCount: controller.miniMemories.length,
              onChanged: (tab) => setState(() {
                _ownTab = tab;
                exitSelect();
              }),
            ),
            const SizedBox(height: 14),
          ],
          if (_tab == MemoriesTab.moments) ...<Widget>[
            FilterRow(
              filter: _filter,
              openTasks: openTasks,
              onChanged: (filter) => setState(() => _filter = filter),
            ),
            const SizedBox(height: 16),
            if (selecting) ...<Widget>[
              SelectionBar(
                count: selectedCount,
                onDelete: () => _bulk('delete'),
                onPin: () => _bulk('pin'),
                onUnpin: () => _bulk('unpin'),
                onArchive: () => _bulk(
                  _filter == MemoryFilter.archived ? 'unarchive' : 'archive',
                ),
                onRename: selectedCount == 1 ? _renameSelected : null,
                onMerge: selectedCount >= 2 ? _mergeSelected : null,
                archiveLabel: _filter == MemoryFilter.archived
                    ? strings.memoriesRestore
                    : strings.memoriesArchive,
              ),
              const SizedBox(height: 14),
            ],
            if (memories.isEmpty)
              AppPanel(
                child: EmptyState(
                  icon: Icons.auto_awesome_outlined,
                  title: _query.isNotEmpty || _filter != MemoryFilter.all
                      ? strings.memoriesEmptyFilteredTitle
                      : strings.memoriesEmptyTitle,
                  message: _query.isNotEmpty || _filter != MemoryFilter.all
                      ? strings.memoriesEmptyFilteredMessage
                      : strings.memoriesEmptyMessage,
                ),
              )
            else
              ...memories.map(
                (memory) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: MemoryCard(
                    memory: memory,
                    selected: isSelected(memory.id),
                    selecting: selecting,
                    onTap: () => _openMemory(memory),
                    onLongPress: () => enterSelect(memory.id),
                  ),
                ),
              ),
          ] else ...<Widget>[
            MiniFilterHint(
              openTasks: openTasks,
              filter: _filter,
              onShowOpenTasks: () =>
                  setState(() => _filter = MemoryFilter.openTasks),
              onShowAll: () => setState(() => _filter = MemoryFilter.all),
            ),
            const SizedBox(height: 12),
            if (minis.isEmpty)
              AppPanel(
                child: EmptyState(
                  icon: Icons.timeline_outlined,
                  title: strings.memoriesNoActionItemsTitle,
                  message: strings.memoriesNoActionItemsMessage,
                ),
              )
            else
              MiniTimeline(
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
