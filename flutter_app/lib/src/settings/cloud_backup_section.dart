import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';

/// Settings card for a self-hosted backup destination: NeoCloud or Nextcloud.
class CloudBackupSectionCard extends StatefulWidget {
  const CloudBackupSectionCard({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<CloudBackupSectionCard> createState() => _CloudBackupSectionCardState();
}

class _CloudBackupSectionCardState extends State<CloudBackupSectionCard> {
  final _urlController = TextEditingController();
  String _provider = 'neocloud';

  @override
  void initState() {
    super.initState();
    widget.controller.loadCloudStatus();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  NeoRecallController get ctrl => widget.controller;

  String _providerName(AppL10n l10n, String? provider) =>
      provider == 'nextcloud'
      ? l10n.cloudProviderNextcloud
      : l10n.cloudProviderNeoCloud;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final l10n = AppL10n.of(context);
    return SettingsCard(
      eyebrow: l10n.cloudEyebrow,
      child: AnimatedBuilder(
        animation: ctrl,
        builder: (context, _) {
          if (ctrl.loadingCloud &&
              !ctrl.cloudConnected &&
              !ctrl.cloudConnecting) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                l10n.cloudTitle,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.cloudDescription,
                style: TextStyle(color: palette.textSecondary, height: 1.45),
              ),
              const SizedBox(height: 16),
              if (ctrl.cloudConnecting)
                _connecting(palette, l10n)
              else if (ctrl.cloudConnected)
                _connected(palette, l10n)
              else
                _disconnected(palette, l10n),
            ],
          );
        },
      ),
    );
  }

  Widget _disconnected(NeoRecallPalette palette, AppL10n l10n) {
    final name = _providerName(l10n, _provider);
    final loginError = ctrl.cloudLoginError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SegmentedButton<String>(
          segments: <ButtonSegment<String>>[
            ButtonSegment<String>(
              value: 'neocloud',
              label: Text(l10n.cloudProviderNeoCloud),
            ),
            ButtonSegment<String>(
              value: 'nextcloud',
              label: Text(l10n.cloudProviderNextcloud),
            ),
          ],
          selected: <String>{_provider},
          showSelectedIcon: false,
          onSelectionChanged: ctrl.cloudBusy
              ? null
              : (selection) => setState(() => _provider = selection.first),
        ),
        if (_provider == 'neocloud') ...<Widget>[
          const SizedBox(height: 10),
          Text(
            l10n.cloudNeoCloudBenefits,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _urlController,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: l10n.cloudInstanceUrlLabel(name),
            hintText: l10n.cloudInstanceUrlHint,
          ),
        ),
        if (loginError != null && loginError.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            loginError,
            style: TextStyle(color: palette.danger, height: 1.4),
          ),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: ctrl.cloudBusy
              ? null
              : () async {
                  final error = await ctrl.startCloudLogin(
                    _urlController.text,
                    provider: _provider,
                  );
                  if (!mounted || error == null) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(error)));
                },
          icon: const Icon(Icons.login, size: 18),
          label: Text(l10n.cloudSignIn(name)),
        ),
      ],
    );
  }

  Widget _connecting(NeoRecallPalette palette, AppL10n l10n) {
    final code = ctrl.cloudUserCode;
    final neocloud = ctrl.cloudProvider != 'nextcloud';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          neocloud ? l10n.cloudNeoCloudWaiting : l10n.cloudWaiting,
          style: TextStyle(color: palette.textSecondary, height: 1.45),
        ),
        if (neocloud && code != null) ...<Widget>[
          const SizedBox(height: 10),
          SelectableText(
            code,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              onPressed: ctrl.cloudLoginUrl == null
                  ? null
                  : () => ctrl.openCloudLoginUrl(ctrl.cloudLoginUrl!),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(l10n.cloudOpenLogin),
            ),
            OutlinedButton(
              onPressed: ctrl.cloudBusy ? null : ctrl.cancelCloudLogin,
              child: Text(l10n.actionCancel),
            ),
          ],
        ),
      ],
    );
  }

  Widget _connected(NeoRecallPalette palette, AppL10n l10n) {
    final status = ctrl.cloudStatus;
    final error = status['lastError'] as String?;
    final name = _providerName(l10n, ctrl.cloudProvider);
    final quota = _quotaLine(l10n, status['quota']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '$name · ${status['username'] ?? ''} · ${status['baseUrl'] ?? ''}',
          style: TextStyle(color: palette.textPrimary, height: 1.4),
        ),
        const SizedBox(height: 6),
        if (quota != null)
          Text(
            quota,
            style: TextStyle(color: palette.textSecondary, fontSize: 13),
          ),
        Text(
          l10n.cloudLastAudio(_formatWhen(l10n, status['lastAudioUploadAt'])),
          style: TextStyle(color: palette.textSecondary, fontSize: 13),
        ),
        Text(
          l10n.cloudLastData(_formatWhen(l10n, status['lastDataBackupAt'])),
          style: TextStyle(color: palette.textSecondary, fontSize: 13),
        ),
        if (error != null && error.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(error, style: TextStyle(color: palette.danger, height: 1.4)),
        ],
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: status['audioEnabled'] == true,
          onChanged: ctrl.cloudBusy
              ? null
              : (value) => ctrl.patchCloud({'audioEnabled': value}),
          title: Text(l10n.cloudAudioTitle),
          subtitle: Text(l10n.cloudAudioDescription(name)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: status['dataBackupEnabled'] == true,
          onChanged: ctrl.cloudBusy
              ? null
              : (value) => ctrl.patchCloud({'dataBackupEnabled': value}),
          title: Text(l10n.cloudDataTitle),
          subtitle: Text(l10n.cloudDataDescription),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: ctrl.cloudBusy
                  ? null
                  : () async {
                      final error = await ctrl.backupCloudNow();
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(error ?? l10n.cloudBackupQueued),
                        ),
                      );
                    },
              icon: const Icon(Icons.backup_outlined, size: 18),
              label: Text(l10n.cloudBackupNow),
            ),
            TextButton(
              onPressed: ctrl.cloudBusy
                  ? null
                  : () => _confirmDisconnect(l10n, name),
              child: Text(l10n.cloudDisconnect),
            ),
          ],
        ),
      ],
    );
  }

  String? _quotaLine(AppL10n l10n, Object? raw) {
    if (raw is! Map) return null;
    final used = raw['used'];
    final limit = raw['limit'];
    if (used is! num) return null;
    if (limit is num && limit >= 0) {
      return l10n.cloudQuota(_formatBytes(used), _formatBytes(limit));
    }
    return l10n.cloudQuotaUnlimited(_formatBytes(used));
  }

  String _formatBytes(num bytes) {
    const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    final digits = unit == 0 || value >= 100 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  String _formatWhen(AppL10n l10n, Object? value) {
    final raw = value as String?;
    if (raw == null || raw.isEmpty) return l10n.cloudNever;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final h = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  Future<void> _confirmDisconnect(AppL10n l10n, String name) async {
    final neocloud = ctrl.cloudProvider == 'neocloud';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.cloudDisconnectTitle(name)),
        content: Text(
          neocloud
              ? '${l10n.cloudDisconnectBody(name)}\n\n${l10n.cloudNeoCloudRevokeHint}'
              : l10n.cloudDisconnectBody(name),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.cloudDisconnect),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await ctrl.disconnectCloud();
    if (!mounted || error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }
}
