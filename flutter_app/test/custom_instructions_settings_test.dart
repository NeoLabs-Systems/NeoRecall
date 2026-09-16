import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_settings.dart';
import 'package:neorecall/main_theme.dart';

Future<void> pumpInstructions(
  WidgetTester tester,
  NeoRecallController controller,
) async {
  tester.view.physicalSize = const Size(1400, 1400);
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
          initialSection: SettingsSection.instructions,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('stored instructions load into their areas and save back', (
    tester,
  ) async {
    final controller = _InstructionsController();
    addTearDown(controller.dispose);
    await pumpInstructions(tester, controller);

    expect(find.text('Write in German.'), findsOneWidget);
    expect(find.text('0/2000'), findsNWidgets(3));

    await tester.enterText(
      find.widgetWithText(TextField, 'When answering questions'),
      'Answer in two sentences.',
    );
    await tester.pump();
    final save = find.text('Save');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(controller.lastUpdate?['instructionsGlobal'], 'Write in German.');
    expect(
      controller.lastUpdate?['instructionsAsk'],
      'Answer in two sentences.',
    );
    expect(controller.lastUpdate?['instructionsMemories'], '');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an instruction over the limit blocks the save rather than failing at the server',
    (tester) async {
      final controller = _InstructionsController();
      addTearDown(controller.dispose);
      await pumpInstructions(tester, controller);

      await tester.enterText(
        find.widgetWithText(TextField, 'When writing summaries'),
        'x' * 2001,
      );
      await tester.pump();
      expect(find.text('At most 2000 characters.'), findsOneWidget);

      final save = find.text('Save');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(controller.lastUpdate, isNull);
    },
  );
}

class _InstructionsController extends NeoRecallController {
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
    'customVocabulary': <String>[],
    'customVocabularyMaxTerms': 100,
    'customVocabularyMaxTermLength': 120,
    'vocabularyCorrectionEnabled': true,
    'automaticSpeakerVocabulary': <String>[],
    'customInstructionsMaxCharacters': 2000,
    'instructionsGlobal': 'Write in German.',
    'instructionsMemories': '',
    'instructionsSummaries': '',
    'instructionsAsk': '',
  };

  @override
  Future<void> updateSettings(Map<String, dynamic> changes) async =>
      lastUpdate = Map<String, dynamic>.from(changes);

  @override
  Future<void> fetchTwoFactorStatus() async {}

  @override
  Future<void> fetchSecurityKeys() async {}
}
