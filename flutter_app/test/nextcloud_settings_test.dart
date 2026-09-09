import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_settings.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';

void main() {
  testWidgets('connected Nextcloud card shows backup toggles', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _CloudController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        theme: buildNeoRecallTheme(Brightness.dark),
        home: Scaffold(
          body: SettingsScreen(
            controller: controller,
            initialSection: SettingsSection.integrations,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Back up to your Nextcloud'), findsOneWidget);
    expect(find.text('Copy recordings'), findsOneWidget);
    expect(find.text('Back up this account'), findsOneWidget);
    expect(find.text('Back up now'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _CloudController extends NeoRecallController {
  _CloudController() {
    cloudStatus = <String, dynamic>{
      'connected': true,
      'status': 'connected',
      'type': 'nextcloud',
      'baseUrl': 'https://cloud.example.test',
      'username': 'ada',
      'audioEnabled': true,
      'dataBackupEnabled': false,
      'lastAudioUploadAt': '2026-09-09T12:00:00.000Z',
      'lastDataBackupAt': null,
    };
  }

  @override
  String get backendUrl => 'https://recall.example.test';

  @override
  Future<Map<String, dynamic>> loadSettings() async => <String, dynamic>{
    'timezone': 'UTC',
  };

  @override
  Future<void> fetchTwoFactorStatus() async {}

  @override
  Future<void> fetchSecurityKeys() async {}

  @override
  Future<void> loadIntegrations() async {}

  @override
  Future<void> loadCloudStatus() async {}
}
