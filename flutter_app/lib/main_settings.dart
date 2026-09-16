import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_devices.dart';
import 'main_provider_setup.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'l10n/gen/app_l10n.dart';
import 'src/l10n/app_language.dart';
import 'src/settings/integrations_section.dart';
import 'src/settings/security_section.dart';
import 'src/settings/usage_section.dart';
import 'src/settings/watch_section.dart';
import 'src/settings/settings_navigation.dart';
import 'src/install/admin_key_store.dart';
import 'src/install/admin_provider_client.dart';

enum SettingsSection {
  general,
  security,
  usage,
  recording,
  memory,
  instructions,
  speakers,
  watch,
  devices,
  services,
  integrations,
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    this.initialSection = SettingsSection.general,
  });

  final NeoRecallController controller;
  final SettingsSection initialSection;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? settings;
  final timezone = TextEditingController();
  final customVocabulary = TextEditingController();
  // One field per area the model writes for, plus one that applies to all of
  // them. Kept as controllers rather than in `settings` so a half-typed
  // instruction survives switching areas and back.
  final instructionsGlobal = TextEditingController();
  final instructionsMemories = TextEditingController();
  final instructionsSummaries = TextEditingController();
  final instructionsAsk = TextEditingController();
  late SettingsSection selectedSection = widget.initialSection;
  bool _savingUploadPolicy = false;
  bool _changingLanguage = false;
  bool _savingKeepRawAudio = false;
  int _loadedContextRetentionDays = 7;
  AdminProviderClient? _adminClient;

  List<String> get _customVocabularyTerms {
    final unique = <String, String>{};
    for (final term
        in customVocabulary.text
            .split('\n')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)) {
      unique.putIfAbsent(term.toLowerCase(), () => term);
    }
    return unique.values.toList();
  }

  String? get _customVocabularyError {
    final current = settings;
    if (current == null) return null;
    final maximumTerms = current['customVocabularyMaxTerms'] as int? ?? 100;
    final maximumLength =
        current['customVocabularyMaxTermLength'] as int? ?? 120;
    if (_customVocabularyTerms.length > maximumTerms) {
      return AppL10n.of(
        context,
      ).settingsVocabularyTooMany(_customVocabularyTerms.length - maximumTerms);
    }
    if (_customVocabularyTerms.any(
      (term) => term.runes.length > maximumLength,
    )) {
      return AppL10n.of(context).settingsVocabularyTermTooLong(maximumLength);
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.loadSettings().then((value) {
      if (!mounted) return;
      timezone.text = value['timezone'] as String? ?? 'UTC';
      customVocabulary.text =
          (value['customVocabulary'] as List<dynamic>? ?? const <dynamic>[])
              .map((term) => term.toString())
              .join('\n');
      _loadedContextRetentionDays =
          value['contextOriginalRetentionDays'] as int? ?? 7;
      instructionsGlobal.text = value['instructionsGlobal'] as String? ?? '';
      instructionsMemories.text =
          value['instructionsMemories'] as String? ?? '';
      instructionsSummaries.text =
          value['instructionsSummaries'] as String? ?? '';
      instructionsAsk.text = value['instructionsAsk'] as String? ?? '';
      setState(() => settings = value);
    });
    // fetchTwoFactorStatus flips a flag and notifies synchronously; deferring to
    // after this frame avoids "setState during build" when the screen is first
    // inflated in response to a navigation rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.fetchTwoFactorStatus();
      widget.controller.fetchSecurityKeys();
    });
  }

  @override
  void dispose() {
    timezone.dispose();
    customVocabulary.dispose();
    instructionsGlobal.dispose();
    instructionsMemories.dispose();
    instructionsSummaries.dispose();
    instructionsAsk.dispose();
    _adminClient?.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final current = settings;
    if (current == null ||
        _customVocabularyError != null ||
        _instructionsError != null) {
      return;
    }
    final strings = AppL10n.of(context);
    final retention = current['contextOriginalRetentionDays'] as int? ?? 7;
    if (retention < _loadedContextRetentionDays) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(strings.settingsShortenRetentionTitle),
          content: Text(strings.settingsShortenRetentionBody(retention)),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(strings.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(strings.settingsShortenRetentionConfirm),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await widget.controller.updateSettings(<String, dynamic>{
      'consolidationIntervalMs': current['consolidationIntervalMs'],
      'timezone': current['timezone'],
      'recurringSpeakerMatching': current['recurringSpeakerMatching'],
      'deferredSpeakerResolution': current['deferredSpeakerResolution'],
      'diarizationEnabled': current['diarizationEnabled'],
      'chunkTargetMs': current['chunkTargetMs'],
      'chunkOverlapMs': current['chunkOverlapMs'],
      'uploadOnlyOnUnmetered': current['uploadOnlyOnUnmetered'],
      'recordingScheduleEnabled': current['recordingScheduleEnabled'],
      'recordingStartMinute': current['recordingStartMinute'],
      'recordingEndMinute': current['recordingEndMinute'],
      'customVocabulary': _customVocabularyTerms,
      'instructionsGlobal': instructionsGlobal.text.trim(),
      'instructionsMemories': instructionsMemories.text.trim(),
      'instructionsSummaries': instructionsSummaries.text.trim(),
      'instructionsAsk': instructionsAsk.text.trim(),
      'vocabularyCorrectionEnabled':
          current['vocabularyCorrectionEnabled'] as bool? ?? true,
      'contextOriginalRetentionDays': retention,
      'keepRawAudio': current['keepRawAudio'] as bool? ?? true,
    });
    _loadedContextRetentionDays = retention;
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.settingsSaved)));
  }

  Future<void> _setUploadOnlyOnUnmetered(bool value) async {
    final current = settings;
    if (current == null || _savingUploadPolicy) return;
    final previous = current['uploadOnlyOnUnmetered'] as bool? ?? true;
    setState(() {
      current['uploadOnlyOnUnmetered'] = value;
      _savingUploadPolicy = true;
    });
    try {
      // Network policy affects a running background queue, so it is applied
      // immediately instead of waiting for the page-level Save button.
      await widget.controller.updateSettings(<String, dynamic>{
        'uploadOnlyOnUnmetered': value,
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => current['uploadOnlyOnUnmetered'] = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppL10n.of(context).settingsUploadPolicyFailed(error.toString()),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingUploadPolicy = false);
    }
  }

  Future<void> _setKeepRawAudio(bool value) async {
    final current = settings;
    if (current == null || _savingKeepRawAudio) return;
    if (!value) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(AppL10n.of(context).settingsStopRawAudioTitle),
          content: Text(AppL10n.of(context).settingsStopRawAudioBody),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(AppL10n.of(context).actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(AppL10n.of(context).settingsStopRawAudioConfirm),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    final previous = current['keepRawAudio'] as bool? ?? true;
    setState(() {
      current['keepRawAudio'] = value;
      _savingKeepRawAudio = true;
    });
    try {
      await widget.controller.updateSettings(<String, dynamic>{
        'keepRawAudio': value,
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => current['keepRawAudio'] = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppL10n.of(context).settingsRawAudioFailed(error.toString()),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingKeepRawAudio = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < AppBreakpoints.rail;
    // The same gutter every other page uses. Settings had its own 28, which is
    // why it never quite lined up with the rest of the app.
    final gutter = width < AppBreakpoints.mobile
        ? AppSpacing.lg - 4
        : AppSpacing.lg;
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, compact ? 20 : 28, gutter, 0),
      child: Column(
        children: <Widget>[
          ScreenHeader(
            title: strings.settingsTitle,
            description: strings.settingsDescription,
            trailing: FilledButton.icon(
              onPressed:
                  widget.controller.loading ||
                      _savingUploadPolicy ||
                      settings == null ||
                      _customVocabularyError != null ||
                      _instructionsError != null ||
                      selectedSection == SettingsSection.watch ||
                      selectedSection == SettingsSection.devices ||
                      selectedSection == SettingsSection.services ||
                      selectedSection == SettingsSection.integrations ||
                      selectedSection == SettingsSection.usage
                  ? null
                  : save,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(strings.actionSave),
            ),
          ),
          Expanded(
            child: compact
                ? Column(
                    children: <Widget>[
                      SettingsNavigation(
                        selected: selectedSection,
                        compact: true,
                        onSelected: _select,
                        watchSupported:
                            widget.controller.isMobileCapturePlatform,
                      ),
                      const SizedBox(height: AppSpacing.md + 2),
                      Expanded(child: _content()),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        width: 240,
                        child: SettingsNavigation(
                          selected: selectedSection,
                          compact: false,
                          onSelected: _select,
                          watchSupported:
                              widget.controller.isMobileCapturePlatform,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      // Capped, not stretched: a settings row spanning a
                      // 2000px window is unreadable.
                      Expanded(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 720),
                            child: _content(),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  void _select(SettingsSection section) {
    setState(() => selectedSection = section);
  }

  Widget _content() {
    if (settings == null &&
        selectedSection != SettingsSection.watch &&
        selectedSection != SettingsSection.devices &&
        selectedSection != SettingsSection.services &&
        selectedSection != SettingsSection.integrations &&
        selectedSection != SettingsSection.usage) {
      return const Center(child: CircularProgressIndicator());
    }
    return switch (selectedSection) {
      SettingsSection.general => _generalSettings(),
      SettingsSection.security => SecuritySection(
        controller: widget.controller,
      ),
      SettingsSection.usage => UsageSection(controller: widget.controller),
      SettingsSection.recording => _recordingSettings(),
      SettingsSection.memory => _memorySettings(),
      SettingsSection.instructions => _instructionSettings(),
      SettingsSection.speakers => _speakerSettings(),
      SettingsSection.watch => WatchSection(controller: widget.controller),
      SettingsSection.devices => _devicesSettings(),
      SettingsSection.services => _servicesSettings(),
      SettingsSection.integrations => IntegrationsSection(
        controller: widget.controller,
      ),
    };
  }

  Widget _devicesSettings() {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    return _sectionList(<Widget>[
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  strings.settingsDevicesTitle,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  strings.settingsDevicesDescription,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          TextButton.icon(
            onPressed: () => widget.controller.selectPage(RecallPage.record),
            icon: const Icon(Icons.mic_none_rounded, size: 18),
            label: Text(strings.settingsOpenRecord),
          ),
        ],
      ),
      const SizedBox(height: AppSpacing.md),
      DevicesPanel(controller: widget.controller, scrollable: false),
    ]);
  }

  /// One settings pane. Sections are spaced by this list rather than by each
  /// section remembering to add a gap after itself — four cards that each
  /// forgot were what made the recording pane read as one long slab.
  /// One client per server and key: rebuilds must not leak a new HTTP client on
  /// every frame.
  AdminProviderClient _adminClientFor(String key) {
    final existing = _adminClient;
    if (existing != null &&
        existing.apiKey == key &&
        existing.backendUrl ==
            widget.controller.backendUrl.replaceFirst(RegExp(r'/$'), '')) {
      return existing;
    }
    existing?.dispose();
    final client = AdminProviderClient(
      backendUrl: widget.controller.backendUrl,
      apiKey: key,
    );
    _adminClient = client;
    return client;
  }

  /// Transcription and memory-writing services, configured through the admin
  /// API with the key stored when this app installed the server. Servers this
  /// app did not install have no stored key, and say so rather than showing an
  /// empty form.
  Widget _servicesSettings() {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    return _sectionList(<Widget>[
      FutureBuilder<String?>(
        future: const AdminKeyStore().read(widget.controller.backendUrl),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final key = snapshot.data;
          if (key == null) {
            return InlineMessage(
              message: strings.settingsServicesNoAdminKey(
                widget.controller.backendUrl,
              ),
              icon: Icons.info_outline,
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                strings.settingsServicesTitle,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              ProviderSetupPanel(client: _adminClientFor(key)),
            ],
          );
        },
      ),
    ]);
  }

  Widget _sectionList(List<Widget> children) {
    final blocks = <Widget>[..._statusMessages(), ...children];
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      itemCount: blocks.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm + 2),
      itemBuilder: (context, index) => blocks[index],
    );
  }

  List<Widget> _statusMessages() => <Widget>[
    // Transient notices now render in the app-wide status bar (see main_shell),
    // so they are not duplicated here; errors stay inline with the settings form.
    if (widget.controller.error != null)
      InlineMessage(message: widget.controller.error!, error: true),
  ];

  Widget _generalSettings() {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    return _sectionList(<Widget>[
      SectionCard(
        eyebrow: strings.settingsSectionGeneral,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              strings.settingsTimeLocaleTitle,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              strings.settingsTimeLocaleDescription,
              style: TextStyle(color: palette.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: timezone,
              decoration: InputDecoration(
                labelText: strings.settingsTimezoneLabel,
                prefixIcon: const Icon(Icons.public_outlined),
              ),
              onChanged: (value) => settings!['timezone'] = value,
            ),
            const Divider(height: 32),
            Text(
              strings.settingsLanguageTitle,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              strings.settingsLanguageDescription,
              style: TextStyle(color: palette.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 18),
            DropdownButtonFormField<AppLanguage>(
              initialValue: widget.controller.language,
              decoration: InputDecoration(
                labelText: strings.settingsLanguageLabel,
                prefixIcon: const Icon(Icons.translate_outlined),
              ),
              items: <DropdownMenuItem<AppLanguage>>[
                for (final language in AppLanguage.values)
                  DropdownMenuItem<AppLanguage>(
                    value: language,
                    child: Text(language.label),
                  ),
              ],
              onChanged: _changingLanguage ? null : _setLanguage,
            ),
          ],
        ),
      ),
    ]);
  }

  /// Applied immediately rather than on Save.
  ///
  /// The whole interface redraws in the new language the moment it is picked,
  /// so leaving the choice pending behind a Save button would show a German
  /// list under an English heading until the button was pressed.
  Future<void> _setLanguage(AppLanguage? value) async {
    if (value == null || value == widget.controller.language) return;
    setState(() => _changingLanguage = true);
    try {
      await widget.controller.setLanguage(value);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppL10n.of(context).settingsLanguageFailed(error.toString()),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _changingLanguage = false);
    }
  }

  Widget _recordingSettings() {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    final current = settings!;
    final minimum = (current['chunkMinMs'] as int) / 1000;
    final maximum = (current['chunkMaxMs'] as int) / 1000;
    return _sectionList(<Widget>[
      SectionCard(
        eyebrow: strings.settingsSectionAlwaysOn,
        child: Column(
          children: <Widget>[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: current['uploadOnlyOnUnmetered'] as bool? ?? true,
              onChanged: _savingUploadPolicy ? null : _setUploadOnlyOnUnmetered,
              title: Text(strings.settingsUnmeteredTitle),
              subtitle: Text(strings.settingsUnmeteredDescription),
            ),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: current['recordingScheduleEnabled'] as bool? ?? false,
              onChanged: (value) =>
                  setState(() => current['recordingScheduleEnabled'] = value),
              title: Text(strings.settingsScheduleTitle),
              subtitle: Text(strings.settingsScheduleDescription),
            ),
            if (current['recordingScheduleEnabled'] == true) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickScheduleMinute(
                        key: 'recordingStartMinute',
                        fallback: 0,
                      ),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(
                        strings.settingsScheduleStart(
                          _formatMinute(
                            current['recordingStartMinute'] as int? ?? 0,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickScheduleMinute(
                        key: 'recordingEndMinute',
                        fallback: 0,
                      ),
                      icon: const Icon(Icons.stop_rounded),
                      label: Text(
                        strings.settingsScheduleStop(
                          _formatMinute(
                            current['recordingEndMinute'] as int? ?? 0,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                strings.settingsScheduleFootnote,
                style: TextStyle(color: palette.textSecondary, height: 1.4),
              ),
            ],
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.multitrack_audio_outlined),
              title: Text(strings.settingsSilenceTitle),
              subtitle: Text(strings.settingsSilenceDescription),
            ),
          ],
        ),
      ),
      SectionCard(
        eyebrow: strings.settingsSectionRecording,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              strings.settingsChunkDuration(
                ((current['chunkTargetMs'] as int) / 1000).round(),
              ),
              style: TextStyle(
                color: palette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            Slider(
              min: minimum,
              max: maximum,
              value: ((current['chunkTargetMs'] as int) / 1000)
                  .clamp(minimum, maximum)
                  .toDouble(),
              onChanged: (value) => setState(
                () => current['chunkTargetMs'] = value.round() * 1000,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              strings.settingsChunkOverlap(
                ((current['chunkOverlapMs'] as int) / 1000).toStringAsFixed(1),
              ),
              style: TextStyle(
                color: palette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            Slider(
              min: 0,
              max: 5,
              divisions: 10,
              value: ((current['chunkOverlapMs'] as int) / 1000)
                  .clamp(0, 5)
                  .toDouble(),
              onChanged: (value) => setState(
                () => current['chunkOverlapMs'] = (value * 1000).round(),
              ),
            ),
          ],
        ),
      ),
      SectionCard(
        eyebrow: strings.settingsSectionTranscription,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: customVocabulary,
              onChanged: (_) => setState(() {}),
              minLines: 4,
              maxLines: 10,
              decoration: InputDecoration(
                labelText: strings.settingsVocabularyLabel,
                hintText: strings.settingsVocabularyHint,
                helperText: strings.settingsVocabularyHelper,
                errorText: _customVocabularyError,
                counterText:
                    '${_customVocabularyTerms.length}/${current['customVocabularyMaxTerms'] ?? 100} terms',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: current['vocabularyCorrectionEnabled'] as bool? ?? true,
              onChanged: (value) => setState(
                () => current['vocabularyCorrectionEnabled'] = value,
              ),
              title: Text(strings.settingsVocabularyCorrectionTitle),
              subtitle: Text(
                strings.settingsVocabularyCorrectionDescription(
                  current['vocabularyCorrectionMinimumLength'] ?? 8,
                ),
              ),
            ),
            if ((current['automaticSpeakerVocabulary'] as List<dynamic>? ??
                    const <dynamic>[])
                .isNotEmpty) ...<Widget>[
              const Divider(height: 28),
              Text(
                strings.settingsSpeakerVocabularyTitle,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children:
                    (current['automaticSpeakerVocabulary'] as List<dynamic>)
                        .map(
                          (name) => Chip(
                            avatar: const Icon(Icons.person_outline, size: 16),
                            label: Text(name.toString()),
                          ),
                        )
                        .toList(),
              ),
            ],
          ],
        ),
      ),
      SectionCard(
        eyebrow: strings.settingsSectionRecordingContext,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SwitchListTile(
              key: const ValueKey<String>('keep-raw-audio'),
              contentPadding: EdgeInsets.zero,
              value: current['keepRawAudio'] as bool? ?? true,
              onChanged: _savingKeepRawAudio ? null : _setKeepRawAudio,
              title: Text(strings.settingsKeepRawAudioTitle),
              subtitle: Text(strings.settingsKeepRawAudioDescription),
            ),
            const Divider(),
            Text(
              strings.settingsRetentionTitle(
                current['contextOriginalRetentionDays'] as int? ?? 7,
              ),
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              strings.settingsRetentionDescription,
              style: TextStyle(color: palette.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 14),
            Slider(
              key: const ValueKey<String>('context-retention-days'),
              min: 1,
              max: 365,
              divisions: 364,
              label: strings.settingsRetentionDays(
                current['contextOriginalRetentionDays'] as int? ?? 7,
              ),
              value: (current['contextOriginalRetentionDays'] as int? ?? 7)
                  .toDouble(),
              onChanged: (value) => setState(
                () => current['contextOriginalRetentionDays'] = value.round(),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <int>[1, 3, 7, 14, 30, 90, 365]
                  .map(
                    (days) => ChoiceChip(
                      label: Text(
                        days == 365
                            ? strings.settingsRetentionOneYear
                            : strings.settingsRetentionDays(days),
                      ),
                      selected:
                          (current['contextOriginalRetentionDays'] as int? ??
                              7) ==
                          days,
                      onSelected: (_) => setState(
                        () => current['contextOriginalRetentionDays'] = days,
                      ),
                    ),
                  )
                  .toList(),
            ),
            if ((current['contextOriginalRetentionDays'] as int? ?? 7) <
                _loadedContextRetentionDays) ...<Widget>[
              const SizedBox(height: 12),
              InlineMessage(
                message: strings.settingsRetentionWarning,
                icon: Icons.warning_amber_rounded,
              ),
            ],
          ],
        ),
      ),
    ]);
  }

  String _formatMinute(int minute) =>
      TimeOfDay(hour: minute ~/ 60, minute: minute % 60).format(context);

  Future<void> _pickScheduleMinute({
    required String key,
    required int fallback,
  }) async {
    final currentMinute = settings?[key] as int? ?? fallback;
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: currentMinute ~/ 60,
        minute: currentMinute % 60,
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => settings![key] = selected.hour * 60 + selected.minute);
  }

  /// How long finished material waits before it is written up.
  ///
  /// The floor comes from the server's own configuration, not from the value
  /// currently chosen: keying the slider's minimum off the *effective* interval
  /// meant every save raised the floor to whatever had just been saved, so the
  /// interval could only ever be increased.
  Widget _memorySettings() {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    final current = settings!;
    const hour = 3600000;
    const maximum = 24 * hour;
    final floor = (current['minConsolidationIntervalMs'] as int? ?? 0).clamp(
      0,
      maximum,
    );
    final chosen = (current['consolidationIntervalMs'] as int? ?? floor).clamp(
      floor,
      maximum,
    );
    // Whole hours, so the label never reads 3.1 hours. The floor stops at 23
    // so the slider always has a range to move through, even on an install
    // configured to write up at most once a day.
    final floorHours = (floor / hour).ceil().clamp(0, 23);
    final chosenHours = (chosen / hour).round().clamp(floorHours, 24);

    return _sectionList(<Widget>[
      SectionCard(
        eyebrow: strings.settingsSectionMemory,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              strings.settingsConsolidationTitle,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              chosenHours == 0
                  ? strings.settingsConsolidationImmediate
                  : strings.settingsConsolidationWait(chosenHours),
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 4),
            Slider(
              min: floorHours.toDouble(),
              max: 24,
              divisions: 24 - floorHours,
              label: chosenHours == 0
                  ? strings.settingsConsolidationSliderImmediate
                  : strings.settingsConsolidationSliderHours(chosenHours),
              value: chosenHours.toDouble(),
              onChanged: (value) => setState(
                () => current['consolidationIntervalMs'] = value.round() * hour,
              ),
            ),
            Text(
              floorHours == 0
                  ? strings.settingsConsolidationFloorNone
                  : strings.settingsConsolidationFloor(floorHours),
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    ]);
  }

  /// How long an instruction may be, and how much of it has been written.
  int get _instructionsLimit =>
      settings?['customInstructionsMaxCharacters'] as int? ?? 2000;

  String? get _instructionsError {
    final over = <TextEditingController>[
      instructionsGlobal,
      instructionsMemories,
      instructionsSummaries,
      instructionsAsk,
    ].where((field) => field.text.runes.length > _instructionsLimit).length;
    if (over == 0) return null;
    return AppL10n.of(
      context,
    ).settingsInstructionsTooLong(over, _instructionsLimit);
  }

  Widget _instructionField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required String helper,
  }) {
    final tooLong = controller.text.runes.length > _instructionsLimit;
    return TextField(
      controller: controller,
      onChanged: (_) => setState(() {}),
      minLines: 3,
      maxLines: 8,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 3,
        errorText: tooLong
            ? AppL10n.of(context).settingsInstructionsLimit(_instructionsLimit)
            : null,
        counterText: '${controller.text.runes.length}/$_instructionsLimit',
        alignLabelWithHint: true,
      ),
    );
  }

  /// Standing instructions for the language model, per area.
  ///
  /// Everything the model writes is a judgement call the product otherwise
  /// makes on the user's behalf — how long a summary runs, whose names get
  /// written out, which language an answer comes back in. This is where the
  /// account owner takes those calls back.
  Widget _instructionSettings() {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    return _sectionList(<Widget>[
      InlineMessage(
        icon: Icons.auto_awesome_outlined,
        message: strings.settingsInstructionsIntro,
      ),
      SectionCard(
        eyebrow: strings.settingsSectionEverywhere,
        child: _instructionField(
          controller: instructionsGlobal,
          label: strings.settingsInstructionsGlobalLabel,
          hint: strings.settingsInstructionsGlobalHint,
          helper: strings.settingsInstructionsGlobalHelper,
        ),
      ),
      SectionCard(
        eyebrow: strings.settingsSectionMemories,
        child: _instructionField(
          controller: instructionsMemories,
          label: strings.settingsInstructionsMemoriesLabel,
          hint: strings.settingsInstructionsMemoriesHint,
          helper: strings.settingsInstructionsMemoriesHelper,
        ),
      ),
      SectionCard(
        eyebrow: strings.settingsSectionSummaries,
        child: _instructionField(
          controller: instructionsSummaries,
          label: strings.settingsInstructionsSummariesLabel,
          hint: strings.settingsInstructionsSummariesHint,
          helper: strings.settingsInstructionsSummariesHelper,
        ),
      ),
      SectionCard(
        eyebrow: strings.settingsSectionAsk,
        child: _instructionField(
          controller: instructionsAsk,
          label: strings.settingsInstructionsAskLabel,
          hint: strings.settingsInstructionsAskHint,
          helper: strings.settingsInstructionsAskHelper,
        ),
      ),
      if (_instructionsError != null)
        Text(
          _instructionsError!,
          style: TextStyle(color: palette.danger, fontSize: 12.5, height: 1.4),
        ),
    ]);
  }

  Widget _speakerSettings() {
    final strings = AppL10n.of(context);
    final current = settings!;
    // The server reports whether local speaker identity models are installed;
    // when unavailable these switches are shown off instead of left to flip.
    final available = current['speakerIdentityAvailable'] as bool? ?? true;
    return _sectionList(<Widget>[
      SectionCard(
        eyebrow: strings.settingsSectionSpeakers,
        child: Column(
          children: <Widget>[
            if (!available)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(strings.settingsSpeakerIdentityUnavailable),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value:
                  available && (current['diarizationEnabled'] as bool? ?? true),
              onChanged: available
                  ? (value) =>
                        setState(() => current['diarizationEnabled'] = value)
                  : null,
              title: Text(strings.settingsDiarizationTitle),
              subtitle: Text(strings.settingsDiarizationDescription),
            ),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value:
                  available &&
                  (current['recurringSpeakerMatching'] as bool? ?? true),
              onChanged: available
                  ? (value) => setState(
                      () => current['recurringSpeakerMatching'] = value,
                    )
                  : null,
              title: Text(strings.settingsRecurringSpeakerTitle),
              subtitle: Text(strings.settingsRecurringSpeakerDescription),
            ),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value:
                  available &&
                  (current['deferredSpeakerResolution'] as bool? ?? true),
              onChanged: available
                  ? (value) => setState(
                      () => current['deferredSpeakerResolution'] = value,
                    )
                  : null,
              title: Text(strings.settingsDeferredSpeakerTitle),
              subtitle: Text(strings.settingsDeferredSpeakerDescription),
            ),
          ],
        ),
      ),
    ]);
  }
}
