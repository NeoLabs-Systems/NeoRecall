import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_theme.dart';
import 'src/devices/appliance/ui/appliance_capture_section.dart';
import 'src/devices/appliance/ui/appliance_setup_flow.dart';

/// Account-level device management.
///
/// Operational Desk UI lives on Record. The Desk row here intentionally reuses
/// [ApplianceDeviceTile], so status language, reconnecting, and the detail sheet
/// cannot drift into a second implementation.
class DevicesPanel extends StatelessWidget {
  const DevicesPanel({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    if (controller.devices.isEmpty) {
      return GlassSurface(
        child: Column(
          children: <Widget>[
            const EmptyState(
              icon: Icons.devices_outlined,
              title: 'No devices yet',
              message:
                  'Apps appear here after their first recording. A NeoRecall Desk '
                  'appears once you set it up.',
            ),
            const SizedBox(height: 8),
            _addDeskButton(context, palette),
            const SizedBox(height: 8),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(right: 2, bottom: 32),
      // One extra row at the end: adding a device belongs where devices are, not
      // behind a sentence pointing at another screen.
      itemCount: controller.devices.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) => index == controller.devices.length
          ? _addDeskButton(context, palette)
          : _row(context, palette, controller.devices[index]),
    );
  }

  Widget _addDeskButton(BuildContext context, NeoRecallPalette palette) {
    return OutlinedButton.icon(
      onPressed: () => _addDesk(context),
      icon: const Icon(Icons.add_rounded, size: 20),
      label: const Text('Add a NeoRecall Desk'),
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.accent,
        side: BorderSide(color: palette.accent.withValues(alpha: 0.4)),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
      ),
    );
  }

  Future<void> _addDesk(BuildContext context) async {
    final completed = await showApplianceSetupFlow(context, controller.appliance);
    if (!completed || !context.mounted) return;
    // The appliance registers itself right after it is provisioned, so a refresh
    // here is what makes it appear in this list without a manual reload.
    await controller.refreshAll();
  }

  Widget _row(
    BuildContext context,
    NeoRecallPalette palette,
    Map<String, dynamic> device,
  ) {
    final revoked = device['revoked_at'] != null;
    final isAppliance = device['kind'] == 'appliance';
    if (isAppliance && !revoked) {
      return ApplianceDeviceTile(
        controller: controller.appliance,
        device: device,
        onTap: () => openApplianceDevice(context, controller.appliance, device),
      );
    }

    return GlassSurface(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: <Widget>[
          Icon(switch (device['kind']) {
            'browser' => Icons.language,
            'appliance' => Icons.speaker_group_outlined,
            _ => Icons.computer,
          }, color: revoked ? palette.textMuted : palette.accent),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        device['name'] as String,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (revoked) ...<Widget>[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: palette.danger.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'REVOKED',
                          style: TextStyle(
                            color: palette.danger,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  '${device['platform']} · ${device['last_heartbeat_at'] ?? 'not recently connected'}',
                  style: TextStyle(color: palette.textMuted),
                ),
              ],
            ),
          ),
          if (device['clock_offset_ms'] != null &&
              (device['clock_offset_ms'] as num).abs() > 120000)
            const Tooltip(
              message: 'Device clock differs by more than two minutes',
              child: Icon(Icons.schedule_send_outlined),
            ),
          IconButton(
            tooltip: 'Revoke device',
            onPressed: revoked
                ? null
                : () => controller.revokeDevice(device['id'] as String),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}
