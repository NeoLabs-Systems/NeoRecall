import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';
import 'admin_client.dart';
import 'admin_widgets.dart';

/// Is the server keeping up: queue, workers, temporary audio, search index.
class AdminOverviewSection extends StatelessWidget {
  const AdminOverviewSection({
    super.key,
    required this.controller,
    required this.client,
  });

  final NeoRecallController controller;
  final AdminClient client;

  @override
  Widget build(BuildContext context) {
    return AdminLoader<AdminStats>(
      controller: controller,
      load: client.stats,
      builder: (context, stats, reload) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _status(context, stats, reload),
          const SizedBox(height: AppSpacing.sm + 2),
          _workers(context, stats),
        ],
      ),
    );
  }

  Widget _status(
    BuildContext context,
    AdminStats stats,
    Future<void> Function() reload,
  ) {
    final strings = AppL10n.of(context);
    return AdminCard(
      id: 'overview.status',
      eyebrow: strings.adminOverviewStatus,
      trailing: IconButton(
        tooltip: strings.adminRefresh,
        onPressed: reload,
        icon: const Icon(Icons.refresh_rounded, size: 20),
      ),
      child: AdminStatGrid(
        tiles: <AdminStatTile>[
          AdminStatTile(
            label: strings.adminStatVersion,
            value: stats.version ?? '—',
          ),
          AdminStatTile(label: strings.adminStatUsers, value: '${stats.users}'),
          AdminStatTile(
            label: strings.adminStatDevices,
            value: '${stats.devices}',
          ),
          AdminStatTile(
            label: strings.adminStatRecordings,
            value: '${stats.recordings}',
          ),
          AdminStatTile(
            label: strings.adminStatQueued,
            value: '${stats.queued}',
            tone: stats.queued > 0 ? AdminTone.warning : AdminTone.ok,
          ),
          AdminStatTile(
            label: strings.adminStatFailedJobs,
            value: '${stats.failed}',
            tone: stats.failed > 0 ? AdminTone.danger : AdminTone.ok,
          ),
          AdminStatTile(
            label: strings.adminStatOldestQueued,
            value: stats.oldestQueuedAt == null
                ? strings.adminNone
                : adminDate(context, stats.oldestQueuedAt),
            tone: stats.oldestQueuedAt == null
                ? AdminTone.ok
                : AdminTone.warning,
          ),
          AdminStatTile(
            label: strings.adminStatTemporaryAudio,
            value: adminMegabytes(stats.temporaryAudioBytes),
            tone: stats.temporaryAudioBytes > 0
                ? AdminTone.warning
                : AdminTone.ok,
          ),
          AdminStatTile(
            label: strings.adminStatCleanupPending,
            value: '${stats.cleanupPending}',
            tone: stats.cleanupPending > 0 ? AdminTone.warning : AdminTone.ok,
          ),
          AdminStatTile(
            label: strings.adminStatSearchIndex,
            value: stats.vectorReady
                ? strings.adminSearchIndexReady(stats.vectorVersion ?? '')
                : strings.adminSearchIndexUnavailable,
            tone: stats.vectorReady ? AdminTone.ok : AdminTone.danger,
          ),
          AdminStatTile(
            label: strings.adminStatAiTokens,
            value: MaterialLocalizations.of(
              context,
            ).formatDecimal(stats.aiTokens),
          ),
        ],
      ),
    );
  }

  Widget _workers(BuildContext context, AdminStats stats) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    return AdminCard(
      id: 'overview.workers',
      eyebrow: strings.adminOverviewWorkers,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AdminRows(
            empty: strings.adminNoWorkers,
            children: <Widget>[
              for (final (index, worker) in stats.workers.indexed)
                AdminListRow(
                  first: index == 0,
                  title: worker.host,
                  chips: <Widget>[AdminStateChip(state: worker.modelState)],
                  lines: <String>[
                    strings.adminWorkerHeartbeat(
                      adminDate(context, worker.heartbeatAt),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            strings.adminProcessingLastDay,
            style: TextStyle(
              color: palette.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          if (stats.processing.isEmpty)
            Text(
              strings.adminNoProcessingSamples,
              style: TextStyle(color: palette.textMuted),
            )
          else
            for (final metric in stats.processing)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  strings.adminProcessingMetric(
                    metric.metric,
                    metric.average.toStringAsFixed(3),
                    metric.maximum.toStringAsFixed(3),
                    metric.unit,
                  ),
                  style: TextStyle(color: palette.textSecondary, fontSize: 12),
                ),
              ),
        ],
      ),
    );
  }
}
