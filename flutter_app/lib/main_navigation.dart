import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'l10n/gen/app_l10n.dart';

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

  /// Resolved against the active translations at build time so the same const
  /// structure renders in whatever language the app is set to.
  final String Function(AppL10n) label;
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

  /// Resolved against the active translations at build time so the same const
  /// structure renders in whatever language the app is set to.
  final String Function(AppL10n) label;
  final IconData icon;
  final List<NeoRecallDestination> destinations;

  NeoRecallDestination get primary => destinations.first;
  bool get hasChildren => destinations.length > 1;

  bool isCurrent(NeoRecallController controller) =>
      destinations.any((destination) => destination.isCurrent(controller));
}

final NeoRecallDestination recordDestination = NeoRecallDestination(
  page: RecallPage.record,
  icon: Icons.mic_none_rounded,
  label: (l10n) => l10n.navRecord,
);

final NeoRecallDestination sourcesDestination = NeoRecallDestination(
  page: RecallPage.sources,
  icon: Icons.grid_view_rounded,
  label: (l10n) => l10n.navSources,
);

final NeoRecallDestination libraryDestination = NeoRecallDestination(
  page: RecallPage.library,
  icon: Icons.subject_rounded,
  label: (l10n) => l10n.navMoments,
  libraryTab: LibraryTab.moments,
);

final NeoRecallDestination memoriesDestination = NeoRecallDestination(
  page: RecallPage.library,
  icon: Icons.auto_awesome_outlined,
  label: (l10n) => l10n.navMemories,
  libraryTab: LibraryTab.memories,
);

final NeoRecallDestination highlightsDestination = NeoRecallDestination(
  page: RecallPage.library,
  icon: Icons.flag_outlined,
  label: (l10n) => l10n.navHighlights,
  libraryTab: LibraryTab.highlights,
);

final NeoRecallDestination speakersDestination = NeoRecallDestination(
  page: RecallPage.library,
  icon: Icons.people_outline_rounded,
  label: (l10n) => l10n.navSpeakers,
  libraryTab: LibraryTab.speakers,
);

final NeoRecallDestination searchDestination = NeoRecallDestination(
  page: RecallPage.search,
  icon: Icons.auto_awesome_rounded,
  label: (l10n) => l10n.navAsk,
);

final NeoRecallDestination settingsDestination = NeoRecallDestination(
  page: RecallPage.settings,
  icon: Icons.tune_rounded,
  label: (l10n) => l10n.navSettings,
);

/// Canonical product structure. The desktop sidebar and the mobile tab bar are
/// both rendered from this, so the two can never drift apart.
// `final`, not `const`: every label is a function of the active translations,
// which is not a constant expression.
final List<NeoRecallNavigationGroup> neoRecallNavigationGroups =
    <NeoRecallNavigationGroup>[
      NeoRecallNavigationGroup(
        label: (l10n) => l10n.navCapture,
        icon: Icons.mic_none_rounded,
        destinations: <NeoRecallDestination>[
          recordDestination,
          sourcesDestination,
        ],
      ),
      NeoRecallNavigationGroup(
        label: (l10n) => l10n.navLibrary,
        icon: Icons.subject_rounded,
        destinations: <NeoRecallDestination>[
          libraryDestination,
          memoriesDestination,
          highlightsDestination,
          speakersDestination,
        ],
      ),
      NeoRecallNavigationGroup(
        label: (l10n) => l10n.navAsk,
        icon: Icons.search_rounded,
        destinations: <NeoRecallDestination>[searchDestination],
      ),
      NeoRecallNavigationGroup(
        label: (l10n) => l10n.navSettings,
        icon: Icons.tune_rounded,
        destinations: <NeoRecallDestination>[settingsDestination],
      ),
    ];

/// The four tabs on a phone. Sources is reached from the Record screen's source
/// sheet rather than the bar: it is somewhere you go to set things up, not one
/// of the four places you live in.
final List<NeoRecallDestination> neoRecallTabDestinations =
    <NeoRecallDestination>[
      recordDestination,
      // No libraryTab: the tab bar returns to Library where the reader left it
      // rather than snapping back to Moments every time.
      NeoRecallDestination(
        page: RecallPage.library,
        icon: Icons.subject_rounded,
        label: (l10n) => l10n.navLibrary,
      ),
      searchDestination,
      settingsDestination,
    ];

/// Which tab is lit for [page]. Pages that are not tabs of their own belong to
/// the tab they are reached from, so the bar never goes blank.
int neoRecallTabIndex(NeoRecallController controller) =>
    switch (controller.page) {
      RecallPage.record || RecallPage.sources => 0,
      RecallPage.library => 1,
      RecallPage.search => 2,
      RecallPage.settings || RecallPage.devices => 3,
    };

String neoRecallPageTitle(NeoRecallController controller, AppL10n l10n) =>
    switch (controller.page) {
      RecallPage.record => l10n.navRecord,
      RecallPage.library => l10n.navLibrary,
      RecallPage.search => l10n.navAsk,
      RecallPage.sources => l10n.navSources,
      RecallPage.devices || RecallPage.settings => l10n.navSettings,
    };
