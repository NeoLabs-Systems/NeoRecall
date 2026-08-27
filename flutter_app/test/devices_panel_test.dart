import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_devices.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/record/record_controls.dart';

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

  _recordingStateTests();
}

/// The device list is where a screenless recorder has to prove it is recording.
void _recordingStateTests() {
  Widget wrap(Widget child) => MaterialApp(
    theme: buildNeoRecallTheme(Brightness.dark),
    home: Scaffold(body: child),
  );

  Map<String, dynamic> appliance({
    String? activeSessionId,
    String? activeSessionStartedAt,
    String? heartbeat,
  }) => <String, dynamic>{
    'id': 'device-1',
    'name': 'NeoRecall Desk',
    'platform': 'raspberrypi',
    'kind': 'appliance',
    'revoked_at': null,
    'last_heartbeat_at': heartbeat,
    'clock_offset_ms': null,
    'active_session_id': activeSessionId,
    'active_session_started_at': activeSessionStartedAt,
  };

  testWidgets('an appliance recording elsewhere still says so in the list', (tester) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    controller.devices = <Map<String, dynamic>>[
      appliance(
        activeSessionId: 'session-1',
        activeSessionStartedAt: DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 14, seconds: 3))
            .toIso8601String(),
      ),
    ];

    await tester.pumpWidget(wrap(DevicesPanel(controller: controller)));
    await tester.pump();

    // The phone is not near the device, so this comes from the server's record
    // of an open session — which is the whole reason that field exists.
    expect(find.textContaining('Recording'), findsOneWidget);
    expect(find.textContaining('14:0'), findsOneWidget);
    expect(find.byType(StatusDot), findsOneWidget);
  });

  testWidgets('an idle appliance reads as a sentence, not a timestamp', (tester) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    controller.devices = <Map<String, dynamic>>[
      appliance(heartbeat: DateTime.now().toUtc().toIso8601String()),
    ];

    await tester.pumpWidget(wrap(DevicesPanel(controller: controller)));
    await tester.pump();

    expect(find.text('Ready'), findsOneWidget);
    expect(find.textContaining('raspberrypi'), findsNothing);
    expect(find.textContaining('T'), findsNothing);
  });

  testWidgets('an appliance nobody has seen for a while says how long', (tester) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    controller.devices = <Map<String, dynamic>>[
      appliance(
        heartbeat: DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 3))
            .toIso8601String(),
      ),
    ];

    await tester.pumpWidget(wrap(DevicesPanel(controller: controller)));
    await tester.pump();

    expect(find.text('Last seen 3 hours ago'), findsOneWidget);
  });

  testWidgets('an appliance opens instead of offering a delete button', (tester) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    controller.devices = <Map<String, dynamic>>[appliance()];

    await tester.pumpWidget(wrap(DevicesPanel(controller: controller)));
    await tester.pump();

    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(find.byType(InkWell), findsWidgets);
  });

  testWidgets('other device kinds are left exactly as they were', (tester) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    controller.devices = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'device-9',
        'name': 'Laptop',
        'platform': 'macos',
        'kind': 'desktop',
        'revoked_at': null,
        'last_heartbeat_at': '2026-08-26T09:00:00.000Z',
        'clock_offset_ms': null,
      },
    ];

    await tester.pumpWidget(wrap(DevicesPanel(controller: controller)));
    await tester.pump();

    expect(find.text('macos · 2026-08-26T09:00:00.000Z'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });
}
