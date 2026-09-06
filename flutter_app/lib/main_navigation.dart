import 'package:flutter/material.dart';

import 'main_controller.dart';

/// A destination the shell can move to.
///
/// A destination is either a page on its own or a page plus the Library list it
/// should land on, so "Memories" in the sidebar and the Memories segment inside
/// Library are the same act rather than two code paths that can disagree.
class NeoRecallDestination {
  const NeoRecallDestination({
    required this.page,
    required this.icon,
    required this.label,
    this.libraryTab,
  });

  final RecallPage page;
  final IconData icon;
  final String label;
  final LibraryTab? libraryTab;

  /// True when [controller] is currently showing this destination.
  bool isCurrent(NeoRecallController controller) {
    if (controller.page != page) return false;
    if (libraryTab == null) return true;
    return controller.libraryTab == libraryTab;
  }

  void select(NeoRecallController controller) {
    final tab = libraryTab;
    if (tab != null) {
      controller.selectLibraryTab(tab);
    } else {
      controller.selectPage(page);
    }
  }
}

/// A collapsible group in the desktop sidebar.
///
/// The same shape as NeoAgent's sidebar: a group row that navigates to its own
/// first destination, with children revealed underneath. Six flat entries were
/// what made the rail read as a list of everything the app can do rather than
/// as a place with sections.
class NeoRecallNavigationGroup {
  const NeoRecallNavigationGroup({
    required this.label,
    required this.icon,
    required this.destinations,
  });

  final String label;
  final IconData icon;
  final List<NeoRecallDestination> destinations;

  NeoRecallDestination get primary => destinations.first;
  bool get hasChildren => destinations.length > 1;

  bool isCurrent(NeoRecallController controller) =>
      destinations.any((destination) => destination.isCurrent(controller));
}

const NeoRecallDestination recordDestination = NeoRecallDestination(
  page: RecallPage.record,
  icon: Icons.mic_none_rounded,
  label: 'Record',
);

const NeoRecallDestination sourcesDestination = NeoRecallDestination(
  page: RecallPage.sources,
  icon: Icons.grid_view_rounded,
  label: 'Sources',
);

const NeoRecallDestination libraryDestination = NeoRecallDestination(
  page: RecallPage.library,
  icon: Icons.subject_rounded,
  label: 'Moments',
  libraryTab: LibraryTab.moments,
);

const NeoRecallDestination memoriesDestination = NeoRecallDestination(
  page: RecallPage.library,
  icon: Icons.auto_awesome_outlined,
  label: 'Memories',
  libraryTab: LibraryTab.memories,
);

const NeoRecallDestination highlightsDestination = NeoRecallDestination(
  page: RecallPage.library,
  icon: Icons.flag_outlined,
  label: 'Highlights',
  libraryTab: LibraryTab.highlights,
);

const NeoRecallDestination speakersDestination = NeoRecallDestination(
  page: RecallPage.library,
  icon: Icons.people_outline_rounded,
  label: 'Speakers',
  libraryTab: LibraryTab.speakers,
);

const NeoRecallDestination searchDestination = NeoRecallDestination(
  page: RecallPage.search,
  icon: Icons.search_rounded,
  label: 'Search',
);

const NeoRecallDestination settingsDestination = NeoRecallDestination(
  page: RecallPage.settings,
  icon: Icons.tune_rounded,
  label: 'Settings',
);

/// Canonical product structure. The desktop sidebar and the mobile tab bar are
/// both rendered from this, so the two can never drift apart.
const List<NeoRecallNavigationGroup> neoRecallNavigationGroups =
    <NeoRecallNavigationGroup>[
      NeoRecallNavigationGroup(
        label: 'Capture',
        icon: Icons.mic_none_rounded,
        destinations: <NeoRecallDestination>[
          recordDestination,
          sourcesDestination,
        ],
      ),
      NeoRecallNavigationGroup(
        label: 'Library',
        icon: Icons.subject_rounded,
        destinations: <NeoRecallDestination>[
          libraryDestination,
          memoriesDestination,
          highlightsDestination,
          speakersDestination,
        ],
      ),
      NeoRecallNavigationGroup(
        label: 'Search',
        icon: Icons.search_rounded,
        destinations: <NeoRecallDestination>[searchDestination],
      ),
      NeoRecallNavigationGroup(
        label: 'Settings',
        icon: Icons.tune_rounded,
        destinations: <NeoRecallDestination>[settingsDestination],
      ),
    ];

/// The four tabs on a phone. Sources is reached from the Record screen's source
/// sheet rather than the bar: it is somewhere you go to set things up, not one
/// of the four places you live in.
const List<NeoRecallDestination> neoRecallTabDestinations =
    <NeoRecallDestination>[
      recordDestination,
      // No libraryTab: the tab bar returns to Library where the reader left it
      // rather than snapping back to Moments every time.
      NeoRecallDestination(
        page: RecallPage.library,
        icon: Icons.subject_rounded,
        label: 'Library',
      ),
      searchDestination,
      settingsDestination,
    ];

/// Which tab is lit for [page]. Pages that are not tabs of their own belong to
/// the tab they are reached from, so the bar never goes blank.
int neoRecallTabIndex(NeoRecallController controller) => switch (controller
    .page) {
  RecallPage.record || RecallPage.sources => 0,
  RecallPage.library => 1,
  RecallPage.search => 2,
  RecallPage.settings || RecallPage.devices => 3,
};

String neoRecallPageTitle(NeoRecallController controller) =>
    switch (controller.page) {
      RecallPage.record => 'Record',
      RecallPage.library => 'Library',
      RecallPage.search => 'Search',
      RecallPage.sources => 'Sources',
      RecallPage.devices || RecallPage.settings => 'Settings',
    };
