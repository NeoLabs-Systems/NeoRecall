import 'package:flutter/material.dart';

import '../../main_settings.dart';
import '../../main_theme.dart';

class SettingsNavigation extends StatelessWidget {
  const SettingsNavigation({
    super.key,
    required this.selected,
    required this.compact,
    required this.onSelected,
  });

  final SettingsSection selected;
  final bool compact;
  final ValueChanged<SettingsSection> onSelected;

  static const items = <_SettingsNavigationItem>[
    _SettingsNavigationItem(
      section: SettingsSection.general,
      icon: Icons.tune,
      label: 'General',
      description: 'Time and locale',
    ),
    _SettingsNavigationItem(
      section: SettingsSection.security,
      icon: Icons.security,
      label: 'Security',
      description: 'Passwords and 2FA',
    ),
    _SettingsNavigationItem(
      section: SettingsSection.recording,
      icon: Icons.graphic_eq_outlined,
      label: 'Recording',
      description: 'Schedule, network, chunks',
    ),
    _SettingsNavigationItem(
      section: SettingsSection.memory,
      icon: Icons.auto_awesome_outlined,
      label: 'Memory',
      description: 'Consolidation timing',
    ),
    _SettingsNavigationItem(
      section: SettingsSection.speakers,
      icon: Icons.record_voice_over_outlined,
      label: 'Speakers',
      description: 'Diarization and matching',
    ),
    _SettingsNavigationItem(
      section: SettingsSection.devices,
      icon: Icons.devices_other_outlined,
      label: 'Account devices',
      description: 'Sessions and access',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return DropdownButtonFormField<SettingsSection>(
        key: ValueKey<SettingsSection>(selected),
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Settings area',
          prefixIcon: Icon(Icons.settings_outlined),
        ),
        items: items
            .map(
              (item) => DropdownMenuItem<SettingsSection>(
                value: item.section,
                child: Text(item.label),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
            child: Text(
              'Settings areas',
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          for (final item in items)
            _SettingsNavigationButton(
              item: item,
              selected: item.section == selected,
              onTap: () => onSelected(item.section),
            ),
        ],
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
                        item.label,
                        style: TextStyle(
                          color: selected
                              ? palette.accent
                              : palette.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.description,
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
  final String label;
  final String description;
}
