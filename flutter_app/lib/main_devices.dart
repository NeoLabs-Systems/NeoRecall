import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_theme.dart';

class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key, required this.controller});
  final NeoRecallController controller;
  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return RefreshIndicator(
      onRefresh: controller.refreshAll,
      child: ListView(
        padding: const EdgeInsets.all(28),
        children: <Widget>[
          const ScreenHeader(
            eyebrow: 'DEVICES',
            title: 'Capture endpoints',
            description:
                'Review registered browsers and desktop clients, clock measurements, last sync, and revocation state.',
          ),
          const SizedBox(height: 24),
          if (controller.devices.isEmpty)
            const GlassSurface(
              child: EmptyState(
                icon: Icons.devices_outlined,
                title: 'No registered devices',
                message:
                    'This client registers when its first recording session syncs.',
              ),
            )
          else
            for (final device in controller.devices)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GlassSurface(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        device['kind'] == 'browser'
                            ? Icons.language
                            : Icons.computer,
                        color: palette.accent,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              device['name'] as String,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
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
                          message:
                              'Device clock differs by more than two minutes',
                          child: Icon(Icons.schedule_send_outlined),
                        ),
                      IconButton(
                        tooltip: 'Revoke device',
                        onPressed: device['revoked_at'] == null
                            ? () => controller.revokeDevice(
                                device['id'] as String,
                              )
                            : null,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
