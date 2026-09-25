import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';
import '../settings/usage_section.dart';
import 'admin_client.dart';
import 'admin_widgets.dart';

/// Accounts on this server and the usage caps that apply to them.
class AdminUsersSection extends StatelessWidget {
  const AdminUsersSection({
    super.key,
    required this.controller,
    required this.client,
  });

  final NeoRecallController controller;
  final AdminClient client;

  @override
  Widget build(BuildContext context) {
    return AdminLoader<(List<AdminUser>, InstallUsageLimits)>(
      controller: controller,
      load: () async => (await client.users(), await client.installLimits()),
      builder: (context, data, reload) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _AccountsCard(
            controller: controller,
            client: client,
            users: data.$1,
            reload: reload,
          ),
          const SizedBox(height: AppSpacing.sm + 2),
          _InstallLimitsCard(
            controller: controller,
            client: client,
            limits: data.$2,
          ),
        ],
      ),
    );
  }
}

class _AccountsCard extends StatefulWidget {
  const _AccountsCard({
    required this.controller,
    required this.client,
    required this.users,
    required this.reload,
  });

  final NeoRecallController controller;
  final AdminClient client;
  final List<AdminUser> users;
  final Future<void> Function() reload;

  @override
  State<_AccountsCard> createState() => _AccountsCardState();
}

class _AccountsCardState extends State<_AccountsCard> {
  /// Past this many accounts a filter is quicker than scrolling.
  static const int _filterFrom = 8;

  final TextEditingController _filter = TextEditingController();
  String? _busyUserId;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _setDisabled(AdminUser user, bool disabled) async {
    final strings = AppL10n.of(context);
    if (disabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(strings.adminDisableTitle(user.username)),
          content: Text(strings.adminDisableBody),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(strings.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(strings.adminDisable),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _busyUserId = user.id);
    try {
      await widget.client.setUserDisabled(user.id, disabled);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            disabled
                ? strings.adminDisabledNotice(user.username)
                : strings.adminEnabledNotice(user.username),
          ),
        ),
      );
      await widget.reload();
    } catch (error) {
      noteAdminFailure(widget.controller, error);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(adminErrorText(error))));
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  Future<void> _editLimits(AdminUser user) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _UserLimitsDialog(
        controller: widget.controller,
        client: widget.client,
        user: user,
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppL10n.of(context).adminLimitsSaved(user.username)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    final query = _filter.text.trim().toLowerCase();
    final users = query.isEmpty
        ? widget.users
        : widget.users
              .where(
                (user) =>
                    user.username.toLowerCase().contains(query) ||
                    (user.email?.toLowerCase().contains(query) ?? false),
              )
              .toList(growable: false);
    return AdminCard(
      id: 'users.accounts',
      eyebrow: strings.adminAccounts,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            strings.adminAccountsDescription,
            style: TextStyle(color: palette.textSecondary, height: 1.45),
          ),
          if (widget.users.length > _filterFrom) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _filter,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.filter_list_rounded),
                hintText: strings.adminFilterAccounts,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          AdminRows(
            empty: strings.adminNoAccounts,
            children: <Widget>[
              for (final (index, user) in users.indexed)
                AdminListRow(
                  first: index == 0,
                  title: user.username,
                  chips: <Widget>[
                    if (user.isAdmin)
                      AdminChip(
                        label: strings.adminRoleAdmin,
                        tone: AdminTone.ok,
                      ),
                    if (user.id == widget.controller.accountId)
                      AdminChip(
                        label: strings.adminYou,
                        tone: AdminTone.neutral,
                      ),
                    if (user.disabled)
                      AdminChip(
                        label: strings.adminAccountDisabled,
                        tone: AdminTone.danger,
                      ),
                  ],
                  lines: <String>[
                    if (user.email != null) user.email!,
                    strings.adminAccountActivity(
                      user.deviceCount,
                      user.recordingCount,
                    ),
                    user.lastLoginAt == null
                        ? strings.adminAccountJoined(
                            adminDate(context, user.createdAt),
                          )
                        : strings.adminAccountDates(
                            adminDate(context, user.createdAt),
                            adminDate(context, user.lastLoginAt),
                          ),
                  ],
                  actions: <Widget>[
                    OutlinedButton.icon(
                      onPressed: () => _editLimits(user),
                      icon: const Icon(Icons.speed_rounded, size: 16),
                      label: Text(strings.adminLimits),
                    ),
                    if (user.disabled)
                      OutlinedButton(
                        onPressed: _busyUserId == user.id
                            ? null
                            : () => _setDisabled(user, false),
                        child: Text(strings.adminEnable),
                      )
                    else
                      Tooltip(
                        message: user.isAdmin
                            ? strings.adminCannotDisableAdmin
                            : '',
                        child: OutlinedButton(
                          onPressed: user.isAdmin || _busyUserId == user.id
                              ? null
                              : () => _setDisabled(user, true),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: palette.danger,
                          ),
                          child: Text(strings.adminDisable),
                        ),
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          InlineMessage(
            icon: Icons.admin_panel_settings_outlined,
            message: strings.adminGrantHint,
          ),
        ],
      ),
    );
  }
}

/// A number field for a usage cap. Digits only; empty is allowed where the
/// caller gives empty a meaning.
Widget _limitField({
  required TextEditingController controller,
  required String label,
  String? hint,
  String? helper,
}) => TextField(
  controller: controller,
  keyboardType: TextInputType.number,
  inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
  decoration: InputDecoration(
    labelText: label,
    hintText: hint,
    helperText: helper,
  ),
);

class _InstallLimitsCard extends StatefulWidget {
  const _InstallLimitsCard({
    required this.controller,
    required this.client,
    required this.limits,
  });

  final NeoRecallController controller;
  final AdminClient client;
  final InstallUsageLimits limits;

  @override
  State<_InstallLimitsCard> createState() => _InstallLimitsCardState();
}

class _InstallLimitsCardState extends State<_InstallLimitsCard> {
  late final TextEditingController _ai4h;
  late final TextEditingController _aiWeek;
  late final TextEditingController _speech4h;
  late final TextEditingController _speechWeek;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ai4h = TextEditingController(text: '${widget.limits.aiTokens4h}');
    _aiWeek = TextEditingController(text: '${widget.limits.aiTokensWeekly}');
    _speech4h = TextEditingController(
      text: '${widget.limits.transcriptionSeconds4h}',
    );
    _speechWeek = TextEditingController(
      text: '${widget.limits.transcriptionSecondsWeekly}',
    );
  }

  @override
  void dispose() {
    for (final field in <TextEditingController>[
      _ai4h,
      _aiWeek,
      _speech4h,
      _speechWeek,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    int read(TextEditingController field) => int.tryParse(field.text) ?? 0;
    try {
      final saved = await widget.client.setInstallLimits(
        InstallUsageLimits(
          aiTokens4h: read(_ai4h),
          aiTokensWeekly: read(_aiWeek),
          transcriptionSeconds4h: read(_speech4h),
          transcriptionSecondsWeekly: read(_speechWeek),
        ),
      );
      if (!mounted) return;
      _ai4h.text = '${saved.aiTokens4h}';
      _aiWeek.text = '${saved.aiTokensWeekly}';
      _speech4h.text = '${saved.transcriptionSeconds4h}';
      _speechWeek.text = '${saved.transcriptionSecondsWeekly}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).adminInstallLimitsSaved)),
      );
    } catch (error) {
      noteAdminFailure(widget.controller, error);
      if (mounted) setState(() => _error = adminErrorText(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    return AdminCard(
      id: 'users.limits',
      eyebrow: strings.adminInstallLimits,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            strings.adminInstallLimitsDescription,
            style: TextStyle(color: palette.textSecondary, height: 1.45),
          ),
          const SizedBox(height: AppSpacing.md),
          _limitField(controller: _ai4h, label: strings.adminLimitAi4h),
          const SizedBox(height: AppSpacing.sm),
          _limitField(controller: _aiWeek, label: strings.adminLimitAiWeek),
          const SizedBox(height: AppSpacing.sm),
          _limitField(controller: _speech4h, label: strings.adminLimitSpeech4h),
          const SizedBox(height: AppSpacing.sm),
          _limitField(
            controller: _speechWeek,
            label: strings.adminLimitSpeechWeek,
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            InlineMessage(message: _error!, error: true),
          ],
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(strings.adminSaveInstallLimits),
            ),
          ),
        ],
      ),
    );
  }
}

class _UserLimitsDialog extends StatefulWidget {
  const _UserLimitsDialog({
    required this.controller,
    required this.client,
    required this.user,
  });

  final NeoRecallController controller;
  final AdminClient client;
  final AdminUser user;

  @override
  State<_UserLimitsDialog> createState() => _UserLimitsDialogState();
}

class _UserLimitsDialogState extends State<_UserLimitsDialog> {
  final Map<String, TextEditingController> _fields =
      <String, TextEditingController>{
        for (final field in AdminUserLimits.fields)
          field: TextEditingController(),
      };
  AdminUserLimits? _limits;
  bool _saving = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final limits = await widget.client.userLimits(widget.user.id);
      if (!mounted) return;
      setState(() {
        _limits = limits;
        for (final entry in limits.overrides.entries) {
          _fields[entry.key]!.text = entry.value?.toString() ?? '';
        }
      });
    } catch (error) {
      noteAdminFailure(widget.controller, error);
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.client.setUserLimits(widget.user.id, <String, int?>{
        for (final entry in _fields.entries)
          entry.key: entry.value.text.trim().isEmpty
              ? null
              : int.parse(entry.value.text.trim()),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      noteAdminFailure(widget.controller, error);
      if (mounted) {
        setState(() {
          _error = error;
          _saving = false;
        });
      }
    }
  }

  String _window(AppL10n strings, UsageWindowSnapshot window) =>
      strings.adminUsageWindow(
        MaterialLocalizations.of(context).formatDecimal(window.used),
        window.limit == null
            ? strings.adminUnlimited
            : MaterialLocalizations.of(context).formatDecimal(window.limit!),
      );

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    final limits = _limits;
    final labels = <String, String>{
      'aiLimit4h': strings.adminLimitAi4h,
      'aiLimitWeekly': strings.adminLimitAiWeek,
      'transcriptionLimit4h': strings.adminLimitSpeech4h,
      'transcriptionLimitWeekly': strings.adminLimitSpeechWeek,
    };
    return AlertDialog(
      title: Text(strings.adminUserLimitsTitle(widget.user.username)),
      content: SizedBox(
        width: 420,
        child: limits == null && _error == null
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (limits != null) ...<Widget>[
                      Text(
                        strings.adminUsageAi(
                          _window(strings, limits.usage.ai.fourHour),
                          _window(strings, limits.usage.ai.weekly),
                        ),
                        style: TextStyle(color: palette.textSecondary),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        strings.adminUsageSpeech(
                          _window(strings, limits.usage.transcription.fourHour),
                          _window(strings, limits.usage.transcription.weekly),
                        ),
                        style: TextStyle(color: palette.textSecondary),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        strings.adminUserLimitsHelp,
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 12,
                        ),
                      ),
                      for (final field in AdminUserLimits.fields) ...<Widget>[
                        const SizedBox(height: AppSpacing.sm),
                        _limitField(
                          controller: _fields[field]!,
                          label: labels[field]!,
                          hint: strings.adminInheritDefault,
                        ),
                      ],
                    ],
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.sm),
                      InlineMessage(
                        message: adminErrorText(_error!),
                        error: true,
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(strings.actionCancel),
        ),
        FilledButton(
          onPressed: limits == null || _saving ? null : _save,
          child: Text(strings.actionSave),
        ),
      ],
    );
  }
}
