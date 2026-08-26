import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_settings.dart';
import 'package:neorecall/main_theme.dart';

void main() {
  testWidgets(
    'custom vocabulary is clear, duplicate-aware, and saves correction preference',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = _VocabularyController();
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

      expect(
        find.text('Added automatically from named speakers'),
        findsOneWidget,
      );
      expect(find.text('Grace Hopper'), findsOneWidget);
      final field = find.widgetWithText(
        TextField,
        'Words and phrases to recognize',
      );
      await tester.enterText(field, 'NeoRecall\nneorecall\nQbii Technologies');
      await tester.pump();
      expect(find.text('2/100 terms'), findsOneWidget);

      final correction = find.text('Correct close transcription misspellings');
      await tester.ensureVisible(correction);
      await tester.tap(correction);
      final save = find.text('Save');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(controller.lastUpdate?['customVocabulary'], <String>[
        'NeoRecall',
        'Qbii Technologies',
      ]);
      expect(controller.lastUpdate?['vocabularyCorrectionEnabled'], false);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('custom vocabulary settings remain usable at phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _VocabularyController();
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
    final field = find.widgetWithText(
      TextField,
      'Words and phrases to recognize',
    );
    await tester.scrollUntilVisible(field, 500);
    expect(field, findsOneWidget);
    expect(find.text('Grace Hopper'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _VocabularyController extends NeoRecallController {
  Map<String, dynamic>? lastUpdate;

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
    'customVocabulary': <String>['NeoRecall'],
    'customVocabularyMaxTerms': 100,
    'customVocabularyMaxTermLength': 120,
    'vocabularyCorrectionMinimumLength': 8,
    'vocabularyCorrectionEnabled': true,
    'automaticSpeakerVocabulary': <String>['Grace Hopper'],
  };

  @override
  Future<void> updateSettings(Map<String, dynamic> changes) async =>
      lastUpdate = Map<String, dynamic>.from(changes);

  @override
  Future<void> fetchTwoFactorStatus() async {}

  @override
  Future<void> fetchSecurityKeys() async {}
}
