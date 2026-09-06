import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_devices.dart';
import 'main_provider_setup.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'src/settings/integrations_section.dart';
import 'src/settings/security_section.dart';
import 'src/settings/settings_navigation.dart';
import 'src/install/admin_key_store.dart';
import 'src/install/admin_provider_client.dart';

enum SettingsSection {
  general,
  security,
  recording,
  memory,
  speakers,
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
  late SettingsSection selectedSection = widget.initialSection;
  bool _savingUploadPolicy = false;
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
      return 'Remove ${_customVocabularyTerms.length - maximumTerms} terms to save.';
    }
    if (_customVocabularyTerms.any(
      (term) => term.runes.length > maximumLength,
    )) {
      return 'Each term must be $maximumLength characters or fewer.';
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
    _adminClient?.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final current = settings;
    if (current == null || _customVocabularyError != null) return;
    final retention = current['contextOriginalRetentionDays'] as int? ?? 7;
    if (retention < _loadedContextRetentionDays) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Shorten original-file retention?'),
          content: Text(
            'Original photos, documents, and raw audio older than $retention days will be permanently deleted during the next cleanup. Transcripts and AI descriptions remain.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Shorten retention'),
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
      'diarizationEnabled': current['diarizationEnabled'],
      'chunkTargetMs': current['chunkTargetMs'],
      'chunkOverlapMs': current['chunkOverlapMs'],
      'uploadOnlyOnUnmetered': current['uploadOnlyOnUnmetered'],
      'recordingScheduleEnabled': current['recordingScheduleEnabled'],
      'recordingStartMinute': current['recordingStartMinute'],
      'recordingEndMinute': current['recordingEndMinute'],
      'customVocabulary': _customVocabularyTerms,
      'vocabularyCorrectionEnabled':
          current['vocabularyCorrectionEnabled'] as bool? ?? true,
      'contextOriginalRetentionDays': retention,
      'keepRawAudio': current['keepRawAudio'] as bool? ?? true,
    });
    _loadedContextRetentionDays = retention;
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Settings saved.')));
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
        SnackBar(content: Text('Could not update upload policy: $error')),
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
          title: const Text('Stop keeping raw audio?'),
          content: const Text(
            'Recordings already on this device will be deleted now. '
            'Transcripts, titles, and memories stay.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete raw audio'),
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
        SnackBar(content: Text('Could not update raw audio storage: $error')),
      );
    } finally {
      if (mounted) setState(() => _savingKeepRawAudio = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
            title: 'Settings',
            description:
                'Capture behaviour, memory, and account security in one place.',
            trailing: FilledButton.icon(
              onPressed:
                  widget.controller.loading ||
                      _savingUploadPolicy ||
                      settings == null ||
                      _customVocabularyError != null ||
                      selectedSection == SettingsSection.devices ||
                      selectedSection == SettingsSection.services ||
                      selectedSection == SettingsSection.integrations
                  ? null
                  : save,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('Save'),
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
        selectedSection != SettingsSection.devices &&
        selectedSection != SettingsSection.services &&
        selectedSection != SettingsSection.integrations) {
      return const Center(child: CircularProgressIndicator());
    }
    return switch (selectedSection) {
      SettingsSection.general => _generalSettings(),
      SettingsSection.security => SecuritySection(
        controller: widget.controller,
      ),
      SettingsSection.recording => _recordingSettings(),
      SettingsSection.memory => _memorySettings(),
      SettingsSection.speakers => _speakerSettings(),
      SettingsSection.devices => _devicesSettings(),
      SettingsSection.services => _servicesSettings(),
      SettingsSection.integrations => IntegrationsSection(
        controller: widget.controller,
      ),
    };
  }

  Widget _devicesSettings() {
    final palette = neoRecallPaletteOf(context);
    return _sectionList(<Widget>[
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Signed-in devices',
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  'Review access or revoke an old client. Set up, connect, and control capture hardware from Record.',
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
            label: const Text('Open Record'),
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
              message:
                  'These services are set on the server itself. This app has no '
                  'administrator key for ${widget.controller.backendUrl}, so ask '
                  'whoever runs that server to configure transcription and '
                  'memory writing there.',
              icon: Icons.info_outline,
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Services',
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
    return _sectionList(<Widget>[
      SectionCard(
        eyebrow: 'GENERAL',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Time and locale',
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Used to place recordings and generated memories on your local timeline.',
              style: TextStyle(color: palette.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: timezone,
              decoration: const InputDecoration(
                labelText: 'IANA timezone',
                prefixIcon: Icon(Icons.public_outlined),
              ),
              onChanged: (value) => settings!['timezone'] = value,
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _recordingSettings() {
    final palette = neoRecallPaletteOf(context);
    final current = settings!;
    final minimum = (current['chunkMinMs'] as int) / 1000;
    final maximum = (current['chunkMaxMs'] as int) / 1000;
    return _sectionList(<Widget>[
      SectionCard(
        eyebrow: 'ALWAYS-ON CAPTURE',
        child: Column(
          children: <Widget>[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: current['uploadOnlyOnUnmetered'] as bool? ?? true,
              onChanged: _savingUploadPolicy ? null : _setUploadOnlyOnUnmetered,
              title: const Text('Upload only on Wi-Fi / unmetered networks'),
              subtitle: const Text(
                'On by default. Recording continues to private app storage '
                'while offline or on mobile data, then uploads when an '
                'unmetered connection is available.',
              ),
            ),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: current['recordingScheduleEnabled'] as bool? ?? false,
              onChanged: (value) =>
                  setState(() => current['recordingScheduleEnabled'] = value),
              title: const Text('Daily recording window'),
              subtitle: const Text(
                'Uses this device’s local time. Off means 24/7; overnight '
                'windows such as 22:00–06:00 are supported.',
              ),
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
                        'Start ${_formatMinute(current['recordingStartMinute'] as int? ?? 0)}',
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
                        'Stop ${_formatMinute(current['recordingEndMinute'] as int? ?? 0)}',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'At the end time, the current chunk is finalized to on-device '
                'storage. Android may require opening NeoRecall before the '
                'phone microphone can restart at the next start time.',
                style: TextStyle(color: palette.textSecondary, height: 1.4),
              ),
            ],
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.multitrack_audio_outlined),
              title: const Text('Silence handling'),
              subtitle: const Text(
                'Server-side voice activity detection marks silent chunks. '
                'The phone keeps its copy until a terminal receipt proves '
                'processing completed and server audio was deleted.',
              ),
            ),
          ],
        ),
      ),
      SectionCard(
        eyebrow: 'RECORDING',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Chunk duration: ${((current['chunkTargetMs'] as int) / 1000).round()} seconds',
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
              'Boundary overlap: ${((current['chunkOverlapMs'] as int) / 1000).toStringAsFixed(1)} seconds',
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
        eyebrow: 'TRANSCRIPTION',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: customVocabulary,
              onChanged: (_) => setState(() {}),
              minLines: 4,
              maxLines: 10,
              decoration: InputDecoration(
                labelText: 'Words and phrases to recognize',
                hintText: 'NeoRecall\nProduct or company name\nTechnical term',
                helperText: 'One entry per line. Duplicates are ignored.',
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
              title: const Text('Correct close transcription misspellings'),
              subtitle: Text(
                'For providers without native vocabulary matching, only unambiguous single words of '
                '${current['vocabularyCorrectionMinimumLength'] ?? 8}+ characters are corrected.',
              ),
            ),
            if ((current['automaticSpeakerVocabulary'] as List<dynamic>? ??
                    const <dynamic>[])
                .isNotEmpty) ...<Widget>[
              const Divider(height: 28),
              Text(
                'Added automatically from named speakers',
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
        eyebrow: 'RECORDING CONTEXT',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SwitchListTile(
              key: const ValueKey<String>('keep-raw-audio'),
              contentPadding: EdgeInsets.zero,
              value: current['keepRawAudio'] as bool? ?? true,
              onChanged: _savingKeepRawAudio ? null : _setKeepRawAudio,
              title: const Text('Keep raw audio on this device'),
              subtitle: const Text(
                'On by default. Listen from Moments. The server still deletes '
                'its copy after transcription; only this phone keeps the file, '
                'and only until the retention period below.',
              ),
            ),
            const Divider(),
            Text(
              'Keep original photos, documents, and raw audio for ${current['contextOriginalRetentionDays'] as int? ?? 7} days',
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'After this period NeoRecall deletes the original bytes but keeps transcripts, extracted text, image descriptions, and source links.',
              style: TextStyle(color: palette.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 14),
            Slider(
              key: const ValueKey<String>('context-retention-days'),
              min: 1,
              max: 365,
              divisions: 364,
              label:
                  '${current['contextOriginalRetentionDays'] as int? ?? 7} days',
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
                      label: Text(days == 365 ? '1 year' : '$days days'),
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
              const InlineMessage(
                message:
                    'Shortening retention can permanently delete existing originals on the next server cleanup.',
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
        eyebrow: 'MEMORY',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Consolidation interval',
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              chosenHours == 0
                  ? 'As soon as there is enough material'
                  : 'Wait at least $chosenHours '
                        '${chosenHours == 1 ? 'hour' : 'hours'} between write-ups',
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
              label: chosenHours == 0 ? 'Immediate' : '${chosenHours}h',
              value: chosenHours.toDouble(),
              onChanged: (value) => setState(
                () => current['consolidationIntervalMs'] = value.round() * hour,
              ),
            ),
            Text(
              floorHours == 0
                  ? 'Memories are written when enough has been said, without '
                        'waiting for a conversation to end.'
                  : 'This server will not write up more often than every '
                        '$floorHours ${floorHours == 1 ? 'hour' : 'hours'}.',
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

  Widget _speakerSettings() {
    final current = settings!;
    // The server reports whether local speaker identity models are installed;
    // when unavailable these switches are shown off instead of left to flip.
    final available = current['speakerIdentityAvailable'] as bool? ?? true;
    return _sectionList(<Widget>[
      SectionCard(
        eyebrow: 'SPEAKERS',
        child: Column(
          children: <Widget>[
            if (!available)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Your server cannot tell voices apart right now, so new '
                  'recordings will not be split by speaker. Running setup on '
                  'the server installs what it needs. Names you have already '
                  'given a speaker are kept.',
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value:
                  available && (current['diarizationEnabled'] as bool? ?? true),
              onChanged: available
                  ? (value) =>
                        setState(() => current['diarizationEnabled'] = value)
                  : null,
              title: const Text('Speaker diarization'),
              subtitle: const Text(
                'Separate overlapping speakers during transcription.',
              ),
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
              title: const Text('Recurring speaker matching'),
              subtitle: const Text(
                'Match known voiceprints across recordings.',
              ),
            ),
          ],
        ),
      ),
    ]);
  }
}
