// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_l10n.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppL10nEn extends AppL10n {
  AppL10nEn([String locale = 'en']) : super(locale);

  @override
  String get appLoading => 'Loading NeoRecall';

  @override
  String get settingsLanguageTitle => 'Language';

  @override
  String get settingsLanguageDescription =>
      'The language NeoRecall uses for the app and for the memories, summaries, and answers it writes. Recordings are still transcribed in whatever language was spoken.';

  @override
  String get settingsLanguageLabel => 'App and memory language';

  @override
  String settingsLanguageFailed(String error) {
    return 'Could not change the language: $error';
  }

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionSave => 'Save';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsDescription =>
      'Capture behaviour, memory, and account security in one place.';

  @override
  String get settingsSaved => 'Settings saved.';

  @override
  String settingsVocabularyTooMany(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Remove $count terms to save.',
      one: 'Remove 1 term to save.',
    );
    return '$_temp0';
  }

  @override
  String settingsVocabularyTermTooLong(int maximum) {
    return 'Each term must be $maximum characters or fewer.';
  }

  @override
  String get settingsShortenRetentionTitle =>
      'Shorten original-file retention?';

  @override
  String settingsShortenRetentionBody(int days) {
    return 'Original photos, documents, and raw audio older than $days days will be permanently deleted during the next cleanup. Transcripts and AI descriptions remain.';
  }

  @override
  String get settingsShortenRetentionConfirm => 'Shorten retention';

  @override
  String settingsUploadPolicyFailed(String error) {
    return 'Could not update upload policy: $error';
  }

  @override
  String get settingsStopRawAudioTitle => 'Stop keeping raw audio?';

  @override
  String get settingsStopRawAudioBody =>
      'Recordings already on this device will be deleted now. Transcripts, titles, and memories stay.';

  @override
  String get settingsStopRawAudioConfirm => 'Delete raw audio';

  @override
  String settingsRawAudioFailed(String error) {
    return 'Could not update raw audio storage: $error';
  }

  @override
  String get settingsDevicesTitle => 'Signed-in devices';

  @override
  String get settingsDevicesDescription =>
      'Review access or revoke an old client. Set up, connect, and control capture hardware from Record.';

  @override
  String get settingsOpenRecord => 'Open Record';

  @override
  String settingsServicesNoAdminKey(String backendUrl) {
    return 'These services are set on the server itself. This app has no administrator key for $backendUrl, so ask whoever runs that server to configure transcription and memory writing there.';
  }

  @override
  String get settingsServicesTitle => 'Services';

  @override
  String get settingsSectionGeneral => 'GENERAL';

  @override
  String get settingsTimeLocaleTitle => 'Time and locale';

  @override
  String get settingsTimeLocaleDescription =>
      'Used to place recordings and generated memories on your local timeline.';

  @override
  String get settingsTimezoneLabel => 'IANA timezone';

  @override
  String get settingsSectionAlwaysOn => 'ALWAYS-ON CAPTURE';

  @override
  String get settingsUnmeteredTitle =>
      'Upload only on Wi-Fi / unmetered networks';

  @override
  String get settingsUnmeteredDescription =>
      'On by default. Recording continues to private app storage while offline or on mobile data, then uploads when an unmetered connection is available.';

  @override
  String get settingsScheduleTitle => 'Daily recording window';

  @override
  String get settingsScheduleDescription =>
      'Uses this device’s local time. Off means 24/7; overnight windows such as 22:00–06:00 are supported.';

  @override
  String settingsScheduleStart(String time) {
    return 'Start $time';
  }

  @override
  String settingsScheduleStop(String time) {
    return 'Stop $time';
  }

  @override
  String get settingsScheduleFootnote =>
      'At the end time, the current chunk is finalized to on-device storage. Android may require opening NeoRecall before the phone microphone can restart at the next start time.';

  @override
  String get settingsSilenceTitle => 'Silence handling';

  @override
  String get settingsSilenceDescription =>
      'Server-side voice activity detection marks silent chunks. The phone keeps its copy until a terminal receipt proves processing completed and server audio was deleted.';

  @override
  String get settingsSectionRecording => 'RECORDING';

  @override
  String settingsChunkDuration(int seconds) {
    return 'Chunk duration: $seconds seconds';
  }

  @override
  String settingsChunkOverlap(String seconds) {
    return 'Boundary overlap: $seconds seconds';
  }

  @override
  String get settingsSectionTranscription => 'TRANSCRIPTION';

  @override
  String get settingsVocabularyLabel => 'Words and phrases to recognize';

  @override
  String get settingsVocabularyHint =>
      'NeoRecall\nProduct or company name\nTechnical term';

  @override
  String get settingsVocabularyHelper =>
      'One entry per line. Duplicates are ignored.';

  @override
  String get settingsVocabularyCorrectionTitle =>
      'Correct close transcription misspellings';

  @override
  String settingsVocabularyCorrectionDescription(Object minimum) {
    return 'For providers without native vocabulary matching, only unambiguous single words of $minimum+ characters are corrected.';
  }

  @override
  String get settingsSpeakerVocabularyTitle =>
      'Added automatically from named speakers';

  @override
  String get settingsSectionRecordingContext => 'RECORDING CONTEXT';

  @override
  String get settingsKeepRawAudioTitle => 'Keep raw audio on this device';

  @override
  String get settingsKeepRawAudioDescription =>
      'On by default. Listen from Moments. The server still deletes its copy after transcription; only this phone keeps the file, and only until the retention period below.';

  @override
  String settingsRetentionTitle(int days) {
    return 'Keep original photos, documents, and raw audio for $days days';
  }

  @override
  String get settingsRetentionDescription =>
      'After this period NeoRecall deletes the original bytes but keeps transcripts, extracted text, image descriptions, and source links.';

  @override
  String settingsRetentionDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String get settingsRetentionOneYear => '1 year';

  @override
  String get settingsRetentionWarning =>
      'Shortening retention can permanently delete existing originals on the next server cleanup.';

  @override
  String get settingsSectionMemory => 'MEMORY';

  @override
  String get settingsConsolidationTitle => 'Consolidation interval';

  @override
  String get settingsConsolidationImmediate =>
      'As soon as there is enough material';

  @override
  String settingsConsolidationWait(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'Wait at least $hours hours between write-ups',
      one: 'Wait at least 1 hour between write-ups',
    );
    return '$_temp0';
  }

  @override
  String get settingsConsolidationSliderImmediate => 'Immediate';

  @override
  String settingsConsolidationSliderHours(int hours) {
    return '${hours}h';
  }

  @override
  String get settingsConsolidationFloorNone =>
      'Memories are written when enough has been said, without waiting for a conversation to end.';

  @override
  String settingsConsolidationFloor(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other:
          'This server will not write up more often than every $hours hours.',
      one: 'This server will not write up more often than every hour.',
    );
    return '$_temp0';
  }

  @override
  String settingsInstructionsTooLong(int count, int limit) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Shorten $count instructions to $limit characters to save.',
      one: 'Shorten 1 instruction to $limit characters to save.',
    );
    return '$_temp0';
  }

  @override
  String settingsInstructionsLimit(int limit) {
    return 'At most $limit characters.';
  }

  @override
  String get settingsInstructionsIntro =>
      'These are sent with every request in their area. They shape tone, length, language, and what matters to you — they cannot change what the model is allowed to read, and evidence still comes only from your own recordings.';

  @override
  String get settingsSectionEverywhere => 'EVERYWHERE';

  @override
  String get settingsInstructionsGlobalLabel => 'Global instructions';

  @override
  String get settingsInstructionsGlobalHint =>
      'Write in German.\nUse 24-hour times.';

  @override
  String get settingsInstructionsGlobalHelper =>
      'Applied to memories, summaries, and answers alike.';

  @override
  String get settingsSectionMemories => 'MEMORIES';

  @override
  String get settingsInstructionsMemoriesLabel => 'When writing memories';

  @override
  String get settingsSectionSummaries => 'SUMMARIES';

  @override
  String get settingsInstructionsSummariesLabel => 'When writing summaries';

  @override
  String get settingsSectionAsk => 'ASK';

  @override
  String get settingsInstructionsAskLabel => 'When answering questions';

  @override
  String get settingsSectionSpeakers => 'SPEAKERS';

  @override
  String get settingsDiarizationTitle => 'Speaker diarization';

  @override
  String get settingsDiarizationDescription =>
      'Separate overlapping speakers during transcription.';

  @override
  String get settingsRecurringSpeakerTitle => 'Recurring speaker matching';

  @override
  String get settingsRecurringSpeakerDescription =>
      'Match known voiceprints across recordings.';

  @override
  String get settingsInstructionsMemoriesHint =>
      'Always name who was there.\nKeep decisions and promises separate from small talk.';

  @override
  String get settingsInstructionsMemoriesHelper =>
      'Used while an occasion is written up into a memory card, and when memories are rewritten or merged.';

  @override
  String get settingsInstructionsSummariesHint =>
      'Five lines at most.\nLead with what changed.';

  @override
  String get settingsInstructionsSummariesHelper =>
      'Used for the daily summary and for the running summary of a conversation while it is still being recorded.';

  @override
  String get settingsInstructionsAskHint =>
      'Answer in two sentences, then stop.';

  @override
  String get settingsInstructionsAskHelper =>
      'Used for every answer on the Ask tab.';

  @override
  String get settingsSpeakerIdentityUnavailable =>
      'Your server cannot tell voices apart right now, so new recordings will not be split by speaker. Running setup on the server installs what it needs. Names you have already given a speaker are kept.';

  @override
  String get settingsDeferredSpeakerTitle =>
      'Review speakers when a conversation ends';

  @override
  String get settingsDeferredSpeakerDescription =>
      'Look again at who spoke once the whole conversation can be heard, so one person is not listed several times. Speaker labels may change shortly after a recording finishes.';

  @override
  String get settingsNavGeneral => 'General';

  @override
  String get settingsNavGeneralDescription => 'Time and locale';

  @override
  String get settingsNavSecurity => 'Security';

  @override
  String get settingsNavSecurityDescription => 'Passwords and 2FA';

  @override
  String get settingsNavRecording => 'Recording';

  @override
  String get settingsNavRecordingDescription => 'Schedule, network, chunks';

  @override
  String get settingsNavMemory => 'Memory';

  @override
  String get settingsNavMemoryDescription => 'Consolidation timing';

  @override
  String get settingsNavInstructions => 'Instructions';

  @override
  String get settingsNavInstructionsDescription =>
      'How the model writes for you';

  @override
  String get settingsNavSpeakers => 'Speakers';

  @override
  String get settingsNavSpeakersDescription => 'Diarization and matching';

  @override
  String get settingsNavWatch => 'Watch';

  @override
  String get settingsNavWatchDescription => 'Wear OS setup and digest';

  @override
  String get settingsNavDevices => 'Account devices';

  @override
  String get settingsNavDevicesDescription => 'Sessions and access';

  @override
  String get settingsNavServices => 'Services';

  @override
  String get settingsNavServicesDescription =>
      'Transcription and memory writing';

  @override
  String get settingsNavIntegrations => 'Integrations';

  @override
  String get settingsNavIntegrationsDescription => 'NeoAgent and MCP';

  @override
  String get settingsNavAreaLabel => 'Settings area';

  @override
  String get settingsNavAreasHeading => 'Settings areas';

  @override
  String get navRecord => 'Record';

  @override
  String get navSources => 'Sources';

  @override
  String get navMoments => 'Moments';

  @override
  String get navMemories => 'Memories';

  @override
  String get navHighlights => 'Highlights';

  @override
  String get navSpeakers => 'Speakers';

  @override
  String get navAsk => 'Ask';

  @override
  String get navSettings => 'Settings';

  @override
  String get navCapture => 'Capture';

  @override
  String get navLibrary => 'Library';

  @override
  String get shellAccountFallback => 'Account';

  @override
  String get shellControlSurface => 'CONTROL SURFACE';

  @override
  String get shellSignOut => 'Sign out';

  @override
  String get shellBatteryWarning =>
      'Battery optimization may suspend always-on capture on this device.';

  @override
  String get shellBatteryFix => 'Fix';

  @override
  String get shellOffline =>
      'Offline — capture continues; uploads resume when reconnected.';

  @override
  String get shellRecordingActive => 'Recording is active.';

  @override
  String get shellRecordingOpen => 'Open';

  @override
  String shellSyncing(String label) {
    return 'Syncing $label';
  }

  @override
  String get authPasswordsDoNotMatch => 'Passwords do not match.';

  @override
  String get authTwoFactorTitle => 'Enter 2FA code';

  @override
  String get authRegisterTitle => 'Create your NeoRecall account';

  @override
  String get authSignInTitle => 'Sign in';

  @override
  String get authTwoFactorSubtitle =>
      'Open your authenticator app and enter the current NeoRecall code.';

  @override
  String get authRegisterSubtitle =>
      'Your first account becomes the NeoRecall administrator for this server.';

  @override
  String get authSignInSubtitle => 'Enter your NeoRecall account details.';

  @override
  String get authRetryLocalStartup => 'Retry local startup';

  @override
  String get authTwoFactorFieldLabel => '2FA or recovery code';

  @override
  String get authUsernameLabel => 'Username';

  @override
  String get authEmailLabel => 'Email (optional)';

  @override
  String get authPasswordLabel => 'Password';

  @override
  String get authConfirmPasswordLabel => 'Confirm password';

  @override
  String get authVerify => 'Verify';

  @override
  String get authCreateAccount => 'Create account';

  @override
  String get authSecurityKeySignIn => 'Sign in with a security key';

  @override
  String get authSwitchToSignIn => 'Already have an account? Sign in';

  @override
  String get authSwitchToRegister => 'Need a new account? Register';

  @override
  String get authServerButton => 'Server';

  @override
  String get authWelcomeEyebrow => 'WELCOME TO NEORECALL';

  @override
  String get authSetUpOrConnect => 'Set up or connect NeoRecall';

  @override
  String get authConnect => 'Connect NeoRecall';

  @override
  String get authSetUpOrConnectBody =>
      'Install NeoRecall on this computer without a terminal, or enter the address of a server that is already running.';

  @override
  String get authConnectBody =>
      'Enter the address of the NeoRecall server this device should use.';

  @override
  String get authInstallLocally => 'Set up NeoRecall on this computer';

  @override
  String get authOrConnectRunning => 'or connect to a running server';

  @override
  String get authServerAddressLabel => 'NeoRecall server address';

  @override
  String get authConnectToServer => 'Connect to this server';

  @override
  String get authBackToSignIn => 'Back to sign in';

  @override
  String get askNewQuestion => 'New question';

  @override
  String get askHint => 'Ask anything about your day';

  @override
  String get askFollowUpHint => 'Ask a follow-up';

  @override
  String get askStarterToday => 'What did I do today?';

  @override
  String get askStarterFollowUps =>
      'What did I say I would follow up on this week?';

  @override
  String get askStarterYesterday =>
      'Who did I talk to yesterday, and about what?';

  @override
  String get askEyebrow => 'Recall';

  @override
  String get askDescription =>
      'Your recall, in your own words. Retrieval and the answer both run wherever your NeoRecall server does — no query leaves it.';

  @override
  String get askStartWith => 'Start with';

  @override
  String askWeakMatches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count weaker matches were left out — they share words with the question, not meaning.',
      one:
          '1 weaker match was left out — it shares words with the question, not meaning.',
    );
    return '$_temp0';
  }

  @override
  String get askSourcesExpanded => 'SOURCES';

  @override
  String get askSourcesCollapsed => 'SHOW SOURCES';

  @override
  String askPeriodRead(String period) {
    return 'Read $period';
  }

  @override
  String askPeriodFrom(String time) {
    return 'from $time';
  }

  @override
  String askPeriodUntil(String time) {
    return 'until $time';
  }

  @override
  String get askNothingRecorded => 'nothing recorded';

  @override
  String get askSubmitTooltip => 'Ask';

  @override
  String get askSearching => 'Searching your recall';

  @override
  String memoriesBulkDeleted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count memories deleted',
      one: '1 memory deleted',
    );
    return '$_temp0';
  }

  @override
  String memoriesBulkPinned(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count memories pinned',
      one: '1 memory pinned',
    );
    return '$_temp0';
  }

  @override
  String memoriesBulkUnpinned(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count memories unpinned',
      one: '1 memory unpinned',
    );
    return '$_temp0';
  }

  @override
  String memoriesBulkArchived(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count memories archived',
      one: '1 memory archived',
    );
    return '$_temp0';
  }

  @override
  String memoriesBulkRestored(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count memories restored',
      one: '1 memory restored',
    );
    return '$_temp0';
  }

  @override
  String memoriesBulkUpdated(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count memories updated',
      one: '1 memory updated',
    );
    return '$_temp0';
  }

  @override
  String memoriesBulkFailed(String error) {
    return 'Could not update memories: $error';
  }

  @override
  String memoriesRenameFailed(String error) {
    return 'Could not rename: $error';
  }

  @override
  String get memoriesMergeTitle => 'Merge memories?';

  @override
  String memoriesMergeBody(int count) {
    return 'Combine $count memories into one. Highlights and conversation evidence stay; a new title and description are written for the combined moment.';
  }

  @override
  String get memoriesMergeConfirm => 'Merge';

  @override
  String get memoriesMergedQueued =>
      'Memories merged. The description will update shortly.';

  @override
  String get memoriesMerged => 'Memories merged.';

  @override
  String memoriesMergeFailed(String error) {
    return 'Could not merge memories: $error';
  }

  @override
  String get memoriesRenameDialogTitle => 'Rename memory';

  @override
  String get memoriesTitleLabel => 'Title';

  @override
  String get actionDone => 'Done';

  @override
  String get actionSelect => 'Select';

  @override
  String get memoriesDescription =>
      'Your conversations, distilled into clear memories and actionable highlights.';

  @override
  String get memoriesRestore => 'Restore';

  @override
  String get memoriesArchive => 'Archive';

  @override
  String get memoriesEmptyFilteredTitle => 'No matching memories';

  @override
  String get memoriesEmptyTitle => 'Nothing here yet';

  @override
  String get memoriesEmptyFilteredMessage =>
      'Try another filter or clear the search.';

  @override
  String get memoriesEmptyMessage =>
      'Keep recording. When a conversation ends, NeoRecall quietly turns it into a memory.';

  @override
  String get memoriesNoActionItemsTitle => 'No action items yet';

  @override
  String get memoriesNoActionItemsMessage =>
      'Concrete assignments and commitments will appear here when a conversation creates them.';

  @override
  String momentsDeleteTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count moments?',
      one: 'Delete this moment?',
    );
    return '$_temp0';
  }

  @override
  String get momentsDeleteBodyOne =>
      'This will permanently delete this conversation and its transcript. A memory that came only from this conversation will be removed too.';

  @override
  String get momentsDeleteBodyMany =>
      'This will permanently delete these conversations and their transcripts. Memories that came only from them will be removed too.';

  @override
  String get actionDelete => 'Delete';

  @override
  String momentsDeleted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count moments deleted',
      one: '1 moment deleted',
    );
    return '$_temp0';
  }

  @override
  String momentsDeleteFailed(String error) {
    return 'Could not delete moments: $error';
  }

  @override
  String get momentsDescription =>
      'A compact stream of conversations. Expand only the ones you want to read in full.';

  @override
  String get momentsEmptyNoTranscript => 'No transcript yet';

  @override
  String get momentsEmptyNothing => 'Nothing to show yet';

  @override
  String get momentsEmptyNoTranscriptMessage =>
      'Start a recording or import audio. Persisted segments will appear here.';

  @override
  String get momentsEmptyNothingMessage =>
      'Your recordings are safe. They will appear here once the above is sorted out.';

  @override
  String get momentsToday => 'Today';

  @override
  String momentsGroupCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count moments',
      one: '1 moment',
    );
    return '$_temp0';
  }

  @override
  String get momentsStatusPending => 'Being sorted';

  @override
  String get momentsStatusSetAside => 'Waiting on a summary';

  @override
  String get momentsStatusAwaitsWriteUp => 'Summary on the way';

  @override
  String get momentsListen => 'Listen';

  @override
  String get momentsUnassignedSpeaker => 'Unassigned';

  @override
  String get momentsJustRecorded => 'Just recorded';

  @override
  String get momentsConversation => 'Conversation';

  @override
  String get momentsLoadingRest => 'Loading the rest of this moment';

  @override
  String momentsShowingFirstLines(int shown, int total) {
    return 'Showing the first $shown of $total lines.';
  }

  @override
  String get momentsShowLess => 'Show less';

  @override
  String momentsMoreLines(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count more lines',
      one: '1 more line',
    );
    return '$_temp0';
  }

  @override
  String get momentsWritingUp => 'Writing up';

  @override
  String get momentsWriteUpAgain => 'Write up again';

  @override
  String get momentsWriteUpNow => 'Write up now';

  @override
  String get momentsRecordingBadge => 'Recording';

  @override
  String get momentsNewer => 'Newer';

  @override
  String get momentsOlder => 'Older';

  @override
  String momentsPage(int page) {
    return 'Page $page';
  }

  @override
  String get momentsSelectPrompt => 'Select moments';

  @override
  String momentsSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String get momentsAllSelected => 'All moments selected';

  @override
  String get momentsSelectAll => 'Select all moments';

  @override
  String get speakersRenameTitle => 'Name recurring speaker';

  @override
  String get speakersDisplayNameLabel => 'Display name';

  @override
  String get speakersMergeIntoTitle => 'Merge another voice into this speaker';

  @override
  String get speakersUnnamed => 'Unnamed recurring speaker';

  @override
  String speakersDeleteManyTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count speakers?',
      one: 'Delete 1 speaker?',
    );
    return '$_temp0';
  }

  @override
  String get speakersDeleteManyBody =>
      'This will permanently delete these speaker profiles. Associated transcript segments will no longer identify them.';

  @override
  String speakersDeleted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count speakers deleted',
      one: '1 speaker deleted',
    );
    return '$_temp0';
  }

  @override
  String speakersDeleteFailed(String error) {
    return 'Could not delete speakers: $error';
  }

  @override
  String get speakersCombineTargetTitle => 'Combine into which speaker?';

  @override
  String speakersCombined(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count speakers combined',
      one: '1 speaker combined',
    );
    return '$_temp0';
  }

  @override
  String speakersCombineFailed(String error) {
    return 'Could not combine speakers: $error';
  }

  @override
  String get speakersUpToDate => 'Speaker profiles are already up to date';

  @override
  String speakersMergedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matching speaker profiles merged',
      one: '1 matching speaker profile merged',
    );
    return '$_temp0';
  }

  @override
  String speakersReevaluateFailed(String error) {
    return 'Could not re-evaluate speakers: $error';
  }

  @override
  String speakersPreviewFailed(String error) {
    return 'Preview failed: $error';
  }

  @override
  String get speakersReevaluateTooltip =>
      'Re-evaluate and merge matching speakers';

  @override
  String get speakersDescription =>
      'Recognize a voice with a short clean sample, then name or merge its recurring profile.';

  @override
  String get speakersEmptyTitle => 'No recurring speakers yet';

  @override
  String get speakersEmptyMessage =>
      'A speaker appears after a full 10-second clean voice preview is available.';

  @override
  String get speakersDeleteOneTitle => 'Delete speaker?';

  @override
  String get speakersDeleteOneBody =>
      'This will permanently delete this speaker profile. Associated transcript segments will no longer identify this speaker.';

  @override
  String get speakersPausePreview => 'Pause voice preview';

  @override
  String get speakersPlayPreview => 'Play voice preview';

  @override
  String get speakersPreviewNeeded => 'A full clean voice preview is needed';

  @override
  String get speakersNameTooltip => 'Name speaker';

  @override
  String get speakersDeleteTooltip => 'Delete speaker';

  @override
  String get speakersSelectPrompt => 'Select speakers';

  @override
  String speakersSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String get speakersAllSelected => 'All speakers selected';

  @override
  String get speakersSelectAll => 'Select all speakers';

  @override
  String get speakersCombineTooltip => 'Combine into one speaker';

  @override
  String get monthShort1 => 'JAN';

  @override
  String get monthShort2 => 'FEB';

  @override
  String get monthShort3 => 'MAR';

  @override
  String get monthShort4 => 'APR';

  @override
  String get monthShort5 => 'MAY';

  @override
  String get monthShort6 => 'JUN';

  @override
  String get monthShort7 => 'JUL';

  @override
  String get monthShort8 => 'AUG';

  @override
  String get monthShort9 => 'SEP';

  @override
  String get monthShort10 => 'OCT';

  @override
  String get monthShort11 => 'NOV';

  @override
  String get monthShort12 => 'DEC';

  @override
  String get weekdayLong1 => 'MONDAY';

  @override
  String get weekdayLong2 => 'TUESDAY';

  @override
  String get weekdayLong3 => 'WEDNESDAY';

  @override
  String get weekdayLong4 => 'THURSDAY';

  @override
  String get weekdayLong5 => 'FRIDAY';

  @override
  String get weekdayLong6 => 'SATURDAY';

  @override
  String get weekdayLong7 => 'SUNDAY';

  @override
  String get recordConsentTitle => 'Recording consent and visible use';

  @override
  String get recordConsentBody =>
      'NeoRecall records privately spoken words. Record only when everyone has been informed and you are legally permitted to do so. Recording always remains visibly indicated; NeoRecall has no covert mode.';

  @override
  String get recordConsentAccept => 'I understand';

  @override
  String get recordDeviceNoAnswer => 'The device did not answer.';

  @override
  String get recordFootnoteOfflineDevice =>
      'This device records by itself — there is no live capture. Use “Sync device recordings” to pull and transcribe them.';

  @override
  String get recordFootnoteEitherSide =>
      'Start from the app or the device. Either side can stop. Recordings made while you were away still sync from the device.';

  @override
  String get recordFootnoteSystemAudio =>
      'System audio uses the OS screen-recording permission and captures audio only, not video frames.';

  @override
  String get recordOffline =>
      'You are offline. Capture continues locally and queued audio uploads automatically when the connection returns.';

  @override
  String get recordSourceWearable => 'Wearable';

  @override
  String get recordSourceDesk => 'NeoRecall Desk';

  @override
  String get recordSourcePhoneMicrophone => 'Phone microphone';

  @override
  String get recordSourceMicrophoneAndDevice => 'Microphone and device audio';

  @override
  String get recordSourceDeviceAudio => 'Device audio';

  @override
  String get recordSourceMicrophone => 'Microphone';

  @override
  String get recordNoteTitle => 'Add a note';

  @override
  String get recordNoteHint =>
      'Names, context, decisions, or anything the transcript may miss…';

  @override
  String get recordNoteSave => 'Save note';

  @override
  String get recordGreetingStillUp => 'Still up';

  @override
  String get recordGreetingMorning => 'Good morning';

  @override
  String get recordGreetingAfternoon => 'Good afternoon';

  @override
  String get recordGreetingEvening => 'Good evening';

  @override
  String get recordDurationUnderMinute => 'under a minute';

  @override
  String recordDurationMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get recordStateLive => 'LIVE';

  @override
  String get recordStateStandby => 'STANDBY';

  @override
  String get recordStateRecording => 'Recording';

  @override
  String get recordStateReady => 'Ready to record';

  @override
  String get recordStateDeviceSync => 'Recordings sync from the device';

  @override
  String get recordTodayLabel => 'Today';

  @override
  String get recordNothingToday => 'Nothing recorded yet today.';

  @override
  String get recordUntitledMoment => 'Untitled moment';

  @override
  String recordSegmentCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count segments',
      one: '1 segment',
    );
    return '$_temp0';
  }

  @override
  String get recordAllMoments => 'All moments →';

  @override
  String get recordContextFootnote =>
      'Add context as it happens. Every item is stored locally before it is synchronized.';

  @override
  String get recordInProgressTitle => 'Recording in progress';

  @override
  String get recordInProgressDescription =>
      'Mark important moments and add notes, images, or documents without leaving the recording.';

  @override
  String get recordContextTitle => 'Recording context';

  @override
  String get recordContextDescription =>
      'These sources help NeoRecall understand what matters and improve the final memory.';

  @override
  String get recordContextHighlight => 'Highlight';

  @override
  String get recordContextNote => 'Note';

  @override
  String get recordContextPhoto => 'Photo';

  @override
  String get recordContextFile => 'File';

  @override
  String get recordContextEmpty => 'No context added yet.';

  @override
  String get recordHighlightedMoment => 'Highlighted moment';

  @override
  String get recordVisibleAndActive => 'Recording is visible and active';

  @override
  String recordMomentCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count moments',
      one: '1 moment',
    );
    return '$_temp0';
  }

  @override
  String get securitySectionEyebrow => 'SECURITY';

  @override
  String get securityTwoFactorTitle => 'Two-factor authentication';

  @override
  String get securityTwoFactorDescription =>
      'Protect your account with an authenticator app.';

  @override
  String securityTwoFactorEnabled(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '2FA is enabled ($count recovery codes remaining)',
      one: '2FA is enabled (1 recovery code remaining)',
    );
    return '$_temp0';
  }

  @override
  String get securityDisableTwoFactor => 'Disable 2FA';

  @override
  String get securityRegenerateCodes => 'Regenerate codes';

  @override
  String get securityTwoFactorDisabled => '2FA is not enabled';

  @override
  String get securityEnableTwoFactor => 'Enable 2FA';

  @override
  String get securityKeysEyebrow => 'SECURITY KEYS';

  @override
  String get securityKeysTitle => 'Security keys';

  @override
  String get securityKeysDescription =>
      'Sign in with a hardware key or passkey instead of your password. A key that asks for a PIN or a fingerprint also replaces your two-factor code.';

  @override
  String get securityKeysNone => 'No security keys registered.';

  @override
  String get securityKeysAdd => 'Add security key';

  @override
  String get securityKeysUnsupported =>
      'This device cannot register security keys. Open NeoRecall in a browser over HTTPS to add one.';

  @override
  String get securityKeyFallbackName => 'Security key';

  @override
  String get securityKeyNeverUsed => 'Never used';

  @override
  String securityKeyLastUsed(String date) {
    return 'Last used $date';
  }

  @override
  String get actionRename => 'Rename';

  @override
  String get actionRemove => 'Remove';

  @override
  String get securityYourUsername => 'your username';

  @override
  String get securityEraseTitle => 'Erase everything you have recorded';

  @override
  String get securityEraseIntro =>
      'This empties your library but keeps your account. There is no undo and no backup you can ask to restore from.';

  @override
  String get securityEraseItem1 =>
      'Every recording, transcript and conversation';

  @override
  String get securityEraseItem2 =>
      'All memories, highlights and daily summaries';

  @override
  String get securityEraseItem3 => 'Named speakers and their voice profiles';

  @override
  String get securityEraseItem4 =>
      'Imported audio and anything still waiting to upload';

  @override
  String get securityKeptItem1 => 'Your account, password and security keys';

  @override
  String get securityKeptItem2 => 'Your settings and paired devices';

  @override
  String get securityEraseConfirm => 'Erase my data';

  @override
  String get securityErasedNotice => 'Everything you had recorded was erased.';

  @override
  String get securityDeleteAccountTitle => 'Delete your account';

  @override
  String get securityDeleteAccountIntro =>
      'This removes everything, permanently, and closes the account. There is no undo and no backup you can ask to restore from.';

  @override
  String get securityDeleteItem1 => 'Every transcript, conversation and memory';

  @override
  String get securityDeleteItem2 =>
      'Recordings still waiting to upload on this device';

  @override
  String get securityDeleteItem3 =>
      'Connected devices, security keys and sign-in history';

  @override
  String get securityDeleteItem4 =>
      'The account itself, and your ability to sign in';

  @override
  String get securityDeleteConfirm => 'Delete permanently';

  @override
  String get securityDeletedNotice =>
      'Your account and all its data were deleted.';

  @override
  String get securityDangerZone => 'DANGER ZONE';

  @override
  String get securityEraseCardDescription =>
      'Empties your library — recordings, transcripts, memories, highlights and voice profiles — and keeps your account, settings and paired devices. This cannot be undone.';

  @override
  String get securityEraseCardAction => 'Erase my data…';

  @override
  String get securityDeleteCardDescription =>
      'Removes everything above and closes the account itself, including your sign-in, security keys and connected devices. Nothing identifying you is kept. This cannot be undone.';

  @override
  String get securityDeleteCardAction => 'Delete account…';

  @override
  String get securityNameKeyTitle => 'Name this key';

  @override
  String get securityNameKeyMessage =>
      'Give the key a name you will recognise, for example \"YubiKey\".';

  @override
  String securityKeyDefaultName(int number) {
    return 'Security key $number';
  }

  @override
  String get securityRenameKeyTitle => 'Rename security key';

  @override
  String securityRenameKeyMessage(String name) {
    return 'Enter a new name for \"$name\".';
  }

  @override
  String get securityEnterPassword => 'Enter password';

  @override
  String get securityPasswordForDisable =>
      'Your current password is required to disable 2FA';

  @override
  String get securityPasswordRequired => 'Your current password is required.';

  @override
  String get securityEnterTwoFactorCode => 'Enter 2FA code';

  @override
  String get securityEnterAuthenticatorCode =>
      'Enter your current authenticator code.';

  @override
  String get securityScanQr => 'Scan this QR code in your authenticator app.';

  @override
  String get securityAuthenticatorCodeLabel => 'Authenticator code';

  @override
  String get actionVerify => 'Verify';

  @override
  String get securityRecoveryCodesTitle => 'Recovery Codes';

  @override
  String get securityRecoveryCodesBody =>
      'Save these codes in a secure place. They are shown only once.';

  @override
  String get destructiveYourPassword => 'Your password';

  @override
  String get destructiveCodeHelper =>
      'A current code, or one of your recovery codes.';

  @override
  String destructiveTypeToConfirm(String username) {
    return 'Type $username to confirm';
  }

  @override
  String get integrationsMcpEyebrow => 'MCP';

  @override
  String get integrationsMcpTitle => 'Connect Claude, ChatGPT, or Cursor';

  @override
  String get integrationsMcpDescription =>
      'Paste this MCP URL into Claude, ChatGPT (MCP), or Cursor. The client opens NeoRecall for sign-in and the same read-only consent as NeoAgent. Ask, ingest, and memory edits stay inside NeoRecall.';

  @override
  String get integrationsMcpCopied => 'MCP URL copied';

  @override
  String get integrationsMcpCopy => 'Copy MCP URL';

  @override
  String get integrationsConnectedEyebrow => 'CONNECTED APPS';

  @override
  String get integrationsNoneConnected =>
      'No apps are connected yet. After you authorize NeoAgent or an MCP client, it appears here so you can revoke it.';

  @override
  String get integrationsConnectedApp => 'Connected app';

  @override
  String get integrationsRevoke => 'Revoke';

  @override
  String get integrationsClientNeoAgent => 'NeoAgent';

  @override
  String get integrationsClientMcp => 'MCP client';

  @override
  String get integrationsClientOAuth => 'OAuth client';

  @override
  String get integrationsThisApp => 'this app';

  @override
  String get integrationsRevokeTitle => 'Revoke access?';

  @override
  String integrationsRevokeBody(String name) {
    return '$name will lose read-only access to this account until you connect it again.';
  }

  @override
  String get memoriesSearchHint => 'Search memories…';

  @override
  String get memoriesFilterAll => 'All';

  @override
  String get memoriesFilterPinned => 'Pinned';

  @override
  String get memoriesFilterThisWeek => 'This week';

  @override
  String get memoriesFilterMeetings => 'Meetings';

  @override
  String get memoriesFilterDecisions => 'Decisions';

  @override
  String get memoriesFilterOpenTasks => 'Open tasks';

  @override
  String memoriesFilterOpenTasksCount(int count) {
    return 'Open tasks ($count)';
  }

  @override
  String get memoriesFilterArchived => 'Archived';

  @override
  String get memoriesSelectPrompt => 'Select memories';

  @override
  String memoriesSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String get memoriesMergeTooltip => 'Merge';

  @override
  String get memoriesPin => 'Pin';

  @override
  String get memoriesUnpin => 'Unpin';

  @override
  String get memoriesTodaysStory => 'Today’s story';

  @override
  String get memoriesAllHighlights => 'All highlights';

  @override
  String memoriesDue(String date) {
    return 'Due $date';
  }

  @override
  String get memoriesReopen => 'Reopen';

  @override
  String get memoriesMarkDone => 'Mark done';

  @override
  String get memoryContextDialogTitle => 'Add memory context';

  @override
  String get memoryContextDialogHint =>
      'Add details that should improve this memory…';

  @override
  String get memoryContextDialogConfirm => 'Add and update';

  @override
  String get memoryDeleteTitle => 'Delete memory?';

  @override
  String get memoryDeleteBody =>
      'This removes the memory and its highlights. Transcripts stay available on the timeline.';

  @override
  String memoryLoadFailed(String error) {
    return 'Could not load details.\n$error';
  }

  @override
  String get memoryPeopleAndThings => 'People & things';

  @override
  String get memoryEntityUnknown => 'Unknown';

  @override
  String get memoryContextHeading => 'Context';

  @override
  String get memoryNoContext =>
      'No notes or files are attached to this memory.';

  @override
  String get memoryContextUsedByAi => 'Used by AI';

  @override
  String get memoryContextReadyForAi => 'Ready for AI';

  @override
  String get memoryContextRetry => 'Retry analysis';

  @override
  String get memoryContextRemove => 'Remove context';

  @override
  String get memoryFromConversation => 'From the conversation';

  @override
  String miniLoadFailed(String error) {
    return 'Could not load highlight.\n$error';
  }

  @override
  String miniFromMemory(String emoji, String title) {
    return 'From $emoji $title';
  }

  @override
  String get miniEvidence => 'Evidence';

  @override
  String get miniNoExcerpts => 'No transcript excerpts linked.';

  @override
  String get processingEtaUnderMinute => 'under a minute';

  @override
  String processingEtaMinutes(int minutes) {
    return 'about $minutes min';
  }

  @override
  String processingEtaHours(int hours) {
    return 'about $hours hr';
  }

  @override
  String processingEtaHoursMinutes(int hours, int minutes) {
    return 'about $hours hr $minutes min';
  }

  @override
  String get processingNeedsAttention => 'Processing needs attention';

  @override
  String get processingStageWatchTransfer => 'Downloading from device';

  @override
  String get processingStagePhoneQueue => 'Queued securely on this device';

  @override
  String get processingStageUpload => 'Uploading to server';

  @override
  String get processingStageServerQueue => 'Waiting in transcription queue';

  @override
  String get processingStageTranscription => 'Transcribing on server';

  @override
  String get processingStageFinalizing => 'Finalizing secure receipts';

  @override
  String get processingStageComplete => 'Everything is processed';

  @override
  String processingWatchAudioWaiting(String duration) {
    return '$duration of audio waiting';
  }

  @override
  String get processingWatchReceiving => 'Receiving encrypted audio';

  @override
  String processingWatchItemsWaiting(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items waiting',
      one: '1 item waiting',
    );
    return '$_temp0';
  }

  @override
  String get processingWatchNoBacklog => 'No device backlog';

  @override
  String get processingStepDeviceTransfer => 'Device transfer';

  @override
  String get processingStepStoredOnPhone => 'Stored on phone';

  @override
  String get processingNoLocalQueue => 'No recordings waiting locally';

  @override
  String processingReadyForUpload(int count) {
    return '$count ready for upload';
  }

  @override
  String get processingStepServerUpload => 'Server upload';

  @override
  String get processingNoUploadInFlight => 'No upload currently in flight';

  @override
  String processingUploadingNow(int count) {
    return '$count uploading now';
  }

  @override
  String get processingStepServerTranscription => 'Server transcription';

  @override
  String processingTranscribingQueued(int transcribing, int queued) {
    return '$transcribing transcribing · $queued queued';
  }

  @override
  String processingWaitingForWorker(int count) {
    return '$count waiting for a worker';
  }

  @override
  String get processingServerQueueClear => 'Server queue is clear';

  @override
  String get processingStepSafeCompletion => 'Safe completion';

  @override
  String get processingTranscriptPersisted =>
      'Transcript persisted; audio released';

  @override
  String processingVerifying(int count) {
    return '$count verifying persistence and deletion';
  }

  @override
  String get processingWaitingEarlierStages => 'Waiting for earlier stages';

  @override
  String processingPendingCount(int count) {
    return '$count pending';
  }

  @override
  String processingMbProtected(String size) {
    return '$size MB protected';
  }

  @override
  String processingEtaPrefix(String eta) {
    return 'ETA $eta';
  }

  @override
  String get processingEtaCalibrating => 'ETA calibrating';

  @override
  String get processingUploadOnMobileData => 'Upload once with mobile data';

  @override
  String get processingReviewQueued => 'Review queued audio';

  @override
  String get processingRetryFailed => 'Retry failed';

  @override
  String get processingSomethingNeedsAttention => 'Something needs attention';

  @override
  String get processingStillWorking => 'Still working on it';

  @override
  String processingDeviceHolding(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Your device is still holding $count recordings, so nothing has been lost.',
      one:
          'Your device is still holding 1 recording, so nothing has been lost.',
    );
    return '$_temp0';
  }

  @override
  String get processingUnderMinuteLeft => 'under a minute left';

  @override
  String get processingGettingAudio => 'Getting audio from your device';

  @override
  String processingUploadingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Uploading $count recordings',
      one: 'Uploading a recording',
    );
    return '$_temp0';
  }

  @override
  String processingTranscribingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Transcribing $count recordings',
      one: 'Transcribing a recording',
    );
    return '$_temp0';
  }

  @override
  String processingEtaMinutesLeft(int minutes) {
    return 'about $minutes min left';
  }

  @override
  String processingEtaHoursLeft(int hours) {
    return 'about $hours hr left';
  }

  @override
  String processingEtaHoursMinutesLeft(int hours, int minutes) {
    return 'about $hours hr $minutes min left';
  }

  @override
  String get deviceAddDevice => 'Add device';

  @override
  String get deviceConnected => 'Connected';

  @override
  String get deviceNotConnected => 'Not connected';

  @override
  String get deviceAddDeviceSemantics => 'Add a device';

  @override
  String deviceManageSemantics(String label) {
    return 'Manage $label';
  }

  @override
  String get deviceNoneTitle => 'No device yet';

  @override
  String get deviceNoneBody =>
      'NeoRecall records with the phone microphone until you connect a wearable or set up a Desk.';

  @override
  String get deviceScanning => 'Scanning…';

  @override
  String get deviceScanForWearables => 'Scan for wearables';

  @override
  String get deviceSetUpDesk => 'Set up a NeoRecall Desk';

  @override
  String get deviceRemembered => 'Remembered — not connected right now';

  @override
  String get deviceStatBattery => 'Battery';

  @override
  String get deviceStatSynced => 'Synced';

  @override
  String get deviceStatSyncedUnit => 'recordings';

  @override
  String get deviceStatLeft => 'Left';

  @override
  String get deviceStatQueued => 'queued';

  @override
  String get deviceOfflineFirstStreams =>
      'This device can record on its own as well. Anything it captured while you were away syncs here when it connects, or you can pull it now.';

  @override
  String get deviceOfflineFirstOnly =>
      'This device records on its own — press record and stop on the device itself. Recordings sync here when it connects, or you can pull them now.';

  @override
  String get deviceStranded =>
      'The device has recordings but no Wi-Fi. They can move to this phone over Bluetooth and upload from here later.';

  @override
  String get deviceMovingRecordings => 'Moving recordings…';

  @override
  String get deviceMoveRecordings => 'Move recordings to this phone';

  @override
  String get deviceScanAnother => 'Scan for another wearable';

  @override
  String get deviceDiagnostics => 'Device and sync diagnostics';

  @override
  String get deviceForget => 'Forget this device';

  @override
  String get sourceRecordFrom => 'Record from';

  @override
  String get sourceLockedWhileRecording =>
      'The source is locked while a recording is running.';

  @override
  String get sourceOneAtATime =>
      'Only one source records at a time. The choice sticks until you change it.';

  @override
  String get sourceThisComputer => 'This computer';

  @override
  String get sourcePhoneSubtitle => 'Always available, nothing to connect';

  @override
  String get sourceComputerSubtitle =>
      'Microphone, and system audio if you want it';

  @override
  String get sourceDeviceAudioDesktop =>
      'Device audio — everything this machine plays';

  @override
  String get sourceTabOrSystemAudio => 'Tab or system audio';

  @override
  String get sourceNoWearable => 'No wearable connected yet';

  @override
  String sourceConnectedWithBattery(Object battery) {
    return 'Connected · $battery%';
  }

  @override
  String get sourceScan => 'Scan';

  @override
  String get sourceDeskNotSetUp => 'Not set up';

  @override
  String get sourceSetUp => 'Set up';

  @override
  String get sourceDeskSubtitle => 'Records the room on its own';

  @override
  String get sourceFoundNearby => 'Found nearby';

  @override
  String sourceReadyForAudio(String type) {
    return '$type · ready for audio';
  }

  @override
  String get sourceWearableFallback => 'wearable';

  @override
  String get sourceReconnect => 'Reconnect';

  @override
  String get sourceConnect => 'Connect';

  @override
  String get sourceImportAudio => 'Import an audio file';

  @override
  String get sourceConsentNote =>
      'Recording privately spoken words may require everyone’s consent. NeoRecall never hides that it is recording.';

  @override
  String get sourceWebBluetoothNote =>
      'The browser opens its own Bluetooth chooser, and capture continues only while this tab stays active.';

  @override
  String get libraryTitle => 'Library';

  @override
  String get floatingConsentTitle => 'Before you record';

  @override
  String get floatingOpenLibrary => 'Open library';

  @override
  String get floatingHide => 'Hide';

  @override
  String get devicesEmptyTitle => 'No devices yet';

  @override
  String get devicesEmptyMessage =>
      'Apps appear here after their first recording. A NeoRecall Desk appears once you set it up.';

  @override
  String get devicesAddDesk => 'Add a NeoRecall Desk';

  @override
  String get devicesRevoked => 'REVOKED';

  @override
  String get devicesNotRecentlyConnected => 'not recently connected';

  @override
  String get devicesClockOffset =>
      'Device clock differs by more than two minutes';

  @override
  String get devicesRevokeTooltip => 'Revoke device';

  @override
  String get pendingAudioTitle => 'Review queued audio';

  @override
  String get pendingAudioSubtitle =>
      'Local playback only · upload continues normally';

  @override
  String get actionClose => 'Close';

  @override
  String get audioHeadphonesWarning =>
      'Recording is active. Use headphones to avoid recording the playback again.';

  @override
  String get actionRefresh => 'Refresh';

  @override
  String get pendingAudioEmpty =>
      'No retained audio is currently available to review.';

  @override
  String get actionPause => 'Pause';

  @override
  String get actionPlay => 'Play';

  @override
  String get diagnosticsCopied => 'Diagnostic report copied.';

  @override
  String get diagnosticsCleared => 'Diagnostic log cleared.';

  @override
  String get diagnosticsTitle => 'Device & sync diagnostics';

  @override
  String get diagnosticsDescription =>
      'Bluetooth scan/connect, device sync, and import events for this account. Passwords, tokens, audio, transcripts, and other accounts are never included.';

  @override
  String get diagnosticsPreparing => 'Preparing…';

  @override
  String get diagnosticsCopyReport => 'Copy full report';

  @override
  String get diagnosticsClearLog => 'Clear log';

  @override
  String get diagnosticsEmpty =>
      'No diagnostic events yet. Connect a device and sync to populate this log, then refresh.';

  @override
  String get trayQuickCapture => 'Quick capture';

  @override
  String get trayOpenLibrary => 'Open notes library';

  @override
  String get trayStopRecording => 'Stop recording';

  @override
  String get trayQuit => 'Quit';

  @override
  String get audioBack10 => 'Back 10 seconds';

  @override
  String get audioForward10 => 'Forward 10 seconds';

  @override
  String get importChooseAudio => 'Choose audio';

  @override
  String get importTitle => 'Import existing audio';

  @override
  String get importDescription =>
      'WAV, MP3, M4A, and other ffmpeg-supported formats use the same private transcription pipeline.';

  @override
  String syncTransferringProgress(int percent, String remaining) {
    return 'Transferring $percent% · $remaining left';
  }

  @override
  String get syncTransferring => 'Transferring from the device…';

  @override
  String syncWaitingOnDevice(String duration) {
    return '$duration waiting on the device';
  }

  @override
  String syncSyncedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count recordings synced',
      one: '1 recording synced',
    );
    return '$_temp0';
  }

  @override
  String get floatingConsentBody =>
      'Tell everyone that NeoRecall is recording and make sure you are allowed to capture the conversation. Recording is always visibly indicated.';

  @override
  String sourcesLoadFailed(String error) {
    return 'Failed to load sources: $error';
  }

  @override
  String sourcesUpdateFailed(String error) {
    return 'Failed to update: $error';
  }

  @override
  String get sourcesDisconnect => 'Disconnect';

  @override
  String get sourcesDisconnectBody =>
      'Stop this source? Existing transcripts stay in NeoRecall.';

  @override
  String sourcesDisconnectFailed(String error) {
    return 'Failed to disconnect: $error';
  }

  @override
  String get sourcesDescription =>
      'Services that can feed NeoRecall audio. Wearables and a NeoRecall Desk are set up from Record.';

  @override
  String get sourcesLiveCapture => 'Live capture';

  @override
  String get sourcesEmptyTitle => 'Nothing to connect yet';

  @override
  String get sourcesEmptyMessage =>
      'Live sources appear here as they become available for your account.';

  @override
  String sourcesLastSynced(String when) {
    return 'Last synced $when';
  }

  @override
  String get sourcesHowItWorks => 'How it works';

  @override
  String get sourcesOauthNote =>
      'NeoRecall imports cloud recordings after the platform finishes them — it does not join the live call.';

  @override
  String get sourcesJustNow => 'just now';

  @override
  String sourcesMinutesAgo(int minutes) {
    return '${minutes}m ago';
  }

  @override
  String sourcesHoursAgo(int hours) {
    return '${hours}h ago';
  }

  @override
  String get sourcesSyncNow => 'Sync now';

  @override
  String get sourceStatusConnected => 'Connected';

  @override
  String get sourceStatusError => 'Error';

  @override
  String get sourceStatusNotConfigured => 'Not configured';

  @override
  String get sourceStatusPaused => 'Paused';

  @override
  String get discordDefaultName => 'My Discord Bot';

  @override
  String discordError(String error) {
    return 'Error: $error';
  }

  @override
  String get discordTitle => 'Connect Discord';

  @override
  String get discordDescription =>
      'NeoRecall joins voice channels as a bot and records the people you list. Create a bot in the Discord Developer Portal, invite it to your server, then paste its token here.';

  @override
  String get discordUsersLabel => 'Users to record';

  @override
  String get discordUsersHelper => 'Comma-separated Discord usernames';

  @override
  String get discordTokenLabel => 'Bot token';

  @override
  String get discordTokenHelper => 'Stored only on your NeoRecall server';

  @override
  String get discordHowTo => 'How to create the bot';

  @override
  String get discordIntentsNote =>
      'No privileged intents are required. The bot only listens — it never speaks.';

  @override
  String get discordConnect => 'Connect Account';

  @override
  String get discordSteps =>
      '1. Open the Discord Developer Portal and create an application.\n2. Open the \"Bot\" tab, then \"Reset Token\" and copy the token into the field above.\n3. In \"OAuth2 → URL Generator\", tick the \"bot\" scope and the \"View Channels\", \"Connect\", and \"Speak\" permissions.\n4. Open the generated URL and invite the bot to your server.\n\nNo privileged intents are required. The bot only listens — it never speaks.';

  @override
  String get apiRequestTimeout =>
      'The server did not respond in time. Check that it is running and reachable, then try again.';

  @override
  String get apiServerUnreachable =>
      'NeoRecall could not connect to the server. Check that it is online and that this device can reach it.';

  @override
  String apiInvalidResponse(int status) {
    return 'The server returned a response NeoRecall could not read (HTTP $status).';
  }

  @override
  String apiServerUnavailable(int status) {
    return 'The NeoRecall server is unavailable (HTTP $status). Try again shortly or check the server.';
  }

  @override
  String apiRequestRejected(int status) {
    return 'The NeoRecall server rejected the request (HTTP $status).';
  }

  @override
  String get apiUploadInterrupted =>
      'The connection was interrupted while uploading. It will retry automatically.';

  @override
  String get apiContextUploadInterrupted =>
      'The context upload was interrupted. It remains stored locally and will retry.';

  @override
  String get apiImportInterrupted =>
      'The connection was interrupted while uploading. Try the import again.';

  @override
  String get controllerSecurityKeyAdded => 'Security key added.';

  @override
  String get controllerWrongPassword => 'That password is not correct.';

  @override
  String get controllerInvalidTwoFactor =>
      'That authentication code is not valid. Codes expire quickly — try the current one.';

  @override
  String get controllerTwoFactorRequired =>
      'This account needs an authenticator code to confirm.';

  @override
  String controllerDeleteFailed(String error) {
    return 'The account could not be deleted: $error';
  }

  @override
  String controllerNoNewRecordings(String device) {
    return 'No new recordings on $device to sync.';
  }

  @override
  String controllerSyncFailed(String device, String message) {
    return 'Sync of $device failed: $message';
  }

  @override
  String get controllerIncompleteUrl =>
      'Enter a complete server URL including http:// or https://.';

  @override
  String get controllerWidgetStopped =>
      'Recording stopped from the home-screen widget.';

  @override
  String get controllerWidgetSignIn =>
      'Sign in to complete highlights from the home screen.';

  @override
  String get controllerWidgetStarted =>
      'Phone recording started from the home-screen widget.';

  @override
  String controllerWidgetStartFailed(String error) {
    return 'The home-screen widget could not start recording: $error';
  }

  @override
  String get controllerScheduleWaiting =>
      'Recording is waiting for the next configured daily window.';

  @override
  String controllerRecoveryWaiting(String error) {
    return 'Background recording recovery is waiting: $error';
  }

  @override
  String controllerSourceRecoveryFailed(String error) {
    return 'Audio source recovery failed: $error';
  }

  @override
  String get controllerCaptureRecovered =>
      'Audio capture recovered after an interruption.';

  @override
  String get controllerTimelineLoadFailed =>
      'That part of the timeline could not be loaded just now.';

  @override
  String get controllerMomentLoadFailed =>
      'The rest of this moment could not be loaded just now.';

  @override
  String get controllerRewriteQueued =>
      'Writing this moment up again. It will update here when ready.';

  @override
  String get controllerImportQueued =>
      'Import uploaded. Local transcription has been queued.';

  @override
  String get controllerNoteEmpty => 'Write a note before saving it.';

  @override
  String controllerNoteTooLong(int maximum) {
    return 'Notes may contain at most $maximum characters.';
  }

  @override
  String get controllerFileTooLarge =>
      'This file is larger than the server limit.';

  @override
  String get controllerContextWhileRecording =>
      'Context can only be added while recording is active.';

  @override
  String get controllerContextStorageUnavailable =>
      'Recording context storage is unavailable.';

  @override
  String get controllerContextIntegrity =>
      'The locally stored context file failed its integrity check.';

  @override
  String get controllerMergeTooFew => 'Select at least two memories to merge.';

  @override
  String controllerMergeTooMany(int maximum) {
    return 'Select at most $maximum memories to merge.';
  }

  @override
  String get controllerStorageFull => 'Storage full — recording stopped';

  @override
  String liveEtaLeft(String duration) {
    return 'about $duration left';
  }

  @override
  String get liveStorageFullDetail =>
      'Free device storage, then reopen NeoRecall to resume safely.';

  @override
  String get liveStorageFullIssue =>
      'No local space remains for another durable audio block.';

  @override
  String get liveSourceBluetooth => 'Bluetooth device';

  @override
  String liveRecordingFrom(String source) {
    return 'Recording from $source';
  }

  @override
  String get liveRecordingUploading =>
      'Recording safely · uploading in background';

  @override
  String get liveRecordingSafely => 'Recording safely to this device';

  @override
  String get liveWatchTransferDetail =>
      'Audio is moving into protected phone storage';

  @override
  String get liveUploadingTitle => 'Uploading recordings';

  @override
  String get liveUploadingDetail =>
      'Local originals stay protected until processing is verified';

  @override
  String get liveTranscribingDetail =>
      'Audio is safely stored while the transcript is created';

  @override
  String get liveFinalizingTitle => 'Finalizing transcript';

  @override
  String get liveFinalizingDetail =>
      'Waiting for verified persistence and server audio deletion';

  @override
  String get liveQueuedTitle => 'Recordings safely queued';

  @override
  String get liveQueuedDetail => 'Waiting for the next processing step';

  @override
  String get liveIdleTitle => 'NeoRecall is ready';

  @override
  String get liveIdleDetail => 'No recording or processing is active';

  @override
  String liveBytesQueued(String size) {
    return '$size queued';
  }

  @override
  String get widgetIdleTitle => 'Ready to record';

  @override
  String get widgetIdleDetail => 'Nothing is capturing or waiting.';

  @override
  String get statusManualRetry => 'A recording needs a manual upload retry.';

  @override
  String get statusUploadFailed =>
      'A recording upload failed and will retry automatically.';

  @override
  String get statusOffline =>
      'Offline — audio remains safely stored on this device.';

  @override
  String get statusWaitingForWifi =>
      'Waiting for Wi‑Fi because mobile-data uploads are disabled.';

  @override
  String get watchDigestSent => 'Today was sent to the watch.';

  @override
  String get watchCheckAgain => 'Check again';

  @override
  String get watchTitle => 'Record from your wrist';

  @override
  String get watchDescription =>
      'The watch records on its own and holds every clip until this phone confirms it was transcribed and the server copy deleted. Today’s transcript, memories and commitments are sent back to the watch so they can be read without the phone.';

  @override
  String get watchLooking => 'Looking for paired watches…';

  @override
  String get watchSending => 'Sending…';

  @override
  String get watchSendToday => 'Send today now';

  @override
  String get watchNotInstalled => 'NeoRecall not installed';

  @override
  String get watchOutOfRange => 'Installed · out of range';

  @override
  String get watchConnected => 'Installed · connected';

  @override
  String get watchReady => 'READY';

  @override
  String get watchSetUp => 'SET UP';

  @override
  String get watchNonePaired =>
      'No paired watch found. Pair the watch with this phone in the Wear OS app first — NeoRecall can only see watches Android has already paired.';

  @override
  String get watchInstallEyebrow => 'Installing on the watch';

  @override
  String get watchInstallIntro =>
      'NeoRecall for Wear OS ships as its own APK, signed with the same key as this app, and is sideloaded once. It is not on the Play Store, so the watch needs developer options turned on for the install and nothing after that.';

  @override
  String get watchStep1Title => 'Download the watch APK';

  @override
  String get watchStep1Detail =>
      'Take NeoRecall-WearOS-<version>.apk from the latest release, onto a computer that is on the same network as the watch.';

  @override
  String get watchReleasesLabel => 'Releases';

  @override
  String get watchStep2Title => 'Turn on wireless debugging on the watch';

  @override
  String get watchStep2Detail =>
      'Settings → System → About → tap Build number seven times, then Settings → Developer options → ADB debugging and Wireless debugging. The watch shows its IP address there.';

  @override
  String get watchStep3Title => 'Install it over Wi-Fi';

  @override
  String get watchStep3Detail =>
      'From the computer holding the APK, with the watch IP from the previous step:';

  @override
  String get watchConnectLabel => 'Connect';

  @override
  String get watchInstallLabel => 'Install';

  @override
  String get watchStep4Title => 'Open it once on the watch';

  @override
  String get watchStep4Detail =>
      'Allow the microphone, and this page turns to Installed. Add the NeoRecall tiles by long-pressing the watch face, and the complications from the watch face editor.';

  @override
  String get watchInstallFootnote =>
      'Developer options can be turned back off afterwards — the app stays installed and keeps working.';

  @override
  String get providerContinue => 'Continue';

  @override
  String providerChoose(String workload) {
    return 'Choose a $workload provider.';
  }

  @override
  String providerNeedsBaseUrl(String provider) {
    return '$provider needs a base URL.';
  }

  @override
  String get providerSaved =>
      'Saved. The server uses these services from now on.';

  @override
  String get providerLoadFailed => 'The provider settings could not be loaded.';

  @override
  String get providerTryAgain => 'Try again';

  @override
  String get providerIntro =>
      'NeoRecall does the speech detection and speaker matching itself, but the words and the written memories come from services you choose.';

  @override
  String get providerTesting => 'Testing…';

  @override
  String get providerSaving => 'Saving…';

  @override
  String get providerSaveAndTest => 'Save and test';

  @override
  String get providerSaveOnly => 'Save only';

  @override
  String get providerSetUpLater => 'Set these up later';

  @override
  String get providerKeyStored => 'key stored';

  @override
  String get providerServiceLabel => 'Service';

  @override
  String get providerBaseUrlLabel => 'Base URL';

  @override
  String get providerApiKeyStoredLabel =>
      'API key (leave empty to keep the stored one)';

  @override
  String get providerApiKeyLabel => 'API key';

  @override
  String get providerModelOptionalLabel => 'Model (optional)';

  @override
  String get providerModelLabel => 'Model';

  @override
  String get providerFindModels => 'Find models';

  @override
  String get providerLegTranscription => 'Transcription';

  @override
  String get providerLegSpeakerIdentity => 'Speaker identity';

  @override
  String get providerLegMemoryWriting => 'Memory writing';

  @override
  String get providerTranscriptionSubtitle =>
      'Turns recorded speech into words. Speaker identity stays on this machine.';

  @override
  String get providerMemorySubtitle =>
      'Writes titles, summaries, and memories from the transcript.';

  @override
  String installFailed(String error) {
    return 'NeoRecall setup could not finish: $error';
  }

  @override
  String get installFailedShort => 'NeoRecall setup could not finish.';

  @override
  String get actionBack => 'Back';

  @override
  String get installEyebrow => 'LOCAL SETUP';

  @override
  String get installIntro =>
      'NeoRecall will be downloaded from GitHub, installed as a background service, and connected to this app. Both channels can be switched later.';

  @override
  String get installChannelStable => 'Stable';

  @override
  String get installChannelStableDescription =>
      'Released versions only. Recommended for daily use.';

  @override
  String get installChannelRecommended => 'Recommended';

  @override
  String get installChannelBeta => 'Beta';

  @override
  String get installChannelBetaDescription =>
      'New features first, with the rough edges that come with them.';

  @override
  String get installDirectoryLabel => 'Install directory';

  @override
  String installMissingRequirements(String items) {
    return 'Install $items on this computer first, then check again.';
  }

  @override
  String get installCheckAgain => 'Check again';

  @override
  String installStart(String channel) {
    return 'Install the $channel channel';
  }

  @override
  String get installPreparing => 'Preparing NeoRecall…';

  @override
  String get installModelsNote =>
      'The first install downloads about 165 MB of local models, so this can take a few minutes.';

  @override
  String get installDetails => 'Setup details';

  @override
  String installRunning(String location) {
    return 'NeoRecall is running$location. One step left: choose the services that transcribe your recordings and write your memories.';
  }

  @override
  String installLocationAt(String url) {
    return ' at $url';
  }

  @override
  String get installNoAdminKey =>
      'This computer would not store the administrator key, so these services can be set up now but not changed from Settings later. The admin dashboard at /admin can still change them.';

  @override
  String get installCreateAccount => 'Create your account';

  @override
  String installDone(String version) {
    return 'NeoRecall is installed and running$version.';
  }

  @override
  String installVersionSuffix(String version) {
    return ' ($version)';
  }

  @override
  String installCliNotLinked(String directory) {
    return 'The neorecall terminal command was not linked. NeoRecall runs anyway; run \"npm link\" in $directory if you want the command.';
  }

  @override
  String get installChooseServices =>
      'Choose transcription and memory services';

  @override
  String get actionRetry => 'Retry';

  @override
  String get installChangeOptions => 'Change options';

  @override
  String get installTitle => 'Set up NeoRecall on this computer';

  @override
  String get wifiPasswordLabel => 'Network password';

  @override
  String get wifiShowPassword => 'Show password';

  @override
  String get wifiHidePassword => 'Hide password';

  @override
  String get wifiJoin => 'Join';

  @override
  String get applianceOpen => 'Open';

  @override
  String applianceRecordingElapsed(String elapsed) {
    return 'Recording · $elapsed';
  }

  @override
  String get applianceRecording => 'Recording';

  @override
  String get applianceNotSeenYet => 'Not seen yet';

  @override
  String get applianceReady => 'Ready';

  @override
  String applianceLastSeenMinutes(int minutes) {
    return 'Last seen $minutes minutes ago';
  }

  @override
  String applianceLastSeenHours(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'Last seen $hours hours ago',
      one: 'Last seen 1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String applianceLastSeenDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'Last seen $days days ago',
      one: 'Last seen 1 day ago',
    );
    return '$_temp0';
  }

  @override
  String get applianceConnecting => 'Connecting…';

  @override
  String get applianceSettingsTooltip => 'Device settings';

  @override
  String get applianceRecordingBadge => 'RECORDING';

  @override
  String get applianceReadyBadge => 'READY';

  @override
  String get applianceOutOfRangeBadge => 'OUT OF RANGE';

  @override
  String get applianceOutOfRangeBody =>
      'Out of range. This page shows what the device last reported. A recording already running is not affected — the device keeps recording and sending on its own.';

  @override
  String get applianceSoundEyebrow => 'SOUND';

  @override
  String get appliancePlaysOutOf => 'Plays out of';

  @override
  String get applianceSpeaker => 'Speaker';

  @override
  String get applianceHeadphones => 'Headphones';

  @override
  String get applianceRecordsWith => 'Records with';

  @override
  String get applianceOwnMicrophones => 'Its own microphones';

  @override
  String get applianceHeadset => 'Headset';

  @override
  String get applianceHeadsetQualityNote =>
      'While recording, what you hear drops in quality — that is how Bluetooth headsets work.';

  @override
  String get applianceHeadphonesEyebrow => 'HEADPHONES';

  @override
  String get applianceLooking => 'Looking…';

  @override
  String get applianceFind => 'Find';

  @override
  String get applianceNoHeadphones =>
      'No headphones yet. Put yours in pairing mode and tap Find.';

  @override
  String get applianceHeadphonePaired => 'Paired';

  @override
  String get applianceHeadphoneInRange => 'In range';

  @override
  String get applianceDisconnect => 'Disconnect';

  @override
  String get applianceConnect => 'Connect';

  @override
  String get applianceNotSetUp => 'Not set up yet';

  @override
  String applianceSending(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Sending $count recordings',
      one: 'Sending 1 recording',
    );
    return '$_temp0';
  }

  @override
  String applianceWaitingToSend(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count recordings waiting to be sent',
      one: '1 recording waiting to be sent',
    );
    return '$_temp0';
  }

  @override
  String applianceReadyWithHeadset(String headset) {
    return 'Ready · $headset';
  }

  @override
  String get applianceSettingsTitle => 'Device settings';

  @override
  String get applianceNameEyebrow => 'NAME';

  @override
  String get applianceNameHint => 'Desk in the study';

  @override
  String get applianceNetworkEyebrow => 'NETWORK';

  @override
  String get applianceChange => 'Change';

  @override
  String get applianceNetworkOnline =>
      'Connected. Recordings are sent when you stop recording.';

  @override
  String get applianceNetworkOffline =>
      'Not connected. Recordings are kept on the device until it is.';

  @override
  String get applianceSoundCheckEyebrow => 'SOUND CHECK';

  @override
  String get applianceSoundCheckLabel =>
      'Have the device play a tone and listen for it.';

  @override
  String get applianceCheck => 'Check';

  @override
  String get applianceSoftwareEyebrow => 'SOFTWARE';

  @override
  String get applianceVersionUnknown => 'Version unknown';

  @override
  String applianceVersion(String version) {
    return 'Version $version';
  }

  @override
  String get applianceCheckNow => 'Check now';

  @override
  String get applianceAutoUpdateTitle => 'Keep this device up to date';

  @override
  String get applianceAutoUpdateDescription =>
      'Checks once a day and installs new versions by itself. It never interrupts a recording — an update waits until you have stopped.';

  @override
  String get applianceRemoveEyebrow => 'REMOVE';

  @override
  String get applianceRemoveDescription =>
      'Takes this device off your account. Recordings already sent stay in NeoRecall; anything still waiting on the device is lost.';

  @override
  String get applianceRemoveAction => 'Remove this device';

  @override
  String get applianceRemoveTitle => 'Remove this device?';

  @override
  String applianceRemovePending(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'It still has $count recordings that have not been sent. Removing it now loses them.',
      one:
          'It still has 1 recording that has not been sent. Removing it now loses it.',
    );
    return '$_temp0';
  }

  @override
  String get applianceRemoveBody =>
      'You can set it up again at any time by holding its button for five seconds.';

  @override
  String get applianceKeepIt => 'Keep it';

  @override
  String get applianceBluetoothOff => 'Turn Bluetooth on to set up a device.';

  @override
  String get applianceBluetoothUnsupported =>
      'This device cannot use Bluetooth.';

  @override
  String get appliancePairFailed =>
      'Could not pair. Hold the button on the device for five seconds until it beeps three times, then try again.';

  @override
  String get applianceNoAnswer =>
      'The device did not answer. Check the network and try again.';

  @override
  String get applianceAddTitle => 'Add a NeoRecall Desk';

  @override
  String get applianceLookingIntro =>
      'Plug the device in and wait for its short rising tone. If it has been set up before, hold its button for five seconds first.';

  @override
  String get applianceNothingFound => 'Nothing found yet';

  @override
  String get applianceNothingFoundMessage =>
      'Hold the button on the device for five seconds, then look again.';

  @override
  String get applianceSetUpAction => 'Set up';

  @override
  String get applianceLookAgain => 'Look again';

  @override
  String appliancePressButton(String device) {
    return 'Press the button on $device';
  }

  @override
  String get applianceTheDevice => 'the device';

  @override
  String get appliancePressButtonWhy =>
      'The device has no screen, so pressing its button is how it knows the request came from someone standing next to it.';

  @override
  String get applianceLookingForNetworks => 'Looking for networks…';

  @override
  String get applianceNoNetworks => 'No networks found yet.';

  @override
  String get applianceSettingUp => 'Setting the device up…';

  @override
  String get applianceSettingUpDetail =>
      'It is joining your network and signing in.';

  @override
  String get applianceDoneTitle => 'Ready';

  @override
  String applianceDoneBody(String name) {
    return 'Choose \"$name\" as the speaker and microphone on your computer, then press its button to record.';
  }

  @override
  String get actionOk => 'OK';

  @override
  String watchCopyLabel(String label) {
    return 'Copy $label';
  }

  @override
  String backgroundRuntimeFailed(String error) {
    return 'Background runtime could not start: $error';
  }

  @override
  String backgroundStatusFailed(String error) {
    return 'Background status could not be updated: $error';
  }

  @override
  String backgroundHostUnavailable(String error) {
    return 'Android background host is temporarily unavailable: $error';
  }

  @override
  String get controllerWearableAudioStalled =>
      'Your recording device stopped sending audio. Recording is still open and waiting for it.';

  @override
  String get controllerWearableAudioLost =>
      'No audio is arriving from your recording device. Anything said now is not being recorded — reconnect it or record with the phone.';

  @override
  String controllerCaptureIncomplete(int minutes) {
    return 'Only part of this recording was captured; about $minutes minutes of audio never arrived from the recording device.';
  }
}
