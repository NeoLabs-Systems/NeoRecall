import 'dart:ui';

import '../../l10n/gen/app_l10n.dart';

/// A language NeoRecall can present itself in.
///
/// The same choice drives two things that used to be unrelated: the language of
/// the interface, and the language the server's model writes memories,
/// summaries and answers in. Splitting them would let somebody read a German
/// interface over English memory cards, which is not a state anyone asked for.
///
/// [code] is what the server stores and what the model is told to write in, so
/// it must stay in step with the registry in
/// `server/ai/prompts/output_language.js`.
enum AppLanguage {
  english('en', 'English'),
  german('de', 'Deutsch');

  const AppLanguage(this.code, this.label);

  /// The IETF/ISO 639-1 code exchanged with the server.
  final String code;

  /// The language's own name for itself, which is what a picker must show: a
  /// German speaker looking for their language is looking for "Deutsch".
  final String label;

  Locale get locale => Locale(code);

  /// The default when nothing has been chosen and nothing can be detected.
  static const AppLanguage fallback = AppLanguage.english;

  /// The language for a stored or server-supplied code.
  ///
  /// Returns null rather than a fallback so that callers can tell "not set" from
  /// "set to English" — first-launch detection depends on that difference.
  static AppLanguage? fromCode(String? code) {
    if (code == null) return null;
    final normalized = code.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    for (final language in AppLanguage.values) {
      if (language.code == normalized) return language;
    }
    return null;
  }

  /// The language to start a fresh installation in.
  ///
  /// Matched on the primary subtag only, so de-AT and de-CH are German like
  /// de-DE is, and every locale this build does not speak lands on English.
  static AppLanguage detect(List<Locale> systemLocales) {
    for (final locale in systemLocales) {
      final match = fromCode(locale.languageCode);
      if (match != null) return match;
    }
    return fallback;
  }
}

/// The language the app is currently in, for code that runs away from any
/// widget tree.
///
/// Screens read their translations from the widget tree, which is the right
/// answer wherever there is one. The API client, the Android background
/// service and the controller's own notices all produce text the user reads
/// while no BuildContext is in reach, so they read it from here instead. The
/// controller keeps it in step with the chosen language.
AppLanguage currentAppLanguage = AppLanguage.fallback;

/// The translations for [currentAppLanguage].
AppL10n get appStrings => lookupAppL10n(currentAppLanguage.locale);
