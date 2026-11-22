import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_settings.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';

Future<void> _pumpSettings(
  WidgetTester tester,
  NeoRecallController controller,
) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
}

void main() {
  testWidgets('connected Nextcloud card shows backup toggles', (tester) async {
    final controller = _CloudController(<String, dynamic>{
      'connected': true,
      'status': 'connected',
      'type': 'nextcloud',
      'baseUrl': 'https://cloud.example.test',
      'username': 'ada',
      'audioEnabled': true,
      'dataBackupEnabled': false,
      'lastAudioUploadAt': '2026-09-09T12:00:00.000Z',
      'lastDataBackupAt': null,
    });
    addTearDown(controller.dispose);
    await _pumpSettings(tester, controller);

    expect(find.text('Back up to your own cloud'), findsOneWidget);
    expect(find.text('Copy recordings'), findsOneWidget);
    expect(
      find.textContaining('upload one audio file to Nextcloud'),
      findsOneWidget,
    );
    expect(find.text('Back up this account'), findsOneWidget);
    expect(find.text('Back up now'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connected NeoCloud card shows how full NeoCloud is', (
    tester,
  ) async {
    final controller = _CloudController(<String, dynamic>{
      'connected': true,
      'status': 'connected',
      'type': 'neocloud',
      'baseUrl': 'https://files.example.test',
      'username': 'ada',
      'audioEnabled': true,
      'dataBackupEnabled': true,
      'quota': <String, dynamic>{'used': 1610612736, 'limit': 10737418240},
    });
    addTearDown(controller.dispose);
    await _pumpSettings(tester, controller);

    expect(find.textContaining('NeoCloud · ada'), findsOneWidget);
    expect(
      find.text('NeoCloud storage: 1.5 GB of 10.0 GB used'),
      findsOneWidget,
    );
    expect(
      find.textContaining('upload one audio file to NeoCloud'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('disconnected card offers NeoCloud first, Nextcloud second', (
    tester,
  ) async {
    final controller = _CloudController(<String, dynamic>{
      'connected': false,
      'status': 'disconnected',
    });
    addTearDown(controller.dispose);
    await _pumpSettings(tester, controller);

    expect(find.text('Sign in with NeoCloud'), findsOneWidget);
    expect(find.text('NeoCloud URL'), findsOneWidget);
    await tester.tap(find.text('Nextcloud'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in with Nextcloud'), findsOneWidget);
    expect(find.text('Nextcloud URL'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('waiting for NeoCloud shows the code to compare', (tester) async {
    final controller = _CloudController(<String, dynamic>{
      'connected': false,
      'status': 'connecting',
      'type': 'neocloud',
      'userCode': 'ABCD-EFGH',
      'loginUrl': 'https://files.example.test/app/device?code=ABCD-EFGH',
    });
    addTearDown(controller.dispose);
    await _pumpSettings(tester, controller);

    expect(find.text('ABCD-EFGH'), findsOneWidget);
    expect(find.text('Open login page'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.disposeCloud();
  });
}

class _CloudController extends NeoRecallController {
  _CloudController(Map<String, dynamic> status) {
    cloudStatus = status;
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
