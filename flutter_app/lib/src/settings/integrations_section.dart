import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_theme.dart';
import 'settings_section_list.dart';

/// MCP URL and authorized OAuth clients (NeoAgent and remote MCP).
class IntegrationsSection extends StatefulWidget {
  const IntegrationsSection({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<IntegrationsSection> createState() => _IntegrationsSectionState();
}

class _IntegrationsSectionState extends State<IntegrationsSection> {
  @override
  void initState() {
    super.initState();
    widget.controller.loadIntegrations();
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final ctrl = widget.controller;
    return SettingsSectionList(
      controller: ctrl,
      children: <Widget>[
        SectionCard(
          eyebrow: 'MCP',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Connect Claude, ChatGPT, or Cursor',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Paste this MCP URL into Claude, ChatGPT (MCP), or Cursor. '
                'The client opens NeoRecall for sign-in and the same read-only consent as NeoAgent. '
                'Ask, ingest, and memory edits stay inside NeoRecall.',
                style: TextStyle(color: palette.textSecondary, height: 1.45),
              ),
              const SizedBox(height: 16),
              SelectableText(
                ctrl.mcpEndpointUrl,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontFamily: 'IBM Plex Mono',
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: ctrl.mcpEndpointUrl),
                  );
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('MCP URL copied')),
                  );
                },
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: const Text('Copy MCP URL'),
              ),
            ],
          ),
        ),
        SectionCard(
          eyebrow: 'CONNECTED APPS',
          child: _connectedApps(palette, ctrl),
        ),
      ],
    );
  }

  Widget _connectedApps(NeoRecallPalette palette, NeoRecallController ctrl) {
    if (ctrl.loadingIntegrations) {
      return const Center(child: CircularProgressIndicator());
    }
    if (ctrl.integrations.isEmpty) {
      return Text(
        'No apps are connected yet. After you authorize NeoAgent or an MCP client, it appears here so you can revoke it.',
        style: TextStyle(color: palette.textSecondary, height: 1.45),
      );
    }
    return Column(
      children: <Widget>[
        for (var index = 0; index < ctrl.integrations.length; index++) ...<Widget>[
          if (index > 0) const SizedBox(height: 12),
          _integrationRow(palette, ctrl, ctrl.integrations[index]),
        ],
      ],
    );
  }

  Widget _integrationRow(
    NeoRecallPalette palette,
    NeoRecallController ctrl,
    Map<String, dynamic> item,
  ) {
    final name = item['name'] as String? ?? 'Connected app';
    final kind = _kindLabel(item['description'] as String?);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                name,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                kind,
                style: TextStyle(color: palette.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: () => _confirmRevoke(ctrl, item),
          child: const Text('Revoke'),
        ),
      ],
    );
  }

  String _kindLabel(String? description) {
    if (description == 'companion:neoagent') return 'NeoAgent';
    if (description == 'mcp:dcr') return 'MCP client';
    return 'OAuth client';
  }

  Future<void> _confirmRevoke(
    NeoRecallController ctrl,
    Map<String, dynamic> item,
  ) async {
    final name = item['name'] as String? ?? 'this app';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke access?'),
        content: Text(
          '$name will lose read-only access to this account until you connect it again.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final id = item['id'] as String?;
    if (id == null) return;
    await ctrl.revokeIntegration(id);
  }
}
