import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';
import 'admin_client.dart';
import 'admin_widgets.dart';

/// The three questions an operator has about backups — is it on, did the last
/// one work, when is the next — answered before any history.
class AdminBackupsSection extends StatefulWidget {
  const AdminBackupsSection({
    super.key,
    required this.controller,
    required this.client,
    this.onChanged,
  });

  final NeoRecallController controller;
  final AdminClient client;

  /// Called after a backup ran, so the navigation's flag follows.
  final VoidCallback? onChanged;

  @override
  State<AdminBackupsSection> createState() => _AdminBackupsSectionState();
}

class _AdminBackupsSectionState extends State<AdminBackupsSection> {
  bool _running = false;

  Future<void> _runNow(Future<void> Function() reload) async {
    final strings = AppL10n.of(context);
    setState(() => _running = true);
    try {
      final result = await widget.client.runBackup();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.skipped
                ? strings.adminBackupAlreadyRunning
                : strings.adminBackupDone(adminMegabytes(result.bytes)),
          ),
        ),
      );
      widget.onChanged?.call();
      await reload();
    } catch (error) {
      noteAdminFailure(widget.controller, error);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(adminErrorText(error))));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdminLoader<AdminBackups>(
      controller: widget.controller,
      load: widget.client.backups,
      builder: (context, backups, reload) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _status(context, backups, reload),
          const SizedBox(height: AppSpacing.sm + 2),
          _history(context, backups),
        ],
      ),
    );
  }

  Widget _status(
    BuildContext context,
    AdminBackups backups,
    Future<void> Function() reload,
  ) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    final stale = backups.enabled && backups.due;
    return AdminCard(
      id: 'backups.status',
      eyebrow: strings.adminBackups,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            strings.adminBackupsDescription,
            style: TextStyle(color: palette.textSecondary, height: 1.45),
          ),
          const SizedBox(height: AppSpacing.md),
          AdminStatGrid(
            tiles: <AdminStatTile>[
              AdminStatTile(
                label: strings.adminBackupSchedule,
                value: backups.enabled
                    ? strings.adminBackupEvery(backups.intervalHours)
                    : strings.adminBackupDisabled,
                tone: backups.enabled ? AdminTone.ok : AdminTone.warning,
              ),
              AdminStatTile(
                label: strings.adminBackupLast,
                value: backups.lastSuccessAt == null
                    ? strings.adminNever
                    : adminDate(context, backups.lastSuccessAt),
                tone: backups.lastSuccessAt == null
                    ? AdminTone.danger
                    : backups.lastFailed
                    ? AdminTone.warning
                    : AdminTone.ok,
              ),
              AdminStatTile(
                label: strings.adminBackupNext,
                value: backups.running
                    ? strings.adminBackupRunningNow
                    : backups.nextDueAt == null
                    ? strings.adminBackupNextWorker
                    : adminDate(context, backups.nextDueAt),
                tone: stale ? AdminTone.warning : AdminTone.ok,
              ),
              AdminStatTile(
                label: strings.adminBackupRetained,
                value: strings.adminBackupRetainedValue(
                  backups.artifactCount,
                  backups.retain,
                  adminMegabytes(backups.artifactBytes),
                ),
                tone: backups.artifactCount > 0
                    ? AdminTone.ok
                    : AdminTone.danger,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (backups.unreachable != null)
            InlineMessage(
              error: true,
              message: strings.adminBackupUnreachable(
                backups.destination,
                backups.unreachable!,
              ),
            )
          else
            Text(
              strings.adminBackupDestination(
                backups.destination,
                backups.location ?? '',
              ),
              style: TextStyle(color: palette.textMuted, fontSize: 12),
            ),
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _running ? null : () => _runNow(reload),
              icon: _running
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.backup_outlined, size: 18),
              label: Text(
                _running ? strings.adminBackingUp : strings.adminBackUpNow,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _history(BuildContext context, AdminBackups backups) {
    final strings = AppL10n.of(context);
    return AdminCard(
      id: 'backups.history',
      eyebrow: strings.adminBackupHistory,
      child: AdminRows(
        empty: strings.adminNoBackups,
        children: <Widget>[
          for (final (index, entry) in backups.history.indexed)
            AdminListRow(
              first: index == 0,
              title: adminDate(context, entry.startedAt),
              chips: <Widget>[
                AdminStateChip(state: entry.state),
                AdminChip(
                  label: adminStateLabel(AppL10n.of(context), entry.trigger),
                  tone: AdminTone.neutral,
                ),
              ],
              lines: <String>[
                if (entry.bytes > 0) adminMegabytes(entry.bytes),
                if (entry.artifactKey != null)
                  entry.pruned
                      ? strings.adminBackupPruned(entry.artifactKey!)
                      : entry.artifactKey!,
                if (entry.errorCode != null)
                  strings.adminWhyItFailed(
                    <String>[entry.errorCode!, ?entry.errorMessage].join(' · '),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
