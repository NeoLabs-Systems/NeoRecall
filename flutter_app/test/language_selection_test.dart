import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_settings.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/l10n/app_language.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the first launch takes its language from the device', () {
    expect(
      AppLanguage.detect(const <Locale>[Locale('de', 'AT')]),
      AppLanguage.german,
    );
    expect(
      AppLanguage.detect(const <Locale>[Locale('en')]),
      AppLanguage.english,
    );
    // A language this build does not speak is skipped, not guessed at.
    expect(
      AppLanguage.detect(const <Locale>[Locale('fr'), Locale('de')]),
      AppLanguage.german,
    );
    expect(
      AppLanguage.detect(const <Locale>[Locale('ja')]),
      AppLanguage.english,
    );
    expect(AppLanguage.detect(const <Locale>[]), AppLanguage.english);
  });

  test('an unset or unknown stored code is not mistaken for a choice', () {
    expect(AppLanguage.fromCode(null), isNull);
    expect(AppLanguage.fromCode(''), isNull);
    expect(AppLanguage.fromCode('klingon'), isNull);
    expect(AppLanguage.fromCode('DE'), AppLanguage.german);
  });

  test('the German catalogue is a translation, not a copy of the English', () {
    final english = lookupAppL10n(const Locale('en'));
    final german = lookupAppL10n(const Locale('de'));
    expect(german.settingsTitle, 'Einstellungen');
    expect(german.actionCancel, 'Abbrechen');
    expect(german.navRecord, 'Aufnahme');
    expect(german.momentsGroupCount(2), '2 Momente');
    expect(german.momentsGroupCount(1), '1 Moment');
    expect(german.settingsTitle, isNot(english.settingsTitle));
  });

  testWidgets('the settings picker switches the interface and is remembered', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _LanguageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      AnimatedBuilder(
        animation: controller,
        builder: (_, _) => MaterialApp(
          locale: controller.language.locale,
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          theme: buildNeoRecallTheme(Brightness.light),
          home: Scaffold(body: SettingsScreen(controller: controller)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Language'), findsOneWidget);
    final picker = find.byType(DropdownButtonFormField<AppLanguage>);
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deutsch').last);
    await tester.pumpAndSettle();

    expect(controller.language, AppLanguage.german);
    // The heading itself is now German, which is the whole point of the switch.
    expect(find.text('Sprache'), findsOneWidget);
    expect(find.text('Einstellungen'), findsWidgets);
    // Written down, so the next launch does not fall back to detection.
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('appLanguage'), 'de');
    expect(tester.takeException(), isNull);
  });
}

class _LanguageController extends NeoRecallController {
  @override
  Future<Map<String, dynamic>> loadSettings() async => <String, dynamic>{
    'language': null,
    'consolidationIntervalMs': 3600000,
    'effectiveConsolidationIntervalMs': 3600000,
    'minConsolidationIntervalMs': 3600000,
    'timezone': 'UTC',
    'chunkMinMs': 15000,
    'chunkMaxMs': 120000,
    'chunkTargetMs': 30000,
    'chunkOverlapMs': 2000,
    'customVocabulary': <String>[],
    'customVocabularyMaxTerms': 100,
    'customVocabularyMaxTermLength': 120,
    'customInstructionsMaxCharacters': 2000,
    'automaticSpeakerVocabulary': <String>[],
    'contextOriginalRetentionDays': 7,
    'keepRawAudio': true,
    'speakerIdentityAvailable': true,
  };

  // The picker saves through the controller; the account it would save to does
  // not exist in this test, so the local half of the switch is what is checked.
  @override
  Future<void> updateSettings(Map<String, dynamic> changes) async {}

  @override
  Future<void> fetchTwoFactorStatus() async {}

  @override
  Future<void> fetchSecurityKeys() async {}
}
