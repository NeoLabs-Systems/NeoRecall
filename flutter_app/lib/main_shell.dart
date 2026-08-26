import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_memories.dart';
import 'main_navigation.dart';
import 'main_record.dart';
import 'main_search.dart';
import 'main_settings.dart';
import 'main_shared.dart';
import 'main_sources.dart';
import 'main_speakers.dart';
import 'main_theme.dart';
import 'main_timeline.dart';
import 'src/record/sync_cards.dart';

class NeoRecallShell extends StatelessWidget {
  const NeoRecallShell({super.key, required this.controller});

  final NeoRecallController controller;

  Widget _screen() => switch (controller.page) {
    RecallPage.record => RecordScreen(controller: controller),
    RecallPage.timeline => TimelineScreen(controller: controller),
    RecallPage.memories => MemoriesScreen(controller: controller),
    RecallPage.search => SearchScreen(controller: controller),
    RecallPage.speakers => SpeakersScreen(controller: controller),
    RecallPage.sources => SourcesScreen(controller: controller),
    RecallPage.devices => SettingsScreen(
      controller: controller,
      initialSection: SettingsSection.devices,
    ),
    RecallPage.settings => SettingsScreen(controller: controller),
  };

  @override
  Widget build(BuildContext context) {
    return AmbientBackdrop(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 920;
          final content = AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: KeyedSubtree(
              key: ValueKey(controller.page),
              child: _screen(),
            ),
          );

          if (wide) {
            return Scaffold(
              backgroundColor: Colors.transparent,
              body: Row(
                children: <Widget>[
                  _Sidebar(controller: controller),
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
            drawer: Drawer(
              child: SafeArea(
                child: _Sidebar(controller: controller, drawer: true),
              ),
            ),
            appBar: AppBar(
              toolbarHeight: 52,
              titleSpacing: 0,
              leadingWidth: 46,
              title: Text(
                neoRecallPageTitle(controller.page),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            body: SafeArea(
              top: false,
              child: Column(
                children: <Widget>[
                  _GlobalStatusBar(controller: controller),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: content,
                      ),
                    ),
                  ),
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
  const _Sidebar({required this.controller, this.drawer = false});

  final NeoRecallController controller;
  final bool drawer;

  void _select(BuildContext context, RecallPage page) {
    controller.selectPage(page);
    if (drawer) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final accountLabel = controller.username?.trim();
    final safeLabel = accountLabel?.isNotEmpty == true
        ? accountLabel!
        : 'Account';
    final initial = safeLabel.characters.first.toUpperCase();

    return Container(
      width: 276,
      decoration: BoxDecoration(
        color: palette.bgSecondary.withValues(alpha: 0.96),
        border: Border(right: BorderSide(color: palette.border)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 24,
            offset: const Offset(4, 0),
          ),
        ],
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
                gradient: LinearGradient(
                  colors: <Color>[
                    palette.bgCard.withValues(alpha: 0.9),
                    palette.bgSecondary.withValues(alpha: 0.55),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
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
                          'CONTROL SURFACE',
                          style: sectionEyebrowStyle(
                            palette,
                          ).copyWith(color: palette.textMuted, fontSize: 9.5),
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
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              children: <Widget>[
                for (final item in neoRecallNavigationItems)
                  _SidebarButton(
                    selected: controller.page == item.page,
                    icon: item.icon,
                    label: item.label,
                    onTap: () => _select(context, item.page),
                  ),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 12),
            padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.border),
              color: palette.bgCard.withValues(alpha: 0.72),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: controller.page == RecallPage.settings
                        ? palette.accentMuted
                        : palette.bgCard,
                    border: Border.all(
                      color: controller.page == RecallPage.settings
                          ? palette.accent
                          : palette.borderLight,
                    ),
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
                  tooltip: 'Settings',
                  icon: Icons.settings_outlined,
                  onTap: () => _select(context, RecallPage.settings),
                ),
                const SizedBox(width: 4),
                _SidebarIconButton(
                  tooltip: 'Sign out',
                  icon: Icons.logout,
                  onTap: () async {
                    if (drawer) Navigator.of(context).pop();
                    await controller.logout();
                  },
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
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_SidebarButton> createState() => _SidebarButtonState();
}

class _SidebarButtonState extends State<_SidebarButton> {
  bool hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final radius = BorderRadius.circular(11);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: MouseRegion(
        onEnter: (_) => setState(() => hovering = true),
        onExit: (_) => setState(() => hovering = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: radius,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: radius,
                color: widget.selected
                    ? palette.bgCard.withValues(alpha: 0.96)
                    : hovering
                    ? palette.bgTertiary.withValues(alpha: 0.66)
                    : Colors.transparent,
                gradient: widget.selected
                    ? LinearGradient(
                        colors: <Color>[
                          palette.accent.withValues(alpha: 0.10),
                          palette.bgCard.withValues(alpha: 0.96),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
                border: Border.all(
                  color: widget.selected
                      ? palette.borderLight
                      : hovering
                      ? palette.border
                      : Colors.transparent,
                ),
                boxShadow: widget.selected
                    ? <BoxShadow>[
                        BoxShadow(
                          color: palette.accent.withValues(alpha: 0.05),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    widget.icon,
                    size: 19,
                    color: widget.selected ? palette.accent : palette.textMuted,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: widget.selected
                            ? palette.textPrimary
                            : palette.textSecondary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
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
              borderRadius: BorderRadius.circular(12),
              color: palette.bgSecondary.withValues(alpha: 0.55),
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
          message:
              'Battery optimization may suspend always-on capture on this device.',
          actionLabel: 'Fix',
          onAction: () => controller.openBatterySettings(),
        ),
      );
    }
    if (!controller.online) {
      banners.add(
        _StatusBanner(
          icon: Icons.cloud_off_rounded,
          color: palette.textMuted,
          message:
              'Offline — capture continues; uploads resume when reconnected.',
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
          message: 'Recording is active.',
          actionLabel: 'Open',
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
                  'Syncing $label',
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
