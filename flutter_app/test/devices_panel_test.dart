import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_devices.dart';
import 'package:neorecall/main_theme.dart';

/// NeoRecall Desk registers as device kind "appliance"; the devices panel
/// must render it distinctly from other kinds and clearly mark revocation.
void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: buildNeoRecallTheme(Brightness.dark),
    home: Scaffold(body: child),
  );

  testWidgets('an appliance device gets its own icon and no revoked badge while active', (
    tester,
  ) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    controller.devices = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'device-1',
        'name': 'NeoRecall Desk',
        'platform': 'raspberrypi-zero2w',
        'kind': 'appliance',
        'revoked_at': null,
        'last_heartbeat_at': null,
        'clock_offset_ms': null,
      },
    ];

    await tester.pumpWidget(wrap(DevicesPanel(controller: controller)));
    await tester.pump();

    expect(find.text('NeoRecall Desk'), findsOneWidget);
    expect(find.byIcon(Icons.speaker_group_outlined), findsOneWidget);
    expect(find.byIcon(Icons.computer), findsNothing);
    expect(find.text('REVOKED'), findsNothing);
  });

  testWidgets('a revoked appliance device shows a REVOKED badge and disables the revoke action', (
    tester,
  ) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    controller.devices = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'device-2',
        'name': 'NeoRecall Desk (old key)',
        'platform': 'raspberrypi-zero2w',
        'kind': 'appliance',
        'revoked_at': '2026-08-20T00:00:00.000Z',
        'last_heartbeat_at': null,
        'clock_offset_ms': null,
      },
    ];

    await tester.pumpWidget(wrap(DevicesPanel(controller: controller)));
    await tester.pump();

    expect(find.text('REVOKED'), findsOneWidget);
    final revokeButton = tester.widget<IconButton>(find.byType(IconButton));
    expect(revokeButton.onPressed, isNull);
  });
}
