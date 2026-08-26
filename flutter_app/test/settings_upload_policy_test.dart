import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_settings.dart';
import 'package:neorecall/main_theme.dart';

void main() {
  testWidgets('Wi-Fi-only switch applies immediately without page Save', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _SettingsController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.dark),
        home: Scaffold(
          body: SettingsScreen(
            controller: controller,
            initialSection: SettingsSection.recording,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final label = find.text('Upload only on Wi-Fi / unmetered networks');
    expect(label, findsOneWidget);
    await tester.tap(label);
    await tester.pumpAndSettle();

    expect(controller.updates, <Map<String, dynamic>>[
      <String, dynamic>{'uploadOnlyOnUnmetered': false},
    ]);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(
              SwitchListTile,
              'Upload only on Wi-Fi / unmetered networks',
            ),
          )
          .value,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}

class _SettingsController extends NeoRecallController {
  final List<Map<String, dynamic>> updates = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> loadSettings() async => <String, dynamic>{
    'consolidationIntervalMs': 3600000,
    'effectiveConsolidationIntervalMs': 3600000,
    'timezone': 'UTC',
    'recurringSpeakerMatching': true,
    'diarizationEnabled': true,
    'chunkTargetMs': 30000,
    'chunkOverlapMs': 2000,
    'chunkMinMs': 15000,
    'chunkMaxMs': 120000,
    'uploadOnlyOnUnmetered': true,
    'recordingScheduleEnabled': false,
    'recordingStartMinute': 0,
    'recordingEndMinute': 0,
  };

  @override
  Future<void> updateSettings(Map<String, dynamic> changes) async {
    updates.add(Map<String, dynamic>.from(changes));
  }

  @override
  Future<void> fetchTwoFactorStatus() async {}

  @override
  Future<void> fetchSecurityKeys() async {}
}
