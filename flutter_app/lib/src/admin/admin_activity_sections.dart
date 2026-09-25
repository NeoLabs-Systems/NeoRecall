import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';
import 'admin_client.dart';
import 'admin_widgets.dart';

Widget _refreshButton(AppL10n strings, Future<void> Function() reload) =>
    IconButton(
      tooltip: strings.adminRefresh,
      onPressed: reload,
      icon: const Icon(Icons.refresh_rounded, size: 20),
    );

/// Which jobs the list shows. Failures come first: routine maintenance runs
/// every minute and would otherwise push them out of the latest page.
enum _JobFilter { failed, queued, all }

/// Background processing, and the two things an operator does to it: run a
/// failed job again, or stop one that should not continue.
class AdminJobsSection extends StatefulWidget {
  const AdminJobsSection({
    super.key,
    required this.controller,
    required this.client,
    this.onChanged,
  });

  final NeoRecallController controller;
  final AdminClient client;

  /// Called after a job was retried or cancelled, so counts elsewhere follow.
  final VoidCallback? onChanged;

  @override
  State<AdminJobsSection> createState() => _AdminJobsSectionState();
}

class _AdminJobsSectionState extends State<AdminJobsSection> {
  String? _busyJobId;
  _JobFilter _filter = _JobFilter.failed;

  /// Bumped by the refresh button so the list loads again.
  int _generation = 0;

  Future<void> _act(
    AdminJob job,
    Future<void> Function(String id) action,
    String done,
    Future<void> Function() reload,
  ) async {
    setState(() => _busyJobId = job.id);
    try {
      await action(job.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      widget.onChanged?.call();
      await reload();
    } catch (error) {
      noteAdminFailure(widget.controller, error);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(adminErrorText(error))));
    } finally {
      if (mounted) setState(() => _busyJobId = null);
    }
  }

  String? get _status => switch (_filter) {
    _JobFilter.failed => 'failed',
    _JobFilter.queued => 'queued',
    _JobFilter.all => null,
  };

  String _empty(AppL10n strings) => switch (_filter) {
    _JobFilter.failed => strings.adminNoFailedJobs,
    _JobFilter.queued => strings.adminNoQueuedJobs,
    _JobFilter.all => strings.adminNoJobs,
  };

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    return AdminCard(
      id: 'jobs.list',
      eyebrow: strings.adminJobs,
      trailing: IconButton(
        tooltip: strings.adminRefresh,
        onPressed: () => setState(() => _generation += 1),
        icon: const Icon(Icons.refresh_rounded, size: 20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            strings.adminJobsDescription(AdminClient.listLimit),
            style: TextStyle(color: palette.textSecondary, height: 1.45),
          ),
          const SizedBox(height: 12),
          SegmentedTabs<_JobFilter>(
            segments: <({_JobFilter value, String label})>[
              (value: _JobFilter.failed, label: strings.adminJobsFilterFailed),
              (value: _JobFilter.queued, label: strings.adminJobsFilterQueued),
              (value: _JobFilter.all, label: strings.adminJobsFilterAll),
            ],
            selected: _filter,
            onSelected: (filter) => setState(() => _filter = filter),
          ),
          const SizedBox(height: 8),
          AdminLoader<List<AdminJob>>(
            key: ValueKey<(_JobFilter, int)>((_filter, _generation)),
            controller: widget.controller,
            load: () => widget.client.jobs(status: _status),
            builder: (context, jobs, reload) => AdminRows(
              empty: _empty(strings),
              children: <Widget>[
                for (final (index, job) in jobs.indexed)
                  AdminListRow(
                    first: index == 0,
                    title: job.type,
                    chips: <Widget>[AdminStateChip(state: job.status)],
                    lines: <String>[
                      strings.adminJobAttempts(
                        job.attempts,
                        job.maxAttempts,
                        adminDate(context, job.createdAt),
                      ),
                      if (job.errorCode != null || job.errorMessage != null)
                        strings.adminWhyItFailed(
                          <String>[
                            ?job.errorCode,
                            ?job.errorMessage,
                          ].join(' · '),
                        ),
                    ],
                    actions: <Widget>[
                      if (job.retryable)
                        FilledButton.tonal(
                          onPressed: _busyJobId == job.id
                              ? null
                              : () => _act(
                                  job,
                                  widget.client.retryJob,
                                  strings.adminJobRetried,
                                  reload,
                                ),
                          child: Text(strings.adminRetryJob),
                        ),
                      if (job.cancellable)
                        OutlinedButton(
                          onPressed: _busyJobId == job.id
                              ? null
                              : () => _act(
                                  job,
                                  widget.client.cancelJob,
                                  strings.adminJobCancelled,
                                  reload,
                                ),
                          child: Text(strings.adminCancelJob),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Requests sent to the language model: what for, how large, and whether they
/// worked.
class AdminAiRequestsSection extends StatelessWidget {
  const AdminAiRequestsSection({
    super.key,
    required this.controller,
    required this.client,
  });

  final NeoRecallController controller;
  final AdminClient client;

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    return AdminLoader<List<AdminAiRequest>>(
      controller: controller,
      load: client.aiRequests,
      builder: (context, requests, reload) => AdminCard(
        id: 'ai.list',
        eyebrow: strings.adminAiRequests,
        trailing: _refreshButton(strings, reload),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              strings.adminAiRequestsDescription(AdminClient.listLimit),
              style: TextStyle(color: palette.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 8),
            AdminRows(
              empty: strings.adminNoAiRequests,
              children: <Widget>[
                for (final (index, request) in requests.indexed)
                  AdminListRow(
                    first: index == 0,
                    title: request.purpose,
                    chips: <Widget>[AdminStateChip(state: request.state)],
                    lines: <String>[
                      strings.adminAiRequestDetail(
                        request.model ?? '—',
                        MaterialLocalizations.of(
                          context,
                        ).formatDecimal(request.tokens),
                        request.sentAt == null
                            ? strings.adminReserved
                            : adminDate(context, request.sentAt),
                      ),
                      if (request.errorCode != null)
                        strings.adminWhyItFailed(request.errorCode!),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Administrative and security-sensitive changes, newest first.
class AdminAuditSection extends StatelessWidget {
  const AdminAuditSection({
    super.key,
    required this.controller,
    required this.client,
  });

  final NeoRecallController controller;
  final AdminClient client;

  String _actor(AppL10n strings, AdminAuditEntry entry) =>
      switch (entry.actorType) {
        'system' => strings.adminActorSystem,
        'api_key' => strings.adminActorApiKey,
        // No name: the retired dashboard's own login or key, or an admin
        // account erased since.
        'admin' => entry.actorName ?? strings.adminActorEarlierAdmin,
        // Null once the account has been erased.
        _ => entry.actorName ?? strings.adminActorDeleted,
      };

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    return AdminLoader<List<AdminAuditEntry>>(
      controller: controller,
      load: client.audit,
      builder: (context, entries, reload) => AdminCard(
        id: 'audit.list',
        eyebrow: strings.adminAudit,
        trailing: _refreshButton(strings, reload),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              strings.adminAuditDescription(AdminClient.listLimit),
              style: TextStyle(color: palette.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 8),
            AdminRows(
              empty: strings.adminNoAudit,
              children: <Widget>[
                for (final (index, entry) in entries.indexed)
                  AdminListRow(
                    first: index == 0,
                    title: entry.action,
                    chips: <Widget>[
                      if (entry.actorType == 'admin')
                        AdminChip(
                          label: strings.adminRoleAdmin,
                          tone: AdminTone.ok,
                        ),
                    ],
                    lines: <String>[
                      strings.adminAuditBy(
                        _actor(strings, entry),
                        adminDate(context, entry.createdAt),
                      ),
                      if (entry.affectedName != null &&
                          entry.affectedName != entry.actorName)
                        strings.adminAuditAffected(entry.affectedName!),
                      ?entry.resource,
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
