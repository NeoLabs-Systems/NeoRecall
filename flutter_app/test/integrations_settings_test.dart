import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_settings.dart';
import 'package:neorecall/main_theme.dart';

void main() {
  testWidgets('integrations settings show the MCP URL and connected apps', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _IntegrationsController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
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

    expect(find.text('https://recall.example.test/mcp'), findsOneWidget);
    expect(find.text('Copy MCP URL'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('MCP client'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _IntegrationsController extends NeoRecallController {
  _IntegrationsController() {
    integrations = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'nrc_claude',
        'name': 'Claude',
        'description': 'mcp:dcr',
      },
    ];
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
}
