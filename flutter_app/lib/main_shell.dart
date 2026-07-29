import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_devices.dart';
import 'main_memories.dart';
import 'main_record.dart';
import 'main_search.dart';
import 'main_settings.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_speakers.dart';
import 'main_theme.dart';
import 'main_timeline.dart';

class NeoRecallShell extends StatelessWidget {
  const NeoRecallShell({super.key, required this.controller});
  final NeoRecallController controller;

  static const items = <(RecallPage, IconData, String, String)>[
    (
      RecallPage.record,
      Icons.radio_button_checked_rounded,
      'Record',
      'Capture',
    ),
    (RecallPage.timeline, Icons.view_timeline_outlined, 'Timeline', 'Review'),
    (RecallPage.memories, Icons.auto_awesome_outlined, 'Memories', 'Recall'),
    (RecallPage.search, Icons.search_rounded, 'Search', 'Find'),
    (
      RecallPage.speakers,
      Icons.record_voice_over_outlined,
      'Speakers',
      'People',
    ),
    (RecallPage.devices, Icons.devices_outlined, 'Devices', 'Sources'),
    (RecallPage.settings, Icons.tune_rounded, 'Settings', 'Control'),
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
  Widget build(BuildContext context) {
    return AmbientBackdrop(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < AppBreakpoints.mobile;
          final rail = constraints.maxWidth < AppBreakpoints.labeled;
          final content = AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: KeyedSubtree(
              key: ValueKey(controller.page),
              child: _screen(),
            ),
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
                  child: _Sidebar(
                    controller: controller,
                    labeled: true,
                    drawer: true,
                  ),
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
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.controller,
    required this.labeled,
    this.drawer = false,
  });

  final NeoRecallController controller;
  final bool labeled;
  final bool drawer;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      width: labeled ? 248 : 84,
      margin: drawer ? EdgeInsets.zero : const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
      decoration: BoxDecoration(
        color: palette.glassFill,
        borderRadius: drawer
            ? BorderRadius.zero
            : BorderRadius.circular(AppRadius.panel),
        border: drawer ? null : Border.all(color: palette.glassBorder),
        boxShadow: drawer ? null : softPanelShadow(palette),
      ),
      child: Column(
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(
              labeled ? 8 : 0,
              4,
              labeled ? 8 : 0,
              18,
            ),
            child: BrandLockup(logoSize: labeled ? 42 : 36, showName: labeled),
          ),
          if (labeled)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 10),
                child: Text(
                  'CONTROL SURFACE',
                  style: sectionEyebrowStyle(palette),
                ),
              ),
            ),
          for (final item in NeoRecallShell.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: _SidebarButton(
                labeled: labeled,
                selected: controller.page == item.$1,
                icon: item.$2,
                label: item.$3,
                caption: item.$4,
                onTap: () {
                  controller.selectPage(item.$1);
                  if (Scaffold.maybeOf(context)?.isDrawerOpen ?? false) {
                    Navigator.pop(context);
                  }
                },
              ),
            ),
          const Spacer(),
          if (labeled) ...<Widget>[
            MetaPill(
              icon: controller.online
                  ? Icons.cloud_done_outlined
                  : Icons.cloud_off_outlined,
              label: controller.online ? 'Connected' : 'Offline',
              active: controller.online,
            ),
            const SizedBox(height: 10),
            if (controller.username != null)
              Text(
                controller.username!,
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            const SizedBox(height: 8),
          ],
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

class _SidebarButton extends StatelessWidget {
  const _SidebarButton({
    required this.labeled,
    required this.selected,
    required this.icon,
    required this.label,
    required this.caption,
    required this.onTap,
  });

  final bool labeled;
  final bool selected;
  final IconData icon;
  final String label;
  final String caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Material(
      color: selected ? palette.accentMuted : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.input),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.input),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: labeled ? 12 : 10,
            vertical: labeled ? 12 : 14,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                icon,
                color: selected ? palette.accentHover : palette.textSecondary,
              ),
              if (labeled) ...<Widget>[
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        label,
                        style: TextStyle(
                          color: selected
                              ? palette.textPrimary
                              : palette.textSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        caption,
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
