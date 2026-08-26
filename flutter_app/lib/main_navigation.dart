import 'package:flutter/material.dart';

import 'main_controller.dart';

class NeoRecallNavigationItem {
  const NeoRecallNavigationItem({
    required this.page,
    required this.icon,
    required this.label,
  });

  final RecallPage page;
  final IconData icon;
  final String label;
}

/// Canonical product sections. The same shell is rendered on web and desktop;
/// keeping its information architecture in one list prevents platform drift.
const List<NeoRecallNavigationItem> neoRecallNavigationItems =
    <NeoRecallNavigationItem>[
      NeoRecallNavigationItem(
        page: RecallPage.record,
        icon: Icons.mic_none_rounded,
        label: 'Record',
      ),
      NeoRecallNavigationItem(
        page: RecallPage.timeline,
        icon: Icons.timeline_rounded,
        label: 'Timeline',
      ),
      NeoRecallNavigationItem(
        page: RecallPage.memories,
        icon: Icons.auto_awesome_outlined,
        label: 'Memories',
      ),
      NeoRecallNavigationItem(
        page: RecallPage.search,
        icon: Icons.search_rounded,
        label: 'Search',
      ),
      NeoRecallNavigationItem(
        page: RecallPage.speakers,
        icon: Icons.people_outline_rounded,
        label: 'Speakers',
      ),
      NeoRecallNavigationItem(
        page: RecallPage.sources,
        icon: Icons.grid_view_rounded,
        label: 'Sources',
      ),
    ];

String neoRecallPageTitle(RecallPage page) {
  for (final item in neoRecallNavigationItems) {
    if (item.page == page) return item.label;
  }
  return 'Settings';
}
