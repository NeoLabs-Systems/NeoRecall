import 'package:flutter/material.dart';

import '../../main_settings.dart';
import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';

class SettingsNavigation extends StatelessWidget {
  const SettingsNavigation({
    super.key,
    required this.selected,
    required this.compact,
    required this.onSelected,
    this.watchSupported = false,
  });

  final SettingsSection selected;
  final bool compact;
  final ValueChanged<SettingsSection> onSelected;

  /// Whether this build can talk to a Wear OS watch at all. Offering the area
  /// on a desktop would only ever answer "no watch found", which reads as a
  /// fault rather than as a platform that has no watches.
  final bool watchSupported;

  List<_SettingsNavigationItem> get _visibleItems => items
      .where((item) => item.section != SettingsSection.watch || watchSupported)
      .toList(growable: false);

  // `final`, not `const`: each label is a function of the active translations,
  // and a closure over a generated getter is not a constant expression.
  static final items = <_SettingsNavigationItem>[
    _SettingsNavigationItem(
      section: SettingsSection.general,
      icon: Icons.tune,
      label: (l10n) => l10n.settingsNavGeneral,
      description: (l10n) => l10n.settingsNavGeneralDescription,
    ),
    _SettingsNavigationItem(
      section: SettingsSection.security,
      icon: Icons.security,
      label: (l10n) => l10n.settingsNavSecurity,
      description: (l10n) => l10n.settingsNavSecurityDescription,
    ),
    _SettingsNavigationItem(
      section: SettingsSection.recording,
      icon: Icons.graphic_eq_outlined,
      label: (l10n) => l10n.settingsNavRecording,
      description: (l10n) => l10n.settingsNavRecordingDescription,
    ),
    _SettingsNavigationItem(
      section: SettingsSection.memory,
      icon: Icons.auto_awesome_outlined,
      label: (l10n) => l10n.settingsNavMemory,
      description: (l10n) => l10n.settingsNavMemoryDescription,
    ),
    _SettingsNavigationItem(
      section: SettingsSection.instructions,
      icon: Icons.edit_note_outlined,
      label: (l10n) => l10n.settingsNavInstructions,
      description: (l10n) => l10n.settingsNavInstructionsDescription,
    ),
    _SettingsNavigationItem(
      section: SettingsSection.speakers,
      icon: Icons.record_voice_over_outlined,
      label: (l10n) => l10n.settingsNavSpeakers,
      description: (l10n) => l10n.settingsNavSpeakersDescription,
    ),
    _SettingsNavigationItem(
      section: SettingsSection.watch,
      icon: Icons.watch_outlined,
      label: (l10n) => l10n.settingsNavWatch,
      description: (l10n) => l10n.settingsNavWatchDescription,
    ),
    _SettingsNavigationItem(
      section: SettingsSection.devices,
      icon: Icons.devices_other_outlined,
      label: (l10n) => l10n.settingsNavDevices,
      description: (l10n) => l10n.settingsNavDevicesDescription,
    ),
    _SettingsNavigationItem(
      section: SettingsSection.services,
      icon: Icons.cloud_outlined,
      label: (l10n) => l10n.settingsNavServices,
      description: (l10n) => l10n.settingsNavServicesDescription,
    ),
    _SettingsNavigationItem(
      section: SettingsSection.integrations,
      icon: Icons.hub_outlined,
      label: (l10n) => l10n.settingsNavIntegrations,
      description: (l10n) => l10n.settingsNavIntegrationsDescription,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return DropdownButtonFormField<SettingsSection>(
        key: ValueKey<SettingsSection>(selected),
        initialValue: selected,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: AppL10n.of(context).settingsNavAreaLabel,
          prefixIcon: const Icon(Icons.settings_outlined),
        ),
        items: _visibleItems
            .map(
              (item) => DropdownMenuItem<SettingsSection>(
                value: item.section,
                child: Text(item.label(AppL10n.of(context))),
              ),
            )
            .toList(),
        onChanged: (section) {
          if (section != null) onSelected(section);
        },
      );
    }

    final palette = neoRecallPaletteOf(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.bgSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.border),
      ),
      // The rail scrolls on its own: eight areas with descriptions are taller
      // than a short desktop window, and a nav that overflows is a nav with an
      // unreachable last entry.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
              child: Text(
                AppL10n.of(context).settingsNavAreasHeading,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final item in _visibleItems)
              _SettingsNavigationButton(
                item: item,
                selected: item.section == selected,
                onTap: () => onSelected(item.section),
              ),
          ],
        ),
      ),
    );
  }
}

class _SettingsNavigationButton extends StatelessWidget {
  const _SettingsNavigationButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _SettingsNavigationItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected
            ? palette.accent.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  item.icon,
                  size: 20,
                  color: selected ? palette.accent : palette.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.label(AppL10n.of(context)),
                        style: TextStyle(
                          color: selected
                              ? palette.accent
                              : palette.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.description(AppL10n.of(context)),
                        style: TextStyle(
                          color: palette.textSecondary,
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsNavigationItem {
  const _SettingsNavigationItem({
    required this.section,
    required this.icon,
    required this.label,
    required this.description,
  });

  final SettingsSection section;
  final IconData icon;

  /// Resolved against the active translations rather than stored as text: the
  /// list is const and built once, but the rail is rebuilt in whatever language
  /// the app is currently in.
  final String Function(AppL10n) label;
  final String Function(AppL10n) description;
}
