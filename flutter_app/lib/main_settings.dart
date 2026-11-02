import 'dart:async';

import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_devices.dart';
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

export 'main_controller.dart' show SettingsSection;

/// Settings: one list of pages, grouped by what they affect. Every page is a
/// tap from the list, and every change saves as it is made.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    this.initialSection,
  });

  final NeoRecallController controller;

  /// Opens on this page instead of the one the controller remembers.
  final SettingsSection? initialSection;

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
  final _search = TextEditingController();

  /// The open page. Null on a phone while the page list is showing.
  late SettingsSection? _section =
      widget.initialSection ?? widget.controller.settingsSection;

  /// Saves still in flight, shown in the page header.
  int _saving = 0;
  bool _savingUploadPolicy = false;
  bool _changingLanguage = false;
  bool _savingKeepRawAudio = false;
  int _loadedContextRetentionDays = 7;

  /// Text settings save shortly after typing stops and when the field loses
  /// focus, each only when its text differs from what was last saved.
  late final Map<String, _TextAutosave> _textAutosaves =
      <String, _TextAutosave>{
        'timezone': _TextAutosave(_saveTimezone),
        'customVocabulary': _TextAutosave(_saveVocabulary),
        'instructionsGlobal': _TextAutosave(
          () => _saveInstruction('instructionsGlobal', instructionsGlobal),
        ),
        'instructionsMemories': _TextAutosave(
          () => _saveInstruction('instructionsMemories', instructionsMemories),
        ),
        'instructionsSummaries': _TextAutosave(
          () =>
              _saveInstruction('instructionsSummaries', instructionsSummaries),
        ),
        'instructionsAsk': _TextAutosave(
          () => _saveInstruction('instructionsAsk', instructionsAsk),
        ),
      };

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
    for (final autosave in _textAutosaves.values) {
      autosave.attach();
    }
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
    // Leaving the page with an edit still waiting saves it. The save runs after
    // this frame: the tree is locked while widgets are being disposed.
    for (final autosave in _textAutosaves.values) {
      autosave.dispose();
    }
    _search.dispose();
    timezone.dispose();
    customVocabulary.dispose();
    instructionsGlobal.dispose();
    instructionsMemories.dispose();
    instructionsSummaries.dispose();
    instructionsAsk.dispose();
    super.dispose();
  }

  /// Sends [changes] to the server now. [onFailed] puts the page back the way
  /// it was if the save does not go through.
  Future<void> _apply(
    Map<String, dynamic> changes, {
    VoidCallback? onFailed,
  }) async {
    if (mounted) setState(() => _saving++);
    try {
      await widget.controller.updateSettings(changes);
    } catch (error) {
      if (!mounted) return;
      setState(() => onFailed?.call());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppL10n.of(context).settingsSaveFailed(error.toString()),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving--);
    }
  }

  /// Saves one value of [settings] that a control has just changed.
  void _set(String key, Object? value) {
    final current = settings;
    if (current == null) return;
    final previous = current[key];
    current[key] = value;
    // A text field can save as the page closes, after this state is gone.
    if (mounted) setState(() {});
    unawaited(
      _apply(<String, dynamic>{
        key: value,
      }, onFailed: () => current[key] = previous),
    );
  }

  void _saveTimezone() {
    final value = timezone.text.trim();
    if (value.isEmpty || value == settings?['timezone']) return;
    _set('timezone', value);
  }

  void _saveVocabulary() {
    final current = settings;
    if (current == null) return;
    final terms = _customVocabularyTerms;
    // The same limits _customVocabularyError reports, checked without a
    // BuildContext because this can run as the page closes.
    final maximumTerms = current['customVocabularyMaxTerms'] as int? ?? 100;
    final maximumLength =
        current['customVocabularyMaxTermLength'] as int? ?? 120;
    if (terms.length > maximumTerms ||
        terms.any((term) => term.runes.length > maximumLength)) {
      return;
    }
    final saved = (current['customVocabulary'] as List<dynamic>? ?? const [])
        .map((term) => term.toString())
        .toList();
    if (terms.join('\n') == saved.join('\n')) return;
    _set('customVocabulary', terms);
  }

  void _saveInstruction(String key, TextEditingController field) {
    final current = settings;
    if (current == null) return;
    if (field.text.runes.length > _instructionsLimit) return;
    final value = field.text.trim();
    if (value == (current[key] as String? ?? '')) return;
    _set(key, value);
  }

  /// A shorter retention deletes recordings already past it, so it is
  /// confirmed before it is saved. A longer one saves straight away.
  Future<void> _commitRetention(int days) async {
    final current = settings;
    if (current == null) return;
    if (days < _loadedContextRetentionDays) {
      final strings = AppL10n.of(context);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(strings.settingsShortenRetentionTitle),
          content: Text(strings.settingsShortenRetentionBody(days)),
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
      if (!mounted) return;
      if (confirmed != true) {
        setState(
          () => current['contextOriginalRetentionDays'] =
              _loadedContextRetentionDays,
        );
        return;
      }
    }
    final previous = _loadedContextRetentionDays;
    _loadedContextRetentionDays = days;
    setState(() => current['contextOriginalRetentionDays'] = days);
    await _apply(
      <String, dynamic>{'contextOriginalRetentionDays': days},
      onFailed: () {
        _loadedContextRetentionDays = previous;
        current['contextOriginalRetentionDays'] = previous;
      },
    );
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
      await _apply(<String, dynamic>{
        'uploadOnlyOnUnmetered': value,
      }, onFailed: () => current['uploadOnlyOnUnmetered'] = previous);
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
      await _apply(<String, dynamic>{
        'keepRawAudio': value,
      }, onFailed: () => current['keepRawAudio'] = previous);
    } finally {
      if (mounted) setState(() => _savingKeepRawAudio = false);
    }
  }

  void _select(SettingsSection section) {
    _search.clear();
    setState(() => _section = section);
    widget.controller.selectSettingsSection(section);
  }

  void _showList() {
    setState(() => _section = null);
    widget.controller.selectSettingsSection(null);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < AppBreakpoints.rail;
    // The same gutter every other page uses.
    final gutter = width < AppBreakpoints.mobile
        ? AppSpacing.lg - 4
        : AppSpacing.lg;
    final padding = EdgeInsets.fromLTRB(gutter, compact ? 20 : 28, gutter, 0);
    final watchSupported = widget.controller.isMobileCapturePlatform;
    final query = _search.text.trim();
    final section = _section;

    if (compact && (section == null || query.isNotEmpty)) {
      return Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ScreenHeader(title: strings.settingsTitle),
            Expanded(
              child: SettingsNavigation(
                selected: null,
                compact: true,
                onSelected: _select,
                searchController: _search,
                onSearchChanged: () => setState(() {}),
                watchSupported: watchSupported,
              ),
            ),
          ],
        ),
      );
    }

    if (compact) {
      // On a phone a page sits on top of the list: back returns to it.
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _showList();
        },
        child: Padding(
          padding: padding.copyWith(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _showList,
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 16),
                  label: Text(strings.settingsTitle),
                ),
              ),
              _pageHeader(section!, compact: true),
              Expanded(child: _content(section)),
            ],
          ),
        ),
      );
    }

    final shown = section ?? SettingsSection.general;
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 240,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ScreenHeader(title: strings.settingsTitle),
                Expanded(
                  child: SettingsNavigation(
                    selected: query.isEmpty ? shown : null,
                    compact: false,
                    onSelected: _select,
                    searchController: _search,
                    onSearchChanged: () => setState(() {}),
                    watchSupported: watchSupported,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xl),
          // Capped, not stretched: a settings row spanning a 2000px window is
          // unreadable.
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: query.isNotEmpty
                    ? ListView(
                        children: <Widget>[
                          SettingsSearchResults(
                            query: query,
                            watchSupported: watchSupported,
                            onSelected: _select,
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          _pageHeader(shown, compact: false),
                          Expanded(child: _content(shown)),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The page's group, title and description, and whether a change is still
  /// being saved.
  Widget _pageHeader(SettingsSection section, {required bool compact}) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    final saving = _saving > 0;
    final status = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (saving)
          SizedBox.square(
            dimension: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: palette.textMuted,
            ),
          )
        else
          Icon(Icons.check_rounded, size: 15, color: palette.success),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            saving
                ? strings.settingsSaving
                : strings.settingsSavedAutomatically,
            style: TextStyle(color: palette.textMuted, fontSize: 12.5),
          ),
        ),
      ],
    );
    final header = ScreenHeader(
      eyebrow: section.group.label(strings),
      title: section.label(strings),
      description: section.description(strings),
      trailing: compact
          ? null
          : Padding(padding: const EdgeInsets.only(top: 4), child: status),
    );
    if (!compact) return header;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        header,
        Padding(padding: const EdgeInsets.only(bottom: 12), child: status),
      ],
    );
  }

  Widget _content(SettingsSection section) {
    if (settings == null &&
        section != SettingsSection.watch &&
        section != SettingsSection.devices &&
        section != SettingsSection.integrations &&
        section != SettingsSection.security &&
        section != SettingsSection.usage) {
      return const Center(child: CircularProgressIndicator());
    }
    return switch (section) {
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
      SettingsSection.integrations => IntegrationsSection(
        controller: widget.controller,
      ),
    };
  }

  Widget _devicesSettings() {
    final strings = AppL10n.of(context);
    return _sectionList(<Widget>[
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => widget.controller.selectPage(RecallPage.record),
          icon: const Icon(Icons.mic_none_rounded, size: 18),
          label: Text(strings.settingsOpenRecord),
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      DevicesPanel(controller: widget.controller, scrollable: false),
    ]);
  }

  /// One settings pane. Sections are spaced by this list rather than by each
  /// section remembering to add a gap after itself — four cards that each
  /// forgot were what made the recording pane read as one long slab.
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
              focusNode: _textAutosaves['timezone']!.focus,
              decoration: InputDecoration(
                labelText: strings.settingsTimezoneLabel,
                prefixIcon: const Icon(Icons.public_outlined),
              ),
              onChanged: (_) => _textAutosaves['timezone']!.changed(),
              onSubmitted: (_) => _textAutosaves['timezone']!.flush(),
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
              onChanged: (value) => _set('recordingScheduleEnabled', value),
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
              onChangeEnd: (value) =>
                  _set('chunkTargetMs', value.round() * 1000),
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
              onChangeEnd: (value) =>
                  _set('chunkOverlapMs', (value * 1000).round()),
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
              focusNode: _textAutosaves['customVocabulary']!.focus,
              onChanged: (_) {
                setState(() {});
                _textAutosaves['customVocabulary']!.changed();
              },
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
              onChanged: (value) => _set('vocabularyCorrectionEnabled', value),
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
              onChangeEnd: (value) => _commitRetention(value.round()),
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
                      onSelected: (_) => _commitRetention(days),
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
    _set(key, selected.hour * 60 + selected.minute);
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
              onChangeEnd: (value) =>
                  _set('consolidationIntervalMs', value.round() * hour),
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
    required String key,
    required TextEditingController controller,
    required String label,
    required String hint,
    required String helper,
  }) {
    final tooLong = controller.text.runes.length > _instructionsLimit;
    final autosave = _textAutosaves[key]!;
    return TextField(
      controller: controller,
      focusNode: autosave.focus,
      onChanged: (_) {
        setState(() {});
        autosave.changed();
      },
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
          key: 'instructionsGlobal',
          controller: instructionsGlobal,
          label: strings.settingsInstructionsGlobalLabel,
          hint: strings.settingsInstructionsGlobalHint,
          helper: strings.settingsInstructionsGlobalHelper,
        ),
      ),
      SectionCard(
        eyebrow: strings.settingsSectionMemories,
        child: _instructionField(
          key: 'instructionsMemories',
          controller: instructionsMemories,
          label: strings.settingsInstructionsMemoriesLabel,
          hint: strings.settingsInstructionsMemoriesHint,
          helper: strings.settingsInstructionsMemoriesHelper,
        ),
      ),
      SectionCard(
        eyebrow: strings.settingsSectionSummaries,
        child: _instructionField(
          key: 'instructionsSummaries',
          controller: instructionsSummaries,
          label: strings.settingsInstructionsSummariesLabel,
          hint: strings.settingsInstructionsSummariesHint,
          helper: strings.settingsInstructionsSummariesHelper,
        ),
      ),
      SectionCard(
        eyebrow: strings.settingsSectionAsk,
        child: _instructionField(
          key: 'instructionsAsk',
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
                  ? (value) => _set('diarizationEnabled', value)
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
                  ? (value) => _set('recurringSpeakerMatching', value)
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
                  ? (value) => _set('deferredSpeakerResolution', value)
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

/// Saves one text setting shortly after typing stops, when the field loses
/// focus, and when the page closes with an edit still waiting. The save itself
/// decides whether anything changed.
class _TextAutosave {
  _TextAutosave(this._save);

  final VoidCallback _save;
  final FocusNode focus = FocusNode();
  Timer? _timer;

  void attach() {
    focus.addListener(() {
      if (!focus.hasFocus) flush();
    });
  }

  void changed() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1200), _save);
  }

  void flush() {
    _timer?.cancel();
    _save();
  }

  void dispose() {
    final pending = _timer?.isActive ?? false;
    _timer?.cancel();
    if (pending) scheduleMicrotask(_save);
    focus.dispose();
  }
}
