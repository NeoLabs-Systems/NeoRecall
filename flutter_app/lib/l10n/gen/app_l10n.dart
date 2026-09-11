import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_l10n_de.dart';
import 'app_l10n_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppL10n
/// returned by `AppL10n.of(context)`.
///
/// Applications need to include `AppL10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_l10n.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppL10n.localizationsDelegates,
///   supportedLocales: AppL10n.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppL10n.supportedLocales
/// property.
abstract class AppL10n {
  AppL10n(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppL10n of(BuildContext context) {
    return Localizations.of<AppL10n>(context, AppL10n)!;
  }

  static const LocalizationsDelegate<AppL10n> delegate = _AppL10nDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
  ];

  /// Splash screen line while the app boots.
  ///
  /// In en, this message translates to:
  /// **'Loading NeoRecall'**
  String get appLoading;

  /// No description provided for @settingsLanguageTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguageTitle;

  /// No description provided for @settingsLanguageDescription.
  ///
  /// In en, this message translates to:
  /// **'The language NeoRecall uses for the app and for the memories, summaries, and answers it writes. Recordings are still transcribed in whatever language was spoken.'**
  String get settingsLanguageDescription;

  /// No description provided for @settingsLanguageLabel.
  ///
  /// In en, this message translates to:
  /// **'App and memory language'**
  String get settingsLanguageLabel;

  /// No description provided for @settingsLanguageFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not change the language: {error}'**
  String settingsLanguageFailed(String error);

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get actionSave;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsDescription.
  ///
  /// In en, this message translates to:
  /// **'Capture behaviour, memory, and account security in one place.'**
  String get settingsDescription;

  /// No description provided for @settingsSaved.
  ///
  /// In en, this message translates to:
  /// **'Settings saved.'**
  String get settingsSaved;

  /// No description provided for @settingsVocabularyTooMany.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Remove 1 term to save.} other{Remove {count} terms to save.}}'**
  String settingsVocabularyTooMany(int count);

  /// No description provided for @settingsVocabularyTermTooLong.
  ///
  /// In en, this message translates to:
  /// **'Each term must be {maximum} characters or fewer.'**
  String settingsVocabularyTermTooLong(int maximum);

  /// No description provided for @settingsShortenRetentionTitle.
  ///
  /// In en, this message translates to:
  /// **'Shorten original-file retention?'**
  String get settingsShortenRetentionTitle;

  /// No description provided for @settingsShortenRetentionBody.
  ///
  /// In en, this message translates to:
  /// **'Original photos, documents, and raw audio older than {days} days will be permanently deleted during the next cleanup. Transcripts and AI descriptions remain.'**
  String settingsShortenRetentionBody(int days);

  /// No description provided for @settingsShortenRetentionConfirm.
  ///
  /// In en, this message translates to:
  /// **'Shorten retention'**
  String get settingsShortenRetentionConfirm;

  /// No description provided for @settingsUploadPolicyFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update upload policy: {error}'**
  String settingsUploadPolicyFailed(String error);

  /// No description provided for @settingsStopRawAudioTitle.
  ///
  /// In en, this message translates to:
  /// **'Stop keeping raw audio?'**
  String get settingsStopRawAudioTitle;

  /// No description provided for @settingsStopRawAudioBody.
  ///
  /// In en, this message translates to:
  /// **'Recordings already on this device will be deleted now. Transcripts, titles, and memories stay.'**
  String get settingsStopRawAudioBody;

  /// No description provided for @settingsStopRawAudioConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete raw audio'**
  String get settingsStopRawAudioConfirm;

  /// No description provided for @settingsRawAudioFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update raw audio storage: {error}'**
  String settingsRawAudioFailed(String error);

  /// No description provided for @settingsDevicesTitle.
  ///
  /// In en, this message translates to:
  /// **'Signed-in devices'**
  String get settingsDevicesTitle;

  /// No description provided for @settingsDevicesDescription.
  ///
  /// In en, this message translates to:
  /// **'Review access or revoke an old client. Set up, connect, and control capture hardware from Record.'**
  String get settingsDevicesDescription;

  /// No description provided for @settingsOpenRecord.
  ///
  /// In en, this message translates to:
  /// **'Open Record'**
  String get settingsOpenRecord;

  /// No description provided for @settingsServicesNoAdminKey.
  ///
  /// In en, this message translates to:
  /// **'These services are set on the server itself. This app has no administrator key for {backendUrl}, so ask whoever runs that server to configure transcription and memory writing there.'**
  String settingsServicesNoAdminKey(String backendUrl);

  /// No description provided for @settingsServicesTitle.
  ///
  /// In en, this message translates to:
  /// **'Services'**
  String get settingsServicesTitle;

  /// No description provided for @settingsSectionGeneral.
  ///
  /// In en, this message translates to:
  /// **'GENERAL'**
  String get settingsSectionGeneral;

  /// No description provided for @settingsTimeLocaleTitle.
  ///
  /// In en, this message translates to:
  /// **'Time and locale'**
  String get settingsTimeLocaleTitle;

  /// No description provided for @settingsTimeLocaleDescription.
  ///
  /// In en, this message translates to:
  /// **'Used to place recordings and generated memories on your local timeline.'**
  String get settingsTimeLocaleDescription;

  /// No description provided for @settingsTimezoneLabel.
  ///
  /// In en, this message translates to:
  /// **'IANA timezone'**
  String get settingsTimezoneLabel;

  /// No description provided for @settingsSectionAlwaysOn.
  ///
  /// In en, this message translates to:
  /// **'ALWAYS-ON CAPTURE'**
  String get settingsSectionAlwaysOn;

  /// No description provided for @settingsUnmeteredTitle.
  ///
  /// In en, this message translates to:
  /// **'Upload only on Wi-Fi / unmetered networks'**
  String get settingsUnmeteredTitle;

  /// No description provided for @settingsUnmeteredDescription.
  ///
  /// In en, this message translates to:
  /// **'On by default. Recording continues to private app storage while offline or on mobile data, then uploads when an unmetered connection is available.'**
  String get settingsUnmeteredDescription;

  /// No description provided for @settingsScheduleTitle.
  ///
  /// In en, this message translates to:
  /// **'Daily recording window'**
  String get settingsScheduleTitle;

  /// No description provided for @settingsScheduleDescription.
  ///
  /// In en, this message translates to:
  /// **'Uses this device’s local time. Off means 24/7; overnight windows such as 22:00–06:00 are supported.'**
  String get settingsScheduleDescription;

  /// No description provided for @settingsScheduleStart.
  ///
  /// In en, this message translates to:
  /// **'Start {time}'**
  String settingsScheduleStart(String time);

  /// No description provided for @settingsScheduleStop.
  ///
  /// In en, this message translates to:
  /// **'Stop {time}'**
  String settingsScheduleStop(String time);

  /// No description provided for @settingsScheduleFootnote.
  ///
  /// In en, this message translates to:
  /// **'At the end time, the current chunk is finalized to on-device storage. Android may require opening NeoRecall before the phone microphone can restart at the next start time.'**
  String get settingsScheduleFootnote;

  /// No description provided for @settingsSilenceTitle.
  ///
  /// In en, this message translates to:
  /// **'Silence handling'**
  String get settingsSilenceTitle;

  /// No description provided for @settingsSilenceDescription.
  ///
  /// In en, this message translates to:
  /// **'Server-side voice activity detection marks silent chunks. The phone keeps its copy until a terminal receipt proves processing completed and server audio was deleted.'**
  String get settingsSilenceDescription;

  /// No description provided for @settingsSectionRecording.
  ///
  /// In en, this message translates to:
  /// **'RECORDING'**
  String get settingsSectionRecording;

  /// No description provided for @settingsChunkDuration.
  ///
  /// In en, this message translates to:
  /// **'Chunk duration: {seconds} seconds'**
  String settingsChunkDuration(int seconds);

  /// No description provided for @settingsChunkOverlap.
  ///
  /// In en, this message translates to:
  /// **'Boundary overlap: {seconds} seconds'**
  String settingsChunkOverlap(String seconds);

  /// No description provided for @settingsSectionTranscription.
  ///
  /// In en, this message translates to:
  /// **'TRANSCRIPTION'**
  String get settingsSectionTranscription;

  /// No description provided for @settingsVocabularyLabel.
  ///
  /// In en, this message translates to:
  /// **'Words and phrases to recognize'**
  String get settingsVocabularyLabel;

  /// No description provided for @settingsVocabularyHint.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall\nProduct or company name\nTechnical term'**
  String get settingsVocabularyHint;

  /// No description provided for @settingsVocabularyHelper.
  ///
  /// In en, this message translates to:
  /// **'One entry per line. Duplicates are ignored.'**
  String get settingsVocabularyHelper;

  /// No description provided for @settingsVocabularyCorrectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Correct close transcription misspellings'**
  String get settingsVocabularyCorrectionTitle;

  /// No description provided for @settingsVocabularyCorrectionDescription.
  ///
  /// In en, this message translates to:
  /// **'For providers without native vocabulary matching, only unambiguous single words of {minimum}+ characters are corrected.'**
  String settingsVocabularyCorrectionDescription(Object minimum);

  /// No description provided for @settingsSpeakerVocabularyTitle.
  ///
  /// In en, this message translates to:
  /// **'Added automatically from named speakers'**
  String get settingsSpeakerVocabularyTitle;

  /// No description provided for @settingsSectionRecordingContext.
  ///
  /// In en, this message translates to:
  /// **'RECORDING CONTEXT'**
  String get settingsSectionRecordingContext;

  /// No description provided for @settingsKeepRawAudioTitle.
  ///
  /// In en, this message translates to:
  /// **'Keep raw audio on this device'**
  String get settingsKeepRawAudioTitle;

  /// No description provided for @settingsKeepRawAudioDescription.
  ///
  /// In en, this message translates to:
  /// **'On by default. Listen from Moments. The server still deletes its copy after transcription; only this phone keeps the file, and only until the retention period below.'**
  String get settingsKeepRawAudioDescription;

  /// No description provided for @settingsRetentionTitle.
  ///
  /// In en, this message translates to:
  /// **'Keep original photos, documents, and raw audio for {days} days'**
  String settingsRetentionTitle(int days);

  /// No description provided for @settingsRetentionDescription.
  ///
  /// In en, this message translates to:
  /// **'After this period NeoRecall deletes the original bytes but keeps transcripts, extracted text, image descriptions, and source links.'**
  String get settingsRetentionDescription;

  /// No description provided for @settingsRetentionDays.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{1 day} other{{days} days}}'**
  String settingsRetentionDays(int days);

  /// No description provided for @settingsRetentionOneYear.
  ///
  /// In en, this message translates to:
  /// **'1 year'**
  String get settingsRetentionOneYear;

  /// No description provided for @settingsRetentionWarning.
  ///
  /// In en, this message translates to:
  /// **'Shortening retention can permanently delete existing originals on the next server cleanup.'**
  String get settingsRetentionWarning;

  /// No description provided for @settingsSectionMemory.
  ///
  /// In en, this message translates to:
  /// **'MEMORY'**
  String get settingsSectionMemory;

  /// No description provided for @settingsConsolidationTitle.
  ///
  /// In en, this message translates to:
  /// **'Consolidation interval'**
  String get settingsConsolidationTitle;

  /// No description provided for @settingsConsolidationImmediate.
  ///
  /// In en, this message translates to:
  /// **'As soon as there is enough material'**
  String get settingsConsolidationImmediate;

  /// No description provided for @settingsConsolidationWait.
  ///
  /// In en, this message translates to:
  /// **'{hours, plural, =1{Wait at least 1 hour between write-ups} other{Wait at least {hours} hours between write-ups}}'**
  String settingsConsolidationWait(int hours);

  /// No description provided for @settingsConsolidationSliderImmediate.
  ///
  /// In en, this message translates to:
  /// **'Immediate'**
  String get settingsConsolidationSliderImmediate;

  /// No description provided for @settingsConsolidationSliderHours.
  ///
  /// In en, this message translates to:
  /// **'{hours}h'**
  String settingsConsolidationSliderHours(int hours);

  /// No description provided for @settingsConsolidationFloorNone.
  ///
  /// In en, this message translates to:
  /// **'Memories are written when enough has been said, without waiting for a conversation to end.'**
  String get settingsConsolidationFloorNone;

  /// No description provided for @settingsConsolidationFloor.
  ///
  /// In en, this message translates to:
  /// **'{hours, plural, =1{This server will not write up more often than every hour.} other{This server will not write up more often than every {hours} hours.}}'**
  String settingsConsolidationFloor(int hours);

  /// No description provided for @settingsInstructionsTooLong.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Shorten 1 instruction to {limit} characters to save.} other{Shorten {count} instructions to {limit} characters to save.}}'**
  String settingsInstructionsTooLong(int count, int limit);

  /// No description provided for @settingsInstructionsLimit.
  ///
  /// In en, this message translates to:
  /// **'At most {limit} characters.'**
  String settingsInstructionsLimit(int limit);

  /// No description provided for @settingsInstructionsIntro.
  ///
  /// In en, this message translates to:
  /// **'These are sent with every request in their area. They shape tone, length, language, and what matters to you — they cannot change what the model is allowed to read, and evidence still comes only from your own recordings.'**
  String get settingsInstructionsIntro;

  /// No description provided for @settingsSectionEverywhere.
  ///
  /// In en, this message translates to:
  /// **'EVERYWHERE'**
  String get settingsSectionEverywhere;

  /// No description provided for @settingsInstructionsGlobalLabel.
  ///
  /// In en, this message translates to:
  /// **'Global instructions'**
  String get settingsInstructionsGlobalLabel;

  /// No description provided for @settingsInstructionsGlobalHint.
  ///
  /// In en, this message translates to:
  /// **'Write in German.\nUse 24-hour times.'**
  String get settingsInstructionsGlobalHint;

  /// No description provided for @settingsInstructionsGlobalHelper.
  ///
  /// In en, this message translates to:
  /// **'Applied to memories, summaries, and answers alike.'**
  String get settingsInstructionsGlobalHelper;

  /// No description provided for @settingsSectionMemories.
  ///
  /// In en, this message translates to:
  /// **'MEMORIES'**
  String get settingsSectionMemories;

  /// No description provided for @settingsInstructionsMemoriesLabel.
  ///
  /// In en, this message translates to:
  /// **'When writing memories'**
  String get settingsInstructionsMemoriesLabel;

  /// No description provided for @settingsSectionSummaries.
  ///
  /// In en, this message translates to:
  /// **'SUMMARIES'**
  String get settingsSectionSummaries;

  /// No description provided for @settingsInstructionsSummariesLabel.
  ///
  /// In en, this message translates to:
  /// **'When writing summaries'**
  String get settingsInstructionsSummariesLabel;

  /// No description provided for @settingsSectionAsk.
  ///
  /// In en, this message translates to:
  /// **'ASK'**
  String get settingsSectionAsk;

  /// No description provided for @settingsInstructionsAskLabel.
  ///
  /// In en, this message translates to:
  /// **'When answering questions'**
  String get settingsInstructionsAskLabel;

  /// No description provided for @settingsSectionSpeakers.
  ///
  /// In en, this message translates to:
  /// **'SPEAKERS'**
  String get settingsSectionSpeakers;

  /// No description provided for @settingsDiarizationTitle.
  ///
  /// In en, this message translates to:
  /// **'Speaker diarization'**
  String get settingsDiarizationTitle;

  /// No description provided for @settingsDiarizationDescription.
  ///
  /// In en, this message translates to:
  /// **'Separate overlapping speakers during transcription.'**
  String get settingsDiarizationDescription;

  /// No description provided for @settingsRecurringSpeakerTitle.
  ///
  /// In en, this message translates to:
  /// **'Recurring speaker matching'**
  String get settingsRecurringSpeakerTitle;

  /// No description provided for @settingsRecurringSpeakerDescription.
  ///
  /// In en, this message translates to:
  /// **'Match known voiceprints across recordings.'**
  String get settingsRecurringSpeakerDescription;

  /// No description provided for @settingsInstructionsMemoriesHint.
  ///
  /// In en, this message translates to:
  /// **'Always name who was there.\nKeep decisions and promises separate from small talk.'**
  String get settingsInstructionsMemoriesHint;

  /// No description provided for @settingsInstructionsMemoriesHelper.
  ///
  /// In en, this message translates to:
  /// **'Used while an occasion is written up into a memory card, and when memories are rewritten or merged.'**
  String get settingsInstructionsMemoriesHelper;

  /// No description provided for @settingsInstructionsSummariesHint.
  ///
  /// In en, this message translates to:
  /// **'Five lines at most.\nLead with what changed.'**
  String get settingsInstructionsSummariesHint;

  /// No description provided for @settingsInstructionsSummariesHelper.
  ///
  /// In en, this message translates to:
  /// **'Used for the daily summary and for the running summary of a conversation while it is still being recorded.'**
  String get settingsInstructionsSummariesHelper;

  /// No description provided for @settingsInstructionsAskHint.
  ///
  /// In en, this message translates to:
  /// **'Answer in two sentences, then stop.'**
  String get settingsInstructionsAskHint;

  /// No description provided for @settingsInstructionsAskHelper.
  ///
  /// In en, this message translates to:
  /// **'Used for every answer on the Ask tab.'**
  String get settingsInstructionsAskHelper;

  /// No description provided for @settingsSpeakerIdentityUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Your server cannot tell voices apart right now, so new recordings will not be split by speaker. Running setup on the server installs what it needs. Names you have already given a speaker are kept.'**
  String get settingsSpeakerIdentityUnavailable;

  /// No description provided for @settingsDeferredSpeakerTitle.
  ///
  /// In en, this message translates to:
  /// **'Review speakers when a conversation ends'**
  String get settingsDeferredSpeakerTitle;

  /// No description provided for @settingsDeferredSpeakerDescription.
  ///
  /// In en, this message translates to:
  /// **'Look again at who spoke once the whole conversation can be heard, so one person is not listed several times. Speaker labels may change shortly after a recording finishes.'**
  String get settingsDeferredSpeakerDescription;

  /// No description provided for @settingsNavGeneral.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get settingsNavGeneral;

  /// No description provided for @settingsNavGeneralDescription.
  ///
  /// In en, this message translates to:
  /// **'Time and locale'**
  String get settingsNavGeneralDescription;

  /// No description provided for @settingsNavSecurity.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get settingsNavSecurity;

  /// No description provided for @settingsNavSecurityDescription.
  ///
  /// In en, this message translates to:
  /// **'Passwords and 2FA'**
  String get settingsNavSecurityDescription;

  /// No description provided for @settingsNavUsage.
  ///
  /// In en, this message translates to:
  /// **'Usage'**
  String get settingsNavUsage;

  /// No description provided for @settingsNavUsageDescription.
  ///
  /// In en, this message translates to:
  /// **'AI and transcription limits'**
  String get settingsNavUsageDescription;

  /// No description provided for @usageSectionEyebrow.
  ///
  /// In en, this message translates to:
  /// **'Usage & limits'**
  String get usageSectionEyebrow;

  /// No description provided for @usageSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'How much this account has used'**
  String get usageSectionTitle;

  /// No description provided for @usageSectionDescription.
  ///
  /// In en, this message translates to:
  /// **'These are rolling 4-hour and 7-day allowances. Usage drops on its own as older work ages out. Recording keeps going if a limit is reached; the original audio stays available until it can be written up.'**
  String get usageSectionDescription;

  /// No description provided for @usageAiTitle.
  ///
  /// In en, this message translates to:
  /// **'Language-model use'**
  String get usageAiTitle;

  /// No description provided for @usageTranscriptionTitle.
  ///
  /// In en, this message translates to:
  /// **'Transcription'**
  String get usageTranscriptionTitle;

  /// No description provided for @usageWindowFourHour.
  ///
  /// In en, this message translates to:
  /// **'Last 4 hours'**
  String get usageWindowFourHour;

  /// No description provided for @usageWindowWeekly.
  ///
  /// In en, this message translates to:
  /// **'Last 7 days'**
  String get usageWindowWeekly;

  /// No description provided for @usageUnlimited.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get usageUnlimited;

  /// No description provided for @usageCustomBadge.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get usageCustomBadge;

  /// No description provided for @usageUsedOfLimit.
  ///
  /// In en, this message translates to:
  /// **'{used} of {limit}'**
  String usageUsedOfLimit(String used, String limit);

  /// No description provided for @usageNextDrop.
  ///
  /// In en, this message translates to:
  /// **'Next drop {when}'**
  String usageNextDrop(String when);

  /// No description provided for @usageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Usage could not be loaded just now.'**
  String get usageUnavailable;

  /// No description provided for @usageAskLimited.
  ///
  /// In en, this message translates to:
  /// **'You have reached the language-model allowance for now. Try again later.'**
  String get usageAskLimited;

  /// No description provided for @settingsNavRecording.
  ///
  /// In en, this message translates to:
  /// **'Recording'**
  String get settingsNavRecording;

  /// No description provided for @settingsNavRecordingDescription.
  ///
  /// In en, this message translates to:
  /// **'Schedule, network, chunks'**
  String get settingsNavRecordingDescription;

  /// No description provided for @settingsNavMemory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get settingsNavMemory;

  /// No description provided for @settingsNavMemoryDescription.
  ///
  /// In en, this message translates to:
  /// **'Consolidation timing'**
  String get settingsNavMemoryDescription;

  /// No description provided for @settingsNavInstructions.
  ///
  /// In en, this message translates to:
  /// **'Instructions'**
  String get settingsNavInstructions;

  /// No description provided for @settingsNavInstructionsDescription.
  ///
  /// In en, this message translates to:
  /// **'How the model writes for you'**
  String get settingsNavInstructionsDescription;

  /// No description provided for @settingsNavSpeakers.
  ///
  /// In en, this message translates to:
  /// **'Speakers'**
  String get settingsNavSpeakers;

  /// No description provided for @settingsNavSpeakersDescription.
  ///
  /// In en, this message translates to:
  /// **'Diarization and matching'**
  String get settingsNavSpeakersDescription;

  /// No description provided for @settingsNavWatch.
  ///
  /// In en, this message translates to:
  /// **'Watch'**
  String get settingsNavWatch;

  /// No description provided for @settingsNavWatchDescription.
  ///
  /// In en, this message translates to:
  /// **'Wear OS setup and digest'**
  String get settingsNavWatchDescription;

  /// No description provided for @settingsNavDevices.
  ///
  /// In en, this message translates to:
  /// **'Account devices'**
  String get settingsNavDevices;

  /// No description provided for @settingsNavDevicesDescription.
  ///
  /// In en, this message translates to:
  /// **'Sessions and access'**
  String get settingsNavDevicesDescription;

  /// No description provided for @settingsNavServices.
  ///
  /// In en, this message translates to:
  /// **'Services'**
  String get settingsNavServices;

  /// No description provided for @settingsNavServicesDescription.
  ///
  /// In en, this message translates to:
  /// **'Transcription and memory writing'**
  String get settingsNavServicesDescription;

  /// No description provided for @settingsNavIntegrations.
  ///
  /// In en, this message translates to:
  /// **'Integrations'**
  String get settingsNavIntegrations;

  /// No description provided for @settingsNavIntegrationsDescription.
  ///
  /// In en, this message translates to:
  /// **'NeoAgent and MCP'**
  String get settingsNavIntegrationsDescription;

  /// No description provided for @settingsNavAreaLabel.
  ///
  /// In en, this message translates to:
  /// **'Settings area'**
  String get settingsNavAreaLabel;

  /// No description provided for @settingsNavAreasHeading.
  ///
  /// In en, this message translates to:
  /// **'Settings areas'**
  String get settingsNavAreasHeading;

  /// No description provided for @navRecord.
  ///
  /// In en, this message translates to:
  /// **'Record'**
  String get navRecord;

  /// No description provided for @navSources.
  ///
  /// In en, this message translates to:
  /// **'Sources'**
  String get navSources;

  /// No description provided for @navMoments.
  ///
  /// In en, this message translates to:
  /// **'Moments'**
  String get navMoments;

  /// No description provided for @navMemories.
  ///
  /// In en, this message translates to:
  /// **'Memories'**
  String get navMemories;

  /// No description provided for @navHighlights.
  ///
  /// In en, this message translates to:
  /// **'Highlights'**
  String get navHighlights;

  /// No description provided for @navSpeakers.
  ///
  /// In en, this message translates to:
  /// **'Speakers'**
  String get navSpeakers;

  /// No description provided for @navAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask'**
  String get navAsk;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @navCapture.
  ///
  /// In en, this message translates to:
  /// **'Capture'**
  String get navCapture;

  /// No description provided for @navLibrary.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get navLibrary;

  /// No description provided for @shellAccountFallback.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get shellAccountFallback;

  /// No description provided for @shellControlSurface.
  ///
  /// In en, this message translates to:
  /// **'CONTROL SURFACE'**
  String get shellControlSurface;

  /// No description provided for @shellSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get shellSignOut;

  /// No description provided for @shellBatteryWarning.
  ///
  /// In en, this message translates to:
  /// **'Battery optimization may suspend always-on capture on this device.'**
  String get shellBatteryWarning;

  /// No description provided for @shellBatteryFix.
  ///
  /// In en, this message translates to:
  /// **'Fix'**
  String get shellBatteryFix;

  /// No description provided for @shellOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline — capture continues; uploads resume when reconnected.'**
  String get shellOffline;

  /// No description provided for @shellRecordingActive.
  ///
  /// In en, this message translates to:
  /// **'Recording is active.'**
  String get shellRecordingActive;

  /// No description provided for @shellRecordingOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get shellRecordingOpen;

  /// No description provided for @shellSyncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing {label}'**
  String shellSyncing(String label);

  /// No description provided for @authPasswordsDoNotMatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match.'**
  String get authPasswordsDoNotMatch;

  /// No description provided for @authTwoFactorTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter 2FA code'**
  String get authTwoFactorTitle;

  /// No description provided for @authRegisterTitle.
  ///
  /// In en, this message translates to:
  /// **'Create your NeoRecall account'**
  String get authRegisterTitle;

  /// No description provided for @authSignInTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get authSignInTitle;

  /// No description provided for @authTwoFactorSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Open your authenticator app and enter the current NeoRecall code.'**
  String get authTwoFactorSubtitle;

  /// No description provided for @authRegisterSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your first account becomes the NeoRecall administrator for this server.'**
  String get authRegisterSubtitle;

  /// No description provided for @authSignInSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your NeoRecall account details.'**
  String get authSignInSubtitle;

  /// No description provided for @authRetryLocalStartup.
  ///
  /// In en, this message translates to:
  /// **'Retry local startup'**
  String get authRetryLocalStartup;

  /// No description provided for @authTwoFactorFieldLabel.
  ///
  /// In en, this message translates to:
  /// **'2FA or recovery code'**
  String get authTwoFactorFieldLabel;

  /// No description provided for @authUsernameLabel.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get authUsernameLabel;

  /// No description provided for @authEmailLabel.
  ///
  /// In en, this message translates to:
  /// **'Email (optional)'**
  String get authEmailLabel;

  /// No description provided for @authPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get authPasswordLabel;

  /// No description provided for @authConfirmPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm password'**
  String get authConfirmPasswordLabel;

  /// No description provided for @authVerify.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get authVerify;

  /// No description provided for @authCreateAccount.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get authCreateAccount;

  /// No description provided for @authSecurityKeySignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in with a security key'**
  String get authSecurityKeySignIn;

  /// No description provided for @authSwitchToSignIn.
  ///
  /// In en, this message translates to:
  /// **'Already have an account? Sign in'**
  String get authSwitchToSignIn;

  /// No description provided for @authSwitchToRegister.
  ///
  /// In en, this message translates to:
  /// **'Need a new account? Register'**
  String get authSwitchToRegister;

  /// No description provided for @authServerButton.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get authServerButton;

  /// No description provided for @authWelcomeEyebrow.
  ///
  /// In en, this message translates to:
  /// **'WELCOME TO NEORECALL'**
  String get authWelcomeEyebrow;

  /// No description provided for @authSetUpOrConnect.
  ///
  /// In en, this message translates to:
  /// **'Set up or connect NeoRecall'**
  String get authSetUpOrConnect;

  /// No description provided for @authConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect NeoRecall'**
  String get authConnect;

  /// No description provided for @authSetUpOrConnectBody.
  ///
  /// In en, this message translates to:
  /// **'Install NeoRecall on this computer without a terminal, or enter the address of a server that is already running.'**
  String get authSetUpOrConnectBody;

  /// No description provided for @authConnectBody.
  ///
  /// In en, this message translates to:
  /// **'Enter the address of the NeoRecall server this device should use.'**
  String get authConnectBody;

  /// No description provided for @authInstallLocally.
  ///
  /// In en, this message translates to:
  /// **'Set up NeoRecall on this computer'**
  String get authInstallLocally;

  /// No description provided for @authOrConnectRunning.
  ///
  /// In en, this message translates to:
  /// **'or connect to a running server'**
  String get authOrConnectRunning;

  /// No description provided for @authServerAddressLabel.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall server address'**
  String get authServerAddressLabel;

  /// No description provided for @authConnectToServer.
  ///
  /// In en, this message translates to:
  /// **'Connect to this server'**
  String get authConnectToServer;

  /// No description provided for @authBackToSignIn.
  ///
  /// In en, this message translates to:
  /// **'Back to sign in'**
  String get authBackToSignIn;

  /// No description provided for @askNewQuestion.
  ///
  /// In en, this message translates to:
  /// **'New question'**
  String get askNewQuestion;

  /// No description provided for @askHint.
  ///
  /// In en, this message translates to:
  /// **'Ask anything about your day'**
  String get askHint;

  /// No description provided for @askFollowUpHint.
  ///
  /// In en, this message translates to:
  /// **'Ask a follow-up'**
  String get askFollowUpHint;

  /// No description provided for @askStarterToday.
  ///
  /// In en, this message translates to:
  /// **'What did I do today?'**
  String get askStarterToday;

  /// No description provided for @askStarterFollowUps.
  ///
  /// In en, this message translates to:
  /// **'What did I say I would follow up on this week?'**
  String get askStarterFollowUps;

  /// No description provided for @askStarterYesterday.
  ///
  /// In en, this message translates to:
  /// **'Who did I talk to yesterday, and about what?'**
  String get askStarterYesterday;

  /// No description provided for @askEyebrow.
  ///
  /// In en, this message translates to:
  /// **'Recall'**
  String get askEyebrow;

  /// No description provided for @askDescription.
  ///
  /// In en, this message translates to:
  /// **'Your recall, in your own words. Retrieval and the answer both run wherever your NeoRecall server does — no query leaves it.'**
  String get askDescription;

  /// No description provided for @askStartWith.
  ///
  /// In en, this message translates to:
  /// **'Start with'**
  String get askStartWith;

  /// No description provided for @askWeakMatches.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 weaker match was left out — it shares words with the question, not meaning.} other{{count} weaker matches were left out — they share words with the question, not meaning.}}'**
  String askWeakMatches(int count);

  /// No description provided for @askSourcesExpanded.
  ///
  /// In en, this message translates to:
  /// **'SOURCES'**
  String get askSourcesExpanded;

  /// No description provided for @askSourcesCollapsed.
  ///
  /// In en, this message translates to:
  /// **'SHOW SOURCES'**
  String get askSourcesCollapsed;

  /// No description provided for @askPeriodRead.
  ///
  /// In en, this message translates to:
  /// **'Read {period}'**
  String askPeriodRead(String period);

  /// No description provided for @askPeriodFrom.
  ///
  /// In en, this message translates to:
  /// **'from {time}'**
  String askPeriodFrom(String time);

  /// No description provided for @askPeriodUntil.
  ///
  /// In en, this message translates to:
  /// **'until {time}'**
  String askPeriodUntil(String time);

  /// No description provided for @askNothingRecorded.
  ///
  /// In en, this message translates to:
  /// **'nothing recorded'**
  String get askNothingRecorded;

  /// No description provided for @askSubmitTooltip.
  ///
  /// In en, this message translates to:
  /// **'Ask'**
  String get askSubmitTooltip;

  /// No description provided for @askSearching.
  ///
  /// In en, this message translates to:
  /// **'Searching your recall'**
  String get askSearching;

  /// No description provided for @memoriesBulkDeleted.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 memory deleted} other{{count} memories deleted}}'**
  String memoriesBulkDeleted(int count);

  /// No description provided for @memoriesBulkPinned.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 memory pinned} other{{count} memories pinned}}'**
  String memoriesBulkPinned(int count);

  /// No description provided for @memoriesBulkUnpinned.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 memory unpinned} other{{count} memories unpinned}}'**
  String memoriesBulkUnpinned(int count);

  /// No description provided for @memoriesBulkArchived.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 memory archived} other{{count} memories archived}}'**
  String memoriesBulkArchived(int count);

  /// No description provided for @memoriesBulkRestored.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 memory restored} other{{count} memories restored}}'**
  String memoriesBulkRestored(int count);

  /// No description provided for @memoriesBulkUpdated.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 memory updated} other{{count} memories updated}}'**
  String memoriesBulkUpdated(int count);

  /// No description provided for @memoriesBulkFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update memories: {error}'**
  String memoriesBulkFailed(String error);

  /// No description provided for @memoriesRenameFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not rename: {error}'**
  String memoriesRenameFailed(String error);

  /// No description provided for @memoriesMergeTitle.
  ///
  /// In en, this message translates to:
  /// **'Merge memories?'**
  String get memoriesMergeTitle;

  /// No description provided for @memoriesMergeBody.
  ///
  /// In en, this message translates to:
  /// **'Combine {count} memories into one. Highlights and conversation evidence stay; a new title and description are written for the combined moment.'**
  String memoriesMergeBody(int count);

  /// No description provided for @memoriesMergeConfirm.
  ///
  /// In en, this message translates to:
  /// **'Merge'**
  String get memoriesMergeConfirm;

  /// No description provided for @memoriesMergedQueued.
  ///
  /// In en, this message translates to:
  /// **'Memories merged. The description will update shortly.'**
  String get memoriesMergedQueued;

  /// No description provided for @memoriesMerged.
  ///
  /// In en, this message translates to:
  /// **'Memories merged.'**
  String get memoriesMerged;

  /// No description provided for @memoriesMergeFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not merge memories: {error}'**
  String memoriesMergeFailed(String error);

  /// No description provided for @memoriesRenameDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename memory'**
  String get memoriesRenameDialogTitle;

  /// No description provided for @memoriesTitleLabel.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get memoriesTitleLabel;

  /// No description provided for @actionDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get actionDone;

  /// No description provided for @actionSelect.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get actionSelect;

  /// No description provided for @memoriesDescription.
  ///
  /// In en, this message translates to:
  /// **'Your conversations, distilled into clear memories and actionable highlights.'**
  String get memoriesDescription;

  /// No description provided for @memoriesRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get memoriesRestore;

  /// No description provided for @memoriesArchive.
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get memoriesArchive;

  /// No description provided for @memoriesEmptyFilteredTitle.
  ///
  /// In en, this message translates to:
  /// **'No matching memories'**
  String get memoriesEmptyFilteredTitle;

  /// No description provided for @memoriesEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing here yet'**
  String get memoriesEmptyTitle;

  /// No description provided for @memoriesEmptyFilteredMessage.
  ///
  /// In en, this message translates to:
  /// **'Try another filter or clear the search.'**
  String get memoriesEmptyFilteredMessage;

  /// No description provided for @memoriesEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Keep recording. When a conversation ends, NeoRecall quietly turns it into a memory.'**
  String get memoriesEmptyMessage;

  /// No description provided for @memoriesNoActionItemsTitle.
  ///
  /// In en, this message translates to:
  /// **'No action items yet'**
  String get memoriesNoActionItemsTitle;

  /// No description provided for @memoriesNoActionItemsMessage.
  ///
  /// In en, this message translates to:
  /// **'Concrete assignments and commitments will appear here when a conversation creates them.'**
  String get memoriesNoActionItemsMessage;

  /// No description provided for @momentsDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Delete this moment?} other{Delete {count} moments?}}'**
  String momentsDeleteTitle(int count);

  /// No description provided for @momentsDeleteBodyOne.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete this conversation and its transcript. A memory that came only from this conversation will be removed too.'**
  String get momentsDeleteBodyOne;

  /// No description provided for @momentsDeleteBodyMany.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete these conversations and their transcripts. Memories that came only from them will be removed too.'**
  String get momentsDeleteBodyMany;

  /// No description provided for @actionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get actionDelete;

  /// No description provided for @momentsDeleted.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 moment deleted} other{{count} moments deleted}}'**
  String momentsDeleted(int count);

  /// No description provided for @momentsDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not delete moments: {error}'**
  String momentsDeleteFailed(String error);

  /// No description provided for @momentsDescription.
  ///
  /// In en, this message translates to:
  /// **'A compact stream of conversations. Expand only the ones you want to read in full.'**
  String get momentsDescription;

  /// No description provided for @momentsEmptyNoTranscript.
  ///
  /// In en, this message translates to:
  /// **'No transcript yet'**
  String get momentsEmptyNoTranscript;

  /// No description provided for @momentsEmptyNothing.
  ///
  /// In en, this message translates to:
  /// **'Nothing to show yet'**
  String get momentsEmptyNothing;

  /// No description provided for @momentsEmptyNoTranscriptMessage.
  ///
  /// In en, this message translates to:
  /// **'Start a recording or import audio. Persisted segments will appear here.'**
  String get momentsEmptyNoTranscriptMessage;

  /// No description provided for @momentsEmptyNothingMessage.
  ///
  /// In en, this message translates to:
  /// **'Your recordings are safe. They will appear here once the above is sorted out.'**
  String get momentsEmptyNothingMessage;

  /// No description provided for @momentsToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get momentsToday;

  /// No description provided for @momentsGroupCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 moment} other{{count} moments}}'**
  String momentsGroupCount(int count);

  /// No description provided for @momentsStatusPending.
  ///
  /// In en, this message translates to:
  /// **'Being sorted'**
  String get momentsStatusPending;

  /// No description provided for @momentsStatusSetAside.
  ///
  /// In en, this message translates to:
  /// **'Waiting on a summary'**
  String get momentsStatusSetAside;

  /// No description provided for @momentsStatusAwaitsWriteUp.
  ///
  /// In en, this message translates to:
  /// **'Summary on the way'**
  String get momentsStatusAwaitsWriteUp;

  /// No description provided for @momentsListen.
  ///
  /// In en, this message translates to:
  /// **'Listen'**
  String get momentsListen;

  /// No description provided for @momentsUnassignedSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Unassigned'**
  String get momentsUnassignedSpeaker;

  /// No description provided for @momentsJustRecorded.
  ///
  /// In en, this message translates to:
  /// **'Just recorded'**
  String get momentsJustRecorded;

  /// No description provided for @momentsConversation.
  ///
  /// In en, this message translates to:
  /// **'Conversation'**
  String get momentsConversation;

  /// No description provided for @momentsLoadingRest.
  ///
  /// In en, this message translates to:
  /// **'Loading the rest of this moment'**
  String get momentsLoadingRest;

  /// No description provided for @momentsShowingFirstLines.
  ///
  /// In en, this message translates to:
  /// **'Showing the first {shown} of {total} lines.'**
  String momentsShowingFirstLines(int shown, int total);

  /// No description provided for @momentsShowLess.
  ///
  /// In en, this message translates to:
  /// **'Show less'**
  String get momentsShowLess;

  /// No description provided for @momentsMoreLines.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 more line} other{{count} more lines}}'**
  String momentsMoreLines(int count);

  /// No description provided for @momentsWritingUp.
  ///
  /// In en, this message translates to:
  /// **'Writing up'**
  String get momentsWritingUp;

  /// No description provided for @momentsWriteUpAgain.
  ///
  /// In en, this message translates to:
  /// **'Write up again'**
  String get momentsWriteUpAgain;

  /// No description provided for @momentsWriteUpNow.
  ///
  /// In en, this message translates to:
  /// **'Write up now'**
  String get momentsWriteUpNow;

  /// No description provided for @momentsRecordingBadge.
  ///
  /// In en, this message translates to:
  /// **'Recording'**
  String get momentsRecordingBadge;

  /// No description provided for @momentsNewer.
  ///
  /// In en, this message translates to:
  /// **'Newer'**
  String get momentsNewer;

  /// No description provided for @momentsOlder.
  ///
  /// In en, this message translates to:
  /// **'Older'**
  String get momentsOlder;

  /// No description provided for @momentsPage.
  ///
  /// In en, this message translates to:
  /// **'Page {page}'**
  String momentsPage(int page);

  /// No description provided for @momentsSelectPrompt.
  ///
  /// In en, this message translates to:
  /// **'Select moments'**
  String get momentsSelectPrompt;

  /// No description provided for @momentsSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String momentsSelectedCount(int count);

  /// No description provided for @momentsAllSelected.
  ///
  /// In en, this message translates to:
  /// **'All moments selected'**
  String get momentsAllSelected;

  /// No description provided for @momentsSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all moments'**
  String get momentsSelectAll;

  /// No description provided for @speakersRenameTitle.
  ///
  /// In en, this message translates to:
  /// **'Name recurring speaker'**
  String get speakersRenameTitle;

  /// No description provided for @speakersDisplayNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get speakersDisplayNameLabel;

  /// No description provided for @speakersMergeIntoTitle.
  ///
  /// In en, this message translates to:
  /// **'Merge another voice into this speaker'**
  String get speakersMergeIntoTitle;

  /// No description provided for @speakersUnnamed.
  ///
  /// In en, this message translates to:
  /// **'Unnamed recurring speaker'**
  String get speakersUnnamed;

  /// No description provided for @speakersDeleteManyTitle.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Delete 1 speaker?} other{Delete {count} speakers?}}'**
  String speakersDeleteManyTitle(int count);

  /// No description provided for @speakersDeleteManyBody.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete these speaker profiles. Associated transcript segments will no longer identify them.'**
  String get speakersDeleteManyBody;

  /// No description provided for @speakersDeleted.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 speaker deleted} other{{count} speakers deleted}}'**
  String speakersDeleted(int count);

  /// No description provided for @speakersDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not delete speakers: {error}'**
  String speakersDeleteFailed(String error);

  /// No description provided for @speakersCombineTargetTitle.
  ///
  /// In en, this message translates to:
  /// **'Combine into which speaker?'**
  String get speakersCombineTargetTitle;

  /// No description provided for @speakersCombined.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 speaker combined} other{{count} speakers combined}}'**
  String speakersCombined(int count);

  /// No description provided for @speakersCombineFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not combine speakers: {error}'**
  String speakersCombineFailed(String error);

  /// No description provided for @speakersUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Speaker profiles are already up to date'**
  String get speakersUpToDate;

  /// No description provided for @speakersMergedCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 matching speaker profile merged} other{{count} matching speaker profiles merged}}'**
  String speakersMergedCount(int count);

  /// No description provided for @speakersReevaluateFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not re-evaluate speakers: {error}'**
  String speakersReevaluateFailed(String error);

  /// No description provided for @speakersPreviewFailed.
  ///
  /// In en, this message translates to:
  /// **'Preview failed: {error}'**
  String speakersPreviewFailed(String error);

  /// No description provided for @speakersReevaluateTooltip.
  ///
  /// In en, this message translates to:
  /// **'Re-evaluate and merge matching speakers'**
  String get speakersReevaluateTooltip;

  /// No description provided for @speakersDescription.
  ///
  /// In en, this message translates to:
  /// **'Recognize a voice with a short clean sample, then name or merge its recurring profile.'**
  String get speakersDescription;

  /// No description provided for @speakersEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No recurring speakers yet'**
  String get speakersEmptyTitle;

  /// No description provided for @speakersEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'A speaker appears after a full 10-second clean voice preview is available.'**
  String get speakersEmptyMessage;

  /// No description provided for @speakersDeleteOneTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete speaker?'**
  String get speakersDeleteOneTitle;

  /// No description provided for @speakersDeleteOneBody.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete this speaker profile. Associated transcript segments will no longer identify this speaker.'**
  String get speakersDeleteOneBody;

  /// No description provided for @speakersPausePreview.
  ///
  /// In en, this message translates to:
  /// **'Pause voice preview'**
  String get speakersPausePreview;

  /// No description provided for @speakersPlayPreview.
  ///
  /// In en, this message translates to:
  /// **'Play voice preview'**
  String get speakersPlayPreview;

  /// No description provided for @speakersPreviewNeeded.
  ///
  /// In en, this message translates to:
  /// **'A full clean voice preview is needed'**
  String get speakersPreviewNeeded;

  /// No description provided for @speakersNameTooltip.
  ///
  /// In en, this message translates to:
  /// **'Name speaker'**
  String get speakersNameTooltip;

  /// No description provided for @speakersDeleteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete speaker'**
  String get speakersDeleteTooltip;

  /// No description provided for @speakersSelectPrompt.
  ///
  /// In en, this message translates to:
  /// **'Select speakers'**
  String get speakersSelectPrompt;

  /// No description provided for @speakersSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String speakersSelectedCount(int count);

  /// No description provided for @speakersAllSelected.
  ///
  /// In en, this message translates to:
  /// **'All speakers selected'**
  String get speakersAllSelected;

  /// No description provided for @speakersSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all speakers'**
  String get speakersSelectAll;

  /// No description provided for @speakersCombineTooltip.
  ///
  /// In en, this message translates to:
  /// **'Combine into one speaker'**
  String get speakersCombineTooltip;

  /// No description provided for @monthShort1.
  ///
  /// In en, this message translates to:
  /// **'JAN'**
  String get monthShort1;

  /// No description provided for @monthShort2.
  ///
  /// In en, this message translates to:
  /// **'FEB'**
  String get monthShort2;

  /// No description provided for @monthShort3.
  ///
  /// In en, this message translates to:
  /// **'MAR'**
  String get monthShort3;

  /// No description provided for @monthShort4.
  ///
  /// In en, this message translates to:
  /// **'APR'**
  String get monthShort4;

  /// No description provided for @monthShort5.
  ///
  /// In en, this message translates to:
  /// **'MAY'**
  String get monthShort5;

  /// No description provided for @monthShort6.
  ///
  /// In en, this message translates to:
  /// **'JUN'**
  String get monthShort6;

  /// No description provided for @monthShort7.
  ///
  /// In en, this message translates to:
  /// **'JUL'**
  String get monthShort7;

  /// No description provided for @monthShort8.
  ///
  /// In en, this message translates to:
  /// **'AUG'**
  String get monthShort8;

  /// No description provided for @monthShort9.
  ///
  /// In en, this message translates to:
  /// **'SEP'**
  String get monthShort9;

  /// No description provided for @monthShort10.
  ///
  /// In en, this message translates to:
  /// **'OCT'**
  String get monthShort10;

  /// No description provided for @monthShort11.
  ///
  /// In en, this message translates to:
  /// **'NOV'**
  String get monthShort11;

  /// No description provided for @monthShort12.
  ///
  /// In en, this message translates to:
  /// **'DEC'**
  String get monthShort12;

  /// No description provided for @weekdayLong1.
  ///
  /// In en, this message translates to:
  /// **'MONDAY'**
  String get weekdayLong1;

  /// No description provided for @weekdayLong2.
  ///
  /// In en, this message translates to:
  /// **'TUESDAY'**
  String get weekdayLong2;

  /// No description provided for @weekdayLong3.
  ///
  /// In en, this message translates to:
  /// **'WEDNESDAY'**
  String get weekdayLong3;

  /// No description provided for @weekdayLong4.
  ///
  /// In en, this message translates to:
  /// **'THURSDAY'**
  String get weekdayLong4;

  /// No description provided for @weekdayLong5.
  ///
  /// In en, this message translates to:
  /// **'FRIDAY'**
  String get weekdayLong5;

  /// No description provided for @weekdayLong6.
  ///
  /// In en, this message translates to:
  /// **'SATURDAY'**
  String get weekdayLong6;

  /// No description provided for @weekdayLong7.
  ///
  /// In en, this message translates to:
  /// **'SUNDAY'**
  String get weekdayLong7;

  /// No description provided for @recordConsentTitle.
  ///
  /// In en, this message translates to:
  /// **'Recording consent and visible use'**
  String get recordConsentTitle;

  /// No description provided for @recordConsentBody.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall records privately spoken words. Record only when everyone has been informed and you are legally permitted to do so. Recording always remains visibly indicated; NeoRecall has no covert mode.'**
  String get recordConsentBody;

  /// No description provided for @recordConsentAccept.
  ///
  /// In en, this message translates to:
  /// **'I understand'**
  String get recordConsentAccept;

  /// No description provided for @recordDeviceNoAnswer.
  ///
  /// In en, this message translates to:
  /// **'The device did not answer.'**
  String get recordDeviceNoAnswer;

  /// No description provided for @recordFootnoteOfflineDevice.
  ///
  /// In en, this message translates to:
  /// **'This device records by itself — there is no live capture. Use “Sync device recordings” to pull and transcribe them.'**
  String get recordFootnoteOfflineDevice;

  /// No description provided for @recordFootnoteEitherSide.
  ///
  /// In en, this message translates to:
  /// **'Start from the app or the device. Either side can stop. Recordings made while you were away still sync from the device.'**
  String get recordFootnoteEitherSide;

  /// No description provided for @recordFootnoteSystemAudio.
  ///
  /// In en, this message translates to:
  /// **'System audio uses the OS screen-recording permission and captures audio only, not video frames.'**
  String get recordFootnoteSystemAudio;

  /// No description provided for @recordOffline.
  ///
  /// In en, this message translates to:
  /// **'You are offline. Capture continues locally and queued audio uploads automatically when the connection returns.'**
  String get recordOffline;

  /// No description provided for @recordSourceWearable.
  ///
  /// In en, this message translates to:
  /// **'Wearable'**
  String get recordSourceWearable;

  /// No description provided for @recordSourceDesk.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall Desk'**
  String get recordSourceDesk;

  /// No description provided for @recordSourcePhoneMicrophone.
  ///
  /// In en, this message translates to:
  /// **'Phone microphone'**
  String get recordSourcePhoneMicrophone;

  /// No description provided for @recordSourceMicrophoneAndDevice.
  ///
  /// In en, this message translates to:
  /// **'Microphone and device audio'**
  String get recordSourceMicrophoneAndDevice;

  /// No description provided for @recordSourceDeviceAudio.
  ///
  /// In en, this message translates to:
  /// **'Device audio'**
  String get recordSourceDeviceAudio;

  /// No description provided for @recordSourceMicrophone.
  ///
  /// In en, this message translates to:
  /// **'Microphone'**
  String get recordSourceMicrophone;

  /// No description provided for @recordNoteTitle.
  ///
  /// In en, this message translates to:
  /// **'Add a note'**
  String get recordNoteTitle;

  /// No description provided for @recordNoteHint.
  ///
  /// In en, this message translates to:
  /// **'Names, context, decisions, or anything the transcript may miss…'**
  String get recordNoteHint;

  /// No description provided for @recordNoteSave.
  ///
  /// In en, this message translates to:
  /// **'Save note'**
  String get recordNoteSave;

  /// No description provided for @recordGreetingStillUp.
  ///
  /// In en, this message translates to:
  /// **'Still up'**
  String get recordGreetingStillUp;

  /// No description provided for @recordGreetingMorning.
  ///
  /// In en, this message translates to:
  /// **'Good morning'**
  String get recordGreetingMorning;

  /// No description provided for @recordGreetingAfternoon.
  ///
  /// In en, this message translates to:
  /// **'Good afternoon'**
  String get recordGreetingAfternoon;

  /// No description provided for @recordGreetingEvening.
  ///
  /// In en, this message translates to:
  /// **'Good evening'**
  String get recordGreetingEvening;

  /// No description provided for @recordDurationUnderMinute.
  ///
  /// In en, this message translates to:
  /// **'under a minute'**
  String get recordDurationUnderMinute;

  /// No description provided for @recordDurationMinutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String recordDurationMinutes(int minutes);

  /// No description provided for @recordStateLive.
  ///
  /// In en, this message translates to:
  /// **'LIVE'**
  String get recordStateLive;

  /// No description provided for @recordStateStandby.
  ///
  /// In en, this message translates to:
  /// **'STANDBY'**
  String get recordStateStandby;

  /// No description provided for @recordStateRecording.
  ///
  /// In en, this message translates to:
  /// **'Recording'**
  String get recordStateRecording;

  /// No description provided for @recordStateReady.
  ///
  /// In en, this message translates to:
  /// **'Ready to record'**
  String get recordStateReady;

  /// No description provided for @recordStateDeviceSync.
  ///
  /// In en, this message translates to:
  /// **'Recordings sync from the device'**
  String get recordStateDeviceSync;

  /// No description provided for @recordTodayLabel.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get recordTodayLabel;

  /// No description provided for @recordNothingToday.
  ///
  /// In en, this message translates to:
  /// **'Nothing recorded yet today.'**
  String get recordNothingToday;

  /// No description provided for @recordUntitledMoment.
  ///
  /// In en, this message translates to:
  /// **'Untitled moment'**
  String get recordUntitledMoment;

  /// No description provided for @recordSegmentCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 segment} other{{count} segments}}'**
  String recordSegmentCount(int count);

  /// No description provided for @recordAllMoments.
  ///
  /// In en, this message translates to:
  /// **'All moments →'**
  String get recordAllMoments;

  /// No description provided for @recordContextFootnote.
  ///
  /// In en, this message translates to:
  /// **'Add context as it happens. Every item is stored locally before it is synchronized.'**
  String get recordContextFootnote;

  /// No description provided for @recordInProgressTitle.
  ///
  /// In en, this message translates to:
  /// **'Recording in progress'**
  String get recordInProgressTitle;

  /// No description provided for @recordInProgressDescription.
  ///
  /// In en, this message translates to:
  /// **'Mark important moments and add notes, images, or documents without leaving the recording.'**
  String get recordInProgressDescription;

  /// No description provided for @recordContextTitle.
  ///
  /// In en, this message translates to:
  /// **'Recording context'**
  String get recordContextTitle;

  /// No description provided for @recordContextDescription.
  ///
  /// In en, this message translates to:
  /// **'These sources help NeoRecall understand what matters and improve the final memory.'**
  String get recordContextDescription;

  /// No description provided for @recordContextHighlight.
  ///
  /// In en, this message translates to:
  /// **'Highlight'**
  String get recordContextHighlight;

  /// No description provided for @recordContextNote.
  ///
  /// In en, this message translates to:
  /// **'Note'**
  String get recordContextNote;

  /// No description provided for @recordContextPhoto.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get recordContextPhoto;

  /// No description provided for @recordContextFile.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get recordContextFile;

  /// No description provided for @recordContextEmpty.
  ///
  /// In en, this message translates to:
  /// **'No context added yet.'**
  String get recordContextEmpty;

  /// No description provided for @recordDropTitle.
  ///
  /// In en, this message translates to:
  /// **'Drop to add context'**
  String get recordDropTitle;

  /// No description provided for @recordDropHint.
  ///
  /// In en, this message translates to:
  /// **'The file joins the running recording and helps shape the memory.'**
  String get recordDropHint;

  /// No description provided for @recordDropAdded.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 file added as context} other{{count} files added as context}}'**
  String recordDropAdded(int count);

  /// No description provided for @recordDropRejected.
  ///
  /// In en, this message translates to:
  /// **'{name}: {reason}'**
  String recordDropRejected(String name, String reason);

  /// No description provided for @recordDropUnreadable.
  ///
  /// In en, this message translates to:
  /// **'{name} could not be read. Drop single files, not folders.'**
  String recordDropUnreadable(String name);

  /// No description provided for @recordDropNoRecording.
  ///
  /// In en, this message translates to:
  /// **'The recording ended before the file arrived, so nothing was added.'**
  String get recordDropNoRecording;

  /// No description provided for @recordHighlightedMoment.
  ///
  /// In en, this message translates to:
  /// **'Highlighted moment'**
  String get recordHighlightedMoment;

  /// No description provided for @recordVisibleAndActive.
  ///
  /// In en, this message translates to:
  /// **'Recording is visible and active'**
  String get recordVisibleAndActive;

  /// No description provided for @recordMomentCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 moment} other{{count} moments}}'**
  String recordMomentCount(int count);

  /// No description provided for @securitySectionEyebrow.
  ///
  /// In en, this message translates to:
  /// **'SECURITY'**
  String get securitySectionEyebrow;

  /// No description provided for @securityTwoFactorTitle.
  ///
  /// In en, this message translates to:
  /// **'Two-factor authentication'**
  String get securityTwoFactorTitle;

  /// No description provided for @securityTwoFactorDescription.
  ///
  /// In en, this message translates to:
  /// **'Protect your account with an authenticator app.'**
  String get securityTwoFactorDescription;

  /// No description provided for @securityTwoFactorEnabled.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{2FA is enabled (1 recovery code remaining)} other{2FA is enabled ({count} recovery codes remaining)}}'**
  String securityTwoFactorEnabled(int count);

  /// No description provided for @securityDisableTwoFactor.
  ///
  /// In en, this message translates to:
  /// **'Disable 2FA'**
  String get securityDisableTwoFactor;

  /// No description provided for @securityRegenerateCodes.
  ///
  /// In en, this message translates to:
  /// **'Regenerate codes'**
  String get securityRegenerateCodes;

  /// No description provided for @securityTwoFactorDisabled.
  ///
  /// In en, this message translates to:
  /// **'2FA is not enabled'**
  String get securityTwoFactorDisabled;

  /// No description provided for @securityEnableTwoFactor.
  ///
  /// In en, this message translates to:
  /// **'Enable 2FA'**
  String get securityEnableTwoFactor;

  /// No description provided for @securityKeysEyebrow.
  ///
  /// In en, this message translates to:
  /// **'SECURITY KEYS'**
  String get securityKeysEyebrow;

  /// No description provided for @securityKeysTitle.
  ///
  /// In en, this message translates to:
  /// **'Security keys'**
  String get securityKeysTitle;

  /// No description provided for @securityKeysDescription.
  ///
  /// In en, this message translates to:
  /// **'Sign in with a hardware key or passkey instead of your password. A key that asks for a PIN or a fingerprint also replaces your two-factor code.'**
  String get securityKeysDescription;

  /// No description provided for @securityKeysNone.
  ///
  /// In en, this message translates to:
  /// **'No security keys registered.'**
  String get securityKeysNone;

  /// No description provided for @securityKeysAdd.
  ///
  /// In en, this message translates to:
  /// **'Add security key'**
  String get securityKeysAdd;

  /// No description provided for @securityKeysUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This device cannot register security keys. Open NeoRecall in a browser over HTTPS to add one.'**
  String get securityKeysUnsupported;

  /// No description provided for @securityKeyFallbackName.
  ///
  /// In en, this message translates to:
  /// **'Security key'**
  String get securityKeyFallbackName;

  /// No description provided for @securityKeyNeverUsed.
  ///
  /// In en, this message translates to:
  /// **'Never used'**
  String get securityKeyNeverUsed;

  /// No description provided for @securityKeyLastUsed.
  ///
  /// In en, this message translates to:
  /// **'Last used {date}'**
  String securityKeyLastUsed(String date);

  /// No description provided for @actionRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get actionRename;

  /// No description provided for @actionRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get actionRemove;

  /// No description provided for @securityYourUsername.
  ///
  /// In en, this message translates to:
  /// **'your username'**
  String get securityYourUsername;

  /// No description provided for @securityExportEyebrow.
  ///
  /// In en, this message translates to:
  /// **'YOUR DATA'**
  String get securityExportEyebrow;

  /// No description provided for @securityExportTitle.
  ///
  /// In en, this message translates to:
  /// **'Download a copy of your data'**
  String get securityExportTitle;

  /// No description provided for @securityExportDescription.
  ///
  /// In en, this message translates to:
  /// **'A zip of this account: transcripts, conversations, memories, summaries, notes, named speakers and settings. It does not include audio, voiceprints, other people, or server secrets.'**
  String get securityExportDescription;

  /// No description provided for @securityExportAction.
  ///
  /// In en, this message translates to:
  /// **'Download my data'**
  String get securityExportAction;

  /// No description provided for @securityExportSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved {name}'**
  String securityExportSaved(String name);

  /// No description provided for @securityEraseTitle.
  ///
  /// In en, this message translates to:
  /// **'Erase everything you have recorded'**
  String get securityEraseTitle;

  /// No description provided for @securityEraseIntro.
  ///
  /// In en, this message translates to:
  /// **'This empties your library but keeps your account. There is no undo and no backup you can ask to restore from.'**
  String get securityEraseIntro;

  /// No description provided for @securityEraseItem1.
  ///
  /// In en, this message translates to:
  /// **'Every recording, transcript and conversation'**
  String get securityEraseItem1;

  /// No description provided for @securityEraseItem2.
  ///
  /// In en, this message translates to:
  /// **'All memories, highlights and daily summaries'**
  String get securityEraseItem2;

  /// No description provided for @securityEraseItem3.
  ///
  /// In en, this message translates to:
  /// **'Named speakers and their voice profiles'**
  String get securityEraseItem3;

  /// No description provided for @securityEraseItem4.
  ///
  /// In en, this message translates to:
  /// **'Imported audio and anything still waiting to upload'**
  String get securityEraseItem4;

  /// No description provided for @securityKeptItem1.
  ///
  /// In en, this message translates to:
  /// **'Your account, password and security keys'**
  String get securityKeptItem1;

  /// No description provided for @securityKeptItem2.
  ///
  /// In en, this message translates to:
  /// **'Your settings and paired devices'**
  String get securityKeptItem2;

  /// No description provided for @securityEraseConfirm.
  ///
  /// In en, this message translates to:
  /// **'Erase my data'**
  String get securityEraseConfirm;

  /// No description provided for @securityErasedNotice.
  ///
  /// In en, this message translates to:
  /// **'Everything you had recorded was erased.'**
  String get securityErasedNotice;

  /// No description provided for @securityDeleteAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete your account'**
  String get securityDeleteAccountTitle;

  /// No description provided for @securityDeleteAccountIntro.
  ///
  /// In en, this message translates to:
  /// **'This removes everything, permanently, and closes the account. There is no undo and no backup you can ask to restore from.'**
  String get securityDeleteAccountIntro;

  /// No description provided for @securityDeleteItem1.
  ///
  /// In en, this message translates to:
  /// **'Every transcript, conversation and memory'**
  String get securityDeleteItem1;

  /// No description provided for @securityDeleteItem2.
  ///
  /// In en, this message translates to:
  /// **'Recordings still waiting to upload on this device'**
  String get securityDeleteItem2;

  /// No description provided for @securityDeleteItem3.
  ///
  /// In en, this message translates to:
  /// **'Connected devices, security keys and sign-in history'**
  String get securityDeleteItem3;

  /// No description provided for @securityDeleteItem4.
  ///
  /// In en, this message translates to:
  /// **'The account itself, and your ability to sign in'**
  String get securityDeleteItem4;

  /// No description provided for @securityDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete permanently'**
  String get securityDeleteConfirm;

  /// No description provided for @securityDeletedNotice.
  ///
  /// In en, this message translates to:
  /// **'Your account and all its data were deleted.'**
  String get securityDeletedNotice;

  /// No description provided for @securityDangerZone.
  ///
  /// In en, this message translates to:
  /// **'DANGER ZONE'**
  String get securityDangerZone;

  /// No description provided for @securityEraseCardDescription.
  ///
  /// In en, this message translates to:
  /// **'Empties your library — recordings, transcripts, memories, highlights and voice profiles — and keeps your account, settings and paired devices. This cannot be undone.'**
  String get securityEraseCardDescription;

  /// No description provided for @securityEraseCardAction.
  ///
  /// In en, this message translates to:
  /// **'Erase my data…'**
  String get securityEraseCardAction;

  /// No description provided for @securityDeleteCardDescription.
  ///
  /// In en, this message translates to:
  /// **'Removes everything above and closes the account itself, including your sign-in, security keys and connected devices. Nothing identifying you is kept. This cannot be undone.'**
  String get securityDeleteCardDescription;

  /// No description provided for @securityDeleteCardAction.
  ///
  /// In en, this message translates to:
  /// **'Delete account…'**
  String get securityDeleteCardAction;

  /// No description provided for @securityNameKeyTitle.
  ///
  /// In en, this message translates to:
  /// **'Name this key'**
  String get securityNameKeyTitle;

  /// No description provided for @securityNameKeyMessage.
  ///
  /// In en, this message translates to:
  /// **'Give the key a name you will recognise, for example \"YubiKey\".'**
  String get securityNameKeyMessage;

  /// No description provided for @securityKeyDefaultName.
  ///
  /// In en, this message translates to:
  /// **'Security key {number}'**
  String securityKeyDefaultName(int number);

  /// No description provided for @securityRenameKeyTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename security key'**
  String get securityRenameKeyTitle;

  /// No description provided for @securityRenameKeyMessage.
  ///
  /// In en, this message translates to:
  /// **'Enter a new name for \"{name}\".'**
  String securityRenameKeyMessage(String name);

  /// No description provided for @securityEnterPassword.
  ///
  /// In en, this message translates to:
  /// **'Enter password'**
  String get securityEnterPassword;

  /// No description provided for @securityPasswordForDisable.
  ///
  /// In en, this message translates to:
  /// **'Your current password is required to disable 2FA'**
  String get securityPasswordForDisable;

  /// No description provided for @securityPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'Your current password is required.'**
  String get securityPasswordRequired;

  /// No description provided for @securityEnterTwoFactorCode.
  ///
  /// In en, this message translates to:
  /// **'Enter 2FA code'**
  String get securityEnterTwoFactorCode;

  /// No description provided for @securityEnterAuthenticatorCode.
  ///
  /// In en, this message translates to:
  /// **'Enter your current authenticator code.'**
  String get securityEnterAuthenticatorCode;

  /// No description provided for @securityScanQr.
  ///
  /// In en, this message translates to:
  /// **'Scan this QR code in your authenticator app.'**
  String get securityScanQr;

  /// No description provided for @securityAuthenticatorCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Authenticator code'**
  String get securityAuthenticatorCodeLabel;

  /// No description provided for @actionVerify.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get actionVerify;

  /// No description provided for @securityRecoveryCodesTitle.
  ///
  /// In en, this message translates to:
  /// **'Recovery Codes'**
  String get securityRecoveryCodesTitle;

  /// No description provided for @securityRecoveryCodesBody.
  ///
  /// In en, this message translates to:
  /// **'Save these codes in a secure place. They are shown only once.'**
  String get securityRecoveryCodesBody;

  /// No description provided for @destructiveYourPassword.
  ///
  /// In en, this message translates to:
  /// **'Your password'**
  String get destructiveYourPassword;

  /// No description provided for @destructiveCodeHelper.
  ///
  /// In en, this message translates to:
  /// **'A current code, or one of your recovery codes.'**
  String get destructiveCodeHelper;

  /// No description provided for @destructiveTypeToConfirm.
  ///
  /// In en, this message translates to:
  /// **'Type {username} to confirm'**
  String destructiveTypeToConfirm(String username);

  /// No description provided for @integrationsMcpEyebrow.
  ///
  /// In en, this message translates to:
  /// **'MCP'**
  String get integrationsMcpEyebrow;

  /// No description provided for @integrationsMcpTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect Claude, ChatGPT, or Cursor'**
  String get integrationsMcpTitle;

  /// No description provided for @integrationsMcpDescription.
  ///
  /// In en, this message translates to:
  /// **'Paste this MCP URL into Claude, ChatGPT (MCP), or Cursor. The client opens NeoRecall for sign-in and the same read-only consent as NeoAgent. Ask, ingest, and memory edits stay inside NeoRecall.'**
  String get integrationsMcpDescription;

  /// No description provided for @integrationsMcpCopied.
  ///
  /// In en, this message translates to:
  /// **'MCP URL copied'**
  String get integrationsMcpCopied;

  /// No description provided for @integrationsMcpCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy MCP URL'**
  String get integrationsMcpCopy;

  /// No description provided for @integrationsConnectedEyebrow.
  ///
  /// In en, this message translates to:
  /// **'CONNECTED APPS'**
  String get integrationsConnectedEyebrow;

  /// No description provided for @integrationsNoneConnected.
  ///
  /// In en, this message translates to:
  /// **'No apps are connected yet. After you authorize NeoAgent or an MCP client, it appears here so you can revoke it.'**
  String get integrationsNoneConnected;

  /// No description provided for @integrationsConnectedApp.
  ///
  /// In en, this message translates to:
  /// **'Connected app'**
  String get integrationsConnectedApp;

  /// No description provided for @integrationsRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get integrationsRevoke;

  /// No description provided for @integrationsClientNeoAgent.
  ///
  /// In en, this message translates to:
  /// **'NeoAgent'**
  String get integrationsClientNeoAgent;

  /// No description provided for @integrationsClientMcp.
  ///
  /// In en, this message translates to:
  /// **'MCP client'**
  String get integrationsClientMcp;

  /// No description provided for @integrationsClientOAuth.
  ///
  /// In en, this message translates to:
  /// **'OAuth client'**
  String get integrationsClientOAuth;

  /// No description provided for @integrationsThisApp.
  ///
  /// In en, this message translates to:
  /// **'this app'**
  String get integrationsThisApp;

  /// No description provided for @integrationsRevokeTitle.
  ///
  /// In en, this message translates to:
  /// **'Revoke access?'**
  String get integrationsRevokeTitle;

  /// No description provided for @integrationsRevokeBody.
  ///
  /// In en, this message translates to:
  /// **'{name} will lose read-only access to this account until you connect it again.'**
  String integrationsRevokeBody(String name);

  /// No description provided for @cloudNextcloudEyebrow.
  ///
  /// In en, this message translates to:
  /// **'NEXTCLOUD'**
  String get cloudNextcloudEyebrow;

  /// No description provided for @cloudNextcloudTitle.
  ///
  /// In en, this message translates to:
  /// **'Back up to your Nextcloud'**
  String get cloudNextcloudTitle;

  /// No description provided for @cloudNextcloudDescription.
  ///
  /// In en, this message translates to:
  /// **'Connect a self-hosted Nextcloud instance. NeoRecall can copy your recordings and a dump of this account there. Copies only go out — nothing is read back or restored from Nextcloud.'**
  String get cloudNextcloudDescription;

  /// No description provided for @cloudInstanceUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Nextcloud URL'**
  String get cloudInstanceUrlLabel;

  /// No description provided for @cloudInstanceUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://cloud.example.com'**
  String get cloudInstanceUrlHint;

  /// No description provided for @cloudSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in with Nextcloud'**
  String get cloudSignIn;

  /// No description provided for @cloudWaiting.
  ///
  /// In en, this message translates to:
  /// **'Finish signing in in the browser. This screen updates when Nextcloud issues an app password.'**
  String get cloudWaiting;

  /// No description provided for @cloudOpenLogin.
  ///
  /// In en, this message translates to:
  /// **'Open login page'**
  String get cloudOpenLogin;

  /// No description provided for @cloudAudioTitle.
  ///
  /// In en, this message translates to:
  /// **'Copy recordings'**
  String get cloudAudioTitle;

  /// No description provided for @cloudAudioDescription.
  ///
  /// In en, this message translates to:
  /// **'When a recording ends, upload one audio file to Nextcloud. NeoRecall still deletes its own copies.'**
  String get cloudAudioDescription;

  /// No description provided for @cloudDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Back up this account'**
  String get cloudDataTitle;

  /// No description provided for @cloudDataDescription.
  ///
  /// In en, this message translates to:
  /// **'Periodically upload transcripts, memories, summaries and settings for this account only.'**
  String get cloudDataDescription;

  /// No description provided for @cloudBackupNow.
  ///
  /// In en, this message translates to:
  /// **'Back up now'**
  String get cloudBackupNow;

  /// No description provided for @cloudBackupQueued.
  ///
  /// In en, this message translates to:
  /// **'Backup queued'**
  String get cloudBackupQueued;

  /// No description provided for @cloudDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get cloudDisconnect;

  /// No description provided for @cloudDisconnectTitle.
  ///
  /// In en, this message translates to:
  /// **'Disconnect Nextcloud?'**
  String get cloudDisconnectTitle;

  /// No description provided for @cloudDisconnectBody.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall will forget this instance and stop uploading. Files already copied to Nextcloud are left in place.'**
  String get cloudDisconnectBody;

  /// No description provided for @cloudLastAudio.
  ///
  /// In en, this message translates to:
  /// **'Last audio copy: {when}'**
  String cloudLastAudio(String when);

  /// No description provided for @cloudLastData.
  ///
  /// In en, this message translates to:
  /// **'Last data backup: {when}'**
  String cloudLastData(String when);

  /// No description provided for @cloudNever.
  ///
  /// In en, this message translates to:
  /// **'never'**
  String get cloudNever;

  /// No description provided for @memoriesSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search memories…'**
  String get memoriesSearchHint;

  /// No description provided for @memoriesFilterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get memoriesFilterAll;

  /// No description provided for @memoriesFilterPinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get memoriesFilterPinned;

  /// No description provided for @memoriesFilterThisWeek.
  ///
  /// In en, this message translates to:
  /// **'This week'**
  String get memoriesFilterThisWeek;

  /// No description provided for @memoriesFilterMeetings.
  ///
  /// In en, this message translates to:
  /// **'Meetings'**
  String get memoriesFilterMeetings;

  /// No description provided for @memoriesFilterDecisions.
  ///
  /// In en, this message translates to:
  /// **'Decisions'**
  String get memoriesFilterDecisions;

  /// No description provided for @memoriesFilterOpenTasks.
  ///
  /// In en, this message translates to:
  /// **'Open tasks'**
  String get memoriesFilterOpenTasks;

  /// No description provided for @memoriesFilterOpenTasksCount.
  ///
  /// In en, this message translates to:
  /// **'Open tasks ({count})'**
  String memoriesFilterOpenTasksCount(int count);

  /// No description provided for @memoriesFilterArchived.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get memoriesFilterArchived;

  /// No description provided for @memoriesSelectPrompt.
  ///
  /// In en, this message translates to:
  /// **'Select memories'**
  String get memoriesSelectPrompt;

  /// No description provided for @memoriesSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String memoriesSelectedCount(int count);

  /// No description provided for @memoriesMergeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Merge'**
  String get memoriesMergeTooltip;

  /// No description provided for @memoriesPin.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get memoriesPin;

  /// No description provided for @memoriesUnpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get memoriesUnpin;

  /// No description provided for @memoriesTodaysStory.
  ///
  /// In en, this message translates to:
  /// **'Today’s story'**
  String get memoriesTodaysStory;

  /// No description provided for @memoriesAllHighlights.
  ///
  /// In en, this message translates to:
  /// **'All highlights'**
  String get memoriesAllHighlights;

  /// No description provided for @memoriesDue.
  ///
  /// In en, this message translates to:
  /// **'Due {date}'**
  String memoriesDue(String date);

  /// No description provided for @memoriesReopen.
  ///
  /// In en, this message translates to:
  /// **'Reopen'**
  String get memoriesReopen;

  /// No description provided for @memoriesMarkDone.
  ///
  /// In en, this message translates to:
  /// **'Mark done'**
  String get memoriesMarkDone;

  /// No description provided for @memoryContextDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Add memory context'**
  String get memoryContextDialogTitle;

  /// No description provided for @memoryContextDialogHint.
  ///
  /// In en, this message translates to:
  /// **'Add details that should improve this memory…'**
  String get memoryContextDialogHint;

  /// No description provided for @memoryContextDialogConfirm.
  ///
  /// In en, this message translates to:
  /// **'Add and update'**
  String get memoryContextDialogConfirm;

  /// No description provided for @memoryDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete memory?'**
  String get memoryDeleteTitle;

  /// No description provided for @memoryDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'This removes the memory and its highlights. Transcripts stay available on the timeline.'**
  String get memoryDeleteBody;

  /// No description provided for @memoryLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load details.\n{error}'**
  String memoryLoadFailed(String error);

  /// No description provided for @memoryPeopleAndThings.
  ///
  /// In en, this message translates to:
  /// **'People & things'**
  String get memoryPeopleAndThings;

  /// No description provided for @memoryEntityUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get memoryEntityUnknown;

  /// No description provided for @memoryContextHeading.
  ///
  /// In en, this message translates to:
  /// **'Context'**
  String get memoryContextHeading;

  /// No description provided for @memoryNoContext.
  ///
  /// In en, this message translates to:
  /// **'No notes or files are attached to this memory.'**
  String get memoryNoContext;

  /// No description provided for @memoryContextUsedByAi.
  ///
  /// In en, this message translates to:
  /// **'Used by AI'**
  String get memoryContextUsedByAi;

  /// No description provided for @memoryContextReadyForAi.
  ///
  /// In en, this message translates to:
  /// **'Ready for AI'**
  String get memoryContextReadyForAi;

  /// No description provided for @memoryContextRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry analysis'**
  String get memoryContextRetry;

  /// No description provided for @memoryContextRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove context'**
  String get memoryContextRemove;

  /// No description provided for @memoryFromConversation.
  ///
  /// In en, this message translates to:
  /// **'From the conversation'**
  String get memoryFromConversation;

  /// No description provided for @miniLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load highlight.\n{error}'**
  String miniLoadFailed(String error);

  /// No description provided for @miniFromMemory.
  ///
  /// In en, this message translates to:
  /// **'From {emoji} {title}'**
  String miniFromMemory(String emoji, String title);

  /// No description provided for @miniEvidence.
  ///
  /// In en, this message translates to:
  /// **'Evidence'**
  String get miniEvidence;

  /// No description provided for @miniNoExcerpts.
  ///
  /// In en, this message translates to:
  /// **'No transcript excerpts linked.'**
  String get miniNoExcerpts;

  /// No description provided for @processingEtaUnderMinute.
  ///
  /// In en, this message translates to:
  /// **'under a minute'**
  String get processingEtaUnderMinute;

  /// No description provided for @processingEtaMinutes.
  ///
  /// In en, this message translates to:
  /// **'about {minutes} min'**
  String processingEtaMinutes(int minutes);

  /// No description provided for @processingEtaHours.
  ///
  /// In en, this message translates to:
  /// **'about {hours} hr'**
  String processingEtaHours(int hours);

  /// No description provided for @processingEtaHoursMinutes.
  ///
  /// In en, this message translates to:
  /// **'about {hours} hr {minutes} min'**
  String processingEtaHoursMinutes(int hours, int minutes);

  /// No description provided for @processingNeedsAttention.
  ///
  /// In en, this message translates to:
  /// **'Processing needs attention'**
  String get processingNeedsAttention;

  /// No description provided for @processingStageWatchTransfer.
  ///
  /// In en, this message translates to:
  /// **'Downloading from device'**
  String get processingStageWatchTransfer;

  /// No description provided for @processingStagePhoneQueue.
  ///
  /// In en, this message translates to:
  /// **'Queued securely on this device'**
  String get processingStagePhoneQueue;

  /// No description provided for @processingStageUpload.
  ///
  /// In en, this message translates to:
  /// **'Uploading to server'**
  String get processingStageUpload;

  /// No description provided for @processingStageServerQueue.
  ///
  /// In en, this message translates to:
  /// **'Waiting in transcription queue'**
  String get processingStageServerQueue;

  /// No description provided for @processingStageTranscription.
  ///
  /// In en, this message translates to:
  /// **'Transcribing on server'**
  String get processingStageTranscription;

  /// No description provided for @processingStageFinalizing.
  ///
  /// In en, this message translates to:
  /// **'Finalizing secure receipts'**
  String get processingStageFinalizing;

  /// No description provided for @processingStageComplete.
  ///
  /// In en, this message translates to:
  /// **'Everything is processed'**
  String get processingStageComplete;

  /// No description provided for @processingWatchAudioWaiting.
  ///
  /// In en, this message translates to:
  /// **'{duration} of audio waiting'**
  String processingWatchAudioWaiting(String duration);

  /// No description provided for @processingWatchReceiving.
  ///
  /// In en, this message translates to:
  /// **'Receiving encrypted audio'**
  String get processingWatchReceiving;

  /// No description provided for @processingWatchItemsWaiting.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item waiting} other{{count} items waiting}}'**
  String processingWatchItemsWaiting(int count);

  /// No description provided for @processingWatchNoBacklog.
  ///
  /// In en, this message translates to:
  /// **'No device backlog'**
  String get processingWatchNoBacklog;

  /// No description provided for @processingStepDeviceTransfer.
  ///
  /// In en, this message translates to:
  /// **'Device transfer'**
  String get processingStepDeviceTransfer;

  /// No description provided for @processingStepStoredOnPhone.
  ///
  /// In en, this message translates to:
  /// **'Stored on phone'**
  String get processingStepStoredOnPhone;

  /// No description provided for @processingNoLocalQueue.
  ///
  /// In en, this message translates to:
  /// **'No recordings waiting locally'**
  String get processingNoLocalQueue;

  /// No description provided for @processingReadyForUpload.
  ///
  /// In en, this message translates to:
  /// **'{count} ready for upload'**
  String processingReadyForUpload(int count);

  /// No description provided for @processingStepServerUpload.
  ///
  /// In en, this message translates to:
  /// **'Server upload'**
  String get processingStepServerUpload;

  /// No description provided for @processingNoUploadInFlight.
  ///
  /// In en, this message translates to:
  /// **'No upload currently in flight'**
  String get processingNoUploadInFlight;

  /// No description provided for @processingUploadingNow.
  ///
  /// In en, this message translates to:
  /// **'{count} uploading now'**
  String processingUploadingNow(int count);

  /// No description provided for @processingStepServerTranscription.
  ///
  /// In en, this message translates to:
  /// **'Server transcription'**
  String get processingStepServerTranscription;

  /// No description provided for @processingTranscribingQueued.
  ///
  /// In en, this message translates to:
  /// **'{transcribing} transcribing · {queued} queued'**
  String processingTranscribingQueued(int transcribing, int queued);

  /// No description provided for @processingWaitingForWorker.
  ///
  /// In en, this message translates to:
  /// **'{count} waiting for a worker'**
  String processingWaitingForWorker(int count);

  /// No description provided for @processingServerQueueClear.
  ///
  /// In en, this message translates to:
  /// **'Server queue is clear'**
  String get processingServerQueueClear;

  /// No description provided for @processingStepSafeCompletion.
  ///
  /// In en, this message translates to:
  /// **'Safe completion'**
  String get processingStepSafeCompletion;

  /// No description provided for @processingTranscriptPersisted.
  ///
  /// In en, this message translates to:
  /// **'Transcript persisted; audio released'**
  String get processingTranscriptPersisted;

  /// No description provided for @processingVerifying.
  ///
  /// In en, this message translates to:
  /// **'{count} verifying persistence and deletion'**
  String processingVerifying(int count);

  /// No description provided for @processingWaitingEarlierStages.
  ///
  /// In en, this message translates to:
  /// **'Waiting for earlier stages'**
  String get processingWaitingEarlierStages;

  /// No description provided for @processingPendingCount.
  ///
  /// In en, this message translates to:
  /// **'{count} pending'**
  String processingPendingCount(int count);

  /// No description provided for @processingMbProtected.
  ///
  /// In en, this message translates to:
  /// **'{size} MB protected'**
  String processingMbProtected(String size);

  /// No description provided for @processingEtaPrefix.
  ///
  /// In en, this message translates to:
  /// **'ETA {eta}'**
  String processingEtaPrefix(String eta);

  /// No description provided for @processingEtaCalibrating.
  ///
  /// In en, this message translates to:
  /// **'ETA calibrating'**
  String get processingEtaCalibrating;

  /// No description provided for @processingUploadOnMobileData.
  ///
  /// In en, this message translates to:
  /// **'Upload once with mobile data'**
  String get processingUploadOnMobileData;

  /// No description provided for @processingReviewQueued.
  ///
  /// In en, this message translates to:
  /// **'Review queued audio'**
  String get processingReviewQueued;

  /// No description provided for @processingRetryFailed.
  ///
  /// In en, this message translates to:
  /// **'Retry failed'**
  String get processingRetryFailed;

  /// No description provided for @processingSomethingNeedsAttention.
  ///
  /// In en, this message translates to:
  /// **'Something needs attention'**
  String get processingSomethingNeedsAttention;

  /// No description provided for @processingStillWorking.
  ///
  /// In en, this message translates to:
  /// **'Still working on it'**
  String get processingStillWorking;

  /// No description provided for @processingDeviceHolding.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Your device is still holding 1 recording, so nothing has been lost.} other{Your device is still holding {count} recordings, so nothing has been lost.}}'**
  String processingDeviceHolding(int count);

  /// No description provided for @processingUnderMinuteLeft.
  ///
  /// In en, this message translates to:
  /// **'under a minute left'**
  String get processingUnderMinuteLeft;

  /// No description provided for @processingGettingAudio.
  ///
  /// In en, this message translates to:
  /// **'Getting audio from your device'**
  String get processingGettingAudio;

  /// No description provided for @processingUploadingCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Uploading a recording} other{Uploading {count} recordings}}'**
  String processingUploadingCount(int count);

  /// No description provided for @processingTranscribingCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Transcribing a recording} other{Transcribing {count} recordings}}'**
  String processingTranscribingCount(int count);

  /// No description provided for @processingEtaMinutesLeft.
  ///
  /// In en, this message translates to:
  /// **'about {minutes} min left'**
  String processingEtaMinutesLeft(int minutes);

  /// No description provided for @processingEtaHoursLeft.
  ///
  /// In en, this message translates to:
  /// **'about {hours} hr left'**
  String processingEtaHoursLeft(int hours);

  /// No description provided for @processingEtaHoursMinutesLeft.
  ///
  /// In en, this message translates to:
  /// **'about {hours} hr {minutes} min left'**
  String processingEtaHoursMinutesLeft(int hours, int minutes);

  /// No description provided for @deviceAddDevice.
  ///
  /// In en, this message translates to:
  /// **'Add device'**
  String get deviceAddDevice;

  /// No description provided for @deviceConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get deviceConnected;

  /// No description provided for @deviceNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get deviceNotConnected;

  /// No description provided for @deviceAddDeviceSemantics.
  ///
  /// In en, this message translates to:
  /// **'Add a device'**
  String get deviceAddDeviceSemantics;

  /// No description provided for @deviceManageSemantics.
  ///
  /// In en, this message translates to:
  /// **'Manage {label}'**
  String deviceManageSemantics(String label);

  /// No description provided for @deviceNoneTitle.
  ///
  /// In en, this message translates to:
  /// **'No device yet'**
  String get deviceNoneTitle;

  /// No description provided for @deviceNoneBody.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall records with the phone microphone until you connect a wearable or set up a Desk.'**
  String get deviceNoneBody;

  /// No description provided for @deviceScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning…'**
  String get deviceScanning;

  /// No description provided for @deviceScanForWearables.
  ///
  /// In en, this message translates to:
  /// **'Scan for wearables'**
  String get deviceScanForWearables;

  /// No description provided for @deviceSetUpDesk.
  ///
  /// In en, this message translates to:
  /// **'Set up a NeoRecall Desk'**
  String get deviceSetUpDesk;

  /// No description provided for @deviceRemembered.
  ///
  /// In en, this message translates to:
  /// **'Remembered — not connected right now'**
  String get deviceRemembered;

  /// No description provided for @deviceStatBattery.
  ///
  /// In en, this message translates to:
  /// **'Battery'**
  String get deviceStatBattery;

  /// No description provided for @deviceStatSynced.
  ///
  /// In en, this message translates to:
  /// **'Synced'**
  String get deviceStatSynced;

  /// No description provided for @deviceStatSyncedUnit.
  ///
  /// In en, this message translates to:
  /// **'recordings'**
  String get deviceStatSyncedUnit;

  /// No description provided for @deviceStatLeft.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get deviceStatLeft;

  /// No description provided for @deviceStatQueued.
  ///
  /// In en, this message translates to:
  /// **'queued'**
  String get deviceStatQueued;

  /// No description provided for @deviceOfflineFirstStreams.
  ///
  /// In en, this message translates to:
  /// **'This device can record on its own as well. Anything it captured while you were away syncs here when it connects, or you can pull it now.'**
  String get deviceOfflineFirstStreams;

  /// No description provided for @deviceOfflineFirstOnly.
  ///
  /// In en, this message translates to:
  /// **'This device records on its own — press record and stop on the device itself. Recordings sync here when it connects, or you can pull them now.'**
  String get deviceOfflineFirstOnly;

  /// No description provided for @deviceStranded.
  ///
  /// In en, this message translates to:
  /// **'The device has recordings but no Wi-Fi. They can move to this phone over Bluetooth and upload from here later.'**
  String get deviceStranded;

  /// No description provided for @deviceMovingRecordings.
  ///
  /// In en, this message translates to:
  /// **'Moving recordings…'**
  String get deviceMovingRecordings;

  /// No description provided for @deviceMoveRecordings.
  ///
  /// In en, this message translates to:
  /// **'Move recordings to this phone'**
  String get deviceMoveRecordings;

  /// No description provided for @deviceScanAnother.
  ///
  /// In en, this message translates to:
  /// **'Scan for another wearable'**
  String get deviceScanAnother;

  /// No description provided for @deviceDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Device and sync diagnostics'**
  String get deviceDiagnostics;

  /// No description provided for @deviceForget.
  ///
  /// In en, this message translates to:
  /// **'Forget this device'**
  String get deviceForget;

  /// No description provided for @sourceRecordFrom.
  ///
  /// In en, this message translates to:
  /// **'Record from'**
  String get sourceRecordFrom;

  /// No description provided for @sourceLockedWhileRecording.
  ///
  /// In en, this message translates to:
  /// **'The source is locked while a recording is running.'**
  String get sourceLockedWhileRecording;

  /// No description provided for @sourceOneAtATime.
  ///
  /// In en, this message translates to:
  /// **'Only one source records at a time. The choice sticks until you change it.'**
  String get sourceOneAtATime;

  /// No description provided for @sourceThisComputer.
  ///
  /// In en, this message translates to:
  /// **'This computer'**
  String get sourceThisComputer;

  /// No description provided for @sourcePhoneSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Always available, nothing to connect'**
  String get sourcePhoneSubtitle;

  /// No description provided for @sourceComputerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Microphone, and system audio if you want it'**
  String get sourceComputerSubtitle;

  /// No description provided for @sourceDeviceAudioDesktop.
  ///
  /// In en, this message translates to:
  /// **'Device audio — everything this machine plays'**
  String get sourceDeviceAudioDesktop;

  /// No description provided for @sourceTabOrSystemAudio.
  ///
  /// In en, this message translates to:
  /// **'Tab or system audio'**
  String get sourceTabOrSystemAudio;

  /// No description provided for @sourceNoWearable.
  ///
  /// In en, this message translates to:
  /// **'No wearable connected yet'**
  String get sourceNoWearable;

  /// No description provided for @sourceConnectedWithBattery.
  ///
  /// In en, this message translates to:
  /// **'Connected · {battery}%'**
  String sourceConnectedWithBattery(Object battery);

  /// No description provided for @sourceScan.
  ///
  /// In en, this message translates to:
  /// **'Scan'**
  String get sourceScan;

  /// No description provided for @sourceDeskNotSetUp.
  ///
  /// In en, this message translates to:
  /// **'Not set up'**
  String get sourceDeskNotSetUp;

  /// No description provided for @sourceSetUp.
  ///
  /// In en, this message translates to:
  /// **'Set up'**
  String get sourceSetUp;

  /// No description provided for @sourceDeskSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Records the room on its own'**
  String get sourceDeskSubtitle;

  /// No description provided for @sourceFoundNearby.
  ///
  /// In en, this message translates to:
  /// **'Found nearby'**
  String get sourceFoundNearby;

  /// No description provided for @sourceReadyForAudio.
  ///
  /// In en, this message translates to:
  /// **'{type} · ready for audio'**
  String sourceReadyForAudio(String type);

  /// No description provided for @sourceWearableFallback.
  ///
  /// In en, this message translates to:
  /// **'wearable'**
  String get sourceWearableFallback;

  /// No description provided for @sourceReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get sourceReconnect;

  /// No description provided for @sourceConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get sourceConnect;

  /// No description provided for @sourceImportAudio.
  ///
  /// In en, this message translates to:
  /// **'Import an audio file'**
  String get sourceImportAudio;

  /// No description provided for @sourceConsentNote.
  ///
  /// In en, this message translates to:
  /// **'Recording privately spoken words may require everyone’s consent. NeoRecall never hides that it is recording.'**
  String get sourceConsentNote;

  /// No description provided for @sourceWebBluetoothNote.
  ///
  /// In en, this message translates to:
  /// **'The browser opens its own Bluetooth chooser, and capture continues only while this tab stays active.'**
  String get sourceWebBluetoothNote;

  /// No description provided for @libraryTitle.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get libraryTitle;

  /// No description provided for @floatingConsentTitle.
  ///
  /// In en, this message translates to:
  /// **'Before you record'**
  String get floatingConsentTitle;

  /// No description provided for @floatingOpenLibrary.
  ///
  /// In en, this message translates to:
  /// **'Open library'**
  String get floatingOpenLibrary;

  /// No description provided for @floatingHide.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get floatingHide;

  /// No description provided for @devicesEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No devices yet'**
  String get devicesEmptyTitle;

  /// No description provided for @devicesEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Apps appear here after their first recording. A NeoRecall Desk appears once you set it up.'**
  String get devicesEmptyMessage;

  /// No description provided for @devicesAddDesk.
  ///
  /// In en, this message translates to:
  /// **'Add a NeoRecall Desk'**
  String get devicesAddDesk;

  /// No description provided for @devicesRevoked.
  ///
  /// In en, this message translates to:
  /// **'REVOKED'**
  String get devicesRevoked;

  /// No description provided for @devicesNotRecentlyConnected.
  ///
  /// In en, this message translates to:
  /// **'not recently connected'**
  String get devicesNotRecentlyConnected;

  /// No description provided for @devicesClockOffset.
  ///
  /// In en, this message translates to:
  /// **'Device clock differs by more than two minutes'**
  String get devicesClockOffset;

  /// No description provided for @devicesRevokeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Revoke device'**
  String get devicesRevokeTooltip;

  /// No description provided for @pendingAudioTitle.
  ///
  /// In en, this message translates to:
  /// **'Review queued audio'**
  String get pendingAudioTitle;

  /// No description provided for @pendingAudioSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Local playback only · upload continues normally'**
  String get pendingAudioSubtitle;

  /// No description provided for @actionClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get actionClose;

  /// No description provided for @audioHeadphonesWarning.
  ///
  /// In en, this message translates to:
  /// **'Recording is active. Use headphones to avoid recording the playback again.'**
  String get audioHeadphonesWarning;

  /// No description provided for @actionRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get actionRefresh;

  /// No description provided for @pendingAudioEmpty.
  ///
  /// In en, this message translates to:
  /// **'No retained audio is currently available to review.'**
  String get pendingAudioEmpty;

  /// No description provided for @actionPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get actionPause;

  /// No description provided for @actionPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get actionPlay;

  /// No description provided for @diagnosticsCopied.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic report copied.'**
  String get diagnosticsCopied;

  /// No description provided for @diagnosticsCleared.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic log cleared.'**
  String get diagnosticsCleared;

  /// No description provided for @diagnosticsTitle.
  ///
  /// In en, this message translates to:
  /// **'Device & sync diagnostics'**
  String get diagnosticsTitle;

  /// No description provided for @diagnosticsDescription.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth scan/connect, device sync, and import events for this account. Passwords, tokens, audio, transcripts, and other accounts are never included.'**
  String get diagnosticsDescription;

  /// No description provided for @diagnosticsPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing…'**
  String get diagnosticsPreparing;

  /// No description provided for @diagnosticsCopyReport.
  ///
  /// In en, this message translates to:
  /// **'Copy full report'**
  String get diagnosticsCopyReport;

  /// No description provided for @diagnosticsClearLog.
  ///
  /// In en, this message translates to:
  /// **'Clear log'**
  String get diagnosticsClearLog;

  /// No description provided for @diagnosticsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No diagnostic events yet. Connect a device and sync to populate this log, then refresh.'**
  String get diagnosticsEmpty;

  /// No description provided for @trayQuickCapture.
  ///
  /// In en, this message translates to:
  /// **'Quick capture'**
  String get trayQuickCapture;

  /// No description provided for @trayOpenLibrary.
  ///
  /// In en, this message translates to:
  /// **'Open notes library'**
  String get trayOpenLibrary;

  /// No description provided for @trayStopRecording.
  ///
  /// In en, this message translates to:
  /// **'Stop recording'**
  String get trayStopRecording;

  /// No description provided for @trayQuit.
  ///
  /// In en, this message translates to:
  /// **'Quit'**
  String get trayQuit;

  /// No description provided for @audioBack10.
  ///
  /// In en, this message translates to:
  /// **'Back 10 seconds'**
  String get audioBack10;

  /// No description provided for @audioForward10.
  ///
  /// In en, this message translates to:
  /// **'Forward 10 seconds'**
  String get audioForward10;

  /// No description provided for @importChooseAudio.
  ///
  /// In en, this message translates to:
  /// **'Choose audio'**
  String get importChooseAudio;

  /// No description provided for @importTitle.
  ///
  /// In en, this message translates to:
  /// **'Import existing audio'**
  String get importTitle;

  /// No description provided for @importDescription.
  ///
  /// In en, this message translates to:
  /// **'WAV, MP3, M4A, and other ffmpeg-supported formats use the same private transcription pipeline.'**
  String get importDescription;

  /// No description provided for @syncTransferringProgress.
  ///
  /// In en, this message translates to:
  /// **'Transferring {percent}% · {remaining} left'**
  String syncTransferringProgress(int percent, String remaining);

  /// No description provided for @syncTransferring.
  ///
  /// In en, this message translates to:
  /// **'Transferring from the device…'**
  String get syncTransferring;

  /// No description provided for @syncWaitingOnDevice.
  ///
  /// In en, this message translates to:
  /// **'{duration} waiting on the device'**
  String syncWaitingOnDevice(String duration);

  /// No description provided for @syncSyncedCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 recording synced} other{{count} recordings synced}}'**
  String syncSyncedCount(int count);

  /// No description provided for @floatingConsentBody.
  ///
  /// In en, this message translates to:
  /// **'Tell everyone that NeoRecall is recording and make sure you are allowed to capture the conversation. Recording is always visibly indicated.'**
  String get floatingConsentBody;

  /// No description provided for @sourcesLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load sources: {error}'**
  String sourcesLoadFailed(String error);

  /// No description provided for @sourcesUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to update: {error}'**
  String sourcesUpdateFailed(String error);

  /// No description provided for @sourcesDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get sourcesDisconnect;

  /// No description provided for @sourcesDisconnectBody.
  ///
  /// In en, this message translates to:
  /// **'Stop this source? Existing transcripts stay in NeoRecall.'**
  String get sourcesDisconnectBody;

  /// No description provided for @sourcesDisconnectFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to disconnect: {error}'**
  String sourcesDisconnectFailed(String error);

  /// No description provided for @sourcesDescription.
  ///
  /// In en, this message translates to:
  /// **'Services that can feed NeoRecall audio. Wearables and a NeoRecall Desk are set up from Record.'**
  String get sourcesDescription;

  /// No description provided for @sourcesLiveCapture.
  ///
  /// In en, this message translates to:
  /// **'Live capture'**
  String get sourcesLiveCapture;

  /// No description provided for @sourcesEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing to connect yet'**
  String get sourcesEmptyTitle;

  /// No description provided for @sourcesEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Live sources appear here as they become available for your account.'**
  String get sourcesEmptyMessage;

  /// No description provided for @sourcesLastSynced.
  ///
  /// In en, this message translates to:
  /// **'Last synced {when}'**
  String sourcesLastSynced(String when);

  /// No description provided for @sourcesHowItWorks.
  ///
  /// In en, this message translates to:
  /// **'How it works'**
  String get sourcesHowItWorks;

  /// No description provided for @sourcesOauthNote.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall imports cloud recordings after the platform finishes them — it does not join the live call.'**
  String get sourcesOauthNote;

  /// No description provided for @sourcesJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get sourcesJustNow;

  /// No description provided for @sourcesMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{minutes}m ago'**
  String sourcesMinutesAgo(int minutes);

  /// No description provided for @sourcesHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{hours}h ago'**
  String sourcesHoursAgo(int hours);

  /// No description provided for @sourcesSyncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get sourcesSyncNow;

  /// No description provided for @sourceStatusConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get sourceStatusConnected;

  /// No description provided for @sourceStatusError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get sourceStatusError;

  /// No description provided for @sourceStatusNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Not configured'**
  String get sourceStatusNotConfigured;

  /// No description provided for @sourceStatusPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get sourceStatusPaused;

  /// No description provided for @discordDefaultName.
  ///
  /// In en, this message translates to:
  /// **'My Discord Bot'**
  String get discordDefaultName;

  /// No description provided for @discordError.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String discordError(String error);

  /// No description provided for @discordTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect Discord'**
  String get discordTitle;

  /// No description provided for @discordDescription.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall joins voice channels as a bot and records the people you list. Create a bot in the Discord Developer Portal, invite it to your server, then paste its token here.'**
  String get discordDescription;

  /// No description provided for @discordUsersLabel.
  ///
  /// In en, this message translates to:
  /// **'Users to record'**
  String get discordUsersLabel;

  /// No description provided for @discordUsersHelper.
  ///
  /// In en, this message translates to:
  /// **'Comma-separated Discord usernames'**
  String get discordUsersHelper;

  /// No description provided for @discordTokenLabel.
  ///
  /// In en, this message translates to:
  /// **'Bot token'**
  String get discordTokenLabel;

  /// No description provided for @discordTokenHelper.
  ///
  /// In en, this message translates to:
  /// **'Stored only on your NeoRecall server'**
  String get discordTokenHelper;

  /// No description provided for @discordHowTo.
  ///
  /// In en, this message translates to:
  /// **'How to create the bot'**
  String get discordHowTo;

  /// No description provided for @discordIntentsNote.
  ///
  /// In en, this message translates to:
  /// **'No privileged intents are required. The bot only listens — it never speaks.'**
  String get discordIntentsNote;

  /// No description provided for @discordConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect Account'**
  String get discordConnect;

  /// No description provided for @discordSteps.
  ///
  /// In en, this message translates to:
  /// **'1. Open the Discord Developer Portal and create an application.\n2. Open the \"Bot\" tab, then \"Reset Token\" and copy the token into the field above.\n3. In \"OAuth2 → URL Generator\", tick the \"bot\" scope and the \"View Channels\", \"Connect\", and \"Speak\" permissions.\n4. Open the generated URL and invite the bot to your server.\n\nNo privileged intents are required. The bot only listens — it never speaks.'**
  String get discordSteps;

  /// No description provided for @apiRequestTimeout.
  ///
  /// In en, this message translates to:
  /// **'The server did not respond in time. Check that it is running and reachable, then try again.'**
  String get apiRequestTimeout;

  /// No description provided for @apiServerUnreachable.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall could not connect to the server. Check that it is online and that this device can reach it.'**
  String get apiServerUnreachable;

  /// No description provided for @apiInvalidResponse.
  ///
  /// In en, this message translates to:
  /// **'The server returned a response NeoRecall could not read (HTTP {status}).'**
  String apiInvalidResponse(int status);

  /// No description provided for @apiServerUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The NeoRecall server is unavailable (HTTP {status}). Try again shortly or check the server.'**
  String apiServerUnavailable(int status);

  /// No description provided for @apiRequestRejected.
  ///
  /// In en, this message translates to:
  /// **'The NeoRecall server rejected the request (HTTP {status}).'**
  String apiRequestRejected(int status);

  /// No description provided for @apiUploadInterrupted.
  ///
  /// In en, this message translates to:
  /// **'The connection was interrupted while uploading. It will retry automatically.'**
  String get apiUploadInterrupted;

  /// No description provided for @apiContextUploadInterrupted.
  ///
  /// In en, this message translates to:
  /// **'The context upload was interrupted. It remains stored locally and will retry.'**
  String get apiContextUploadInterrupted;

  /// No description provided for @apiImportInterrupted.
  ///
  /// In en, this message translates to:
  /// **'The connection was interrupted while uploading. Try the import again.'**
  String get apiImportInterrupted;

  /// No description provided for @controllerSecurityKeyAdded.
  ///
  /// In en, this message translates to:
  /// **'Security key added.'**
  String get controllerSecurityKeyAdded;

  /// No description provided for @controllerWrongPassword.
  ///
  /// In en, this message translates to:
  /// **'That password is not correct.'**
  String get controllerWrongPassword;

  /// No description provided for @controllerInvalidTwoFactor.
  ///
  /// In en, this message translates to:
  /// **'That authentication code is not valid. Codes expire quickly — try the current one.'**
  String get controllerInvalidTwoFactor;

  /// No description provided for @controllerTwoFactorRequired.
  ///
  /// In en, this message translates to:
  /// **'This account needs an authenticator code to confirm.'**
  String get controllerTwoFactorRequired;

  /// No description provided for @controllerDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'The account could not be deleted: {error}'**
  String controllerDeleteFailed(String error);

  /// No description provided for @controllerNoNewRecordings.
  ///
  /// In en, this message translates to:
  /// **'No new recordings on {device} to sync.'**
  String controllerNoNewRecordings(String device);

  /// No description provided for @controllerSyncFailed.
  ///
  /// In en, this message translates to:
  /// **'Sync of {device} failed: {message}'**
  String controllerSyncFailed(String device, String message);

  /// No description provided for @controllerIncompleteUrl.
  ///
  /// In en, this message translates to:
  /// **'Enter a complete server URL including http:// or https://.'**
  String get controllerIncompleteUrl;

  /// No description provided for @controllerWidgetStopped.
  ///
  /// In en, this message translates to:
  /// **'Recording stopped from the home-screen widget.'**
  String get controllerWidgetStopped;

  /// No description provided for @controllerWidgetSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in to complete highlights from the home screen.'**
  String get controllerWidgetSignIn;

  /// No description provided for @controllerWidgetStarted.
  ///
  /// In en, this message translates to:
  /// **'Phone recording started from the home-screen widget.'**
  String get controllerWidgetStarted;

  /// No description provided for @controllerWidgetStartFailed.
  ///
  /// In en, this message translates to:
  /// **'The home-screen widget could not start recording: {error}'**
  String controllerWidgetStartFailed(String error);

  /// No description provided for @controllerScheduleWaiting.
  ///
  /// In en, this message translates to:
  /// **'Recording is waiting for the next configured daily window.'**
  String get controllerScheduleWaiting;

  /// No description provided for @controllerRecoveryWaiting.
  ///
  /// In en, this message translates to:
  /// **'Background recording recovery is waiting: {error}'**
  String controllerRecoveryWaiting(String error);

  /// No description provided for @controllerSourceRecoveryFailed.
  ///
  /// In en, this message translates to:
  /// **'Audio source recovery failed: {error}'**
  String controllerSourceRecoveryFailed(String error);

  /// No description provided for @controllerCaptureRecovered.
  ///
  /// In en, this message translates to:
  /// **'Audio capture recovered after an interruption.'**
  String get controllerCaptureRecovered;

  /// No description provided for @controllerTimelineLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'That part of the timeline could not be loaded just now.'**
  String get controllerTimelineLoadFailed;

  /// No description provided for @controllerMomentLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'The rest of this moment could not be loaded just now.'**
  String get controllerMomentLoadFailed;

  /// No description provided for @controllerRewriteQueued.
  ///
  /// In en, this message translates to:
  /// **'Writing this moment up again. It will update here when ready.'**
  String get controllerRewriteQueued;

  /// No description provided for @controllerImportQueued.
  ///
  /// In en, this message translates to:
  /// **'Import uploaded. Local transcription has been queued.'**
  String get controllerImportQueued;

  /// No description provided for @controllerWearableScanEmpty.
  ///
  /// In en, this message translates to:
  /// **'No supported device found. Check that the wearable is switched on, close by, and not already connected to another app or phone.'**
  String get controllerWearableScanEmpty;

  /// No description provided for @controllerWearableScanChooserEmpty.
  ///
  /// In en, this message translates to:
  /// **'No device was selected in the browser chooser.'**
  String get controllerWearableScanChooserEmpty;

  /// No description provided for @controllerNoteEmpty.
  ///
  /// In en, this message translates to:
  /// **'Write a note before saving it.'**
  String get controllerNoteEmpty;

  /// No description provided for @controllerNoteTooLong.
  ///
  /// In en, this message translates to:
  /// **'Notes may contain at most {maximum} characters.'**
  String controllerNoteTooLong(int maximum);

  /// No description provided for @controllerFileTooLarge.
  ///
  /// In en, this message translates to:
  /// **'This file is larger than the server limit.'**
  String get controllerFileTooLarge;

  /// No description provided for @controllerContextWhileRecording.
  ///
  /// In en, this message translates to:
  /// **'Context can only be added while recording is active.'**
  String get controllerContextWhileRecording;

  /// No description provided for @controllerContextStorageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Recording context storage is unavailable.'**
  String get controllerContextStorageUnavailable;

  /// No description provided for @controllerContextIntegrity.
  ///
  /// In en, this message translates to:
  /// **'The locally stored context file failed its integrity check.'**
  String get controllerContextIntegrity;

  /// No description provided for @controllerMergeTooFew.
  ///
  /// In en, this message translates to:
  /// **'Select at least two memories to merge.'**
  String get controllerMergeTooFew;

  /// No description provided for @controllerMergeTooMany.
  ///
  /// In en, this message translates to:
  /// **'Select at most {maximum} memories to merge.'**
  String controllerMergeTooMany(int maximum);

  /// No description provided for @controllerStorageFull.
  ///
  /// In en, this message translates to:
  /// **'Storage full — recording stopped'**
  String get controllerStorageFull;

  /// No description provided for @liveEtaLeft.
  ///
  /// In en, this message translates to:
  /// **'about {duration} left'**
  String liveEtaLeft(String duration);

  /// No description provided for @liveStorageFullDetail.
  ///
  /// In en, this message translates to:
  /// **'Free device storage, then reopen NeoRecall to resume safely.'**
  String get liveStorageFullDetail;

  /// No description provided for @liveStorageFullIssue.
  ///
  /// In en, this message translates to:
  /// **'No local space remains for another durable audio block.'**
  String get liveStorageFullIssue;

  /// No description provided for @liveSourceBluetooth.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth device'**
  String get liveSourceBluetooth;

  /// No description provided for @liveRecordingFrom.
  ///
  /// In en, this message translates to:
  /// **'Recording from {source}'**
  String liveRecordingFrom(String source);

  /// No description provided for @liveRecordingUploading.
  ///
  /// In en, this message translates to:
  /// **'Recording safely · uploading in background'**
  String get liveRecordingUploading;

  /// No description provided for @liveRecordingSafely.
  ///
  /// In en, this message translates to:
  /// **'Recording safely to this device'**
  String get liveRecordingSafely;

  /// No description provided for @liveWatchTransferDetail.
  ///
  /// In en, this message translates to:
  /// **'Audio is moving into protected phone storage'**
  String get liveWatchTransferDetail;

  /// No description provided for @liveUploadingTitle.
  ///
  /// In en, this message translates to:
  /// **'Uploading recordings'**
  String get liveUploadingTitle;

  /// No description provided for @liveUploadingDetail.
  ///
  /// In en, this message translates to:
  /// **'Local originals stay protected until processing is verified'**
  String get liveUploadingDetail;

  /// No description provided for @liveTranscribingDetail.
  ///
  /// In en, this message translates to:
  /// **'Audio is safely stored while the transcript is created'**
  String get liveTranscribingDetail;

  /// No description provided for @liveFinalizingTitle.
  ///
  /// In en, this message translates to:
  /// **'Finalizing transcript'**
  String get liveFinalizingTitle;

  /// No description provided for @liveFinalizingDetail.
  ///
  /// In en, this message translates to:
  /// **'Waiting for verified persistence and server audio deletion'**
  String get liveFinalizingDetail;

  /// No description provided for @liveQueuedTitle.
  ///
  /// In en, this message translates to:
  /// **'Recordings safely queued'**
  String get liveQueuedTitle;

  /// No description provided for @liveQueuedDetail.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the next processing step'**
  String get liveQueuedDetail;

  /// No description provided for @liveIdleTitle.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall is ready'**
  String get liveIdleTitle;

  /// No description provided for @liveIdleDetail.
  ///
  /// In en, this message translates to:
  /// **'No recording or processing is active'**
  String get liveIdleDetail;

  /// No description provided for @liveBytesQueued.
  ///
  /// In en, this message translates to:
  /// **'{size} queued'**
  String liveBytesQueued(String size);

  /// No description provided for @widgetIdleTitle.
  ///
  /// In en, this message translates to:
  /// **'Ready to record'**
  String get widgetIdleTitle;

  /// No description provided for @widgetIdleDetail.
  ///
  /// In en, this message translates to:
  /// **'Nothing is capturing or waiting.'**
  String get widgetIdleDetail;

  /// No description provided for @statusManualRetry.
  ///
  /// In en, this message translates to:
  /// **'A recording needs a manual upload retry.'**
  String get statusManualRetry;

  /// No description provided for @statusUploadFailed.
  ///
  /// In en, this message translates to:
  /// **'A recording upload failed and will retry automatically.'**
  String get statusUploadFailed;

  /// No description provided for @statusOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline — audio remains safely stored on this device.'**
  String get statusOffline;

  /// No description provided for @statusWaitingForWifi.
  ///
  /// In en, this message translates to:
  /// **'Waiting for Wi‑Fi because mobile-data uploads are disabled.'**
  String get statusWaitingForWifi;

  /// No description provided for @watchDigestSent.
  ///
  /// In en, this message translates to:
  /// **'Today was sent to the watch.'**
  String get watchDigestSent;

  /// No description provided for @watchCheckAgain.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get watchCheckAgain;

  /// No description provided for @watchTitle.
  ///
  /// In en, this message translates to:
  /// **'Record from your wrist'**
  String get watchTitle;

  /// No description provided for @watchDescription.
  ///
  /// In en, this message translates to:
  /// **'The watch records on its own and holds every clip until this phone confirms it was transcribed and the server copy deleted. Today’s transcript, memories and commitments are sent back to the watch so they can be read without the phone.'**
  String get watchDescription;

  /// No description provided for @watchLooking.
  ///
  /// In en, this message translates to:
  /// **'Looking for paired watches…'**
  String get watchLooking;

  /// No description provided for @watchSending.
  ///
  /// In en, this message translates to:
  /// **'Sending…'**
  String get watchSending;

  /// No description provided for @watchSendToday.
  ///
  /// In en, this message translates to:
  /// **'Send today now'**
  String get watchSendToday;

  /// No description provided for @watchNotInstalled.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall not installed'**
  String get watchNotInstalled;

  /// No description provided for @watchOutOfRange.
  ///
  /// In en, this message translates to:
  /// **'Installed · out of range'**
  String get watchOutOfRange;

  /// No description provided for @watchConnected.
  ///
  /// In en, this message translates to:
  /// **'Installed · connected'**
  String get watchConnected;

  /// No description provided for @watchReady.
  ///
  /// In en, this message translates to:
  /// **'READY'**
  String get watchReady;

  /// No description provided for @watchSetUp.
  ///
  /// In en, this message translates to:
  /// **'SET UP'**
  String get watchSetUp;

  /// No description provided for @watchNonePaired.
  ///
  /// In en, this message translates to:
  /// **'No paired watch found. Pair the watch with this phone in the Wear OS app first — NeoRecall can only see watches Android has already paired.'**
  String get watchNonePaired;

  /// No description provided for @watchInstallEyebrow.
  ///
  /// In en, this message translates to:
  /// **'Installing on the watch'**
  String get watchInstallEyebrow;

  /// No description provided for @watchInstallIntro.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall for Wear OS ships as its own APK, signed with the same key as this app, and is sideloaded once. It is not on the Play Store, so the watch needs developer options turned on for the install and nothing after that.'**
  String get watchInstallIntro;

  /// No description provided for @watchStep1Title.
  ///
  /// In en, this message translates to:
  /// **'Download the watch APK'**
  String get watchStep1Title;

  /// No description provided for @watchStep1Detail.
  ///
  /// In en, this message translates to:
  /// **'Take NeoRecall-WearOS-<version>.apk from the latest release, onto a computer that is on the same network as the watch.'**
  String get watchStep1Detail;

  /// No description provided for @watchReleasesLabel.
  ///
  /// In en, this message translates to:
  /// **'Releases'**
  String get watchReleasesLabel;

  /// No description provided for @watchStep2Title.
  ///
  /// In en, this message translates to:
  /// **'Turn on wireless debugging on the watch'**
  String get watchStep2Title;

  /// No description provided for @watchStep2Detail.
  ///
  /// In en, this message translates to:
  /// **'Settings → System → About → tap Build number seven times, then Settings → Developer options → ADB debugging and Wireless debugging. The watch shows its IP address there.'**
  String get watchStep2Detail;

  /// No description provided for @watchStep3Title.
  ///
  /// In en, this message translates to:
  /// **'Install it over Wi-Fi'**
  String get watchStep3Title;

  /// No description provided for @watchStep3Detail.
  ///
  /// In en, this message translates to:
  /// **'From the computer holding the APK, with the watch IP from the previous step:'**
  String get watchStep3Detail;

  /// No description provided for @watchConnectLabel.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get watchConnectLabel;

  /// No description provided for @watchInstallLabel.
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get watchInstallLabel;

  /// No description provided for @watchStep4Title.
  ///
  /// In en, this message translates to:
  /// **'Open it once on the watch'**
  String get watchStep4Title;

  /// No description provided for @watchStep4Detail.
  ///
  /// In en, this message translates to:
  /// **'Allow the microphone, and this page turns to Installed. Add the NeoRecall tiles by long-pressing the watch face, and the complications from the watch face editor.'**
  String get watchStep4Detail;

  /// No description provided for @watchInstallFootnote.
  ///
  /// In en, this message translates to:
  /// **'Developer options can be turned back off afterwards — the app stays installed and keeps working.'**
  String get watchInstallFootnote;

  /// No description provided for @providerContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get providerContinue;

  /// No description provided for @providerChoose.
  ///
  /// In en, this message translates to:
  /// **'Choose a {workload} provider.'**
  String providerChoose(String workload);

  /// No description provided for @providerNeedsBaseUrl.
  ///
  /// In en, this message translates to:
  /// **'{provider} needs a base URL.'**
  String providerNeedsBaseUrl(String provider);

  /// No description provided for @providerSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved. The server uses these services from now on.'**
  String get providerSaved;

  /// No description provided for @providerLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'The provider settings could not be loaded.'**
  String get providerLoadFailed;

  /// No description provided for @providerTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get providerTryAgain;

  /// No description provided for @providerIntro.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall does the speech detection and speaker matching itself, but the words and the written memories come from services you choose.'**
  String get providerIntro;

  /// No description provided for @providerTesting.
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get providerTesting;

  /// No description provided for @providerSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get providerSaving;

  /// No description provided for @providerSaveAndTest.
  ///
  /// In en, this message translates to:
  /// **'Save and test'**
  String get providerSaveAndTest;

  /// No description provided for @providerSaveOnly.
  ///
  /// In en, this message translates to:
  /// **'Save only'**
  String get providerSaveOnly;

  /// No description provided for @providerSetUpLater.
  ///
  /// In en, this message translates to:
  /// **'Set these up later'**
  String get providerSetUpLater;

  /// No description provided for @providerKeyStored.
  ///
  /// In en, this message translates to:
  /// **'key stored'**
  String get providerKeyStored;

  /// No description provided for @providerServiceLabel.
  ///
  /// In en, this message translates to:
  /// **'Service'**
  String get providerServiceLabel;

  /// No description provided for @providerBaseUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Base URL'**
  String get providerBaseUrlLabel;

  /// No description provided for @providerApiKeyStoredLabel.
  ///
  /// In en, this message translates to:
  /// **'API key (leave empty to keep the stored one)'**
  String get providerApiKeyStoredLabel;

  /// No description provided for @providerApiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get providerApiKeyLabel;

  /// No description provided for @providerModelOptionalLabel.
  ///
  /// In en, this message translates to:
  /// **'Model (optional)'**
  String get providerModelOptionalLabel;

  /// No description provided for @providerModelLabel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get providerModelLabel;

  /// No description provided for @providerFindModels.
  ///
  /// In en, this message translates to:
  /// **'Find models'**
  String get providerFindModels;

  /// No description provided for @providerLegTranscription.
  ///
  /// In en, this message translates to:
  /// **'Transcription'**
  String get providerLegTranscription;

  /// No description provided for @providerLegSpeakerIdentity.
  ///
  /// In en, this message translates to:
  /// **'Speaker identity'**
  String get providerLegSpeakerIdentity;

  /// No description provided for @providerLegMemoryWriting.
  ///
  /// In en, this message translates to:
  /// **'Memory writing'**
  String get providerLegMemoryWriting;

  /// No description provided for @providerTranscriptionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Turns recorded speech into words. Speaker identity stays on this machine.'**
  String get providerTranscriptionSubtitle;

  /// No description provided for @providerMemorySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Writes titles, summaries, and memories from the transcript.'**
  String get providerMemorySubtitle;

  /// No description provided for @installFailed.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall setup could not finish: {error}'**
  String installFailed(String error);

  /// No description provided for @installFailedShort.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall setup could not finish.'**
  String get installFailedShort;

  /// No description provided for @actionBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get actionBack;

  /// No description provided for @installEyebrow.
  ///
  /// In en, this message translates to:
  /// **'LOCAL SETUP'**
  String get installEyebrow;

  /// No description provided for @installIntro.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall will be downloaded from GitHub, installed as a background service, and connected to this app. Both channels can be switched later.'**
  String get installIntro;

  /// No description provided for @installChannelStable.
  ///
  /// In en, this message translates to:
  /// **'Stable'**
  String get installChannelStable;

  /// No description provided for @installChannelStableDescription.
  ///
  /// In en, this message translates to:
  /// **'Released versions only. Recommended for daily use.'**
  String get installChannelStableDescription;

  /// No description provided for @installChannelRecommended.
  ///
  /// In en, this message translates to:
  /// **'Recommended'**
  String get installChannelRecommended;

  /// No description provided for @installChannelBeta.
  ///
  /// In en, this message translates to:
  /// **'Beta'**
  String get installChannelBeta;

  /// No description provided for @installChannelBetaDescription.
  ///
  /// In en, this message translates to:
  /// **'New features first, with the rough edges that come with them.'**
  String get installChannelBetaDescription;

  /// No description provided for @installDirectoryLabel.
  ///
  /// In en, this message translates to:
  /// **'Install directory'**
  String get installDirectoryLabel;

  /// No description provided for @installMissingRequirements.
  ///
  /// In en, this message translates to:
  /// **'Install {items} on this computer first, then check again.'**
  String installMissingRequirements(String items);

  /// No description provided for @installCheckAgain.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get installCheckAgain;

  /// No description provided for @installStart.
  ///
  /// In en, this message translates to:
  /// **'Install the {channel} channel'**
  String installStart(String channel);

  /// No description provided for @installPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing NeoRecall…'**
  String get installPreparing;

  /// No description provided for @installModelsNote.
  ///
  /// In en, this message translates to:
  /// **'The first install downloads about 165 MB of local models, so this can take a few minutes.'**
  String get installModelsNote;

  /// No description provided for @installDetails.
  ///
  /// In en, this message translates to:
  /// **'Setup details'**
  String get installDetails;

  /// No description provided for @installRunning.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall is running{location}. One step left: choose the services that transcribe your recordings and write your memories.'**
  String installRunning(String location);

  /// No description provided for @installLocationAt.
  ///
  /// In en, this message translates to:
  /// **' at {url}'**
  String installLocationAt(String url);

  /// No description provided for @installNoAdminKey.
  ///
  /// In en, this message translates to:
  /// **'This computer would not store the administrator key, so these services can be set up now but not changed from Settings later. The admin dashboard at /admin can still change them.'**
  String get installNoAdminKey;

  /// No description provided for @installCreateAccount.
  ///
  /// In en, this message translates to:
  /// **'Create your account'**
  String get installCreateAccount;

  /// No description provided for @installDone.
  ///
  /// In en, this message translates to:
  /// **'NeoRecall is installed and running{version}.'**
  String installDone(String version);

  /// No description provided for @installVersionSuffix.
  ///
  /// In en, this message translates to:
  /// **' ({version})'**
  String installVersionSuffix(String version);

  /// No description provided for @installCliNotLinked.
  ///
  /// In en, this message translates to:
  /// **'The neorecall terminal command was not linked. NeoRecall runs anyway; run \"npm link\" in {directory} if you want the command.'**
  String installCliNotLinked(String directory);

  /// No description provided for @installChooseServices.
  ///
  /// In en, this message translates to:
  /// **'Choose transcription and memory services'**
  String get installChooseServices;

  /// No description provided for @actionRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get actionRetry;

  /// No description provided for @installChangeOptions.
  ///
  /// In en, this message translates to:
  /// **'Change options'**
  String get installChangeOptions;

  /// No description provided for @installTitle.
  ///
  /// In en, this message translates to:
  /// **'Set up NeoRecall on this computer'**
  String get installTitle;

  /// No description provided for @wifiPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Network password'**
  String get wifiPasswordLabel;

  /// No description provided for @wifiShowPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get wifiShowPassword;

  /// No description provided for @wifiHidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get wifiHidePassword;

  /// No description provided for @wifiJoin.
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get wifiJoin;

  /// No description provided for @applianceOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get applianceOpen;

  /// No description provided for @applianceRecordingElapsed.
  ///
  /// In en, this message translates to:
  /// **'Recording · {elapsed}'**
  String applianceRecordingElapsed(String elapsed);

  /// No description provided for @applianceRecording.
  ///
  /// In en, this message translates to:
  /// **'Recording'**
  String get applianceRecording;

  /// No description provided for @applianceNotSeenYet.
  ///
  /// In en, this message translates to:
  /// **'Not seen yet'**
  String get applianceNotSeenYet;

  /// No description provided for @applianceReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get applianceReady;

  /// No description provided for @applianceLastSeenMinutes.
  ///
  /// In en, this message translates to:
  /// **'Last seen {minutes} minutes ago'**
  String applianceLastSeenMinutes(int minutes);

  /// No description provided for @applianceLastSeenHours.
  ///
  /// In en, this message translates to:
  /// **'{hours, plural, =1{Last seen 1 hour ago} other{Last seen {hours} hours ago}}'**
  String applianceLastSeenHours(int hours);

  /// No description provided for @applianceLastSeenDays.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{Last seen 1 day ago} other{Last seen {days} days ago}}'**
  String applianceLastSeenDays(int days);

  /// No description provided for @applianceConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get applianceConnecting;

  /// No description provided for @applianceSettingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Device settings'**
  String get applianceSettingsTooltip;

  /// No description provided for @applianceRecordingBadge.
  ///
  /// In en, this message translates to:
  /// **'RECORDING'**
  String get applianceRecordingBadge;

  /// No description provided for @applianceReadyBadge.
  ///
  /// In en, this message translates to:
  /// **'READY'**
  String get applianceReadyBadge;

  /// No description provided for @applianceOutOfRangeBadge.
  ///
  /// In en, this message translates to:
  /// **'OUT OF RANGE'**
  String get applianceOutOfRangeBadge;

  /// No description provided for @applianceOutOfRangeBody.
  ///
  /// In en, this message translates to:
  /// **'Out of range. This page shows what the device last reported. A recording already running is not affected — the device keeps recording and sending on its own.'**
  String get applianceOutOfRangeBody;

  /// No description provided for @applianceSoundEyebrow.
  ///
  /// In en, this message translates to:
  /// **'SOUND'**
  String get applianceSoundEyebrow;

  /// No description provided for @appliancePlaysOutOf.
  ///
  /// In en, this message translates to:
  /// **'Plays out of'**
  String get appliancePlaysOutOf;

  /// No description provided for @applianceSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Speaker'**
  String get applianceSpeaker;

  /// No description provided for @applianceHeadphones.
  ///
  /// In en, this message translates to:
  /// **'Headphones'**
  String get applianceHeadphones;

  /// No description provided for @applianceRecordsWith.
  ///
  /// In en, this message translates to:
  /// **'Records with'**
  String get applianceRecordsWith;

  /// No description provided for @applianceOwnMicrophones.
  ///
  /// In en, this message translates to:
  /// **'Its own microphones'**
  String get applianceOwnMicrophones;

  /// No description provided for @applianceHeadset.
  ///
  /// In en, this message translates to:
  /// **'Headset'**
  String get applianceHeadset;

  /// No description provided for @applianceHeadsetQualityNote.
  ///
  /// In en, this message translates to:
  /// **'While recording, what you hear drops in quality — that is how Bluetooth headsets work.'**
  String get applianceHeadsetQualityNote;

  /// No description provided for @applianceHeadphonesEyebrow.
  ///
  /// In en, this message translates to:
  /// **'HEADPHONES'**
  String get applianceHeadphonesEyebrow;

  /// No description provided for @applianceLooking.
  ///
  /// In en, this message translates to:
  /// **'Looking…'**
  String get applianceLooking;

  /// No description provided for @applianceFind.
  ///
  /// In en, this message translates to:
  /// **'Find'**
  String get applianceFind;

  /// No description provided for @applianceNoHeadphones.
  ///
  /// In en, this message translates to:
  /// **'No headphones yet. Put yours in pairing mode and tap Find.'**
  String get applianceNoHeadphones;

  /// No description provided for @applianceHeadphonePaired.
  ///
  /// In en, this message translates to:
  /// **'Paired'**
  String get applianceHeadphonePaired;

  /// No description provided for @applianceHeadphoneInRange.
  ///
  /// In en, this message translates to:
  /// **'In range'**
  String get applianceHeadphoneInRange;

  /// No description provided for @applianceDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get applianceDisconnect;

  /// No description provided for @applianceConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get applianceConnect;

  /// No description provided for @applianceNotSetUp.
  ///
  /// In en, this message translates to:
  /// **'Not set up yet'**
  String get applianceNotSetUp;

  /// No description provided for @applianceSending.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Sending 1 recording} other{Sending {count} recordings}}'**
  String applianceSending(int count);

  /// No description provided for @applianceWaitingToSend.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 recording waiting to be sent} other{{count} recordings waiting to be sent}}'**
  String applianceWaitingToSend(int count);

  /// No description provided for @applianceReadyWithHeadset.
  ///
  /// In en, this message translates to:
  /// **'Ready · {headset}'**
  String applianceReadyWithHeadset(String headset);

  /// No description provided for @applianceSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Device settings'**
  String get applianceSettingsTitle;

  /// No description provided for @applianceNameEyebrow.
  ///
  /// In en, this message translates to:
  /// **'NAME'**
  String get applianceNameEyebrow;

  /// No description provided for @applianceNameHint.
  ///
  /// In en, this message translates to:
  /// **'Desk in the study'**
  String get applianceNameHint;

  /// No description provided for @applianceNetworkEyebrow.
  ///
  /// In en, this message translates to:
  /// **'NETWORK'**
  String get applianceNetworkEyebrow;

  /// No description provided for @applianceChange.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get applianceChange;

  /// No description provided for @applianceNetworkOnline.
  ///
  /// In en, this message translates to:
  /// **'Connected. Recordings are sent when you stop recording.'**
  String get applianceNetworkOnline;

  /// No description provided for @applianceNetworkOffline.
  ///
  /// In en, this message translates to:
  /// **'Not connected. Recordings are kept on the device until it is.'**
  String get applianceNetworkOffline;

  /// No description provided for @applianceSoundCheckEyebrow.
  ///
  /// In en, this message translates to:
  /// **'SOUND CHECK'**
  String get applianceSoundCheckEyebrow;

  /// No description provided for @applianceSoundCheckLabel.
  ///
  /// In en, this message translates to:
  /// **'Have the device play a tone and listen for it.'**
  String get applianceSoundCheckLabel;

  /// No description provided for @applianceCheck.
  ///
  /// In en, this message translates to:
  /// **'Check'**
  String get applianceCheck;

  /// No description provided for @applianceSoftwareEyebrow.
  ///
  /// In en, this message translates to:
  /// **'SOFTWARE'**
  String get applianceSoftwareEyebrow;

  /// No description provided for @applianceVersionUnknown.
  ///
  /// In en, this message translates to:
  /// **'Version unknown'**
  String get applianceVersionUnknown;

  /// No description provided for @applianceVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String applianceVersion(String version);

  /// No description provided for @applianceCheckNow.
  ///
  /// In en, this message translates to:
  /// **'Check now'**
  String get applianceCheckNow;

  /// No description provided for @applianceAutoUpdateTitle.
  ///
  /// In en, this message translates to:
  /// **'Keep this device up to date'**
  String get applianceAutoUpdateTitle;

  /// No description provided for @applianceAutoUpdateDescription.
  ///
  /// In en, this message translates to:
  /// **'Checks once a day and installs new versions by itself. It never interrupts a recording — an update waits until you have stopped.'**
  String get applianceAutoUpdateDescription;

  /// No description provided for @applianceRemoveEyebrow.
  ///
  /// In en, this message translates to:
  /// **'REMOVE'**
  String get applianceRemoveEyebrow;

  /// No description provided for @applianceRemoveDescription.
  ///
  /// In en, this message translates to:
  /// **'Takes this device off your account. Recordings already sent stay in NeoRecall; anything still waiting on the device is lost.'**
  String get applianceRemoveDescription;

  /// No description provided for @applianceRemoveAction.
  ///
  /// In en, this message translates to:
  /// **'Remove this device'**
  String get applianceRemoveAction;

  /// No description provided for @applianceRemoveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove this device?'**
  String get applianceRemoveTitle;

  /// No description provided for @applianceRemovePending.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{It still has 1 recording that has not been sent. Removing it now loses it.} other{It still has {count} recordings that have not been sent. Removing it now loses them.}}'**
  String applianceRemovePending(int count);

  /// No description provided for @applianceRemoveBody.
  ///
  /// In en, this message translates to:
  /// **'You can set it up again at any time by holding its button for five seconds.'**
  String get applianceRemoveBody;

  /// No description provided for @applianceKeepIt.
  ///
  /// In en, this message translates to:
  /// **'Keep it'**
  String get applianceKeepIt;

  /// No description provided for @applianceBluetoothOff.
  ///
  /// In en, this message translates to:
  /// **'Turn Bluetooth on to set up a device.'**
  String get applianceBluetoothOff;

  /// No description provided for @applianceBluetoothUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This device cannot use Bluetooth.'**
  String get applianceBluetoothUnsupported;

  /// No description provided for @appliancePairFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not pair. Hold the button on the device for five seconds until it beeps three times, then try again.'**
  String get appliancePairFailed;

  /// No description provided for @applianceNoAnswer.
  ///
  /// In en, this message translates to:
  /// **'The device did not answer. Check the network and try again.'**
  String get applianceNoAnswer;

  /// No description provided for @applianceAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add a NeoRecall Desk'**
  String get applianceAddTitle;

  /// No description provided for @applianceLookingIntro.
  ///
  /// In en, this message translates to:
  /// **'Plug the device in and wait for its short rising tone. If it has been set up before, hold its button for five seconds first.'**
  String get applianceLookingIntro;

  /// No description provided for @applianceNothingFound.
  ///
  /// In en, this message translates to:
  /// **'Nothing found yet'**
  String get applianceNothingFound;

  /// No description provided for @applianceNothingFoundMessage.
  ///
  /// In en, this message translates to:
  /// **'Hold the button on the device for five seconds, then look again.'**
  String get applianceNothingFoundMessage;

  /// No description provided for @applianceSetUpAction.
  ///
  /// In en, this message translates to:
  /// **'Set up'**
  String get applianceSetUpAction;

  /// No description provided for @applianceLookAgain.
  ///
  /// In en, this message translates to:
  /// **'Look again'**
  String get applianceLookAgain;

  /// No description provided for @appliancePressButton.
  ///
  /// In en, this message translates to:
  /// **'Press the button on {device}'**
  String appliancePressButton(String device);

  /// No description provided for @applianceTheDevice.
  ///
  /// In en, this message translates to:
  /// **'the device'**
  String get applianceTheDevice;

  /// No description provided for @appliancePressButtonWhy.
  ///
  /// In en, this message translates to:
  /// **'The device has no screen, so pressing its button is how it knows the request came from someone standing next to it.'**
  String get appliancePressButtonWhy;

  /// No description provided for @applianceLookingForNetworks.
  ///
  /// In en, this message translates to:
  /// **'Looking for networks…'**
  String get applianceLookingForNetworks;

  /// No description provided for @applianceNoNetworks.
  ///
  /// In en, this message translates to:
  /// **'No networks found yet.'**
  String get applianceNoNetworks;

  /// No description provided for @applianceSettingUp.
  ///
  /// In en, this message translates to:
  /// **'Setting the device up…'**
  String get applianceSettingUp;

  /// No description provided for @applianceSettingUpDetail.
  ///
  /// In en, this message translates to:
  /// **'It is joining your network and signing in.'**
  String get applianceSettingUpDetail;

  /// No description provided for @applianceDoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get applianceDoneTitle;

  /// No description provided for @applianceDoneBody.
  ///
  /// In en, this message translates to:
  /// **'Choose \"{name}\" as the speaker and microphone on your computer, then press its button to record.'**
  String applianceDoneBody(String name);

  /// No description provided for @actionOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get actionOk;

  /// No description provided for @watchCopyLabel.
  ///
  /// In en, this message translates to:
  /// **'Copy {label}'**
  String watchCopyLabel(String label);

  /// No description provided for @backgroundRuntimeFailed.
  ///
  /// In en, this message translates to:
  /// **'Background runtime could not start: {error}'**
  String backgroundRuntimeFailed(String error);

  /// No description provided for @backgroundStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Background status could not be updated: {error}'**
  String backgroundStatusFailed(String error);

  /// No description provided for @backgroundHostUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Android background host is temporarily unavailable: {error}'**
  String backgroundHostUnavailable(String error);

  /// No description provided for @controllerWearableAudioStalled.
  ///
  /// In en, this message translates to:
  /// **'Your recording device stopped sending audio. Recording is still open and waiting for it.'**
  String get controllerWearableAudioStalled;

  /// No description provided for @controllerWearableAudioLost.
  ///
  /// In en, this message translates to:
  /// **'No audio is arriving from your recording device. Anything said now is not being recorded — reconnect it or record with the phone.'**
  String get controllerWearableAudioLost;

  /// No description provided for @controllerCaptureIncomplete.
  ///
  /// In en, this message translates to:
  /// **'Only part of this recording was captured; about {minutes} minutes of audio never arrived from the recording device.'**
  String controllerCaptureIncomplete(int minutes);
}

class _AppL10nDelegate extends LocalizationsDelegate<AppL10n> {
  const _AppL10nDelegate();

  @override
  Future<AppL10n> load(Locale locale) {
    return SynchronousFuture<AppL10n>(lookupAppL10n(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppL10nDelegate old) => false;
}

AppL10n lookupAppL10n(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppL10nDe();
    case 'en':
      return AppL10nEn();
  }

  throw FlutterError(
    'AppL10n.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
