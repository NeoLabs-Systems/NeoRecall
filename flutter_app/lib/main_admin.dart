import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_provider_setup.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'l10n/gen/app_l10n.dart';
import 'src/admin/admin_activity_sections.dart';
import 'src/admin/admin_backups_section.dart';
import 'src/admin/admin_client.dart';
import 'src/admin/admin_overview_section.dart';
import 'src/admin/admin_processing_section.dart';
import 'src/admin/admin_provider_client.dart';
import 'src/admin/admin_users_section.dart';
import 'src/admin/admin_widgets.dart';

extension AdminAreaX on AdminArea {
  String label(AppL10n l10n) => switch (this) {
    AdminArea.overview => l10n.adminAreaOverview,
    AdminArea.users => l10n.adminAreaUsers,
    AdminArea.jobs => l10n.adminAreaJobs,
    AdminArea.aiRequests => l10n.adminAreaAiRequests,
    AdminArea.audit => l10n.adminAreaAudit,
    AdminArea.backups => l10n.adminAreaBackups,
    AdminArea.providers => l10n.adminAreaProviders,
    AdminArea.processing => l10n.adminAreaProcessing,
  };

  IconData get icon => switch (this) {
    AdminArea.overview => Icons.space_dashboard_outlined,
    AdminArea.users => Icons.group_outlined,
    AdminArea.jobs => Icons.pending_actions_outlined,
    AdminArea.aiRequests => Icons.psychology_outlined,
    AdminArea.audit => Icons.receipt_long_outlined,
    AdminArea.backups => Icons.backup_outlined,
    AdminArea.providers => Icons.cloud_outlined,
    AdminArea.processing => Icons.tune_rounded,
  };
}

/// One thing an admin might look for, the area that has it, and the card on
/// that area to bring into view.
class _AdminSearchEntry {
  const _AdminSearchEntry(this.area, this.card, this.title, this.keywords);

  final AdminArea area;

  /// The [AdminCard.id] holding it.
  final String card;
  final String Function(AppL10n) title;

  /// Words people are likely to type beyond the title, in the app's language.
  final String Function(AppL10n) keywords;

  bool matches(AppL10n l10n, String query) {
    final haystack = '${title(l10n)} ${keywords(l10n)} ${area.label(l10n)}'
        .toLowerCase();
    return query
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .every(haystack.contains);
  }
}

final List<_AdminSearchEntry> _adminSearchIndex = <_AdminSearchEntry>[
  _AdminSearchEntry(
    AdminArea.overview,
    'overview.status',
    (l) => l.adminSearchStatus,
    (l) => l.adminSearchStatusKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.overview,
    'overview.workers',
    (l) => l.adminSearchWorkers,
    (l) => l.adminSearchWorkersKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.users,
    'users.accounts',
    (l) => l.adminSearchAccounts,
    (l) => l.adminSearchAccountsKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.users,
    'users.accounts',
    (l) => l.adminSearchDisable,
    (l) => l.adminSearchDisableKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.users,
    'users.accounts',
    (l) => l.adminSearchAccountLimits,
    (l) => l.adminSearchAccountLimitsKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.users,
    'users.accounts',
    (l) => l.adminSearchAdmins,
    (l) => l.adminSearchAdminsKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.users,
    'users.limits',
    (l) => l.adminSearchInstallLimits,
    (l) => l.adminSearchInstallLimitsKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.jobs,
    'jobs.list',
    (l) => l.adminSearchJobs,
    (l) => l.adminSearchJobsKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.aiRequests,
    'ai.list',
    (l) => l.adminSearchAiRequests,
    (l) => l.adminSearchAiRequestsKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.audit,
    'audit.list',
    (l) => l.adminSearchAudit,
    (l) => l.adminSearchAuditKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.backups,
    'backups.status',
    (l) => l.adminSearchBackUpNow,
    (l) => l.adminSearchBackUpNowKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.backups,
    'backups.status',
    (l) => l.adminSearchBackupSchedule,
    (l) => l.adminSearchBackupScheduleKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.backups,
    'backups.history',
    (l) => l.adminSearchBackupHistory,
    (l) => l.adminSearchBackupHistoryKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.providers,
    'providers',
    (l) => l.adminSearchTranscription,
    (l) => l.adminSearchTranscriptionKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.providers,
    'providers',
    (l) => l.adminSearchLanguageModel,
    (l) => l.adminSearchLanguageModelKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.providers,
    'providers',
    (l) => l.adminSearchTestServices,
    (l) => l.adminSearchTestServicesKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.providers,
    'providers',
    (l) => l.adminSearchSkipThinking,
    (l) => l.adminSearchSkipThinkingKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.providers,
    'providers',
    (l) => l.adminSearchProviderReset,
    (l) => l.adminSearchProviderResetKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.processing,
    'processing.speakers',
    (l) => l.adminSettingsGroupSpeakers,
    (l) => l.adminSearchSpeakersKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.processing,
    'processing.audio',
    (l) => l.adminSettingsGroupAudio,
    (l) => l.adminSearchAudioKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.processing,
    'processing.transcript',
    (l) => l.adminSettingsGroupTranscript,
    (l) => l.adminSearchTranscriptKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.processing,
    'processing.conversations',
    (l) => l.adminSettingsGroupConversations,
    (l) => l.adminSearchConversationsKeywords,
  ),
  _AdminSearchEntry(
    AdminArea.processing,
    'processing.memories',
    (l) => l.adminSettingsGroupMemories,
    (l) => l.adminSearchMemoriesKeywords,
  ),
];

/// The in-app Admin page. Only offered to admin accounts; every endpoint
/// behind it re-checks the account's role on the server.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final TextEditingController _search = TextEditingController();

  /// Card to bring into view after opening a search result.
  String? _targetCard;

  /// What the navigation flags. Loaded when the page opens and again after
  /// something that changes it; never on a timer.
  AdminAttention _attention = const AdminAttention();

  NeoRecallController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _refreshAttention();
  }

  Future<void> _refreshAttention() async {
    final attention = await AdminClient(controller.api).attention();
    if (mounted) setState(() => _attention = attention);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(AdminArea area, {String? card}) {
    setState(() {
      _targetCard = card;
      _search.clear();
    });
    controller.selectAdminArea(area);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < AppBreakpoints.rail;
    final gutter = width < AppBreakpoints.mobile
        ? AppSpacing.lg - 4
        : AppSpacing.lg;
    final area = controller.adminArea;
    final searching = _search.text.trim().isNotEmpty;
    // One scrolling page, as on NeoAgent's Admin page: title, search, the
    // area tabs, then the area. Capped so a form never spans a wide window.
    return ListView(
      padding: EdgeInsets.fromLTRB(
        gutter,
        compact ? 20 : 28,
        gutter,
        AppSpacing.xl,
      ),
      children: <Widget>[
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ScreenHeader(
                  title: strings.adminTitle,
                  description: strings.adminDescription,
                ),
                _searchField(strings),
                const SizedBox(height: 14),
                if (searching)
                  _searchResults(strings)
                else ...<Widget>[
                  _AdminTabBar(
                    selected: area,
                    attention: _attention,
                    onSelect: (next) => _open(next),
                  ),
                  const SizedBox(height: 20),
                  if (controller.error != null) ...<Widget>[
                    InlineMessage(message: controller.error!, error: true),
                    const SizedBox(height: AppSpacing.sm + 2),
                  ],
                  AdminSearchTarget(
                    card: _targetCard,
                    // A fresh subtree per area and target: each area loads its
                    // own data, and a card only scrolls into view for the tap
                    // that targeted it.
                    child: KeyedSubtree(
                      key: ValueKey<String>('${area.name}:$_targetCard'),
                      child: _body(area, strings),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _searchField(AppL10n strings) {
    final query = _search.text.trim();
    return TextField(
      controller: _search,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) {
        final results = _results(strings);
        if (results.isNotEmpty) {
          _open(results.first.area, card: results.first.card);
        }
      },
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search_rounded),
        hintText: strings.adminSearchHint,
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                tooltip: strings.adminSearchClear,
                onPressed: () => setState(_search.clear),
                icon: const Icon(Icons.close_rounded),
              ),
      ),
    );
  }

  List<_AdminSearchEntry> _results(AppL10n strings) {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return const <_AdminSearchEntry>[];
    return _adminSearchIndex
        .where((entry) => entry.matches(strings, query))
        .toList(growable: false);
  }

  Widget _searchResults(AppL10n strings) {
    final palette = neoRecallPaletteOf(context);
    final results = _results(strings);
    if (results.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: strings.adminSearchNothing,
        message: strings.adminSearchNothingHint,
      );
    }
    return AppPanel(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: <Widget>[
          for (final entry in results)
            ListTile(
              leading: Icon(entry.area.icon, color: palette.accent),
              title: Text(entry.title(strings)),
              subtitle: Text(
                strings.adminSearchWhere(entry.area.label(strings)),
              ),
              trailing: const RowChevron(),
              onTap: () => _open(entry.area, card: entry.card),
            ),
        ],
      ),
    );
  }

  Widget _body(AdminArea area, AppL10n strings) {
    final client = AdminClient(controller.api);
    return switch (area) {
      AdminArea.overview => AdminOverviewSection(
        controller: controller,
        client: client,
      ),
      AdminArea.users => AdminUsersSection(
        controller: controller,
        client: client,
      ),
      AdminArea.jobs => AdminJobsSection(
        controller: controller,
        client: client,
        onChanged: _refreshAttention,
      ),
      AdminArea.aiRequests => AdminAiRequestsSection(
        controller: controller,
        client: client,
      ),
      AdminArea.audit => AdminAuditSection(
        controller: controller,
        client: client,
      ),
      AdminArea.backups => AdminBackupsSection(
        controller: controller,
        client: client,
        onChanged: _refreshAttention,
      ),
      AdminArea.providers => AdminCard(
        id: 'providers',
        eyebrow: strings.adminServices,
        child: ProviderSetupPanel(
          client: AdminProviderClient(controller.api),
          onAccessRevoked: controller.adminAccessRevoked,
        ),
      ),
      AdminArea.processing => AdminProcessingSection(
        controller: controller,
        client: client,
      ),
    };
  }
}

/// The flag an area carries in the navigation, if any: a count of failed jobs,
/// or a mark on backups that need a look.
String? _attentionMark(AdminArea area, AdminAttention attention) =>
    switch (area) {
      AdminArea.jobs when attention.failedJobs > 0 => '${attention.failedJobs}',
      AdminArea.backups when attention.backups => '!',
      _ => null,
    };

/// The area tabs, as a wrap of pills like NeoAgent's Admin page.
class _AdminTabBar extends StatelessWidget {
  const _AdminTabBar({
    required this.selected,
    required this.attention,
    required this.onSelect,
  });

  final AdminArea selected;
  final AdminAttention attention;
  final ValueChanged<AdminArea> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final area in AdminArea.values)
          _AdminTabChip(
            area: area,
            active: area == selected,
            mark: _attentionMark(area, attention),
            onTap: () => onSelect(area),
          ),
      ],
    );
  }
}

/// One area tab: the app's pill ([MetaPill]'s look), tappable, with the
/// area's flag at the end when it needs a look.
class _AdminTabChip extends StatelessWidget {
  const _AdminTabChip({
    required this.area,
    required this.active,
    required this.mark,
    required this.onTap,
  });

  final AdminArea area;
  final bool active;
  final String? mark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final radius = BorderRadius.circular(AppRadius.pill);
    final color = active ? palette.accentHover : palette.textSecondary;
    return Semantics(
      selected: active,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: radius,
              color: active ? palette.accentMuted : palette.bgTertiary,
              border: Border.all(
                color: active
                    ? palette.accent.withValues(alpha: 0.3)
                    : palette.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  area.icon,
                  size: 15,
                  color: active ? palette.accent : palette.textMuted,
                ),
                const SizedBox(width: 7),
                Text(
                  area.label(AppL10n.of(context)),
                  style: TextStyle(
                    color: color,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (mark != null) ...<Widget>[
                  const SizedBox(width: 7),
                  // Sized to the label's line so the pill keeps the height of
                  // the pills beside it.
                  TintedSurface(
                    tint: palette.danger,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      mark!,
                      style: TextStyle(
                        color: palette.danger,
                        fontSize: 11,
                        height: 1.35,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
