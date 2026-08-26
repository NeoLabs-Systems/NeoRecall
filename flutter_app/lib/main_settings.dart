import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_devices.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'src/settings/security_section.dart';
import 'src/settings/settings_navigation.dart';

enum SettingsSection { general, security, recording, memory, speakers, devices }

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
    super.dispose();
  }

  Future<void> save() async {
    final current = settings;
    if (current == null || _customVocabularyError != null) return;
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
    });
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

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < AppBreakpoints.rail;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
      child: Column(
        children: <Widget>[
          ScreenHeader(
            eyebrow: 'SETTINGS',
            title: 'Settings',
            description:
                'Recording, memory, speakers, and capture devices in one place.',
            trailing: FilledButton.icon(
              onPressed:
                  widget.controller.loading ||
                      _savingUploadPolicy ||
                      settings == null ||
                      _customVocabularyError != null ||
                      selectedSection == SettingsSection.devices
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
                      const SizedBox(height: 16),
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
                      const SizedBox(width: 24),
                      Expanded(child: _content()),
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
    if (settings == null && selectedSection != SettingsSection.devices) {
      return const Center(child: CircularProgressIndicator());
    }
    return switch (selectedSection) {
      SettingsSection.general => _generalSettings(),
      SettingsSection.security => SecuritySection(controller: widget.controller),
      SettingsSection.recording => _recordingSettings(),
      SettingsSection.memory => _memorySettings(),
      SettingsSection.speakers => _speakerSettings(),
      SettingsSection.devices => DevicesPanel(controller: widget.controller),
    };
  }

  Widget _sectionList(List<Widget> children) {
    return ListView(
      padding: const EdgeInsets.only(right: 2, bottom: 32),
      children: <Widget>[..._statusMessages(), ...children],
    );
  }

  List<Widget> _statusMessages() => <Widget>[
    // Transient notices now render in the app-wide status bar (see main_shell),
    // so they are not duplicated here; errors stay inline with the settings form.
    if (widget.controller.error != null) ...<Widget>[
      InlineMessage(message: widget.controller.error!, error: true),
      const SizedBox(height: 14),
    ],
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

  Widget _memorySettings() {
    final palette = neoRecallPaletteOf(context);
    final current = settings!;
    return _sectionList(<Widget>[
      SectionCard(
        eyebrow: 'MEMORY',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Consolidation interval: ${((current['consolidationIntervalMs'] as int) / 3600000).toStringAsFixed(1)} hours',
              style: TextStyle(
                color: palette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            Slider(
              min: (current['effectiveConsolidationIntervalMs'] as int)
                  .toDouble(),
              max: 24 * 3600000,
              divisions: 23,
              value: (current['consolidationIntervalMs'] as int)
                  .clamp(
                    current['effectiveConsolidationIntervalMs'] as int,
                    24 * 3600000,
                  )
                  .toDouble(),
              onChanged: (value) => setState(
                () => current['consolidationIntervalMs'] = value.round(),
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

