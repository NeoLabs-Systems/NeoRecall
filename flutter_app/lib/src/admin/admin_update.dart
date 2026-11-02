// Updating NeoRecall from the Admin page: the banner that offers a new
// version (and follows the update while it runs) and the Updates card.
// The server runs the same flow as `neorecall update`; this only shows it.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/gen/app_l10n.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import '../api_client.dart';
import 'admin_widgets.dart';
import 'page_reload.dart';

/// What the server knows about updates: the installed version, a newer one
/// waiting on the channel, and the update job when one ran.
class UpdateStatus {
  UpdateStatus(Map<String, dynamic> json)
    : version = '${json['version'] ?? ''}',
      channel = '${json['channel'] ?? 'beta'}',
      selfUpdate = json['selfUpdate'] == true,
      blockedReason = json['blockedReason'] as String?,
      checkedAt = DateTime.tryParse('${json['checkedAt'] ?? ''}')?.toLocal(),
      checkFailed = json['checkFailed'] == true,
      hasAvailable = json['available'] != null,
      availableVersion = (json['available'] as Map?)?['version'] as String?,
      changes =
          ((json['available'] as Map?)?['changes'] as List? ?? const <Object>[])
              .map((item) => '$item')
              .toList(),
      state = '${(json['job'] as Map?)?['state'] ?? 'idle'}',
      progress = (((json['job'] as Map?)?['progress'] as num?) ?? 0).toInt(),
      message = '${(json['job'] as Map?)?['message'] ?? ''}',
      versionAfter = (json['job'] as Map?)?['versionAfter'] as String?,
      logs = ((json['job'] as Map?)?['logs'] as List? ?? const <Object>[])
          .map((line) => '$line')
          .toList(),
      completedAt = DateTime.tryParse(
        '${(json['job'] as Map?)?['completedAt'] ?? ''}',
      )?.toLocal();

  final String version;
  final String channel;
  final bool selfUpdate;
  final String? blockedReason;
  final DateTime? checkedAt;
  final bool checkFailed;
  final bool hasAvailable;
  final String? availableVersion;
  final List<String> changes;
  final String state;
  final int progress;
  final String message;
  final String? versionAfter;
  final List<String> logs;
  final DateTime? completedAt;

  bool get running => state == 'running';
}

/// Loads the update status, starts updates and follows them to the end, also
/// across the server restart in the middle of one.
class UpdateWatcher extends ChangeNotifier {
  UpdateWatcher(this._api);

  final NeoRecallApiClient _api;
  UpdateStatus? status;
  bool busy = false;
  bool reconnecting = false;
  String? error;
  DateTime? _dismissedAt;
  bool _followed = false;
  bool _disposed = false;
  Timer? _timer;

  static const String _base = '/api/v1/admin/update';

  Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Object? body,
  }) async => Map<String, dynamic>.from(
    await _api.request(method, '$_base$path', body: body) as Map,
  );

  /// A finished update is news for half an hour, or until it is dismissed.
  bool get finishedRecently {
    final done = status?.completedAt;
    if (done == null || done == _dismissedAt) return false;
    final state = status!.state;
    return (state == 'completed' || state == 'failed') &&
        DateTime.now().difference(done) < const Duration(minutes: 30);
  }

  bool get justUpdated => _followed && status?.state == 'completed';

  void dismiss() {
    _dismissedAt = status?.completedAt;
    notifyListeners();
  }

  Future<void> load() => _fetch(() => _call('GET', ''));

  Future<void> check() =>
      _guard(() => _fetch(() => _call('POST', '/check'), rethrowErrors: true));

  Future<void> setChannel(String channel) => _guard(
    () => _fetch(
      () =>
          _call('PUT', '/channel', body: <String, Object>{'channel': channel}),
      rethrowErrors: true,
    ),
  );

  Future<void> start() => _guard(() async {
    _followed = true;
    await _fetch(() => _call('POST', ''), rethrowErrors: true);
  });

  Future<void> _guard(Future<void> Function() action) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } on ApiException catch (failure) {
      error = failure.message;
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _fetch(
    Future<Map<String, dynamic>> Function() request, {
    bool rethrowErrors = false,
  }) async {
    try {
      status = UpdateStatus(await request());
      reconnecting = false;
      if (status!.running) _followed = true;
    } on ApiException catch (failure) {
      // The server going away mid-update is expected; anything else is shown.
      final gone = failure.status == 0 || failure.status >= 502;
      if (_followed && gone) {
        reconnecting = true;
      } else if (rethrowErrors) {
        rethrow;
      }
    }
    _schedule();
    if (!_disposed) notifyListeners();
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || !(status?.running == true || reconnecting)) return;
    _timer = Timer(const Duration(seconds: 2), load);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

String updateChannelLabel(AppL10n strings, String channel) =>
    channel == 'stable'
    ? strings.adminUpdateChannelStable
    : strings.adminUpdateChannelBeta;

/// The banner above every Admin area. It offers the update, then shows its
/// progress, then the result; with nothing to say it takes no space.
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key, required this.watcher});

  final UpdateWatcher watcher;

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  bool _showChanges = false;
  bool _reloading = false;

  UpdateWatcher get watcher => widget.watcher;

  Future<void> _confirmAndStart(AppL10n strings, UpdateStatus status) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          strings.adminUpdateConfirmTitle(status.availableVersion ?? ''),
        ),
        content: Text(strings.adminUpdateConfirmMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.adminUpdateNow),
          ),
        ],
      ),
    );
    if (confirmed == true) await watcher.start();
  }

  void _reloadSoon() {
    if (_reloading) return;
    _reloading = true;
    Timer(const Duration(seconds: 3), reloadPage);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    return ListenableBuilder(
      listenable: watcher,
      builder: (context, _) {
        final status = watcher.status;
        if (status == null) return const SizedBox.shrink();
        if (status.running || watcher.reconnecting) {
          return _frame(
            palette,
            palette.accent,
            _running(strings, palette, status),
          );
        }
        if (watcher.finishedRecently) {
          if (status.state == 'completed') {
            if (watcher.justUpdated) _reloadSoon();
            return _frame(
              palette,
              palette.success,
              _completed(strings, palette, status),
            );
          }
          return _frame(
            palette,
            palette.danger,
            _failed(strings, palette, status),
          );
        }
        if (status.hasAvailable && status.selfUpdate) {
          return _frame(
            palette,
            palette.accent,
            _available(strings, palette, status),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _frame(NeoRecallPalette palette, Color tone, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.bgCard,
        borderRadius: BorderRadius.circular(AppRadius.panel),
        border: Border.all(color: tone.withValues(alpha: 0.45)),
      ),
      child: child,
    ),
  );

  Widget _heading(
    NeoRecallPalette palette,
    IconData icon,
    Color tone,
    String title,
    String? subtitle, {
    Widget? trailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 20, color: tone),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary,
                ),
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 13,
                    color: palette.textSecondary,
                    height: 1.45,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...<Widget>[const SizedBox(width: 12), trailing],
      ],
    );
  }

  Widget _available(
    AppL10n strings,
    NeoRecallPalette palette,
    UpdateStatus status,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _heading(
          palette,
          Icons.system_update_alt_rounded,
          palette.accent,
          strings.adminUpdateReadyTitle(status.availableVersion ?? ''),
          strings.adminUpdateReadySubtitle(
            status.version,
            updateChannelLabel(strings, status.channel),
          ),
          trailing: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (status.changes.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _showChanges = !_showChanges),
                  child: Text(strings.adminUpdateWhatsNew),
                ),
              FilledButton(
                onPressed: watcher.busy
                    ? null
                    : () => _confirmAndStart(strings, status),
                child: Text(strings.adminUpdateNow),
              ),
            ],
          ),
        ),
        if (_showChanges)
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final change in status.changes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '•  $change',
                      style: TextStyle(
                        fontSize: 13,
                        color: palette.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (watcher.error != null)
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 10),
            child: Text(
              watcher.error!,
              style: TextStyle(fontSize: 13, color: palette.danger),
            ),
          ),
      ],
    );
  }

  Widget _running(
    AppL10n strings,
    NeoRecallPalette palette,
    UpdateStatus status,
  ) {
    final target = status.versionAfter;
    final detail = watcher.reconnecting
        ? strings.adminUpdateReconnecting
        : status.message;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _heading(
          palette,
          Icons.sync_rounded,
          palette.accent,
          target == null || target.isEmpty
              ? strings.adminUpdatingTitle
              : strings.adminUpdatingToTitle(target),
          detail,
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: LinearProgressIndicator(
            value: watcher.reconnecting ? null : status.progress / 100,
            minHeight: 5,
            backgroundColor: palette.border,
            valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          strings.adminUpdateHandsOff,
          style: TextStyle(fontSize: 12.5, color: palette.textMuted),
        ),
      ],
    );
  }

  Widget _completed(
    AppL10n strings,
    NeoRecallPalette palette,
    UpdateStatus status,
  ) {
    return _heading(
      palette,
      Icons.check_circle_outline_rounded,
      palette.success,
      strings.adminUpdateDoneTitle(status.versionAfter ?? status.version),
      strings.adminUpdateDoneReloading,
      trailing: Wrap(
        spacing: 8,
        children: <Widget>[
          TextButton(
            onPressed: watcher.dismiss,
            child: Text(strings.actionClose),
          ),
          FilledButton(
            onPressed: reloadPage,
            child: Text(strings.adminUpdateReload),
          ),
        ],
      ),
    );
  }

  Widget _failed(
    AppL10n strings,
    NeoRecallPalette palette,
    UpdateStatus status,
  ) {
    return _heading(
      palette,
      Icons.error_outline_rounded,
      palette.danger,
      strings.adminUpdateFailedTitle,
      status.message,
      trailing: Wrap(
        spacing: 8,
        children: <Widget>[
          TextButton(
            onPressed: watcher.dismiss,
            child: Text(strings.actionClose),
          ),
          if (status.hasAvailable && status.selfUpdate)
            FilledButton(
              onPressed: watcher.busy
                  ? null
                  : () => _confirmAndStart(strings, status),
              child: Text(strings.actionRetry),
            ),
        ],
      ),
    );
  }
}

/// The Updates card on the Overview area: channel, check now, why an install
/// cannot update itself, and the log of the last run.
class AdminUpdatesCard extends StatelessWidget {
  const AdminUpdatesCard({super.key, required this.watcher});

  final UpdateWatcher watcher;

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    return ListenableBuilder(
      listenable: watcher,
      builder: (context, _) {
        final status = watcher.status;
        if (status == null) return const SizedBox.shrink();
        final locked = status.running || watcher.busy || !status.selfUpdate;
        final checked = status.checkedAt == null
            ? strings.adminUpdateNeverChecked
            : strings.adminUpdateChecked(adminDate(context, status.checkedAt));
        final summary = status.hasAvailable
            ? strings.adminUpdateReadyTitle(status.availableVersion ?? '')
            : status.checkFailed
            ? strings.adminUpdateCheckFailed
            : status.checkedAt == null
            ? checked
            : '${strings.adminUpdateUpToDate} · $checked';
        TextStyle soft(double size) => TextStyle(
          fontSize: size,
          color: palette.textSecondary,
          height: 1.45,
        );
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm + 2),
          child: AdminCard(
            id: 'overview.updates',
            eyebrow: strings.adminUpdatesTitle,
            trailing: OutlinedButton.icon(
              onPressed: locked ? null : watcher.check,
              icon: watcher.busy
                  ? const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 18),
              label: Text(strings.adminUpdateCheckNow),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(strings.adminUpdatesHint, style: soft(13)),
                const SizedBox(height: 14),
                Text(
                  status.version,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(summary, style: soft(13)),
                const SizedBox(height: 16),
                Text(
                  strings.adminUpdateChannel,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(strings.adminUpdateChannelHint, style: soft(13)),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: <ButtonSegment<String>>[
                      ButtonSegment<String>(
                        value: 'stable',
                        label: Text(strings.adminUpdateChannelStable),
                      ),
                      ButtonSegment<String>(
                        value: 'beta',
                        label: Text(strings.adminUpdateChannelBeta),
                      ),
                    ],
                    selected: <String>{status.channel},
                    onSelectionChanged: locked
                        ? null
                        : (selection) => watcher.setChannel(selection.first),
                  ),
                ),
                if (!status.selfUpdate) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    status.blockedReason == 'container'
                        ? strings.adminUpdateContainerTitle
                        : strings.adminUpdateNotGitTitle,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status.blockedReason == 'container'
                        ? strings.adminUpdateContainerHint
                        : strings.adminUpdateNotGitHint,
                    style: soft(13),
                  ),
                  if (status.blockedReason == 'container') ...<Widget>[
                    const SizedBox(height: 8),
                    SelectableText(
                      'docker compose pull\ndocker compose up -d',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ],
                if (status.logs.isNotEmpty)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: Text(
                      strings.adminUpdateDetails,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: palette.textPrimary,
                      ),
                    ),
                    children: <Widget>[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText(
                          status.logs.join('\n'),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: palette.textSecondary,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                if (watcher.error != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    watcher.error!,
                    style: TextStyle(fontSize: 13, color: palette.danger),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
