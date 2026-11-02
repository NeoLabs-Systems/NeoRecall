import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';

/// How the Settings pages are grouped in the list. Every page names its group
/// above its title, so it is clear whether a change is about the account, how
/// audio is captured, what is written from it, or another service.
enum SettingsGroup { account, capture, memory, connections }

extension SettingsGroupLabel on SettingsGroup {
  String label(AppL10n l10n) => switch (this) {
    SettingsGroup.account => l10n.settingsGroupAccount,
    SettingsGroup.capture => l10n.settingsGroupCapture,
    SettingsGroup.memory => l10n.settingsGroupMemory,
    SettingsGroup.connections => l10n.settingsGroupConnections,
  };
}

extension SettingsSectionInfo on SettingsSection {
  SettingsGroup get group => switch (this) {
    SettingsSection.general ||
    SettingsSection.security ||
    SettingsSection.usage => SettingsGroup.account,
    SettingsSection.recording ||
    SettingsSection.speakers ||
    SettingsSection.devices ||
    SettingsSection.watch => SettingsGroup.capture,
    SettingsSection.memory ||
    SettingsSection.instructions => SettingsGroup.memory,
    SettingsSection.integrations => SettingsGroup.connections,
  };

  IconData get icon => switch (this) {
    SettingsSection.general => Icons.tune,
    SettingsSection.security => Icons.security,
    SettingsSection.usage => Icons.data_usage_outlined,
    SettingsSection.recording => Icons.graphic_eq_outlined,
    SettingsSection.speakers => Icons.record_voice_over_outlined,
    SettingsSection.devices => Icons.devices_other_outlined,
    SettingsSection.watch => Icons.watch_outlined,
    SettingsSection.memory => Icons.auto_awesome_outlined,
    SettingsSection.instructions => Icons.edit_note_outlined,
    SettingsSection.integrations => Icons.hub_outlined,
  };

  String label(AppL10n l10n) => switch (this) {
    SettingsSection.general => l10n.settingsNavGeneral,
    SettingsSection.security => l10n.settingsNavSecurity,
    SettingsSection.usage => l10n.settingsNavUsage,
    SettingsSection.recording => l10n.settingsNavRecording,
    SettingsSection.speakers => l10n.settingsNavSpeakers,
    SettingsSection.devices => l10n.settingsNavDevices,
    SettingsSection.watch => l10n.settingsNavWatch,
    SettingsSection.memory => l10n.settingsNavMemory,
    SettingsSection.instructions => l10n.settingsNavInstructions,
    SettingsSection.integrations => l10n.settingsNavIntegrations,
  };

  String description(AppL10n l10n) => switch (this) {
    SettingsSection.general => l10n.settingsNavGeneralDescription,
    SettingsSection.security => l10n.settingsNavSecurityDescription,
    SettingsSection.usage => l10n.settingsNavUsageDescription,
    SettingsSection.recording => l10n.settingsNavRecordingDescription,
    SettingsSection.speakers => l10n.settingsNavSpeakersDescription,
    SettingsSection.devices => l10n.settingsNavDevicesDescription,
    SettingsSection.watch => l10n.settingsNavWatchDescription,
    SettingsSection.memory => l10n.settingsNavMemoryDescription,
    SettingsSection.instructions => l10n.settingsNavInstructionsDescription,
    SettingsSection.integrations => l10n.settingsNavIntegrationsDescription,
  };
}

/// The pages this build shows. A watch only pairs with a phone, so offering the
/// page on a desktop would only ever answer "no watch found".
List<SettingsSection> visibleSettingsSections({required bool watchSupported}) =>
    SettingsSection.values
        .where((section) => section != SettingsSection.watch || watchSupported)
        .toList(growable: false);

/// One searchable setting and the page it lives on.
class _SettingsEntry {
  const _SettingsEntry(this.section, this.label, [this.keywords = const []]);

  final SettingsSection section;
  final String Function(AppL10n) label;

  /// Extra English terms people search for, such as "wifi" for the upload
  /// policy.
  final List<String> keywords;

  bool matches(AppL10n l10n, String query) =>
      label(l10n).toLowerCase().contains(query) ||
      keywords.any((keyword) => keyword.contains(query));
}

final List<_SettingsEntry> _settingsEntries = <_SettingsEntry>[
  _SettingsEntry(SettingsSection.general, (l) => l.settingsTimezoneLabel, [
    'timezone',
    'clock',
  ]),
  _SettingsEntry(SettingsSection.general, (l) => l.settingsLanguageTitle, [
    'deutsch',
    'english',
  ]),
  _SettingsEntry(SettingsSection.security, (l) => l.securityTwoFactorTitle, [
    '2fa',
    'authenticator',
    'passkey',
    'password',
    'sign out',
    'logout',
  ]),
  _SettingsEntry(SettingsSection.recording, (l) => l.settingsUnmeteredTitle, [
    'wifi',
    'wi-fi',
    'mobile data',
    'upload',
  ]),
  _SettingsEntry(SettingsSection.recording, (l) => l.settingsScheduleTitle, [
    'schedule',
    'hours',
  ]),
  _SettingsEntry(SettingsSection.recording, (l) => l.settingsSectionRecording, [
    'chunk',
    'overlap',
  ]),
  _SettingsEntry(SettingsSection.recording, (l) => l.settingsVocabularyLabel, [
    'vocabulary',
    'names',
    'spelling',
  ]),
  _SettingsEntry(
    SettingsSection.recording,
    (l) => l.settingsVocabularyCorrectionTitle,
  ),
  _SettingsEntry(
    SettingsSection.recording,
    (l) => l.settingsKeepRawAudioTitle,
    ['raw audio', 'retention', 'delete'],
  ),
  _SettingsEntry(SettingsSection.speakers, (l) => l.settingsDiarizationTitle, [
    'diarization',
  ]),
  _SettingsEntry(
    SettingsSection.speakers,
    (l) => l.settingsRecurringSpeakerTitle,
  ),
  _SettingsEntry(
    SettingsSection.speakers,
    (l) => l.settingsDeferredSpeakerTitle,
  ),
  _SettingsEntry(SettingsSection.memory, (l) => l.settingsConsolidationTitle, [
    'consolidation',
    'interval',
  ]),
  _SettingsEntry(
    SettingsSection.instructions,
    (l) => l.settingsInstructionsGlobalLabel,
    ['prompt', 'instructions'],
  ),
  _SettingsEntry(
    SettingsSection.instructions,
    (l) => l.settingsInstructionsMemoriesLabel,
  ),
  _SettingsEntry(
    SettingsSection.instructions,
    (l) => l.settingsInstructionsSummariesLabel,
  ),
  _SettingsEntry(
    SettingsSection.instructions,
    (l) => l.settingsInstructionsAskLabel,
  ),
  _SettingsEntry(SettingsSection.devices, (l) => l.settingsDevicesTitle, [
    'bluetooth',
    'wearable',
    'pendant',
  ]),
  _SettingsEntry(
    SettingsSection.integrations,
    (l) => l.settingsNavIntegrations,
    ['mcp', 'nextcloud', 'claude', 'backup'],
  ),
];

/// The Settings page list: a rail beside the open page on wide screens, the
/// whole screen on a phone. A search replaces the list with matching settings.
class SettingsNavigation extends StatelessWidget {
  const SettingsNavigation({
    super.key,
    required this.selected,
    required this.compact,
    required this.onSelected,
    required this.searchController,
    required this.onSearchChanged,
    this.watchSupported = false,
  });

  /// Highlighted in the rail; null while a search is showing.
  final SettingsSection? selected;
  final bool compact;
  final ValueChanged<SettingsSection> onSelected;
  final TextEditingController searchController;
  final VoidCallback onSearchChanged;
  final bool watchSupported;

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    final query = searchController.text.trim();
    final sections = visibleSettingsSections(watchSupported: watchSupported);
    return ListView(
      padding: EdgeInsets.only(bottom: compact ? AppSpacing.xl : AppSpacing.md),
      children: <Widget>[
        TextField(
          controller: searchController,
          onChanged: (_) => onSearchChanged(),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            hintText: l10n.settingsSearchHint,
            prefixIcon: Icon(Icons.search, size: 18, color: palette.textMuted),
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    tooltip: l10n.actionCancel,
                    icon: Icon(Icons.close, size: 18, color: palette.textMuted),
                    onPressed: () {
                      searchController.clear();
                      onSearchChanged();
                    },
                  ),
          ),
        ),
        if (compact && query.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          SettingsSearchResults(
            query: query,
            watchSupported: watchSupported,
            onSelected: onSelected,
          ),
        ] else
          for (final group in SettingsGroup.values)
            ..._group(context, group, <SettingsSection>[
              for (final section in sections)
                if (section.group == group) section,
            ]),
      ],
    );
  }

  List<Widget> _group(
    BuildContext context,
    SettingsGroup group,
    List<SettingsSection> sections,
  ) {
    if (sections.isEmpty) return const <Widget>[];
    final l10n = AppL10n.of(context);
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(4, AppSpacing.lg, 4, 8),
      child: Text(
        group.label(l10n).toUpperCase(),
        style: sectionEyebrowStyle(neoRecallPaletteOf(context)),
      ),
    );
    if (!compact) {
      return <Widget>[
        header,
        for (final section in sections)
          _RailItem(
            section: section,
            selected: section == selected,
            onTap: () => onSelected(section),
          ),
      ];
    }
    return <Widget>[
      header,
      _CardList(
        children: <Widget>[
          for (final section in sections)
            _ListTile(
              icon: section.icon,
              title: section.label(l10n),
              subtitle: section.description(l10n),
              onTap: () => onSelected(section),
            ),
        ],
      ),
    ];
  }
}

/// Pages and settings matching a search. Each opens the page it lives on.
class SettingsSearchResults extends StatelessWidget {
  const SettingsSearchResults({
    super.key,
    required this.query,
    required this.watchSupported,
    required this.onSelected,
  });

  final String query;
  final bool watchSupported;
  final ValueChanged<SettingsSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    final needle = query.toLowerCase();
    final sections = visibleSettingsSections(watchSupported: watchSupported);
    final pageHits = sections
        .where((section) => section.label(l10n).toLowerCase().contains(needle))
        .toList();
    final entryHits = _settingsEntries
        .where(
          (entry) =>
              sections.contains(entry.section) && entry.matches(l10n, needle),
        )
        .toList();
    final total = pageHits.length + entryHits.length;
    if (total == 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Text(
          l10n.settingsSearchNoMatch(query),
          style: TextStyle(color: palette.textSecondary, height: 1.45),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Text(
            l10n.settingsSearchResultCount(total),
            style: TextStyle(color: palette.textSecondary, fontSize: 13),
          ),
        ),
        _CardList(
          children: <Widget>[
            for (final section in pageHits)
              _ListTile(
                icon: section.icon,
                title: section.label(l10n),
                subtitle: section.group.label(l10n),
                onTap: () => onSelected(section),
              ),
            for (final entry in entryHits)
              _ListTile(
                icon: entry.section.icon,
                title: entry.label(l10n),
                subtitle:
                    '${entry.section.group.label(l10n)} › '
                    '${entry.section.label(l10n)}',
                onTap: () => onSelected(entry.section),
              ),
          ],
        ),
      ],
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final SettingsSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected
            ? palette.accent.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: <Widget>[
                Icon(
                  section.icon,
                  size: 18,
                  color: selected ? palette.accent : palette.textMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    section.label(AppL10n.of(context)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? palette.textPrimary
                          : palette.textSecondary,
                    ),
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

/// Rows on one card, split by hairlines.
class _CardList extends StatelessWidget {
  const _CardList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.bgCard,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: palette.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < children.length; i++) ...<Widget>[
            if (i > 0) Divider(height: 1, thickness: 1, color: palette.border),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _ListTile extends StatelessWidget {
  const _ListTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: <Widget>[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: palette.bgSecondary,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 17, color: palette.textSecondary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.textMuted,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const RowChevron(),
          ],
        ),
      ),
    );
  }
}
