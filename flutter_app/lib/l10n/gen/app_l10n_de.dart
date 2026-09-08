// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_l10n.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppL10nDe extends AppL10n {
  AppL10nDe([String locale = 'de']) : super(locale);

  @override
  String get appLoading => 'NeoRecall wird geladen';

  @override
  String get settingsLanguageTitle => 'Sprache';

  @override
  String get settingsLanguageDescription =>
      'Die Sprache, in der NeoRecall die App anzeigt und Erinnerungen, Zusammenfassungen und Antworten schreibt. Aufnahmen werden weiterhin in der tatsächlich gesprochenen Sprache transkribiert.';

  @override
  String get settingsLanguageLabel => 'Sprache für App und Erinnerungen';

  @override
  String settingsLanguageFailed(String error) {
    return 'Die Sprache konnte nicht geändert werden: $error';
  }

  @override
  String get actionCancel => 'Abbrechen';

  @override
  String get actionSave => 'Speichern';

  @override
  String get settingsTitle => 'Einstellungen';

  @override
  String get settingsDescription =>
      'Aufnahmeverhalten, Erinnerungen und Kontosicherheit an einem Ort.';

  @override
  String get settingsSaved => 'Einstellungen gespeichert.';

  @override
  String settingsVocabularyTooMany(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Entfernen Sie $count Begriffe, um zu speichern.',
      one: 'Entfernen Sie 1 Begriff, um zu speichern.',
    );
    return '$_temp0';
  }

  @override
  String settingsVocabularyTermTooLong(int maximum) {
    return 'Jeder Begriff darf höchstens $maximum Zeichen lang sein.';
  }

  @override
  String get settingsShortenRetentionTitle =>
      'Aufbewahrung der Originaldateien verkürzen?';

  @override
  String settingsShortenRetentionBody(int days) {
    return 'Originalfotos, Dokumente und Rohaudio, die älter als $days Tage sind, werden bei der nächsten Bereinigung endgültig gelöscht. Transkripte und KI-Beschreibungen bleiben erhalten.';
  }

  @override
  String get settingsShortenRetentionConfirm => 'Aufbewahrung verkürzen';

  @override
  String settingsUploadPolicyFailed(String error) {
    return 'Die Upload-Regel konnte nicht geändert werden: $error';
  }

  @override
  String get settingsStopRawAudioTitle => 'Rohaudio nicht mehr behalten?';

  @override
  String get settingsStopRawAudioBody =>
      'Aufnahmen, die bereits auf diesem Gerät liegen, werden jetzt gelöscht. Transkripte, Titel und Erinnerungen bleiben erhalten.';

  @override
  String get settingsStopRawAudioConfirm => 'Rohaudio löschen';

  @override
  String settingsRawAudioFailed(String error) {
    return 'Die Rohaudio-Speicherung konnte nicht geändert werden: $error';
  }

  @override
  String get settingsDevicesTitle => 'Angemeldete Geräte';

  @override
  String get settingsDevicesDescription =>
      'Zugriffe prüfen oder alte Clients entfernen. Aufnahmegeräte richten Sie unter „Aufnahme“ ein, verbinden und steuern Sie dort.';

  @override
  String get settingsOpenRecord => 'Aufnahme öffnen';

  @override
  String settingsServicesNoAdminKey(String backendUrl) {
    return 'Diese Dienste werden auf dem Server selbst eingestellt. Diese App hat keinen Administratorschlüssel für $backendUrl – bitten Sie die Person, die diesen Server betreibt, Transkription und Erinnerungserstellung dort einzurichten.';
  }

  @override
  String get settingsServicesTitle => 'Dienste';

  @override
  String get settingsSectionGeneral => 'ALLGEMEIN';

  @override
  String get settingsTimeLocaleTitle => 'Zeit und Region';

  @override
  String get settingsTimeLocaleDescription =>
      'Damit werden Aufnahmen und erzeugte Erinnerungen auf Ihrer lokalen Zeitachse eingeordnet.';

  @override
  String get settingsTimezoneLabel => 'IANA-Zeitzone';

  @override
  String get settingsSectionAlwaysOn => 'DAUERAUFNAHME';

  @override
  String get settingsUnmeteredTitle =>
      'Nur über WLAN / kostenfreie Netze hochladen';

  @override
  String get settingsUnmeteredDescription =>
      'Standardmäßig aktiv. Ohne Verbindung oder im Mobilfunknetz wird weiter in den privaten App-Speicher aufgenommen und erst hochgeladen, sobald eine kostenfreie Verbindung verfügbar ist.';

  @override
  String get settingsScheduleTitle => 'Tägliches Aufnahmefenster';

  @override
  String get settingsScheduleDescription =>
      'Verwendet die lokale Zeit dieses Geräts. Aus bedeutet rund um die Uhr; Fenster über Nacht wie 22:00–06:00 sind möglich.';

  @override
  String settingsScheduleStart(String time) {
    return 'Beginn $time';
  }

  @override
  String settingsScheduleStop(String time) {
    return 'Ende $time';
  }

  @override
  String get settingsScheduleFootnote =>
      'Zum Endzeitpunkt wird der laufende Abschnitt im Gerätespeicher abgeschlossen. Unter Android muss NeoRecall unter Umständen geöffnet werden, damit das Telefonmikrofon zum nächsten Startzeitpunkt wieder anlaufen kann.';

  @override
  String get settingsSilenceTitle => 'Umgang mit Stille';

  @override
  String get settingsSilenceDescription =>
      'Die serverseitige Sprachaktivitätserkennung markiert stille Abschnitte. Das Telefon behält seine Kopie, bis eine abschließende Quittung belegt, dass die Verarbeitung abgeschlossen und das Audio auf dem Server gelöscht wurde.';

  @override
  String get settingsSectionRecording => 'AUFNAHME';

  @override
  String settingsChunkDuration(int seconds) {
    return 'Abschnittslänge: $seconds Sekunden';
  }

  @override
  String settingsChunkOverlap(String seconds) {
    return 'Überlappung an den Grenzen: $seconds Sekunden';
  }

  @override
  String get settingsSectionTranscription => 'TRANSKRIPTION';

  @override
  String get settingsVocabularyLabel =>
      'Wörter und Wendungen, die erkannt werden sollen';

  @override
  String get settingsVocabularyHint =>
      'NeoRecall\nProdukt- oder Firmenname\nFachbegriff';

  @override
  String get settingsVocabularyHelper =>
      'Ein Eintrag pro Zeile. Doppelte werden ignoriert.';

  @override
  String get settingsVocabularyCorrectionTitle =>
      'Naheliegende Schreibfehler der Transkription korrigieren';

  @override
  String settingsVocabularyCorrectionDescription(Object minimum) {
    return 'Bei Anbietern ohne eigenen Wörterbuchabgleich werden nur eindeutige Einzelwörter ab $minimum Zeichen korrigiert.';
  }

  @override
  String get settingsSpeakerVocabularyTitle =>
      'Automatisch aus benannten Sprechern übernommen';

  @override
  String get settingsSectionRecordingContext => 'AUFNAHMEKONTEXT';

  @override
  String get settingsKeepRawAudioTitle => 'Rohaudio auf diesem Gerät behalten';

  @override
  String get settingsKeepRawAudioDescription =>
      'Standardmäßig aktiv. Anhören können Sie es unter „Momente“. Der Server löscht seine Kopie weiterhin nach der Transkription; nur dieses Gerät behält die Datei, und nur bis zum unten eingestellten Zeitraum.';

  @override
  String settingsRetentionTitle(int days) {
    return 'Originalfotos, Dokumente und Rohaudio $days Tage lang behalten';
  }

  @override
  String get settingsRetentionDescription =>
      'Nach diesem Zeitraum löscht NeoRecall die Originaldaten, behält aber Transkripte, extrahierten Text, Bildbeschreibungen und Quellverweise.';

  @override
  String settingsRetentionDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days Tage',
      one: '1 Tag',
    );
    return '$_temp0';
  }

  @override
  String get settingsRetentionOneYear => '1 Jahr';

  @override
  String get settingsRetentionWarning =>
      'Ein Verkürzen der Aufbewahrung kann vorhandene Originale bei der nächsten Serverbereinigung endgültig löschen.';

  @override
  String get settingsSectionMemory => 'ERINNERUNGEN';

  @override
  String get settingsConsolidationTitle => 'Abstand zwischen Auswertungen';

  @override
  String get settingsConsolidationImmediate => 'Sobald genug Material vorliegt';

  @override
  String settingsConsolidationWait(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'Mindestens $hours Stunden zwischen den Auswertungen warten',
      one: 'Mindestens 1 Stunde zwischen den Auswertungen warten',
    );
    return '$_temp0';
  }

  @override
  String get settingsConsolidationSliderImmediate => 'Sofort';

  @override
  String settingsConsolidationSliderHours(int hours) {
    return '$hours Std.';
  }

  @override
  String get settingsConsolidationFloorNone =>
      'Erinnerungen werden geschrieben, sobald genug gesagt wurde – ohne auf das Ende eines Gesprächs zu warten.';

  @override
  String settingsConsolidationFloor(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'Dieser Server wertet höchstens alle $hours Stunden aus.',
      one: 'Dieser Server wertet höchstens einmal pro Stunde aus.',
    );
    return '$_temp0';
  }

  @override
  String settingsInstructionsTooLong(int count, int limit) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Kürzen Sie $count Anweisungen auf $limit Zeichen, um zu speichern.',
      one: 'Kürzen Sie 1 Anweisung auf $limit Zeichen, um zu speichern.',
    );
    return '$_temp0';
  }

  @override
  String settingsInstructionsLimit(int limit) {
    return 'Höchstens $limit Zeichen.';
  }

  @override
  String get settingsInstructionsIntro =>
      'Sie werden bei jeder Anfrage in ihrem Bereich mitgeschickt. Sie beeinflussen Ton, Länge, Sprache und was Ihnen wichtig ist – sie ändern nicht, was das Modell lesen darf, und die Grundlage bleiben ausschließlich Ihre eigenen Aufnahmen.';

  @override
  String get settingsSectionEverywhere => 'ÜBERALL';

  @override
  String get settingsInstructionsGlobalLabel => 'Allgemeine Anweisungen';

  @override
  String get settingsInstructionsGlobalHint =>
      'Schreibe auf Deutsch.\nVerwende 24-Stunden-Zeiten.';

  @override
  String get settingsInstructionsGlobalHelper =>
      'Gilt gleichermaßen für Erinnerungen, Zusammenfassungen und Antworten.';

  @override
  String get settingsSectionMemories => 'ERINNERUNGEN';

  @override
  String get settingsInstructionsMemoriesLabel =>
      'Beim Schreiben von Erinnerungen';

  @override
  String get settingsSectionSummaries => 'ZUSAMMENFASSUNGEN';

  @override
  String get settingsInstructionsSummariesLabel =>
      'Beim Schreiben von Zusammenfassungen';

  @override
  String get settingsSectionAsk => 'FRAGEN';

  @override
  String get settingsInstructionsAskLabel => 'Beim Beantworten von Fragen';

  @override
  String get settingsSectionSpeakers => 'SPRECHER';

  @override
  String get settingsDiarizationTitle => 'Sprechertrennung';

  @override
  String get settingsDiarizationDescription =>
      'Überlappende Sprecher während der Transkription trennen.';

  @override
  String get settingsRecurringSpeakerTitle =>
      'Wiedererkennung bekannter Sprecher';

  @override
  String get settingsRecurringSpeakerDescription =>
      'Bekannte Stimmprofile über Aufnahmen hinweg zuordnen.';

  @override
  String get settingsInstructionsMemoriesHint =>
      'Nenne immer, wer dabei war.\nHalte Entscheidungen und Zusagen von Small Talk getrennt.';

  @override
  String get settingsInstructionsMemoriesHelper =>
      'Wird verwendet, wenn ein Ereignis zu einer Erinnerungskarte ausgearbeitet wird sowie beim Umschreiben und Zusammenführen von Erinnerungen.';

  @override
  String get settingsInstructionsSummariesHint =>
      'Höchstens fünf Zeilen.\nBeginne mit dem, was sich geändert hat.';

  @override
  String get settingsInstructionsSummariesHelper =>
      'Wird für die Tageszusammenfassung und für die laufende Zusammenfassung eines Gesprächs während der Aufnahme verwendet.';

  @override
  String get settingsInstructionsAskHint =>
      'Antworte in zwei Sätzen und höre dann auf.';

  @override
  String get settingsInstructionsAskHelper =>
      'Wird für jede Antwort im Bereich „Fragen“ verwendet.';

  @override
  String get settingsSpeakerIdentityUnavailable =>
      'Ihr Server kann Stimmen derzeit nicht unterscheiden, daher werden neue Aufnahmen nicht nach Sprechern getrennt. Die Einrichtung auf dem Server installiert das Nötige. Bereits vergebene Sprechernamen bleiben erhalten.';

  @override
  String get settingsDeferredSpeakerTitle =>
      'Sprecher am Ende eines Gesprächs erneut prüfen';

  @override
  String get settingsDeferredSpeakerDescription =>
      'Prüft noch einmal, wer gesprochen hat, sobald das ganze Gespräch vorliegt, damit eine Person nicht mehrfach auftaucht. Sprecherbezeichnungen können sich kurz nach dem Ende einer Aufnahme noch ändern.';

  @override
  String get settingsNavGeneral => 'Allgemein';

  @override
  String get settingsNavGeneralDescription => 'Zeit und Region';

  @override
  String get settingsNavSecurity => 'Sicherheit';

  @override
  String get settingsNavSecurityDescription => 'Passwörter und 2FA';

  @override
  String get settingsNavRecording => 'Aufnahme';

  @override
  String get settingsNavRecordingDescription =>
      'Zeitplan, Netzwerk, Abschnitte';

  @override
  String get settingsNavMemory => 'Erinnerungen';

  @override
  String get settingsNavMemoryDescription => 'Zeitpunkt der Auswertung';

  @override
  String get settingsNavInstructions => 'Anweisungen';

  @override
  String get settingsNavInstructionsDescription =>
      'Wie das Modell für Sie schreibt';

  @override
  String get settingsNavSpeakers => 'Sprecher';

  @override
  String get settingsNavSpeakersDescription => 'Sprechertrennung und Zuordnung';

  @override
  String get settingsNavWatch => 'Uhr';

  @override
  String get settingsNavWatchDescription => 'Wear-OS-Einrichtung und Übersicht';

  @override
  String get settingsNavDevices => 'Kontogeräte';

  @override
  String get settingsNavDevicesDescription => 'Sitzungen und Zugriff';

  @override
  String get settingsNavServices => 'Dienste';

  @override
  String get settingsNavServicesDescription =>
      'Transkription und Erinnerungserstellung';

  @override
  String get settingsNavIntegrations => 'Integrationen';

  @override
  String get settingsNavIntegrationsDescription => 'NeoAgent und MCP';

  @override
  String get settingsNavAreaLabel => 'Einstellungsbereich';

  @override
  String get settingsNavAreasHeading => 'Einstellungsbereiche';

  @override
  String get navRecord => 'Aufnahme';

  @override
  String get navSources => 'Quellen';

  @override
  String get navMoments => 'Momente';

  @override
  String get navMemories => 'Erinnerungen';

  @override
  String get navHighlights => 'Markierungen';

  @override
  String get navSpeakers => 'Sprecher';

  @override
  String get navAsk => 'Fragen';

  @override
  String get navSettings => 'Einstellungen';

  @override
  String get navCapture => 'Aufnehmen';

  @override
  String get navLibrary => 'Bibliothek';

  @override
  String get shellAccountFallback => 'Konto';

  @override
  String get shellControlSurface => 'STEUERZENTRALE';

  @override
  String get shellSignOut => 'Abmelden';

  @override
  String get shellBatteryWarning =>
      'Die Akkuoptimierung kann die Daueraufnahme auf diesem Gerät unterbrechen.';

  @override
  String get shellBatteryFix => 'Beheben';

  @override
  String get shellOffline =>
      'Offline – die Aufnahme läuft weiter; Uploads werden nach der Wiederverbindung fortgesetzt.';

  @override
  String get shellRecordingActive => 'Die Aufnahme läuft.';

  @override
  String get shellRecordingOpen => 'Öffnen';

  @override
  String shellSyncing(String label) {
    return '$label wird synchronisiert';
  }

  @override
  String get authPasswordsDoNotMatch => 'Die Passwörter stimmen nicht überein.';

  @override
  String get authTwoFactorTitle => '2FA-Code eingeben';

  @override
  String get authRegisterTitle => 'NeoRecall-Konto erstellen';

  @override
  String get authSignInTitle => 'Anmelden';

  @override
  String get authTwoFactorSubtitle =>
      'Öffnen Sie Ihre Authenticator-App und geben Sie den aktuellen NeoRecall-Code ein.';

  @override
  String get authRegisterSubtitle =>
      'Das erste Konto wird zum NeoRecall-Administrator dieses Servers.';

  @override
  String get authSignInSubtitle => 'Geben Sie Ihre NeoRecall-Kontodaten ein.';

  @override
  String get authRetryLocalStartup => 'Lokalen Start erneut versuchen';

  @override
  String get authTwoFactorFieldLabel => '2FA- oder Wiederherstellungscode';

  @override
  String get authUsernameLabel => 'Benutzername';

  @override
  String get authEmailLabel => 'E-Mail (optional)';

  @override
  String get authPasswordLabel => 'Passwort';

  @override
  String get authConfirmPasswordLabel => 'Passwort bestätigen';

  @override
  String get authVerify => 'Bestätigen';

  @override
  String get authCreateAccount => 'Konto erstellen';

  @override
  String get authSecurityKeySignIn => 'Mit Sicherheitsschlüssel anmelden';

  @override
  String get authSwitchToSignIn => 'Schon ein Konto? Anmelden';

  @override
  String get authSwitchToRegister => 'Neues Konto nötig? Registrieren';

  @override
  String get authServerButton => 'Server';

  @override
  String get authWelcomeEyebrow => 'WILLKOMMEN BEI NEORECALL';

  @override
  String get authSetUpOrConnect => 'NeoRecall einrichten oder verbinden';

  @override
  String get authConnect => 'NeoRecall verbinden';

  @override
  String get authSetUpOrConnectBody =>
      'Installieren Sie NeoRecall ohne Terminal auf diesem Computer oder geben Sie die Adresse eines bereits laufenden Servers ein.';

  @override
  String get authConnectBody =>
      'Geben Sie die Adresse des NeoRecall-Servers ein, den dieses Gerät verwenden soll.';

  @override
  String get authInstallLocally => 'NeoRecall auf diesem Computer einrichten';

  @override
  String get authOrConnectRunning =>
      'oder mit einem laufenden Server verbinden';

  @override
  String get authServerAddressLabel => 'Adresse des NeoRecall-Servers';

  @override
  String get authConnectToServer => 'Mit diesem Server verbinden';

  @override
  String get authBackToSignIn => 'Zurück zur Anmeldung';

  @override
  String get askNewQuestion => 'Neue Frage';

  @override
  String get askHint => 'Fragen Sie alles über Ihren Tag';

  @override
  String get askFollowUpHint => 'Nachfragen';

  @override
  String get askStarterToday => 'Was habe ich heute gemacht?';

  @override
  String get askStarterFollowUps =>
      'Worum wollte ich mich diese Woche noch kümmern?';

  @override
  String get askStarterYesterday =>
      'Mit wem habe ich gestern gesprochen, und worüber?';

  @override
  String get askEyebrow => 'Rückblick';

  @override
  String get askDescription =>
      'Ihre Erinnerungen, in Ihren eigenen Worten. Suche und Antwort laufen dort, wo Ihr NeoRecall-Server läuft – keine Anfrage verlässt ihn.';

  @override
  String get askStartWith => 'Zum Einstieg';

  @override
  String askWeakMatches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count schwächere Treffer wurden ausgelassen – sie teilen Wörter mit der Frage, nicht die Bedeutung.',
      one:
          '1 schwächerer Treffer wurde ausgelassen – er teilt Wörter mit der Frage, nicht die Bedeutung.',
    );
    return '$_temp0';
  }

  @override
  String get askSourcesExpanded => 'QUELLEN';

  @override
  String get askSourcesCollapsed => 'QUELLEN ANZEIGEN';

  @override
  String askPeriodRead(String period) {
    return 'Gelesen: $period';
  }

  @override
  String askPeriodFrom(String time) {
    return 'ab $time';
  }

  @override
  String askPeriodUntil(String time) {
    return 'bis $time';
  }

  @override
  String get askNothingRecorded => 'nichts aufgezeichnet';

  @override
  String get askSubmitTooltip => 'Fragen';

  @override
  String get askSearching => 'Ihre Erinnerungen werden durchsucht';

  @override
  String memoriesBulkDeleted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Erinnerungen gelöscht',
      one: '1 Erinnerung gelöscht',
    );
    return '$_temp0';
  }

  @override
  String memoriesBulkPinned(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Erinnerungen angeheftet',
      one: '1 Erinnerung angeheftet',
    );
    return '$_temp0';
  }

  @override
  String memoriesBulkUnpinned(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Erinnerungen losgelöst',
      one: '1 Erinnerung losgelöst',
    );
    return '$_temp0';
  }

  @override
  String memoriesBulkArchived(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Erinnerungen archiviert',
      one: '1 Erinnerung archiviert',
    );
    return '$_temp0';
  }

  @override
  String memoriesBulkRestored(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Erinnerungen wiederhergestellt',
      one: '1 Erinnerung wiederhergestellt',
    );
    return '$_temp0';
  }

  @override
  String memoriesBulkUpdated(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Erinnerungen aktualisiert',
      one: '1 Erinnerung aktualisiert',
    );
    return '$_temp0';
  }

  @override
  String memoriesBulkFailed(String error) {
    return 'Die Erinnerungen konnten nicht aktualisiert werden: $error';
  }

  @override
  String memoriesRenameFailed(String error) {
    return 'Umbenennen nicht möglich: $error';
  }

  @override
  String get memoriesMergeTitle => 'Erinnerungen zusammenführen?';

  @override
  String memoriesMergeBody(int count) {
    return '$count Erinnerungen zu einer zusammenfassen. Markierungen und Gesprächsbelege bleiben erhalten; für den zusammengeführten Moment werden ein neuer Titel und eine neue Beschreibung geschrieben.';
  }

  @override
  String get memoriesMergeConfirm => 'Zusammenführen';

  @override
  String get memoriesMergedQueued =>
      'Erinnerungen zusammengeführt. Die Beschreibung wird in Kürze aktualisiert.';

  @override
  String get memoriesMerged => 'Erinnerungen zusammengeführt.';

  @override
  String memoriesMergeFailed(String error) {
    return 'Die Erinnerungen konnten nicht zusammengeführt werden: $error';
  }

  @override
  String get memoriesRenameDialogTitle => 'Erinnerung umbenennen';

  @override
  String get memoriesTitleLabel => 'Titel';

  @override
  String get actionDone => 'Fertig';

  @override
  String get actionSelect => 'Auswählen';

  @override
  String get memoriesDescription =>
      'Ihre Gespräche, verdichtet zu klaren Erinnerungen und umsetzbaren Markierungen.';

  @override
  String get memoriesRestore => 'Wiederherstellen';

  @override
  String get memoriesArchive => 'Archivieren';

  @override
  String get memoriesEmptyFilteredTitle => 'Keine passenden Erinnerungen';

  @override
  String get memoriesEmptyTitle => 'Noch nichts vorhanden';

  @override
  String get memoriesEmptyFilteredMessage =>
      'Probieren Sie einen anderen Filter oder löschen Sie die Suche.';

  @override
  String get memoriesEmptyMessage =>
      'Nehmen Sie weiter auf. Wenn ein Gespräch endet, macht NeoRecall im Hintergrund eine Erinnerung daraus.';

  @override
  String get memoriesNoActionItemsTitle => 'Noch keine Aufgaben';

  @override
  String get memoriesNoActionItemsMessage =>
      'Konkrete Aufgaben und Zusagen erscheinen hier, sobald ein Gespräch sie hervorbringt.';

  @override
  String momentsDeleteTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Momente löschen?',
      one: 'Diesen Moment löschen?',
    );
    return '$_temp0';
  }

  @override
  String get momentsDeleteBodyOne =>
      'Dieses Gespräch und sein Transkript werden endgültig gelöscht. Eine Erinnerung, die nur aus diesem Gespräch stammt, wird ebenfalls entfernt.';

  @override
  String get momentsDeleteBodyMany =>
      'Diese Gespräche und ihre Transkripte werden endgültig gelöscht. Erinnerungen, die nur aus ihnen stammen, werden ebenfalls entfernt.';

  @override
  String get actionDelete => 'Löschen';

  @override
  String momentsDeleted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Momente gelöscht',
      one: '1 Moment gelöscht',
    );
    return '$_temp0';
  }

  @override
  String momentsDeleteFailed(String error) {
    return 'Die Momente konnten nicht gelöscht werden: $error';
  }

  @override
  String get momentsDescription =>
      'Ein kompakter Strom von Gesprächen. Klappen Sie nur die auf, die Sie ganz lesen möchten.';

  @override
  String get momentsEmptyNoTranscript => 'Noch kein Transkript';

  @override
  String get momentsEmptyNothing => 'Noch nichts anzuzeigen';

  @override
  String get momentsEmptyNoTranscriptMessage =>
      'Starten Sie eine Aufnahme oder importieren Sie Audio. Gespeicherte Abschnitte erscheinen hier.';

  @override
  String get momentsEmptyNothingMessage =>
      'Ihre Aufnahmen sind sicher. Sie erscheinen hier, sobald das oben Genannte geklärt ist.';

  @override
  String get momentsToday => 'Heute';

  @override
  String momentsGroupCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Momente',
      one: '1 Moment',
    );
    return '$_temp0';
  }

  @override
  String get momentsStatusPending => 'Wird eingeordnet';

  @override
  String get momentsStatusSetAside => 'Wartet auf eine Zusammenfassung';

  @override
  String get momentsStatusAwaitsWriteUp => 'Zusammenfassung ist unterwegs';

  @override
  String get momentsListen => 'Anhören';

  @override
  String get momentsUnassignedSpeaker => 'Nicht zugeordnet';

  @override
  String get momentsJustRecorded => 'Gerade aufgenommen';

  @override
  String get momentsConversation => 'Gespräch';

  @override
  String get momentsLoadingRest => 'Der Rest dieses Moments wird geladen';

  @override
  String momentsShowingFirstLines(int shown, int total) {
    return 'Es werden die ersten $shown von $total Zeilen angezeigt.';
  }

  @override
  String get momentsShowLess => 'Weniger anzeigen';

  @override
  String momentsMoreLines(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count weitere Zeilen',
      one: '1 weitere Zeile',
    );
    return '$_temp0';
  }

  @override
  String get momentsWritingUp => 'Wird ausgearbeitet';

  @override
  String get momentsWriteUpAgain => 'Erneut ausarbeiten';

  @override
  String get momentsWriteUpNow => 'Jetzt ausarbeiten';

  @override
  String get momentsRecordingBadge => 'Aufnahme';

  @override
  String get momentsNewer => 'Neuer';

  @override
  String get momentsOlder => 'Älter';

  @override
  String momentsPage(int page) {
    return 'Seite $page';
  }

  @override
  String get momentsSelectPrompt => 'Momente auswählen';

  @override
  String momentsSelectedCount(int count) {
    return '$count ausgewählt';
  }

  @override
  String get momentsAllSelected => 'Alle Momente ausgewählt';

  @override
  String get momentsSelectAll => 'Alle Momente auswählen';

  @override
  String get speakersRenameTitle => 'Wiederkehrenden Sprecher benennen';

  @override
  String get speakersDisplayNameLabel => 'Anzeigename';

  @override
  String get speakersMergeIntoTitle =>
      'Eine weitere Stimme in diesen Sprecher übernehmen';

  @override
  String get speakersUnnamed => 'Unbenannter wiederkehrender Sprecher';

  @override
  String speakersDeleteManyTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Sprecher löschen?',
      one: '1 Sprecher löschen?',
    );
    return '$_temp0';
  }

  @override
  String get speakersDeleteManyBody =>
      'Diese Sprecherprofile werden endgültig gelöscht. Zugehörige Transkriptabschnitte weisen sie dann nicht mehr aus.';

  @override
  String speakersDeleted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Sprecher gelöscht',
      one: '1 Sprecher gelöscht',
    );
    return '$_temp0';
  }

  @override
  String speakersDeleteFailed(String error) {
    return 'Die Sprecher konnten nicht gelöscht werden: $error';
  }

  @override
  String get speakersCombineTargetTitle =>
      'In welchen Sprecher zusammenführen?';

  @override
  String speakersCombined(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Sprecher zusammengeführt',
      one: '1 Sprecher zusammengeführt',
    );
    return '$_temp0';
  }

  @override
  String speakersCombineFailed(String error) {
    return 'Die Sprecher konnten nicht zusammengeführt werden: $error';
  }

  @override
  String get speakersUpToDate => 'Die Sprecherprofile sind bereits aktuell';

  @override
  String speakersMergedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count passende Sprecherprofile zusammengeführt',
      one: '1 passendes Sprecherprofil zusammengeführt',
    );
    return '$_temp0';
  }

  @override
  String speakersReevaluateFailed(String error) {
    return 'Die Sprecher konnten nicht neu bewertet werden: $error';
  }

  @override
  String speakersPreviewFailed(String error) {
    return 'Die Hörprobe ist fehlgeschlagen: $error';
  }

  @override
  String get speakersReevaluateTooltip =>
      'Sprecher neu bewerten und passende zusammenführen';

  @override
  String get speakersDescription =>
      'Erkennen Sie eine Stimme anhand einer kurzen, sauberen Probe und benennen oder verbinden Sie dann ihr wiederkehrendes Profil.';

  @override
  String get speakersEmptyTitle => 'Noch keine wiederkehrenden Sprecher';

  @override
  String get speakersEmptyMessage =>
      'Ein Sprecher erscheint, sobald eine vollständige, saubere Hörprobe von 10 Sekunden vorliegt.';

  @override
  String get speakersDeleteOneTitle => 'Sprecher löschen?';

  @override
  String get speakersDeleteOneBody =>
      'Dieses Sprecherprofil wird endgültig gelöscht. Zugehörige Transkriptabschnitte weisen diesen Sprecher dann nicht mehr aus.';

  @override
  String get speakersPausePreview => 'Hörprobe pausieren';

  @override
  String get speakersPlayPreview => 'Hörprobe abspielen';

  @override
  String get speakersPreviewNeeded =>
      'Es wird eine vollständige, saubere Hörprobe benötigt';

  @override
  String get speakersNameTooltip => 'Sprecher benennen';

  @override
  String get speakersDeleteTooltip => 'Sprecher löschen';

  @override
  String get speakersSelectPrompt => 'Sprecher auswählen';

  @override
  String speakersSelectedCount(int count) {
    return '$count ausgewählt';
  }

  @override
  String get speakersAllSelected => 'Alle Sprecher ausgewählt';

  @override
  String get speakersSelectAll => 'Alle Sprecher auswählen';

  @override
  String get speakersCombineTooltip => 'Zu einem Sprecher zusammenführen';

  @override
  String get monthShort1 => 'JAN';

  @override
  String get monthShort2 => 'FEB';

  @override
  String get monthShort3 => 'MÄR';

  @override
  String get monthShort4 => 'APR';

  @override
  String get monthShort5 => 'MAI';

  @override
  String get monthShort6 => 'JUN';

  @override
  String get monthShort7 => 'JUL';

  @override
  String get monthShort8 => 'AUG';

  @override
  String get monthShort9 => 'SEP';

  @override
  String get monthShort10 => 'OKT';

  @override
  String get monthShort11 => 'NOV';

  @override
  String get monthShort12 => 'DEZ';

  @override
  String get weekdayLong1 => 'MONTAG';

  @override
  String get weekdayLong2 => 'DIENSTAG';

  @override
  String get weekdayLong3 => 'MITTWOCH';

  @override
  String get weekdayLong4 => 'DONNERSTAG';

  @override
  String get weekdayLong5 => 'FREITAG';

  @override
  String get weekdayLong6 => 'SAMSTAG';

  @override
  String get weekdayLong7 => 'SONNTAG';

  @override
  String get recordConsentTitle =>
      'Einwilligung und sichtbare Nutzung der Aufnahme';

  @override
  String get recordConsentBody =>
      'NeoRecall zeichnet privat gesprochene Worte auf. Nehmen Sie nur auf, wenn alle Beteiligten informiert sind und Sie rechtlich dazu befugt sind. Eine Aufnahme bleibt immer sichtbar gekennzeichnet; NeoRecall hat keinen verdeckten Modus.';

  @override
  String get recordConsentAccept => 'Ich habe verstanden';

  @override
  String get recordDeviceNoAnswer => 'Das Gerät hat nicht geantwortet.';

  @override
  String get recordFootnoteOfflineDevice =>
      'Dieses Gerät nimmt eigenständig auf – es gibt keine Live-Aufnahme. Verwenden Sie „Geräteaufnahmen synchronisieren“, um sie abzurufen und zu transkribieren.';

  @override
  String get recordFootnoteEitherSide =>
      'Starten Sie über die App oder das Gerät. Beide Seiten können stoppen. Aufnahmen, die in Ihrer Abwesenheit entstanden sind, werden weiterhin vom Gerät synchronisiert.';

  @override
  String get recordFootnoteSystemAudio =>
      'Systemaudio nutzt die Bildschirmaufnahme-Berechtigung des Betriebssystems und erfasst nur Ton, keine Videobilder.';

  @override
  String get recordOffline =>
      'Sie sind offline. Die Aufnahme läuft lokal weiter, und wartendes Audio wird automatisch hochgeladen, sobald die Verbindung zurück ist.';

  @override
  String get recordSourceWearable => 'Wearable';

  @override
  String get recordSourceDesk => 'NeoRecall Desk';

  @override
  String get recordSourcePhoneMicrophone => 'Telefonmikrofon';

  @override
  String get recordSourceMicrophoneAndDevice => 'Mikrofon und Geräteton';

  @override
  String get recordSourceDeviceAudio => 'Geräteton';

  @override
  String get recordSourceMicrophone => 'Mikrofon';

  @override
  String get recordNoteTitle => 'Notiz hinzufügen';

  @override
  String get recordNoteHint =>
      'Namen, Zusammenhänge, Entscheidungen – alles, was das Transkript übersehen könnte …';

  @override
  String get recordNoteSave => 'Notiz speichern';

  @override
  String get recordGreetingStillUp => 'Noch wach';

  @override
  String get recordGreetingMorning => 'Guten Morgen';

  @override
  String get recordGreetingAfternoon => 'Guten Tag';

  @override
  String get recordGreetingEvening => 'Guten Abend';

  @override
  String get recordDurationUnderMinute => 'unter einer Minute';

  @override
  String recordDurationMinutes(int minutes) {
    return '$minutes Min.';
  }

  @override
  String get recordStateLive => 'LIVE';

  @override
  String get recordStateStandby => 'BEREIT';

  @override
  String get recordStateRecording => 'Aufnahme läuft';

  @override
  String get recordStateReady => 'Aufnahmebereit';

  @override
  String get recordStateDeviceSync =>
      'Aufnahmen werden vom Gerät synchronisiert';

  @override
  String get recordTodayLabel => 'Heute';

  @override
  String get recordNothingToday => 'Heute wurde noch nichts aufgezeichnet.';

  @override
  String get recordUntitledMoment => 'Moment ohne Titel';

  @override
  String recordSegmentCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Abschnitte',
      one: '1 Abschnitt',
    );
    return '$_temp0';
  }

  @override
  String get recordAllMoments => 'Alle Momente →';

  @override
  String get recordContextFootnote =>
      'Fügen Sie Zusammenhänge hinzu, während sie entstehen. Jeder Eintrag wird zuerst lokal gespeichert und dann synchronisiert.';

  @override
  String get recordInProgressTitle => 'Aufnahme läuft';

  @override
  String get recordInProgressDescription =>
      'Markieren Sie wichtige Stellen und fügen Sie Notizen, Bilder oder Dokumente hinzu, ohne die Aufnahme zu verlassen.';

  @override
  String get recordContextTitle => 'Aufnahmekontext';

  @override
  String get recordContextDescription =>
      'Diese Quellen helfen NeoRecall zu verstehen, worauf es ankommt, und verbessern die fertige Erinnerung.';

  @override
  String get recordContextHighlight => 'Markierung';

  @override
  String get recordContextNote => 'Notiz';

  @override
  String get recordContextPhoto => 'Foto';

  @override
  String get recordContextFile => 'Datei';

  @override
  String get recordContextEmpty => 'Noch kein Kontext hinzugefügt.';

  @override
  String get recordHighlightedMoment => 'Markierte Stelle';

  @override
  String get recordVisibleAndActive => 'Die Aufnahme ist sichtbar und aktiv';

  @override
  String recordMomentCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Momente',
      one: '1 Moment',
    );
    return '$_temp0';
  }

  @override
  String get securitySectionEyebrow => 'SICHERHEIT';

  @override
  String get securityTwoFactorTitle => 'Zwei-Faktor-Authentifizierung';

  @override
  String get securityTwoFactorDescription =>
      'Schützen Sie Ihr Konto mit einer Authenticator-App.';

  @override
  String securityTwoFactorEnabled(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '2FA ist aktiv (noch $count Wiederherstellungscodes)',
      one: '2FA ist aktiv (noch 1 Wiederherstellungscode)',
    );
    return '$_temp0';
  }

  @override
  String get securityDisableTwoFactor => '2FA deaktivieren';

  @override
  String get securityRegenerateCodes => 'Codes neu erzeugen';

  @override
  String get securityTwoFactorDisabled => '2FA ist nicht aktiv';

  @override
  String get securityEnableTwoFactor => '2FA aktivieren';

  @override
  String get securityKeysEyebrow => 'SICHERHEITSSCHLÜSSEL';

  @override
  String get securityKeysTitle => 'Sicherheitsschlüssel';

  @override
  String get securityKeysDescription =>
      'Melden Sie sich mit einem Hardwareschlüssel oder Passkey statt mit Ihrem Passwort an. Ein Schlüssel, der eine PIN oder einen Fingerabdruck verlangt, ersetzt auch Ihren Zwei-Faktor-Code.';

  @override
  String get securityKeysNone => 'Keine Sicherheitsschlüssel registriert.';

  @override
  String get securityKeysAdd => 'Sicherheitsschlüssel hinzufügen';

  @override
  String get securityKeysUnsupported =>
      'Dieses Gerät kann keine Sicherheitsschlüssel registrieren. Öffnen Sie NeoRecall im Browser über HTTPS, um einen hinzuzufügen.';

  @override
  String get securityKeyFallbackName => 'Sicherheitsschlüssel';

  @override
  String get securityKeyNeverUsed => 'Nie verwendet';

  @override
  String securityKeyLastUsed(String date) {
    return 'Zuletzt verwendet am $date';
  }

  @override
  String get actionRename => 'Umbenennen';

  @override
  String get actionRemove => 'Entfernen';

  @override
  String get securityYourUsername => 'Ihr Benutzername';

  @override
  String get securityEraseTitle => 'Alles Aufgezeichnete löschen';

  @override
  String get securityEraseIntro =>
      'Damit wird Ihre Bibliothek geleert, Ihr Konto bleibt aber bestehen. Es gibt kein Rückgängig und keine Sicherung, aus der wiederhergestellt werden könnte.';

  @override
  String get securityEraseItem1 =>
      'Jede Aufnahme, jedes Transkript und jedes Gespräch';

  @override
  String get securityEraseItem2 =>
      'Alle Erinnerungen, Markierungen und Tageszusammenfassungen';

  @override
  String get securityEraseItem3 => 'Benannte Sprecher und ihre Stimmprofile';

  @override
  String get securityEraseItem4 =>
      'Importiertes Audio und alles, was noch auf den Upload wartet';

  @override
  String get securityKeptItem1 =>
      'Ihr Konto, Ihr Passwort und Ihre Sicherheitsschlüssel';

  @override
  String get securityKeptItem2 => 'Ihre Einstellungen und gekoppelten Geräte';

  @override
  String get securityEraseConfirm => 'Meine Daten löschen';

  @override
  String get securityErasedNotice => 'Alles Aufgezeichnete wurde gelöscht.';

  @override
  String get securityDeleteAccountTitle => 'Konto löschen';

  @override
  String get securityDeleteAccountIntro =>
      'Damit wird alles endgültig entfernt und das Konto geschlossen. Es gibt kein Rückgängig und keine Sicherung, aus der wiederhergestellt werden könnte.';

  @override
  String get securityDeleteItem1 =>
      'Jedes Transkript, jedes Gespräch und jede Erinnerung';

  @override
  String get securityDeleteItem2 =>
      'Aufnahmen, die auf diesem Gerät noch auf den Upload warten';

  @override
  String get securityDeleteItem3 =>
      'Verbundene Geräte, Sicherheitsschlüssel und Anmeldeverlauf';

  @override
  String get securityDeleteItem4 =>
      'Das Konto selbst und Ihre Möglichkeit, sich anzumelden';

  @override
  String get securityDeleteConfirm => 'Endgültig löschen';

  @override
  String get securityDeletedNotice =>
      'Ihr Konto und alle zugehörigen Daten wurden gelöscht.';

  @override
  String get securityDangerZone => 'GEFAHRENBEREICH';

  @override
  String get securityEraseCardDescription =>
      'Leert Ihre Bibliothek – Aufnahmen, Transkripte, Erinnerungen, Markierungen und Stimmprofile – und behält Konto, Einstellungen und gekoppelte Geräte. Das lässt sich nicht rückgängig machen.';

  @override
  String get securityEraseCardAction => 'Meine Daten löschen …';

  @override
  String get securityDeleteCardDescription =>
      'Entfernt alles oben Genannte und schließt das Konto selbst, einschließlich Anmeldung, Sicherheitsschlüsseln und verbundenen Geräten. Nichts, was Sie identifiziert, bleibt erhalten. Das lässt sich nicht rückgängig machen.';

  @override
  String get securityDeleteCardAction => 'Konto löschen …';

  @override
  String get securityNameKeyTitle => 'Diesen Schlüssel benennen';

  @override
  String get securityNameKeyMessage =>
      'Geben Sie dem Schlüssel einen Namen, den Sie wiedererkennen, zum Beispiel „YubiKey“.';

  @override
  String securityKeyDefaultName(int number) {
    return 'Sicherheitsschlüssel $number';
  }

  @override
  String get securityRenameKeyTitle => 'Sicherheitsschlüssel umbenennen';

  @override
  String securityRenameKeyMessage(String name) {
    return 'Geben Sie einen neuen Namen für „$name“ ein.';
  }

  @override
  String get securityEnterPassword => 'Passwort eingeben';

  @override
  String get securityPasswordForDisable =>
      'Zum Deaktivieren der 2FA ist Ihr aktuelles Passwort erforderlich';

  @override
  String get securityPasswordRequired =>
      'Ihr aktuelles Passwort ist erforderlich.';

  @override
  String get securityEnterTwoFactorCode => '2FA-Code eingeben';

  @override
  String get securityEnterAuthenticatorCode =>
      'Geben Sie Ihren aktuellen Authenticator-Code ein.';

  @override
  String get securityScanQr =>
      'Scannen Sie diesen QR-Code in Ihrer Authenticator-App.';

  @override
  String get securityAuthenticatorCodeLabel => 'Authenticator-Code';

  @override
  String get actionVerify => 'Bestätigen';

  @override
  String get securityRecoveryCodesTitle => 'Wiederherstellungscodes';

  @override
  String get securityRecoveryCodesBody =>
      'Bewahren Sie diese Codes sicher auf. Sie werden nur einmal angezeigt.';

  @override
  String get destructiveYourPassword => 'Ihr Passwort';

  @override
  String get destructiveCodeHelper =>
      'Ein aktueller Code oder einer Ihrer Wiederherstellungscodes.';

  @override
  String destructiveTypeToConfirm(String username) {
    return 'Geben Sie zur Bestätigung $username ein';
  }

  @override
  String get integrationsMcpEyebrow => 'MCP';

  @override
  String get integrationsMcpTitle => 'Claude, ChatGPT oder Cursor verbinden';

  @override
  String get integrationsMcpDescription =>
      'Fügen Sie diese MCP-Adresse in Claude, ChatGPT (MCP) oder Cursor ein. Der Client öffnet NeoRecall zur Anmeldung und fragt dieselbe schreibgeschützte Zustimmung ab wie NeoAgent. Fragen, Aufnahme und Änderungen an Erinnerungen bleiben in NeoRecall.';

  @override
  String get integrationsMcpCopied => 'MCP-Adresse kopiert';

  @override
  String get integrationsMcpCopy => 'MCP-Adresse kopieren';

  @override
  String get integrationsConnectedEyebrow => 'VERBUNDENE APPS';

  @override
  String get integrationsNoneConnected =>
      'Es sind noch keine Apps verbunden. Sobald Sie NeoAgent oder einen MCP-Client autorisieren, erscheint er hier und kann widerrufen werden.';

  @override
  String get integrationsConnectedApp => 'Verbundene App';

  @override
  String get integrationsRevoke => 'Widerrufen';

  @override
  String get integrationsClientNeoAgent => 'NeoAgent';

  @override
  String get integrationsClientMcp => 'MCP-Client';

  @override
  String get integrationsClientOAuth => 'OAuth-Client';

  @override
  String get integrationsThisApp => 'diese App';

  @override
  String get integrationsRevokeTitle => 'Zugriff widerrufen?';

  @override
  String integrationsRevokeBody(String name) {
    return '$name verliert den schreibgeschützten Zugriff auf dieses Konto, bis Sie die App erneut verbinden.';
  }

  @override
  String get memoriesSearchHint => 'Erinnerungen durchsuchen …';

  @override
  String get memoriesFilterAll => 'Alle';

  @override
  String get memoriesFilterPinned => 'Angeheftet';

  @override
  String get memoriesFilterThisWeek => 'Diese Woche';

  @override
  String get memoriesFilterMeetings => 'Besprechungen';

  @override
  String get memoriesFilterDecisions => 'Entscheidungen';

  @override
  String get memoriesFilterOpenTasks => 'Offene Aufgaben';

  @override
  String memoriesFilterOpenTasksCount(int count) {
    return 'Offene Aufgaben ($count)';
  }

  @override
  String get memoriesFilterArchived => 'Archiviert';

  @override
  String get memoriesSelectPrompt => 'Erinnerungen auswählen';

  @override
  String memoriesSelectedCount(int count) {
    return '$count ausgewählt';
  }

  @override
  String get memoriesMergeTooltip => 'Zusammenführen';

  @override
  String get memoriesPin => 'Anheften';

  @override
  String get memoriesUnpin => 'Lösen';

  @override
  String get memoriesTodaysStory => 'Die Geschichte des Tages';

  @override
  String get memoriesAllHighlights => 'Alle Markierungen';

  @override
  String memoriesDue(String date) {
    return 'Fällig $date';
  }

  @override
  String get memoriesReopen => 'Wieder öffnen';

  @override
  String get memoriesMarkDone => 'Als erledigt markieren';

  @override
  String get memoryContextDialogTitle => 'Kontext zur Erinnerung hinzufügen';

  @override
  String get memoryContextDialogHint =>
      'Ergänzen Sie Angaben, die diese Erinnerung verbessern sollen …';

  @override
  String get memoryContextDialogConfirm => 'Hinzufügen und aktualisieren';

  @override
  String get memoryDeleteTitle => 'Erinnerung löschen?';

  @override
  String get memoryDeleteBody =>
      'Damit werden die Erinnerung und ihre Markierungen entfernt. Transkripte bleiben auf der Zeitachse verfügbar.';

  @override
  String memoryLoadFailed(String error) {
    return 'Details konnten nicht geladen werden.\n$error';
  }

  @override
  String get memoryPeopleAndThings => 'Personen und Dinge';

  @override
  String get memoryEntityUnknown => 'Unbekannt';

  @override
  String get memoryContextHeading => 'Kontext';

  @override
  String get memoryNoContext =>
      'An dieser Erinnerung hängen keine Notizen oder Dateien.';

  @override
  String get memoryContextUsedByAi => 'Von der KI verwendet';

  @override
  String get memoryContextReadyForAi => 'Bereit für die KI';

  @override
  String get memoryContextRetry => 'Analyse erneut versuchen';

  @override
  String get memoryContextRemove => 'Kontext entfernen';

  @override
  String get memoryFromConversation => 'Aus dem Gespräch';

  @override
  String miniLoadFailed(String error) {
    return 'Markierung konnte nicht geladen werden.\n$error';
  }

  @override
  String miniFromMemory(String emoji, String title) {
    return 'Aus $emoji $title';
  }

  @override
  String get miniEvidence => 'Belege';

  @override
  String get miniNoExcerpts => 'Keine Transkriptauszüge verknüpft.';

  @override
  String get processingEtaUnderMinute => 'unter einer Minute';

  @override
  String processingEtaMinutes(int minutes) {
    return 'etwa $minutes Min.';
  }

  @override
  String processingEtaHours(int hours) {
    return 'etwa $hours Std.';
  }

  @override
  String processingEtaHoursMinutes(int hours, int minutes) {
    return 'etwa $hours Std. $minutes Min.';
  }

  @override
  String get processingNeedsAttention =>
      'Die Verarbeitung braucht Aufmerksamkeit';

  @override
  String get processingStageWatchTransfer => 'Wird vom Gerät heruntergeladen';

  @override
  String get processingStagePhoneQueue =>
      'Sicher auf diesem Gerät zwischengespeichert';

  @override
  String get processingStageUpload => 'Wird auf den Server geladen';

  @override
  String get processingStageServerQueue =>
      'Wartet in der Transkriptionswarteschlange';

  @override
  String get processingStageTranscription =>
      'Wird auf dem Server transkribiert';

  @override
  String get processingStageFinalizing =>
      'Sichere Quittungen werden abgeschlossen';

  @override
  String get processingStageComplete => 'Alles ist verarbeitet';

  @override
  String processingWatchAudioWaiting(String duration) {
    return '$duration Audio wartet';
  }

  @override
  String get processingWatchReceiving => 'Verschlüsseltes Audio wird empfangen';

  @override
  String processingWatchItemsWaiting(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Einträge warten',
      one: '1 Eintrag wartet',
    );
    return '$_temp0';
  }

  @override
  String get processingWatchNoBacklog => 'Kein Rückstand auf dem Gerät';

  @override
  String get processingStepDeviceTransfer => 'Geräteübertragung';

  @override
  String get processingStepStoredOnPhone => 'Auf dem Telefon gespeichert';

  @override
  String get processingNoLocalQueue => 'Keine Aufnahmen warten lokal';

  @override
  String processingReadyForUpload(int count) {
    return '$count bereit zum Hochladen';
  }

  @override
  String get processingStepServerUpload => 'Upload zum Server';

  @override
  String get processingNoUploadInFlight => 'Derzeit läuft kein Upload';

  @override
  String processingUploadingNow(int count) {
    return '$count werden gerade hochgeladen';
  }

  @override
  String get processingStepServerTranscription =>
      'Transkription auf dem Server';

  @override
  String processingTranscribingQueued(int transcribing, int queued) {
    return '$transcribing in Transkription · $queued in Warteschlange';
  }

  @override
  String processingWaitingForWorker(int count) {
    return '$count warten auf einen Verarbeiter';
  }

  @override
  String get processingServerQueueClear => 'Die Serverwarteschlange ist leer';

  @override
  String get processingStepSafeCompletion => 'Sicherer Abschluss';

  @override
  String get processingTranscriptPersisted =>
      'Transkript gespeichert; Audio freigegeben';

  @override
  String processingVerifying(int count) {
    return '$count prüfen Speicherung und Löschung';
  }

  @override
  String get processingWaitingEarlierStages => 'Wartet auf frühere Schritte';

  @override
  String processingPendingCount(int count) {
    return '$count ausstehend';
  }

  @override
  String processingMbProtected(String size) {
    return '$size MB geschützt';
  }

  @override
  String processingEtaPrefix(String eta) {
    return 'Voraussichtlich $eta';
  }

  @override
  String get processingEtaCalibrating => 'Restzeit wird ermittelt';

  @override
  String get processingUploadOnMobileData =>
      'Einmalig über Mobilfunk hochladen';

  @override
  String get processingReviewQueued => 'Wartendes Audio prüfen';

  @override
  String get processingRetryFailed => 'Fehlgeschlagene erneut versuchen';

  @override
  String get processingSomethingNeedsAttention =>
      'Etwas braucht Aufmerksamkeit';

  @override
  String get processingStillWorking => 'Wird noch bearbeitet';

  @override
  String processingDeviceHolding(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Ihr Gerät hält noch $count Aufnahmen, es ist also nichts verloren.',
      one: 'Ihr Gerät hält noch 1 Aufnahme, es ist also nichts verloren.',
    );
    return '$_temp0';
  }

  @override
  String get processingUnderMinuteLeft => 'weniger als eine Minute';

  @override
  String get processingGettingAudio => 'Audio wird von Ihrem Gerät geholt';

  @override
  String processingUploadingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Aufnahmen werden hochgeladen',
      one: 'Eine Aufnahme wird hochgeladen',
    );
    return '$_temp0';
  }

  @override
  String processingTranscribingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Aufnahmen werden transkribiert',
      one: 'Eine Aufnahme wird transkribiert',
    );
    return '$_temp0';
  }

  @override
  String processingEtaMinutesLeft(int minutes) {
    return 'noch etwa $minutes Min.';
  }

  @override
  String processingEtaHoursLeft(int hours) {
    return 'noch etwa $hours Std.';
  }

  @override
  String processingEtaHoursMinutesLeft(int hours, int minutes) {
    return 'noch etwa $hours Std. $minutes Min.';
  }

  @override
  String get deviceAddDevice => 'Gerät hinzufügen';

  @override
  String get deviceConnected => 'Verbunden';

  @override
  String get deviceNotConnected => 'Nicht verbunden';

  @override
  String get deviceAddDeviceSemantics => 'Ein Gerät hinzufügen';

  @override
  String deviceManageSemantics(String label) {
    return '$label verwalten';
  }

  @override
  String get deviceNoneTitle => 'Noch kein Gerät';

  @override
  String get deviceNoneBody =>
      'NeoRecall nimmt mit dem Telefonmikrofon auf, bis Sie ein Wearable verbinden oder einen Desk einrichten.';

  @override
  String get deviceScanning => 'Suche läuft …';

  @override
  String get deviceScanForWearables => 'Nach Wearables suchen';

  @override
  String get deviceSetUpDesk => 'Einen NeoRecall Desk einrichten';

  @override
  String get deviceRemembered => 'Gemerkt – derzeit nicht verbunden';

  @override
  String get deviceStatBattery => 'Akku';

  @override
  String get deviceStatSynced => 'Synchronisiert';

  @override
  String get deviceStatSyncedUnit => 'Aufnahmen';

  @override
  String get deviceStatLeft => 'Verbleibend';

  @override
  String get deviceStatQueued => 'in Warteschlange';

  @override
  String get deviceOfflineFirstStreams =>
      'Dieses Gerät kann auch eigenständig aufnehmen. Was es in Ihrer Abwesenheit aufgezeichnet hat, wird beim Verbinden hierher übertragen – oder Sie holen es jetzt.';

  @override
  String get deviceOfflineFirstOnly =>
      'Dieses Gerät nimmt eigenständig auf – Start und Stopp erfolgen am Gerät selbst. Die Aufnahmen werden beim Verbinden hierher übertragen, oder Sie holen sie jetzt.';

  @override
  String get deviceStranded =>
      'Das Gerät hat Aufnahmen, aber kein WLAN. Sie können über Bluetooth auf dieses Telefon übertragen und später von hier hochgeladen werden.';

  @override
  String get deviceMovingRecordings => 'Aufnahmen werden übertragen …';

  @override
  String get deviceMoveRecordings => 'Aufnahmen auf dieses Telefon übertragen';

  @override
  String get deviceScanAnother => 'Nach einem weiteren Wearable suchen';

  @override
  String get deviceDiagnostics => 'Geräte- und Synchronisierungsdiagnose';

  @override
  String get deviceForget => 'Dieses Gerät vergessen';

  @override
  String get sourceRecordFrom => 'Aufnehmen von';

  @override
  String get sourceLockedWhileRecording =>
      'Die Quelle ist während einer laufenden Aufnahme gesperrt.';

  @override
  String get sourceOneAtATime =>
      'Es nimmt immer nur eine Quelle auf. Die Auswahl bleibt bestehen, bis Sie sie ändern.';

  @override
  String get sourceThisComputer => 'Dieser Computer';

  @override
  String get sourcePhoneSubtitle => 'Immer verfügbar, nichts zu verbinden';

  @override
  String get sourceComputerSubtitle => 'Mikrofon und auf Wunsch auch Systemton';

  @override
  String get sourceDeviceAudioDesktop =>
      'Geräteton – alles, was dieser Rechner wiedergibt';

  @override
  String get sourceTabOrSystemAudio => 'Tab- oder Systemton';

  @override
  String get sourceNoWearable => 'Noch kein Wearable verbunden';

  @override
  String sourceConnectedWithBattery(Object battery) {
    return 'Verbunden · $battery %';
  }

  @override
  String get sourceScan => 'Suchen';

  @override
  String get sourceDeskNotSetUp => 'Nicht eingerichtet';

  @override
  String get sourceSetUp => 'Einrichten';

  @override
  String get sourceDeskSubtitle => 'Nimmt den Raum eigenständig auf';

  @override
  String get sourceFoundNearby => 'In der Nähe gefunden';

  @override
  String sourceReadyForAudio(String type) {
    return '$type · bereit für Audio';
  }

  @override
  String get sourceWearableFallback => 'Wearable';

  @override
  String get sourceReconnect => 'Erneut verbinden';

  @override
  String get sourceConnect => 'Verbinden';

  @override
  String get sourceImportAudio => 'Audiodatei importieren';

  @override
  String get sourceConsentNote =>
      'Für die Aufnahme privat gesprochener Worte kann die Zustimmung aller Beteiligten erforderlich sein. NeoRecall verbirgt nie, dass aufgezeichnet wird.';

  @override
  String get sourceWebBluetoothNote =>
      'Der Browser öffnet seine eigene Bluetooth-Auswahl, und die Aufnahme läuft nur, solange dieser Tab aktiv bleibt.';

  @override
  String get libraryTitle => 'Bibliothek';

  @override
  String get floatingConsentTitle => 'Bevor Sie aufnehmen';

  @override
  String get floatingOpenLibrary => 'Bibliothek öffnen';

  @override
  String get floatingHide => 'Ausblenden';

  @override
  String get devicesEmptyTitle => 'Noch keine Geräte';

  @override
  String get devicesEmptyMessage =>
      'Apps erscheinen hier nach ihrer ersten Aufnahme. Ein NeoRecall Desk erscheint, sobald Sie ihn eingerichtet haben.';

  @override
  String get devicesAddDesk => 'Einen NeoRecall Desk hinzufügen';

  @override
  String get devicesRevoked => 'WIDERRUFEN';

  @override
  String get devicesNotRecentlyConnected => 'zuletzt länger nicht verbunden';

  @override
  String get devicesClockOffset =>
      'Die Geräteuhr weicht um mehr als zwei Minuten ab';

  @override
  String get devicesRevokeTooltip => 'Gerät widerrufen';

  @override
  String get pendingAudioTitle => 'Wartendes Audio prüfen';

  @override
  String get pendingAudioSubtitle =>
      'Nur lokale Wiedergabe · der Upload läuft normal weiter';

  @override
  String get actionClose => 'Schließen';

  @override
  String get audioHeadphonesWarning =>
      'Die Aufnahme läuft. Verwenden Sie Kopfhörer, damit die Wiedergabe nicht erneut aufgezeichnet wird.';

  @override
  String get actionRefresh => 'Aktualisieren';

  @override
  String get pendingAudioEmpty =>
      'Derzeit ist kein aufbewahrtes Audio zum Prüfen verfügbar.';

  @override
  String get actionPause => 'Pause';

  @override
  String get actionPlay => 'Abspielen';

  @override
  String get diagnosticsCopied => 'Diagnosebericht kopiert.';

  @override
  String get diagnosticsCleared => 'Diagnoseprotokoll geleert.';

  @override
  String get diagnosticsTitle => 'Geräte- und Synchronisierungsdiagnose';

  @override
  String get diagnosticsDescription =>
      'Bluetooth-Suche und -Verbindung, Gerätesynchronisierung und Importereignisse für dieses Konto. Passwörter, Token, Audio, Transkripte und andere Konten sind nie enthalten.';

  @override
  String get diagnosticsPreparing => 'Wird vorbereitet …';

  @override
  String get diagnosticsCopyReport => 'Vollständigen Bericht kopieren';

  @override
  String get diagnosticsClearLog => 'Protokoll leeren';

  @override
  String get diagnosticsEmpty =>
      'Noch keine Diagnoseereignisse. Verbinden und synchronisieren Sie ein Gerät, um dieses Protokoll zu füllen, und aktualisieren Sie dann.';

  @override
  String get trayQuickCapture => 'Schnellaufnahme';

  @override
  String get trayOpenLibrary => 'Notizbibliothek öffnen';

  @override
  String get trayStopRecording => 'Aufnahme beenden';

  @override
  String get trayQuit => 'Beenden';

  @override
  String get audioBack10 => '10 Sekunden zurück';

  @override
  String get audioForward10 => '10 Sekunden vor';

  @override
  String get importChooseAudio => 'Audio auswählen';

  @override
  String get importTitle => 'Vorhandenes Audio importieren';

  @override
  String get importDescription =>
      'WAV, MP3, M4A und andere von ffmpeg unterstützte Formate durchlaufen dieselbe private Transkriptionsstrecke.';

  @override
  String syncTransferringProgress(int percent, String remaining) {
    return 'Übertragung $percent % · noch $remaining';
  }

  @override
  String get syncTransferring => 'Übertragung vom Gerät …';

  @override
  String syncWaitingOnDevice(String duration) {
    return '$duration warten auf dem Gerät';
  }

  @override
  String syncSyncedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Aufnahmen synchronisiert',
      one: '1 Aufnahme synchronisiert',
    );
    return '$_temp0';
  }

  @override
  String get floatingConsentBody =>
      'Sagen Sie allen Beteiligten, dass NeoRecall aufzeichnet, und vergewissern Sie sich, dass Sie das Gespräch aufnehmen dürfen. Eine Aufnahme ist immer sichtbar gekennzeichnet.';

  @override
  String sourcesLoadFailed(String error) {
    return 'Quellen konnten nicht geladen werden: $error';
  }

  @override
  String sourcesUpdateFailed(String error) {
    return 'Aktualisierung fehlgeschlagen: $error';
  }

  @override
  String get sourcesDisconnect => 'Trennen';

  @override
  String get sourcesDisconnectBody =>
      'Diese Quelle beenden? Vorhandene Transkripte bleiben in NeoRecall erhalten.';

  @override
  String sourcesDisconnectFailed(String error) {
    return 'Trennen fehlgeschlagen: $error';
  }

  @override
  String get sourcesDescription =>
      'Dienste, die NeoRecall mit Audio versorgen können. Wearables und ein NeoRecall Desk werden unter „Aufnahme“ eingerichtet.';

  @override
  String get sourcesLiveCapture => 'Live-Aufnahme';

  @override
  String get sourcesEmptyTitle => 'Noch nichts zum Verbinden';

  @override
  String get sourcesEmptyMessage =>
      'Live-Quellen erscheinen hier, sobald sie für Ihr Konto verfügbar sind.';

  @override
  String sourcesLastSynced(String when) {
    return 'Zuletzt synchronisiert $when';
  }

  @override
  String get sourcesHowItWorks => 'So funktioniert es';

  @override
  String get sourcesOauthNote =>
      'NeoRecall importiert Cloud-Aufnahmen, nachdem die Plattform sie fertiggestellt hat – es nimmt nicht am laufenden Gespräch teil.';

  @override
  String get sourcesJustNow => 'gerade eben';

  @override
  String sourcesMinutesAgo(int minutes) {
    return 'vor $minutes Min.';
  }

  @override
  String sourcesHoursAgo(int hours) {
    return 'vor $hours Std.';
  }

  @override
  String get sourcesSyncNow => 'Jetzt synchronisieren';

  @override
  String get sourceStatusConnected => 'Verbunden';

  @override
  String get sourceStatusError => 'Fehler';

  @override
  String get sourceStatusNotConfigured => 'Nicht eingerichtet';

  @override
  String get sourceStatusPaused => 'Pausiert';

  @override
  String get discordDefaultName => 'Mein Discord-Bot';

  @override
  String discordError(String error) {
    return 'Fehler: $error';
  }

  @override
  String get discordTitle => 'Discord verbinden';

  @override
  String get discordDescription =>
      'NeoRecall tritt Sprachkanälen als Bot bei und nimmt die von Ihnen genannten Personen auf. Erstellen Sie einen Bot im Discord-Entwicklerportal, laden Sie ihn auf Ihren Server ein und fügen Sie hier sein Token ein.';

  @override
  String get discordUsersLabel => 'Aufzunehmende Personen';

  @override
  String get discordUsersHelper =>
      'Discord-Benutzernamen, durch Kommas getrennt';

  @override
  String get discordTokenLabel => 'Bot-Token';

  @override
  String get discordTokenHelper =>
      'Wird ausschließlich auf Ihrem NeoRecall-Server gespeichert';

  @override
  String get discordHowTo => 'So erstellen Sie den Bot';

  @override
  String get discordIntentsNote =>
      'Es sind keine privilegierten Intents erforderlich. Der Bot hört nur zu – er spricht nie.';

  @override
  String get discordConnect => 'Konto verbinden';

  @override
  String get discordSteps =>
      '1. Öffnen Sie das Discord-Entwicklerportal und erstellen Sie eine Anwendung.\n2. Öffnen Sie den Reiter „Bot“, dann „Reset Token“, und kopieren Sie das Token in das Feld oben.\n3. Setzen Sie unter „OAuth2 → URL Generator“ den Scope „bot“ sowie die Berechtigungen „View Channels“, „Connect“ und „Speak“.\n4. Öffnen Sie die erzeugte URL und laden Sie den Bot auf Ihren Server ein.\n\nEs sind keine privilegierten Intents erforderlich. Der Bot hört nur zu – er spricht nie.';

  @override
  String get apiRequestTimeout =>
      'Der Server hat nicht rechtzeitig geantwortet. Prüfen Sie, ob er läuft und erreichbar ist, und versuchen Sie es erneut.';

  @override
  String get apiServerUnreachable =>
      'NeoRecall konnte den Server nicht erreichen. Prüfen Sie, ob er online ist und dieses Gerät ihn erreichen kann.';

  @override
  String apiInvalidResponse(int status) {
    return 'Der Server hat eine Antwort geliefert, die NeoRecall nicht lesen konnte (HTTP $status).';
  }

  @override
  String apiServerUnavailable(int status) {
    return 'Der NeoRecall-Server ist nicht verfügbar (HTTP $status). Versuchen Sie es gleich noch einmal oder prüfen Sie den Server.';
  }

  @override
  String apiRequestRejected(int status) {
    return 'Der NeoRecall-Server hat die Anfrage abgelehnt (HTTP $status).';
  }

  @override
  String get apiUploadInterrupted =>
      'Die Verbindung wurde beim Hochladen unterbrochen. Es wird automatisch erneut versucht.';

  @override
  String get apiContextUploadInterrupted =>
      'Der Kontext-Upload wurde unterbrochen. Er bleibt lokal gespeichert, und es wird erneut versucht.';

  @override
  String get apiImportInterrupted =>
      'Die Verbindung wurde beim Hochladen unterbrochen. Versuchen Sie den Import erneut.';

  @override
  String get controllerSecurityKeyAdded => 'Sicherheitsschlüssel hinzugefügt.';

  @override
  String get controllerWrongPassword => 'Dieses Passwort ist nicht korrekt.';

  @override
  String get controllerInvalidTwoFactor =>
      'Dieser Authentifizierungscode ist ungültig. Codes laufen schnell ab – verwenden Sie den aktuellen.';

  @override
  String get controllerTwoFactorRequired =>
      'Für dieses Konto ist zur Bestätigung ein Authenticator-Code erforderlich.';

  @override
  String controllerDeleteFailed(String error) {
    return 'Das Konto konnte nicht gelöscht werden: $error';
  }

  @override
  String controllerNoNewRecordings(String device) {
    return 'Auf $device gibt es keine neuen Aufnahmen zum Synchronisieren.';
  }

  @override
  String controllerSyncFailed(String device, String message) {
    return 'Die Synchronisierung von $device ist fehlgeschlagen: $message';
  }

  @override
  String get controllerIncompleteUrl =>
      'Geben Sie eine vollständige Server-Adresse einschließlich http:// oder https:// ein.';

  @override
  String get controllerWidgetStopped =>
      'Aufnahme über das Startbildschirm-Widget beendet.';

  @override
  String get controllerWidgetSignIn =>
      'Melden Sie sich an, um Markierungen vom Startbildschirm aus abzuschließen.';

  @override
  String get controllerWidgetStarted =>
      'Telefonaufnahme über das Startbildschirm-Widget gestartet.';

  @override
  String controllerWidgetStartFailed(String error) {
    return 'Das Startbildschirm-Widget konnte die Aufnahme nicht starten: $error';
  }

  @override
  String get controllerScheduleWaiting =>
      'Die Aufnahme wartet auf das nächste eingestellte Tagesfenster.';

  @override
  String controllerRecoveryWaiting(String error) {
    return 'Die Wiederherstellung der Hintergrundaufnahme wartet: $error';
  }

  @override
  String controllerSourceRecoveryFailed(String error) {
    return 'Die Wiederherstellung der Audioquelle ist fehlgeschlagen: $error';
  }

  @override
  String get controllerCaptureRecovered =>
      'Die Audioaufnahme wurde nach einer Unterbrechung wiederhergestellt.';

  @override
  String get controllerTimelineLoadFailed =>
      'Dieser Teil der Zeitachse konnte gerade nicht geladen werden.';

  @override
  String get controllerMomentLoadFailed =>
      'Der Rest dieses Moments konnte gerade nicht geladen werden.';

  @override
  String get controllerRewriteQueued =>
      'Dieser Moment wird erneut ausgearbeitet. Er wird hier aktualisiert, sobald er fertig ist.';

  @override
  String get controllerImportQueued =>
      'Import hochgeladen. Die lokale Transkription wurde eingereiht.';

  @override
  String get controllerNoteEmpty =>
      'Schreiben Sie eine Notiz, bevor Sie sie speichern.';

  @override
  String controllerNoteTooLong(int maximum) {
    return 'Notizen dürfen höchstens $maximum Zeichen enthalten.';
  }

  @override
  String get controllerFileTooLarge =>
      'Diese Datei überschreitet das Serverlimit.';

  @override
  String get controllerContextWhileRecording =>
      'Kontext kann nur während einer laufenden Aufnahme hinzugefügt werden.';

  @override
  String get controllerContextStorageUnavailable =>
      'Der Speicher für den Aufnahmekontext ist nicht verfügbar.';

  @override
  String get controllerContextIntegrity =>
      'Die lokal gespeicherte Kontextdatei hat die Integritätsprüfung nicht bestanden.';

  @override
  String get controllerMergeTooFew =>
      'Wählen Sie mindestens zwei Erinnerungen zum Zusammenführen aus.';

  @override
  String controllerMergeTooMany(int maximum) {
    return 'Wählen Sie höchstens $maximum Erinnerungen zum Zusammenführen aus.';
  }

  @override
  String get controllerStorageFull => 'Speicher voll – Aufnahme beendet';

  @override
  String liveEtaLeft(String duration) {
    return 'noch etwa $duration';
  }

  @override
  String get liveStorageFullDetail =>
      'Geben Sie Gerätespeicher frei und öffnen Sie NeoRecall erneut, um sicher fortzufahren.';

  @override
  String get liveStorageFullIssue =>
      'Es ist kein lokaler Speicher mehr für einen weiteren dauerhaften Audioblock vorhanden.';

  @override
  String get liveSourceBluetooth => 'Bluetooth-Gerät';

  @override
  String liveRecordingFrom(String source) {
    return 'Aufnahme von $source';
  }

  @override
  String get liveRecordingUploading =>
      'Sichere Aufnahme · Upload im Hintergrund';

  @override
  String get liveRecordingSafely => 'Sichere Aufnahme auf diesem Gerät';

  @override
  String get liveWatchTransferDetail =>
      'Audio wird in den geschützten Telefonspeicher übertragen';

  @override
  String get liveUploadingTitle => 'Aufnahmen werden hochgeladen';

  @override
  String get liveUploadingDetail =>
      'Die lokalen Originale bleiben geschützt, bis die Verarbeitung bestätigt ist';

  @override
  String get liveTranscribingDetail =>
      'Das Audio bleibt sicher gespeichert, während das Transkript entsteht';

  @override
  String get liveFinalizingTitle => 'Transkript wird abgeschlossen';

  @override
  String get liveFinalizingDetail =>
      'Wartet auf die bestätigte Speicherung und das Löschen des Serveraudios';

  @override
  String get liveQueuedTitle => 'Aufnahmen sicher eingereiht';

  @override
  String get liveQueuedDetail => 'Wartet auf den nächsten Verarbeitungsschritt';

  @override
  String get liveIdleTitle => 'NeoRecall ist bereit';

  @override
  String get liveIdleDetail =>
      'Es läuft weder eine Aufnahme noch eine Verarbeitung';

  @override
  String liveBytesQueued(String size) {
    return '$size in Warteschlange';
  }

  @override
  String get widgetIdleTitle => 'Aufnahmebereit';

  @override
  String get widgetIdleDetail =>
      'Es wird nichts aufgenommen und nichts wartet.';

  @override
  String get statusManualRetry =>
      'Eine Aufnahme muss manuell erneut hochgeladen werden.';

  @override
  String get statusUploadFailed =>
      'Der Upload einer Aufnahme ist fehlgeschlagen und wird automatisch wiederholt.';

  @override
  String get statusOffline =>
      'Offline – das Audio bleibt sicher auf diesem Gerät gespeichert.';

  @override
  String get statusWaitingForWifi =>
      'Wartet auf WLAN, da Uploads über Mobilfunk deaktiviert sind.';

  @override
  String get watchDigestSent => 'Der heutige Tag wurde an die Uhr gesendet.';

  @override
  String get watchCheckAgain => 'Erneut prüfen';

  @override
  String get watchTitle => 'Vom Handgelenk aus aufnehmen';

  @override
  String get watchDescription =>
      'Die Uhr nimmt eigenständig auf und behält jeden Mitschnitt, bis dieses Telefon bestätigt, dass er transkribiert und die Serverkopie gelöscht wurde. Das heutige Transkript, die Erinnerungen und die Zusagen werden an die Uhr zurückgesendet, damit sie ohne Telefon gelesen werden können.';

  @override
  String get watchLooking => 'Es wird nach gekoppelten Uhren gesucht …';

  @override
  String get watchSending => 'Wird gesendet …';

  @override
  String get watchSendToday => 'Heutigen Tag jetzt senden';

  @override
  String get watchNotInstalled => 'NeoRecall ist nicht installiert';

  @override
  String get watchOutOfRange => 'Installiert · außer Reichweite';

  @override
  String get watchConnected => 'Installiert · verbunden';

  @override
  String get watchReady => 'BEREIT';

  @override
  String get watchSetUp => 'EINRICHTEN';

  @override
  String get watchNonePaired =>
      'Es wurde keine gekoppelte Uhr gefunden. Koppeln Sie die Uhr zuerst in der Wear-OS-App mit diesem Telefon – NeoRecall sieht nur Uhren, die Android bereits gekoppelt hat.';

  @override
  String get watchInstallEyebrow => 'Installation auf der Uhr';

  @override
  String get watchInstallIntro =>
      'NeoRecall für Wear OS wird als eigenes APK ausgeliefert, mit demselben Schlüssel wie diese App signiert, und einmalig manuell installiert. Es ist nicht im Play Store, daher müssen für die Installation die Entwickleroptionen der Uhr eingeschaltet sein – danach nicht mehr.';

  @override
  String get watchStep1Title => 'Das APK für die Uhr herunterladen';

  @override
  String get watchStep1Detail =>
      'Laden Sie NeoRecall-WearOS-<Version>.apk aus der neuesten Version auf einen Computer, der im selben Netzwerk wie die Uhr ist.';

  @override
  String get watchReleasesLabel => 'Versionen';

  @override
  String get watchStep2Title => 'Drahtloses Debugging auf der Uhr einschalten';

  @override
  String get watchStep2Detail =>
      'Einstellungen → System → Über → siebenmal auf die Build-Nummer tippen, dann Einstellungen → Entwickleroptionen → ADB-Debugging und drahtloses Debugging. Dort zeigt die Uhr ihre IP-Adresse an.';

  @override
  String get watchStep3Title => 'Über WLAN installieren';

  @override
  String get watchStep3Detail =>
      'Vom Computer mit dem APK aus, mit der IP der Uhr aus dem vorherigen Schritt:';

  @override
  String get watchConnectLabel => 'Verbinden';

  @override
  String get watchInstallLabel => 'Installieren';

  @override
  String get watchStep4Title => 'Einmal auf der Uhr öffnen';

  @override
  String get watchStep4Detail =>
      'Erlauben Sie das Mikrofon, dann wechselt diese Seite auf „Installiert“. Die NeoRecall-Kacheln fügen Sie durch langes Drücken auf das Zifferblatt hinzu, die Komplikationen über den Zifferblatt-Editor.';

  @override
  String get watchInstallFootnote =>
      'Die Entwickleroptionen können danach wieder ausgeschaltet werden – die App bleibt installiert und funktioniert weiter.';

  @override
  String get providerContinue => 'Weiter';

  @override
  String providerChoose(String workload) {
    return 'Wählen Sie einen Anbieter für $workload.';
  }

  @override
  String providerNeedsBaseUrl(String provider) {
    return '$provider benötigt eine Basis-URL.';
  }

  @override
  String get providerSaved =>
      'Gespeichert. Der Server verwendet ab jetzt diese Dienste.';

  @override
  String get providerLoadFailed =>
      'Die Anbietereinstellungen konnten nicht geladen werden.';

  @override
  String get providerTryAgain => 'Erneut versuchen';

  @override
  String get providerIntro =>
      'NeoRecall erkennt Sprache und ordnet Sprecher selbst zu, doch die Wörter und die geschriebenen Erinnerungen stammen von Diensten, die Sie auswählen.';

  @override
  String get providerTesting => 'Wird getestet …';

  @override
  String get providerSaving => 'Wird gespeichert …';

  @override
  String get providerSaveAndTest => 'Speichern und testen';

  @override
  String get providerSaveOnly => 'Nur speichern';

  @override
  String get providerSetUpLater => 'Später einrichten';

  @override
  String get providerKeyStored => 'Schlüssel gespeichert';

  @override
  String get providerServiceLabel => 'Dienst';

  @override
  String get providerBaseUrlLabel => 'Basis-URL';

  @override
  String get providerApiKeyStoredLabel =>
      'API-Schlüssel (leer lassen, um den gespeicherten zu behalten)';

  @override
  String get providerApiKeyLabel => 'API-Schlüssel';

  @override
  String get providerModelOptionalLabel => 'Modell (optional)';

  @override
  String get providerModelLabel => 'Modell';

  @override
  String get providerFindModels => 'Modelle suchen';

  @override
  String get providerLegTranscription => 'Transkription';

  @override
  String get providerLegSpeakerIdentity => 'Sprechererkennung';

  @override
  String get providerLegMemoryWriting => 'Erinnerungserstellung';

  @override
  String get providerTranscriptionSubtitle =>
      'Wandelt aufgenommene Sprache in Text um. Die Sprechererkennung bleibt auf diesem Rechner.';

  @override
  String get providerMemorySubtitle =>
      'Schreibt Titel, Zusammenfassungen und Erinnerungen aus dem Transkript.';

  @override
  String installFailed(String error) {
    return 'Die Einrichtung von NeoRecall konnte nicht abgeschlossen werden: $error';
  }

  @override
  String get installFailedShort =>
      'Die Einrichtung von NeoRecall konnte nicht abgeschlossen werden.';

  @override
  String get actionBack => 'Zurück';

  @override
  String get installEyebrow => 'LOKALE EINRICHTUNG';

  @override
  String get installIntro =>
      'NeoRecall wird von GitHub heruntergeladen, als Hintergrunddienst installiert und mit dieser App verbunden. Zwischen beiden Kanälen kann später gewechselt werden.';

  @override
  String get installChannelStable => 'Stabil';

  @override
  String get installChannelStableDescription =>
      'Nur veröffentlichte Versionen. Für den täglichen Gebrauch empfohlen.';

  @override
  String get installChannelRecommended => 'Empfohlen';

  @override
  String get installChannelBeta => 'Beta';

  @override
  String get installChannelBetaDescription =>
      'Neue Funktionen zuerst – mit den Ecken und Kanten, die dazugehören.';

  @override
  String get installDirectoryLabel => 'Installationsverzeichnis';

  @override
  String installMissingRequirements(String items) {
    return 'Installieren Sie zuerst $items auf diesem Computer und prüfen Sie dann erneut.';
  }

  @override
  String get installCheckAgain => 'Erneut prüfen';

  @override
  String installStart(String channel) {
    return 'Kanal „$channel“ installieren';
  }

  @override
  String get installPreparing => 'NeoRecall wird vorbereitet …';

  @override
  String get installModelsNote =>
      'Bei der ersten Installation werden rund 165 MB an lokalen Modellen geladen; das kann einige Minuten dauern.';

  @override
  String get installDetails => 'Details zur Einrichtung';

  @override
  String installRunning(String location) {
    return 'NeoRecall läuft$location. Ein Schritt fehlt noch: Wählen Sie die Dienste, die Ihre Aufnahmen transkribieren und Ihre Erinnerungen schreiben.';
  }

  @override
  String installLocationAt(String url) {
    return ' unter $url';
  }

  @override
  String get installNoAdminKey =>
      'Dieser Computer konnte den Administratorschlüssel nicht speichern; diese Dienste lassen sich daher jetzt einrichten, später aber nicht mehr über die Einstellungen ändern. Über das Admin-Dashboard unter /admin sind sie weiterhin änderbar.';

  @override
  String get installCreateAccount => 'Konto erstellen';

  @override
  String installDone(String version) {
    return 'NeoRecall ist installiert und läuft$version.';
  }

  @override
  String installVersionSuffix(String version) {
    return ' ($version)';
  }

  @override
  String installCliNotLinked(String directory) {
    return 'Der Terminalbefehl „neorecall“ wurde nicht verknüpft. NeoRecall läuft trotzdem; führen Sie „npm link“ in $directory aus, wenn Sie den Befehl möchten.';
  }

  @override
  String get installChooseServices =>
      'Dienste für Transkription und Erinnerungen wählen';

  @override
  String get actionRetry => 'Erneut versuchen';

  @override
  String get installChangeOptions => 'Optionen ändern';

  @override
  String get installTitle => 'NeoRecall auf diesem Computer einrichten';

  @override
  String get wifiPasswordLabel => 'Netzwerkpasswort';

  @override
  String get wifiShowPassword => 'Passwort anzeigen';

  @override
  String get wifiHidePassword => 'Passwort verbergen';

  @override
  String get wifiJoin => 'Verbinden';

  @override
  String get applianceOpen => 'Öffnen';

  @override
  String applianceRecordingElapsed(String elapsed) {
    return 'Aufnahme · $elapsed';
  }

  @override
  String get applianceRecording => 'Aufnahme';

  @override
  String get applianceNotSeenYet => 'Noch nicht gesehen';

  @override
  String get applianceReady => 'Bereit';

  @override
  String applianceLastSeenMinutes(int minutes) {
    return 'Zuletzt vor $minutes Minuten gesehen';
  }

  @override
  String applianceLastSeenHours(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'Zuletzt vor $hours Stunden gesehen',
      one: 'Zuletzt vor 1 Stunde gesehen',
    );
    return '$_temp0';
  }

  @override
  String applianceLastSeenDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'Zuletzt vor $days Tagen gesehen',
      one: 'Zuletzt vor 1 Tag gesehen',
    );
    return '$_temp0';
  }

  @override
  String get applianceConnecting => 'Verbindung wird hergestellt …';

  @override
  String get applianceSettingsTooltip => 'Geräteeinstellungen';

  @override
  String get applianceRecordingBadge => 'AUFNAHME';

  @override
  String get applianceReadyBadge => 'BEREIT';

  @override
  String get applianceOutOfRangeBadge => 'AUSSER REICHWEITE';

  @override
  String get applianceOutOfRangeBody =>
      'Außer Reichweite. Diese Seite zeigt, was das Gerät zuletzt gemeldet hat. Eine bereits laufende Aufnahme ist davon nicht betroffen – das Gerät nimmt weiter auf und sendet eigenständig.';

  @override
  String get applianceSoundEyebrow => 'TON';

  @override
  String get appliancePlaysOutOf => 'Wiedergabe über';

  @override
  String get applianceSpeaker => 'Lautsprecher';

  @override
  String get applianceHeadphones => 'Kopfhörer';

  @override
  String get applianceRecordsWith => 'Aufnahme mit';

  @override
  String get applianceOwnMicrophones => 'Eigene Mikrofone';

  @override
  String get applianceHeadset => 'Headset';

  @override
  String get applianceHeadsetQualityNote =>
      'Während der Aufnahme sinkt die Wiedergabequalität – so arbeiten Bluetooth-Headsets nun einmal.';

  @override
  String get applianceHeadphonesEyebrow => 'KOPFHÖRER';

  @override
  String get applianceLooking => 'Suche läuft …';

  @override
  String get applianceFind => 'Suchen';

  @override
  String get applianceNoHeadphones =>
      'Noch keine Kopfhörer. Versetzen Sie Ihre in den Kopplungsmodus und tippen Sie auf „Suchen“.';

  @override
  String get applianceHeadphonePaired => 'Gekoppelt';

  @override
  String get applianceHeadphoneInRange => 'In Reichweite';

  @override
  String get applianceDisconnect => 'Trennen';

  @override
  String get applianceConnect => 'Verbinden';

  @override
  String get applianceNotSetUp => 'Noch nicht eingerichtet';

  @override
  String applianceSending(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Aufnahmen werden gesendet',
      one: '1 Aufnahme wird gesendet',
    );
    return '$_temp0';
  }

  @override
  String applianceWaitingToSend(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Aufnahmen warten auf den Versand',
      one: '1 Aufnahme wartet auf den Versand',
    );
    return '$_temp0';
  }

  @override
  String applianceReadyWithHeadset(String headset) {
    return 'Bereit · $headset';
  }

  @override
  String get applianceSettingsTitle => 'Geräteeinstellungen';

  @override
  String get applianceNameEyebrow => 'NAME';

  @override
  String get applianceNameHint => 'Desk im Arbeitszimmer';

  @override
  String get applianceNetworkEyebrow => 'NETZWERK';

  @override
  String get applianceChange => 'Ändern';

  @override
  String get applianceNetworkOnline =>
      'Verbunden. Aufnahmen werden gesendet, sobald Sie die Aufnahme beenden.';

  @override
  String get applianceNetworkOffline =>
      'Nicht verbunden. Aufnahmen bleiben auf dem Gerät, bis es verbunden ist.';

  @override
  String get applianceSoundCheckEyebrow => 'TONPRÜFUNG';

  @override
  String get applianceSoundCheckLabel =>
      'Das Gerät spielt einen Ton ab und hört auf ihn.';

  @override
  String get applianceCheck => 'Prüfen';

  @override
  String get applianceSoftwareEyebrow => 'SOFTWARE';

  @override
  String get applianceVersionUnknown => 'Version unbekannt';

  @override
  String applianceVersion(String version) {
    return 'Version $version';
  }

  @override
  String get applianceCheckNow => 'Jetzt prüfen';

  @override
  String get applianceAutoUpdateTitle => 'Dieses Gerät aktuell halten';

  @override
  String get applianceAutoUpdateDescription =>
      'Prüft einmal täglich und installiert neue Versionen selbstständig. Eine Aufnahme wird nie unterbrochen – ein Update wartet, bis Sie gestoppt haben.';

  @override
  String get applianceRemoveEyebrow => 'ENTFERNEN';

  @override
  String get applianceRemoveDescription =>
      'Nimmt dieses Gerät von Ihrem Konto. Bereits gesendete Aufnahmen bleiben in NeoRecall; alles, was noch auf dem Gerät wartet, geht verloren.';

  @override
  String get applianceRemoveAction => 'Dieses Gerät entfernen';

  @override
  String get applianceRemoveTitle => 'Dieses Gerät entfernen?';

  @override
  String applianceRemovePending(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Es hat noch $count nicht gesendete Aufnahmen. Wenn Sie es jetzt entfernen, gehen sie verloren.',
      one:
          'Es hat noch 1 nicht gesendete Aufnahme. Wenn Sie es jetzt entfernen, geht sie verloren.',
    );
    return '$_temp0';
  }

  @override
  String get applianceRemoveBody =>
      'Sie können es jederzeit wieder einrichten, indem Sie seine Taste fünf Sekunden lang gedrückt halten.';

  @override
  String get applianceKeepIt => 'Behalten';

  @override
  String get applianceBluetoothOff =>
      'Schalten Sie Bluetooth ein, um ein Gerät einzurichten.';

  @override
  String get applianceBluetoothUnsupported =>
      'Dieses Gerät kann kein Bluetooth verwenden.';

  @override
  String get appliancePairFailed =>
      'Die Kopplung ist fehlgeschlagen. Halten Sie die Taste am Gerät fünf Sekunden lang gedrückt, bis es dreimal piept, und versuchen Sie es erneut.';

  @override
  String get applianceNoAnswer =>
      'Das Gerät hat nicht geantwortet. Prüfen Sie das Netzwerk und versuchen Sie es erneut.';

  @override
  String get applianceAddTitle => 'Einen NeoRecall Desk hinzufügen';

  @override
  String get applianceLookingIntro =>
      'Schließen Sie das Gerät an und warten Sie auf seinen kurzen aufsteigenden Ton. Wurde es bereits eingerichtet, halten Sie zuerst seine Taste fünf Sekunden lang gedrückt.';

  @override
  String get applianceNothingFound => 'Noch nichts gefunden';

  @override
  String get applianceNothingFoundMessage =>
      'Halten Sie die Taste am Gerät fünf Sekunden lang gedrückt und suchen Sie erneut.';

  @override
  String get applianceSetUpAction => 'Einrichten';

  @override
  String get applianceLookAgain => 'Erneut suchen';

  @override
  String appliancePressButton(String device) {
    return 'Drücken Sie die Taste an $device';
  }

  @override
  String get applianceTheDevice => 'dem Gerät';

  @override
  String get appliancePressButtonWhy =>
      'Das Gerät hat kein Display; der Tastendruck ist sein Nachweis, dass die Anfrage von jemandem daneben kommt.';

  @override
  String get applianceLookingForNetworks => 'Es wird nach Netzwerken gesucht …';

  @override
  String get applianceNoNetworks => 'Noch keine Netzwerke gefunden.';

  @override
  String get applianceSettingUp => 'Das Gerät wird eingerichtet …';

  @override
  String get applianceSettingUpDetail =>
      'Es tritt Ihrem Netzwerk bei und meldet sich an.';

  @override
  String get applianceDoneTitle => 'Bereit';

  @override
  String applianceDoneBody(String name) {
    return 'Wählen Sie an Ihrem Computer „$name“ als Lautsprecher und Mikrofon aus und drücken Sie dann die Taste, um aufzunehmen.';
  }

  @override
  String get actionOk => 'OK';

  @override
  String watchCopyLabel(String label) {
    return '$label kopieren';
  }

  @override
  String backgroundRuntimeFailed(String error) {
    return 'Der Hintergrunddienst konnte nicht gestartet werden: $error';
  }

  @override
  String backgroundStatusFailed(String error) {
    return 'Der Hintergrundstatus konnte nicht aktualisiert werden: $error';
  }

  @override
  String backgroundHostUnavailable(String error) {
    return 'Der Android-Hintergrunddienst ist vorübergehend nicht verfügbar: $error';
  }

  @override
  String get controllerWearableAudioStalled =>
      'Ihr Aufnahmegerät sendet keinen Ton mehr. Die Aufnahme läuft weiter und wartet darauf.';

  @override
  String get controllerWearableAudioLost =>
      'Von Ihrem Aufnahmegerät kommt kein Ton an. Was jetzt gesprochen wird, wird nicht aufgezeichnet — verbinden Sie es neu oder nehmen Sie mit dem Telefon auf.';

  @override
  String controllerCaptureIncomplete(int minutes) {
    return 'Von dieser Aufnahme wurde nur ein Teil erfasst; rund $minutes Minuten Ton sind nie vom Aufnahmegerät angekommen.';
  }
}
