import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_theme.dart';
import 'settings_section_list.dart';
import '../../l10n/gen/app_l10n.dart';

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
          eyebrow: AppL10n.of(context).integrationsMcpEyebrow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                AppL10n.of(context).integrationsMcpTitle,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                AppL10n.of(context).integrationsMcpDescription,
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
                    SnackBar(
                      content: Text(AppL10n.of(context).integrationsMcpCopied),
                    ),
                  );
                },
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: Text(AppL10n.of(context).integrationsMcpCopy),
              ),
            ],
          ),
        ),
        SectionCard(
          eyebrow: AppL10n.of(context).integrationsConnectedEyebrow,
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
        AppL10n.of(context).integrationsNoneConnected,
        style: TextStyle(color: palette.textSecondary, height: 1.45),
      );
    }
    return Column(
      children: <Widget>[
        for (
          var index = 0;
          index < ctrl.integrations.length;
          index++
        ) ...<Widget>[
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
    final name =
        item['name'] as String? ?? AppL10n.of(context).integrationsConnectedApp;
    final kind = _kindLabel(
      AppL10n.of(context),
      item['description'] as String?,
    );
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
          child: Text(AppL10n.of(context).integrationsRevoke),
        ),
      ],
    );
  }

  String _kindLabel(AppL10n l10n, String? description) {
    if (description == 'companion:neoagent') {
      return l10n.integrationsClientNeoAgent;
    }
    if (description == 'mcp:dcr') return l10n.integrationsClientMcp;
    return l10n.integrationsClientOAuth;
  }

  Future<void> _confirmRevoke(
    NeoRecallController ctrl,
    Map<String, dynamic> item,
  ) async {
    final name =
        item['name'] as String? ?? AppL10n.of(context).integrationsThisApp;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppL10n.of(context).integrationsRevokeTitle),
        content: Text(AppL10n.of(context).integrationsRevokeBody(name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(AppL10n.of(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(AppL10n.of(context).integrationsRevoke),
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
