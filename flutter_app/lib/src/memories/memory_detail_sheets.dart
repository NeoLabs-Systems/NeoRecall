import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../../main_controller.dart';
import '../../main_theme.dart';
import '../models/memory.dart';
import '../widgets/detail_sheet_mixin.dart';
import 'memory_cards.dart';
import 'memory_formatting.dart';

class MemoryDetailSheet extends StatefulWidget {
  const MemoryDetailSheet({
    super.key,
    required this.controller,
    required this.memory,
    required this.onRename,
  });

  final NeoRecallController controller;
  final RecallMemory memory;
  final Future<void> Function() onRename;

  @override
  State<MemoryDetailSheet> createState() => _MemoryDetailSheetState();
}

class _MemoryDetailSheetState extends State<MemoryDetailSheet>
    with DetailSheetMixin<MemoryDetailSheet> {
  @override
  Future<Map<String, dynamic>> fetchDetail() =>
      widget.controller.loadMemoryDetail(widget.memory.id);

  List<Map<String, dynamic>> get contextItems => listField('contextItems');

  Future<void> _addNote() async {
    final input = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add memory context'),
        content: TextField(
          controller: input,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'Add details that should improve this memory…',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input.text),
            child: const Text('Add and update'),
          ),
        ],
      ),
    );
    if (text?.trim().isEmpty ?? true) return;
    await widget.controller.addMemoryNoteContext(widget.memory.id, text!);
    await loadDetail();
  }

  Future<void> _addFile() async {
    final selection = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.any,
    );
    final file = selection?.files.single;
    if (file?.bytes == null) return;
    final extension = (file!.extension ?? '').toLowerCase();
    final contentType = switch (extension) {
      'pdf' => 'application/pdf',
      'docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'txt' => 'text/plain',
      'md' => 'text/markdown',
      'csv' => 'text/csv',
      'json' => 'application/json',
      'png' ||
      'jpg' ||
      'jpeg' ||
      'webp' => 'image/${extension == 'jpg' ? 'jpeg' : extension}',
      _ => 'application/octet-stream',
    };
    await widget.controller.addMemoryFileContext(
      widget.memory.id,
      file.bytes!,
      file.name,
      contentType,
    );
    await loadDetail();
  }

  Future<void> _removeContext(String id) async {
    await widget.controller.deleteMemoryContext(widget.memory.id, id);
    await loadDetail();
  }

  Future<void> _retryContext(String id) async {
    await widget.controller.retryMemoryContext(widget.memory.id, id);
    await loadDetail();
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
                        formatFullDateTime(memory.startedAt),
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
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : loadError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Could not load details.\n$loadError',
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
                              .map((topic) => SoftPill(label: topic))
                              .toList(),
                        ),
                      ],
                      if (entities.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 22),
                        Text('People & things', style: _sectionStyle(palette)),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: entities.map((entity) {
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
                            return SoftPill(label: '$emoji $name');
                          }).toList(),
                        ),
                      ],
                      if (miniMemories.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 22),
                        Text('Highlights', style: _sectionStyle(palette)),
                        const SizedBox(height: 10),
                        for (final mini in miniMemories)
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
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              'Context',
                              style: _sectionStyle(palette),
                            ),
                          ),
                          TextButton.icon(
                            key: const ValueKey<String>('memory-context-note'),
                            onPressed: _addNote,
                            icon: const Icon(Icons.edit_note_rounded, size: 18),
                            label: const Text('Note'),
                          ),
                          TextButton.icon(
                            key: const ValueKey<String>('memory-context-file'),
                            onPressed: _addFile,
                            icon: const Icon(
                              Icons.attach_file_rounded,
                              size: 18,
                            ),
                            label: const Text('File'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (contextItems.isEmpty)
                        Text(
                          'No notes or files are attached to this memory.',
                          style: TextStyle(color: palette.textMuted),
                        )
                      else
                        for (final item in contextItems)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: palette.bgSecondary.withValues(
                                  alpha: 0.65,
                                ),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: palette.border),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Icon(
                                    item['kind'] == 'image'
                                        ? Icons.image_outlined
                                        : item['kind'] == 'note'
                                        ? Icons.edit_note_rounded
                                        : item['kind'] == 'highlight'
                                        ? Icons.flag_outlined
                                        : Icons.description_outlined,
                                    color: palette.accentHover,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          (item['noteText'] ??
                                                  item['originalName'] ??
                                                  'Highlighted moment')
                                              .toString(),
                                          style: TextStyle(
                                            color: palette.textPrimary,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        if ((item['analysisText'] as String?)
                                                ?.trim()
                                                .isNotEmpty ==
                                            true) ...<Widget>[
                                          const SizedBox(height: 5),
                                          Text(
                                            item['analysisText'] as String,
                                            style: TextStyle(
                                              color: palette.textSoft,
                                              height: 1.4,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 5),
                                        Text(
                                          item['analysisState'] == 'ready'
                                              ? (item['usedByAi'] == true
                                                    ? 'Used by AI'
                                                    : 'Ready for AI')
                                              : (item['analysisErrorMessage'] ??
                                                        item['analysisState'])
                                                    .toString(),
                                          style: TextStyle(
                                            color: palette.textMuted,
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (item['originalAvailable'] == true &&
                                      (item['analysisState'] == 'failed' ||
                                          item['analysisState'] == 'skipped'))
                                    IconButton(
                                      tooltip: 'Retry analysis',
                                      onPressed: () =>
                                          _retryContext(item['id'] as String),
                                      icon: const Icon(
                                        Icons.refresh_rounded,
                                        size: 18,
                                      ),
                                    ),
                                  IconButton(
                                    tooltip: 'Remove context',
                                    onPressed: () =>
                                        _removeContext(item['id'] as String),
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 18,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      const SizedBox(height: 22),
                      Text(
                        'From the conversation',
                        style: _sectionStyle(palette),
                      ),
                      const SizedBox(height: 10),
                      if (sources.isEmpty)
                        Text(
                          'No transcript excerpts are linked to this memory.',
                          style: TextStyle(
                            color: palette.textMuted,
                            height: 1.4,
                          ),
                        )
                      else
                        for (final source in sources)
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
                                        formatTime(
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

class MiniDetailSheet extends StatefulWidget {
  const MiniDetailSheet({
    super.key,
    required this.controller,
    required this.mini,
  });

  final NeoRecallController controller;
  final MiniMemory mini;

  @override
  State<MiniDetailSheet> createState() => _MiniDetailSheetState();
}

class _MiniDetailSheetState extends State<MiniDetailSheet>
    with DetailSheetMixin<MiniDetailSheet> {
  @override
  Future<Map<String, dynamic>> fetchDetail() =>
      widget.controller.loadMiniMemoryDetail(widget.mini.id);

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
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : loadError != null
                ? Center(
                    child: Text(
                      'Could not load highlight.\n$loadError',
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
                          'Due ${formatFullDateTime(mini.dueAt!)}',
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
                      if (sources.isEmpty)
                        Text(
                          'No transcript excerpts linked.',
                          style: TextStyle(color: palette.textMuted),
                        )
                      else
                        for (final source in sources)
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
