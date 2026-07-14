import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_devices.dart';
import 'main_memories.dart';
import 'main_record.dart';
import 'main_search.dart';
import 'main_settings.dart';
import 'main_shared.dart';
import 'main_speakers.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'main_timeline.dart';

class NeoRecallShell extends StatelessWidget {
  const NeoRecallShell({super.key, required this.controller});
  final NeoRecallController controller;
  static const items = <(RecallPage, IconData, String)>[
    (RecallPage.record, Icons.radio_button_checked_rounded, 'Record'),
    (RecallPage.timeline, Icons.view_timeline_outlined, 'Timeline'),
    (RecallPage.memories, Icons.auto_awesome_outlined, 'Memories'),
    (RecallPage.search, Icons.search_rounded, 'Search'),
    (RecallPage.speakers, Icons.record_voice_over_outlined, 'Speakers'),
    (RecallPage.devices, Icons.devices_outlined, 'Devices'),
    (RecallPage.settings, Icons.settings_outlined, 'Settings'),
  ];
  Widget _screen() => switch (controller.page) {
    RecallPage.record => RecordScreen(controller: controller),
    RecallPage.timeline => TimelineScreen(controller: controller),
    RecallPage.memories => MemoriesScreen(controller: controller),
    RecallPage.search => SearchScreen(controller: controller),
    RecallPage.speakers => SpeakersScreen(controller: controller),
    RecallPage.devices => DevicesScreen(controller: controller),
    RecallPage.settings => SettingsScreen(controller: controller),
  };
  @override
  Widget build(BuildContext context) => AmbientBackdrop(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < AppBreakpoints.mobile;
        final rail = constraints.maxWidth < AppBreakpoints.labeled;
        final content = AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: KeyedSubtree(key: ValueKey(controller.page), child: _screen()),
        );
        if (compact) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              title: const BrandLockup(logoSize: 34),
            ),
            drawer: Drawer(
              child: SafeArea(
                child: _Sidebar(controller: controller, labeled: true),
              ),
            ),
            body: content,
          );
        }
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Row(
              children: <Widget>[
                _Sidebar(controller: controller, labeled: !rail),
                Expanded(child: content),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.controller, required this.labeled});
  final NeoRecallController controller;
  final bool labeled;
  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      width: labeled ? 240 : 76,
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 9),
      decoration: BoxDecoration(
        color: palette.glassFill,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.glassBorder),
      ),
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: BrandLockup(logoSize: 40, showName: labeled),
          ),
          for (final item in NeoRecallShell.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: ListTile(
                selected: controller.page == item.$1,
                leading: Icon(item.$2),
                title: labeled ? Text(item.$3) : null,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: labeled ? 12 : 10,
                ),
                onTap: () {
                  controller.selectPage(item.$1);
                  if (Scaffold.maybeOf(context)?.isDrawerOpen ?? false) {
                    Navigator.pop(context);
                  }
                },
              ),
            ),
          const Spacer(),
          if (labeled)
            Text(
              controller.online
                  ? 'Connected'
                  : 'Offline · recording remains available',
              style: TextStyle(
                color: controller.online ? palette.success : palette.warning,
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          const SizedBox(height: 8),
          IconButton(
            tooltip: 'Sign out',
            onPressed: controller.logout,
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
    );
  }
}
