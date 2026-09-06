import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_memories.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_speakers.dart';
import 'main_timeline.dart';
import 'src/memories/memory_filters.dart';

/// Everything the account has recorded, in one place.
///
/// Moments, memories, highlights and speakers were four lists behind three
/// sidebar entries and a tab bar nested inside one of them. They are four
/// segments of one page now: the same reading surface, one level of navigation
/// instead of two, and one page title instead of four.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.controller});

  final NeoRecallController controller;

  static const List<({LibraryTab value, String label})> _segments =
      <({LibraryTab value, String label})>[
        (value: LibraryTab.moments, label: 'Moments'),
        (value: LibraryTab.memories, label: 'Memories'),
        (value: LibraryTab.highlights, label: 'Highlights'),
        (value: LibraryTab.speakers, label: 'Speakers'),
      ];

  Widget _body() {
    switch (controller.libraryTab) {
      case LibraryTab.moments:
        return TimelineScreen(
          key: const ValueKey<String>('library-moments'),
          controller: controller,
          embedded: true,
        );
      case LibraryTab.memories:
        return MemoriesScreen(
          key: const ValueKey<String>('library-memories'),
          controller: controller,
          embedded: true,
          tab: MemoriesTab.moments,
        );
      case LibraryTab.highlights:
        return MemoriesScreen(
          key: const ValueKey<String>('library-highlights'),
          controller: controller,
          embedded: true,
          tab: MemoriesTab.highlights,
        );
      case LibraryTab.speakers:
        return SpeakersScreen(
          key: const ValueKey<String>('library-speakers'),
          controller: controller,
          embedded: true,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final gutter = compact ? AppSpacing.lg - 4 : AppSpacing.lg;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, compact ? 20 : 28, gutter, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const ScreenHeader(title: 'Library'),
              SegmentedTabs<LibraryTab>(
                segments: _segments,
                selected: controller.libraryTab,
                onSelected: controller.selectLibraryTab,
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(gutter, AppSpacing.md + 2, gutter, 0),
            child: _body(),
          ),
        ),
      ],
    );
  }
}
