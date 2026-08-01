import 'package:flutter/material.dart';

import '../../main_theme.dart';
import 'platform_copy.dart';
import 'source_status_chip.dart';

class SourcePlatformCard extends StatelessWidget {
  const SourcePlatformCard({
    super.key,
    required this.copy,
    required this.available,
    this.unavailableReason,
    this.source,
    this.accountEmail,
    this.lastSyncAt,
    this.error,
    this.prerequisites = const <String>[],
    this.busy = false,
    this.onConnect,
    this.onToggle,
    this.onSync,
    this.onDisconnect,
    this.onReconnect,
  });

  final SourcePlatformCopy copy;
  final bool available;
  final String? unavailableReason;
  final Map<String, dynamic>? source;
  final String? accountEmail;
  final String? lastSyncAt;
  final String? error;
  final List<String> prerequisites;
  final bool busy;
  final VoidCallback? onConnect;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onSync;
  final VoidCallback? onDisconnect;
  final VoidCallback? onReconnect;

  bool get isConnected => source != null;
  bool get hasError => error != null && error!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final muted = !available && !isConnected;

    return Card(
      color: palette.bgCard,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: palette.bgSecondary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    copy.icon,
                    color: muted ? palette.textMuted : palette.accent,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              copy.name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (!available && !isConnected)
                            SourceStatusChip.unavailable()
                          else if (hasError)
                            SourceStatusChip.error()
                          else if (isConnected && source!['enabled'] != true)
                            SourceStatusChip.disabled()
                          else if (isConnected)
                            SourceStatusChip.connected(),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        copy.description,
                        style: TextStyle(color: palette.textSecondary, fontSize: 13),
                      ),
                      if (accountEmail != null && accountEmail!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          accountEmail!,
                          style: TextStyle(color: palette.textMuted, fontSize: 12),
                        ),
                      ],
                      if (lastSyncAt != null && lastSyncAt!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Last synced ${_friendlyTime(lastSyncAt!)}',
                          style: TextStyle(color: palette.textMuted, fontSize: 12),
                        ),
                      ],
                      if (hasError) ...[
                        const SizedBox(height: 6),
                        Text(
                          error!,
                          style: TextStyle(color: Colors.red.shade400, fontSize: 12),
                        ),
                      ],
                      if (!available && !isConnected && unavailableReason != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          unavailableReason!,
                          style: TextStyle(color: palette.textMuted, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (busy)
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (isConnected)
                  _ConnectedActions(
                    palette: palette,
                    enabled: source!['enabled'] == true,
                    onToggle: onToggle,
                    onSync: onSync,
                    onDisconnect: onDisconnect,
                    onReconnect: hasError ? onReconnect : null,
                  )
                else if (available)
                  ElevatedButton(
                    onPressed: onConnect,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: palette.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    ),
                    child: Text(copy.connectLabel),
                  ),
              ],
            ),
            if (!isConnected && prerequisites.isNotEmpty) ...[
              const SizedBox(height: 10),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 4),
                  title: Text(
                    'How it works',
                    style: TextStyle(color: palette.textSecondary, fontSize: 13),
                  ),
                  children: [
                    for (final item in prerequisites)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('•  ', style: TextStyle(color: palette.textMuted)),
                            Expanded(
                              child: Text(
                                item,
                                style: TextStyle(color: palette.textMuted, fontSize: 12.5, height: 1.35),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (copy.auth == 'oauth')
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'NeoRecall imports cloud recordings after the platform finishes them — it does not join the live call.',
                          style: TextStyle(color: palette.textMuted, fontSize: 12.5, height: 1.35),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _friendlyTime(String iso) {
    final parsed = DateTime.tryParse(iso)?.toLocal();
    if (parsed == null) return iso;
    final now = DateTime.now();
    final diff = now.difference(parsed);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }
}

class _ConnectedActions extends StatelessWidget {
  const _ConnectedActions({
    required this.palette,
    required this.enabled,
    this.onToggle,
    this.onSync,
    this.onDisconnect,
    this.onReconnect,
  });

  final NeoRecallPalette palette;
  final bool enabled;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onSync;
  final VoidCallback? onDisconnect;
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onReconnect != null)
          TextButton(
            onPressed: onReconnect,
            child: const Text('Reconnect', style: TextStyle(fontSize: 12)),
          ),
        if (onSync != null)
          IconButton(
            tooltip: 'Sync now',
            onPressed: onSync,
            icon: Icon(Icons.sync, color: palette.textSecondary),
          ),
        Switch(
          value: enabled,
          onChanged: onToggle,
          activeThumbColor: palette.accent,
        ),
        IconButton(
          icon: Icon(Icons.link_off, color: palette.danger),
          tooltip: 'Disconnect',
          onPressed: onDisconnect,
        ),
      ],
    );
  }
}
