import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_library.dart';
import 'main_navigation.dart';
import 'main_record.dart';
import 'main_ask.dart';
import 'main_settings.dart';
import 'main_shared.dart';
import 'main_sources.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'src/context/recording_context_drop_target.dart';
import 'src/record/sync_cards.dart';
import 'l10n/gen/app_l10n.dart';

class NeoRecallShell extends StatefulWidget {
  const NeoRecallShell({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<NeoRecallShell> createState() => _NeoRecallShellState();
}

class _NeoRecallShellState extends State<NeoRecallShell> {
  /// Which sidebar group is open. One at a time, like NeoAgent's rail: the
  /// point of grouping is that the reader sees four things, not eleven.
  NeoRecallNavigationGroup? _openGroup;

  NeoRecallController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _openGroup = _groupFor(controller.page);
  }

  @override
  void didUpdateWidget(covariant NeoRecallShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Navigating from anywhere else — a widget deep link, the status bar's
    // "Open" — reveals the group that owns the destination, so the rail never
    // shows a selected child inside a collapsed group.
    final group = _groupFor(controller.page);
    if (group != null && group != _openGroup && group.hasChildren) {
      _openGroup = group;
    }
  }

  NeoRecallNavigationGroup? _groupFor(RecallPage page) {
    for (final group in neoRecallNavigationGroups) {
      if (group.destinations.any((d) => d.page == page)) return group;
    }
    return null;
  }

  Widget _screen() => switch (controller.page) {
    RecallPage.record => RecordScreen(controller: controller),
    RecallPage.library => LibraryScreen(controller: controller),
    RecallPage.search => AskScreen(controller: controller),
    RecallPage.sources => SourcesScreen(controller: controller),
    RecallPage.devices => SettingsScreen(
      controller: controller,
      initialSection: SettingsSection.devices,
    ),
    RecallPage.settings => SettingsScreen(controller: controller),
  };

  void _selectGroup(NeoRecallNavigationGroup group) {
    if (group.hasChildren) {
      setState(() => _openGroup = _openGroup == group ? null : group);
      if (!group.isCurrent(controller)) group.primary.select(controller);
      return;
    }
    group.primary.select(controller);
  }

  @override
  Widget build(BuildContext context) {
    // Wrapping the shell, not the recording screen: a file dropped anywhere in
    // the app — timeline, search, settings — joins the running recording.
    return RecordingContextDropTarget(
      controller: controller,
      child: AppBackdrop(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= AppBreakpoints.rail;
            final content = AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              // A String, not a List: ValueKey compares its value with ==, and
              // two equal Lists are not equal, so a list key rebuilt the whole
              // screen on every notification and threw away its scroll position.
              child: KeyedSubtree(
                key: ValueKey<String>(
                  '${controller.page.name}:${controller.libraryTab.name}',
                ),
                child: _screen(),
              ),
            );

            if (wide) {
              return Scaffold(
                backgroundColor: Colors.transparent,
                body: Row(
                  children: <Widget>[
                    _Sidebar(
                      controller: controller,
                      openGroup: _openGroup,
                      onSelectGroup: _selectGroup,
                    ),
                    Expanded(
                      child: Column(
                        children: <Widget>[
                          _GlobalStatusBar(controller: controller),
                          Expanded(child: ClipRect(child: content)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }

            return Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                bottom: false,
                child: Column(
                  children: <Widget>[
                    _GlobalStatusBar(controller: controller),
                    Expanded(child: ClipRect(child: content)),
                  ],
                ),
              ),
              bottomNavigationBar: _TabBar(controller: controller),
            );
          },
        ),
      ),
    );
  }
}

/// The phone tab bar. Four destinations, a hairline above, and nothing else —
/// the drawer it replaces hid the whole product behind a hamburger.
class _TabBar extends StatelessWidget {
  const _TabBar({required this.controller});

  final NeoRecallController controller;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: NavigationBar(
        selectedIndex: neoRecallTabIndex(controller),
        onDestinationSelected: (index) =>
            neoRecallTabDestinations[index].select(controller),
        destinations: <Widget>[
          for (final destination in neoRecallTabDestinations)
            NavigationDestination(
              icon: Icon(destination.icon),
              label: destination.label(AppL10n.of(context)),
            ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.controller,
    required this.openGroup,
    required this.onSelectGroup,
  });

  final NeoRecallController controller;
  final NeoRecallNavigationGroup? openGroup;
  final ValueChanged<NeoRecallNavigationGroup> onSelectGroup;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final accountLabel = controller.username?.trim();
    final safeLabel = accountLabel?.isNotEmpty == true
        ? accountLabel!
        : AppL10n.of(context).shellAccountFallback;
    final initial = safeLabel.characters.first.toUpperCase();

    return Container(
      width: 276,
      decoration: BoxDecoration(
        color: palette.bgSecondary,
        border: Border(right: BorderSide(color: palette.border)),
      ),
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 16, 14),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: palette.border),
                color: palette.bgCard,
              ),
              child: Row(
                children: <Widget>[
                  const BrandLockup(logoSize: 38, showName: false),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          'NeoRecall',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.35,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          AppL10n.of(context).shellControlSurface,
                          style: sectionEyebrowStyle(
                            palette,
                          ).copyWith(fontSize: 9.5, letterSpacing: 1.8),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              children: <Widget>[
                for (final group in neoRecallNavigationGroups) ...<Widget>[
                  _SidebarButton(
                    selected: group.isCurrent(controller),
                    icon: group.icon,
                    label: group.label(AppL10n.of(context)),
                    trailing: group.hasChildren
                        ? Icon(
                            openGroup == group
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            size: 16,
                            color: palette.textMuted,
                          )
                        : null,
                    onTap: () => onSelectGroup(group),
                  ),
                  if (group.hasChildren && openGroup == group)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 2, 0, 4),
                      child: Container(
                        padding: const EdgeInsets.only(left: 12),
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(color: palette.border),
                          ),
                        ),
                        child: Column(
                          children: <Widget>[
                            for (final destination in group.destinations)
                              _SidebarButton(
                                selected: destination.isCurrent(controller),
                                icon: destination.icon,
                                label: destination.label(AppL10n.of(context)),
                                compact: true,
                                onTap: () => destination.select(controller),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: palette.border),
              color: palette.bgCard,
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: palette.accentMuted,
                    border: Border.all(color: palette.borderLight),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    initial,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    safeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _SidebarIconButton(
                  tooltip: AppL10n.of(context).navSettings,
                  icon: Icons.settings_outlined,
                  onTap: () => controller.selectPage(RecallPage.settings),
                ),
                const SizedBox(width: 4),
                _SidebarIconButton(
                  tooltip: AppL10n.of(context).shellSignOut,
                  icon: Icons.logout,
                  onTap: () async => controller.logout(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarButton extends StatefulWidget {
  const _SidebarButton({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.compact = false,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool compact;

  @override
  State<_SidebarButton> createState() => _SidebarButtonState();
}

class _SidebarButtonState extends State<_SidebarButton> {
  bool hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final radius = BorderRadius.circular(AppRadius.tag);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => hovering = true),
        onExit: (_) => setState(() => hovering = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: radius,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                horizontal: 11,
                vertical: widget.compact ? 7 : 9,
              ),
              decoration: BoxDecoration(
                borderRadius: radius,
                color: widget.selected
                    ? palette.accentMuted
                    : hovering
                    ? palette.bgTertiary
                    : Colors.transparent,
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    widget.icon,
                    size: widget.compact ? 16 : 19,
                    color: widget.selected ? palette.accent : palette.textMuted,
                  ),
                  SizedBox(width: widget.compact ? 9 : 11),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.selected
                            ? palette.textPrimary
                            : palette.textSecondary,
                        fontSize: widget.compact ? 13 : 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (widget.trailing != null) widget.trailing!,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarIconButton extends StatelessWidget {
  const _SidebarIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.tag),
              color: palette.bgTertiary,
              border: Border.all(color: palette.border),
            ),
            child: Icon(icon, size: 17, color: palette.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// Persistent, cross-screen status strip: offline, background-capture risk,
/// transient notices, and an off-Record recording indicator. Renders nothing
/// (zero height) when there is nothing to report.
class _GlobalStatusBar extends StatelessWidget {
  const _GlobalStatusBar({required this.controller});

  final NeoRecallController controller;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final banners = <Widget>[];

    if (controller.backgroundCaptureAtRisk) {
      banners.add(
        _StatusBanner(
          icon: Icons.battery_alert_rounded,
          color: palette.danger,
          message: AppL10n.of(context).shellBatteryWarning,
          actionLabel: AppL10n.of(context).shellBatteryFix,
          onAction: () => controller.openBatterySettings(),
        ),
      );
    }
    if (!controller.online) {
      banners.add(
        _StatusBanner(
          icon: Icons.cloud_off_rounded,
          color: palette.textMuted,
          message: AppL10n.of(context).shellOffline,
        ),
      );
    }
    if (controller.notice != null) {
      banners.add(
        _StatusBanner(
          icon: Icons.info_outline_rounded,
          color: palette.accent,
          message: controller.notice!,
        ),
      );
    }
    if (controller.deviceStorageSyncing) {
      banners.add(_SyncStatusPill(controller: controller));
    }
    if (controller.isRecording && controller.page != RecallPage.record) {
      banners.add(
        _StatusBanner(
          icon: Icons.fiber_manual_record_rounded,
          color: palette.secondary,
          message: AppL10n.of(context).shellRecordingActive,
          actionLabel: AppL10n.of(context).shellRecordingOpen,
          onAction: () => controller.selectPage(RecallPage.record),
        ),
      );
    }

    if (banners.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < banners.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 6),
            banners[i],
          ],
        ],
      ),
    );
  }
}

/// Live device-storage sync indicator: a spinning icon plus a synced/left count,
/// so an in-progress sync reads as active work rather than a flat notice.
class _SyncStatusPill extends StatefulWidget {
  const _SyncStatusPill({required this.controller});

  final NeoRecallController controller;

  @override
  State<_SyncStatusPill> createState() => _SyncStatusPillState();
}

class _SyncStatusPillState extends State<_SyncStatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final controller = widget.controller;
    final synced = controller.deviceStorageSyncedCount;
    final progress = controller.deviceStorageSyncProgress;
    final label = controller.preferredDeviceLabel ?? 'device';
    // Percent and remaining audio come from the device's own announced transfer
    // size, so a long drain reads as progress instead of an endless spinner.
    final percent = progress?.fraction;
    final detail = <String>[
      if (percent != null) '${(percent * 100).round()}%',
      if (synced > 0) '$synced synced',
      if (progress != null && progress.pendingSeconds > 0)
        '${DeviceSyncStatusView.formatDuration(progress.pendingSeconds)} left',
    ].join(' · ');
    final color = palette.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: <Widget>[
          RotationTransition(
            turns: _spin,
            child: Icon(Icons.sync_rounded, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  AppL10n.of(context).shellSyncing(label),
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 11.5,
                      height: 1.2,
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

/// A global status banner: icon, message, and an optional action.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.icon,
    required this.color,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final Color color;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return TintedSurface(
      tint: color,
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      fillOpacity: 0.12,
      borderOpacity: 0.28,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 12.5,
                height: 1.3,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: color,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
