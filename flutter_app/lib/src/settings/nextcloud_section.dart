import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';

/// Settings card for a self-hosted Nextcloud backup sink.
class NextcloudSectionCard extends StatefulWidget {
  const NextcloudSectionCard({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<NextcloudSectionCard> createState() => _NextcloudSectionCardState();
}

class _NextcloudSectionCardState extends State<NextcloudSectionCard> {
  final _urlController = TextEditingController();

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

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final l10n = AppL10n.of(context);
    return SectionCard(
      eyebrow: l10n.cloudNextcloudEyebrow,
      child: AnimatedBuilder(
        animation: ctrl,
        builder: (context, _) {
          if (ctrl.loadingCloud && !ctrl.cloudConnected && !ctrl.cloudConnecting) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                l10n.cloudNextcloudTitle,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.cloudNextcloudDescription,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _urlController,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: l10n.cloudInstanceUrlLabel,
            hintText: l10n.cloudInstanceUrlHint,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: ctrl.cloudBusy
              ? null
              : () async {
                  final error = await ctrl.startCloudLogin(_urlController.text);
                  if (!mounted || error == null) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(error)),
                  );
                },
          icon: const Icon(Icons.login, size: 18),
          label: Text(l10n.cloudSignIn),
        ),
      ],
    );
  }

  Widget _connecting(NeoRecallPalette palette, AppL10n l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          l10n.cloudWaiting,
          style: TextStyle(color: palette.textSecondary, height: 1.45),
        ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '${status['username'] ?? ''} · ${status['baseUrl'] ?? ''}',
          style: TextStyle(color: palette.textPrimary, height: 1.4),
        ),
        const SizedBox(height: 6),
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
          subtitle: Text(l10n.cloudAudioDescription),
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
                          content: Text(
                            error ?? l10n.cloudBackupQueued,
                          ),
                        ),
                      );
                    },
              icon: const Icon(Icons.backup_outlined, size: 18),
              label: Text(l10n.cloudBackupNow),
            ),
            TextButton(
              onPressed: ctrl.cloudBusy ? null : () => _confirmDisconnect(l10n),
              child: Text(l10n.cloudDisconnect),
            ),
          ],
        ),
      ],
    );
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

  Future<void> _confirmDisconnect(AppL10n l10n) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.cloudDisconnectTitle),
        content: Text(l10n.cloudDisconnectBody),
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
