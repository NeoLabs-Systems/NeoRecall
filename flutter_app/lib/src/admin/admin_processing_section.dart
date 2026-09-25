import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';
import '../api_client.dart';
import 'admin_client.dart';
import 'admin_widgets.dart';

/// Where a processing threshold sits on the page.
enum _SettingGroup {
  speakers,
  audio,
  transcript,
  conversations,
  memories,
  other,
}

_SettingGroup _groupOf(String key) => switch (key) {
  'voiceMatchThreshold' => _SettingGroup.speakers,
  'voiceMatchMargin' => _SettingGroup.speakers,
  'voiceEnrollFloor' => _SettingGroup.speakers,
  'voiceEnrollMinimumMs' => _SettingGroup.speakers,
  'voiceRepairThreshold' => _SettingGroup.speakers,
  'speakerClusterThreshold' => _SettingGroup.speakers,
  'speakerClusterMergeThreshold' => _SettingGroup.speakers,
  'speakerMinimumTurnMs' => _SettingGroup.speakers,
  'diarizationClusterDistance' => _SettingGroup.speakers,
  'speakerClusterMargin' => _SettingGroup.speakers,
  'speakerContinuityGapMs' => _SettingGroup.speakers,
  'speakerClusterContinuityThreshold' => _SettingGroup.speakers,
  'audioPreprocessEnabled' => _SettingGroup.audio,
  'audioPreprocessHighpassHz' => _SettingGroup.audio,
  'audioPreprocessDenoiseDb' => _SettingGroup.audio,
  'audioPreprocessMaxGain' => _SettingGroup.audio,
  'dedupeTokenSimilarity' => _SettingGroup.transcript,
  'dedupeTimeToleranceMs' => _SettingGroup.transcript,
  'transcriptRepetitionMinimumRepeats' => _SettingGroup.transcript,
  'transcriptRepetitionMaximumPatternWords' => _SettingGroup.transcript,
  'transcriptRepetitionMinimumCoverage' => _SettingGroup.transcript,
  'transcriptMaximumWordsPerSecond' => _SettingGroup.transcript,
  'conversationHardGapMs' => _SettingGroup.conversations,
  'conversationSoftGapMs' => _SettingGroup.conversations,
  'conversationMinimumMs' => _SettingGroup.conversations,
  'conversationQuietCloseMs' => _SettingGroup.conversations,
  'conversationValleyQuantile' => _SettingGroup.conversations,
  'conversationSemanticSimilarityThreshold' => _SettingGroup.conversations,
  'conversationSemanticValleyProminence' => _SettingGroup.conversations,
  'conversationSemanticContextSegments' => _SettingGroup.conversations,
  'conversationMaximumMs' => _SettingGroup.conversations,
  'conversationMaximumCharacters' => _SettingGroup.conversations,
  'conversationPreviewMinCharacters' => _SettingGroup.conversations,
  'conversationPreviewRefreshCharacters' => _SettingGroup.conversations,
  'conversationPreviewMinIntervalMs' => _SettingGroup.conversations,
  'conversationPreviewFullCharacters' => _SettingGroup.conversations,
  'minAiAudioMs' => _SettingGroup.memories,
  'minNewMaterialChars' => _SettingGroup.memories,
  'minMemoryEvidenceMs' => _SettingGroup.memories,
  'minMemoryEvidenceChars' => _SettingGroup.memories,
  'maxConsolidationInputChars' => _SettingGroup.memories,
  'maxConsolidationConversations' => _SettingGroup.memories,
  'maxMemoryContinuationCandidates' => _SettingGroup.memories,
  'memoryContinuationLookbackMs' => _SettingGroup.memories,
  'maxConsolidationLatencyMs' => _SettingGroup.memories,
  'memoryOccasionGapMs' => _SettingGroup.memories,
  'memorySettleMs' => _SettingGroup.memories,
  'memoryOccasionMaxWaitMs' => _SettingGroup.memories,
  'memoryDedupeEnabled' => _SettingGroup.memories,
  'memoryDedupeSimilarityThreshold' => _SettingGroup.memories,
  'memoryDedupeWindowMs' => _SettingGroup.memories,
  'memoryDedupeMaxPairsPerRun' => _SettingGroup.memories,
  'memoryDedupeNeighbours' => _SettingGroup.memories,
  'consolidationMaxFailures' => _SettingGroup.memories,
  _ => _SettingGroup.other,
};

String _groupLabel(AppL10n strings, _SettingGroup group) => switch (group) {
  _SettingGroup.speakers => strings.adminSettingsGroupSpeakers,
  _SettingGroup.audio => strings.adminSettingsGroupAudio,
  _SettingGroup.transcript => strings.adminSettingsGroupTranscript,
  _SettingGroup.conversations => strings.adminSettingsGroupConversations,
  _SettingGroup.memories => strings.adminSettingsGroupMemories,
  _SettingGroup.other => strings.adminSettingsGroupOther,
};

/// A threshold the server knows and this build does not keeps its own name
/// rather than disappearing.
String _settingLabel(AppL10n strings, String key) => switch (key) {
  'voiceMatchThreshold' => strings.adminSettingVoiceMatchThreshold,
  'voiceMatchMargin' => strings.adminSettingVoiceMatchMargin,
  'voiceEnrollFloor' => strings.adminSettingVoiceEnrollFloor,
  'voiceEnrollMinimumMs' => strings.adminSettingVoiceEnrollMinimumMs,
  'voiceRepairThreshold' => strings.adminSettingVoiceRepairThreshold,
  'speakerClusterThreshold' => strings.adminSettingSpeakerClusterThreshold,
  'speakerClusterMergeThreshold' =>
    strings.adminSettingSpeakerClusterMergeThreshold,
  'speakerMinimumTurnMs' => strings.adminSettingSpeakerMinimumTurnMs,
  'diarizationClusterDistance' =>
    strings.adminSettingDiarizationClusterDistance,
  'speakerClusterMargin' => strings.adminSettingSpeakerClusterMargin,
  'speakerContinuityGapMs' => strings.adminSettingSpeakerContinuityGapMs,
  'speakerClusterContinuityThreshold' =>
    strings.adminSettingSpeakerClusterContinuityThreshold,
  'audioPreprocessEnabled' => strings.adminSettingAudioPreprocessEnabled,
  'audioPreprocessHighpassHz' => strings.adminSettingAudioPreprocessHighpassHz,
  'audioPreprocessDenoiseDb' => strings.adminSettingAudioPreprocessDenoiseDb,
  'audioPreprocessMaxGain' => strings.adminSettingAudioPreprocessMaxGain,
  'dedupeTokenSimilarity' => strings.adminSettingDedupeTokenSimilarity,
  'dedupeTimeToleranceMs' => strings.adminSettingDedupeTimeToleranceMs,
  'transcriptRepetitionMinimumRepeats' =>
    strings.adminSettingTranscriptRepetitionMinimumRepeats,
  'transcriptRepetitionMaximumPatternWords' =>
    strings.adminSettingTranscriptRepetitionMaximumPatternWords,
  'transcriptRepetitionMinimumCoverage' =>
    strings.adminSettingTranscriptRepetitionMinimumCoverage,
  'transcriptMaximumWordsPerSecond' =>
    strings.adminSettingTranscriptMaximumWordsPerSecond,
  'conversationHardGapMs' => strings.adminSettingConversationHardGapMs,
  'conversationSoftGapMs' => strings.adminSettingConversationSoftGapMs,
  'conversationMinimumMs' => strings.adminSettingConversationMinimumMs,
  'conversationQuietCloseMs' => strings.adminSettingConversationQuietCloseMs,
  'conversationValleyQuantile' =>
    strings.adminSettingConversationValleyQuantile,
  'conversationSemanticSimilarityThreshold' =>
    strings.adminSettingConversationSemanticSimilarityThreshold,
  'conversationSemanticValleyProminence' =>
    strings.adminSettingConversationSemanticValleyProminence,
  'conversationSemanticContextSegments' =>
    strings.adminSettingConversationSemanticContextSegments,
  'conversationMaximumMs' => strings.adminSettingConversationMaximumMs,
  'conversationMaximumCharacters' =>
    strings.adminSettingConversationMaximumCharacters,
  'conversationPreviewMinCharacters' =>
    strings.adminSettingConversationPreviewMinCharacters,
  'conversationPreviewRefreshCharacters' =>
    strings.adminSettingConversationPreviewRefreshCharacters,
  'conversationPreviewMinIntervalMs' =>
    strings.adminSettingConversationPreviewMinIntervalMs,
  'conversationPreviewFullCharacters' =>
    strings.adminSettingConversationPreviewFullCharacters,
  'minAiAudioMs' => strings.adminSettingMinAiAudioMs,
  'minNewMaterialChars' => strings.adminSettingMinNewMaterialChars,
  'minMemoryEvidenceMs' => strings.adminSettingMinMemoryEvidenceMs,
  'minMemoryEvidenceChars' => strings.adminSettingMinMemoryEvidenceChars,
  'maxConsolidationInputChars' =>
    strings.adminSettingMaxConsolidationInputChars,
  'maxConsolidationConversations' =>
    strings.adminSettingMaxConsolidationConversations,
  'maxMemoryContinuationCandidates' =>
    strings.adminSettingMaxMemoryContinuationCandidates,
  'memoryContinuationLookbackMs' =>
    strings.adminSettingMemoryContinuationLookbackMs,
  'maxConsolidationLatencyMs' => strings.adminSettingMaxConsolidationLatencyMs,
  'memoryOccasionGapMs' => strings.adminSettingMemoryOccasionGapMs,
  'memorySettleMs' => strings.adminSettingMemorySettleMs,
  'memoryOccasionMaxWaitMs' => strings.adminSettingMemoryOccasionMaxWaitMs,
  'memoryDedupeEnabled' => strings.adminSettingMemoryDedupeEnabled,
  'memoryDedupeSimilarityThreshold' =>
    strings.adminSettingMemoryDedupeSimilarityThreshold,
  'memoryDedupeWindowMs' => strings.adminSettingMemoryDedupeWindowMs,
  'memoryDedupeMaxPairsPerRun' =>
    strings.adminSettingMemoryDedupeMaxPairsPerRun,
  'memoryDedupeNeighbours' => strings.adminSettingMemoryDedupeNeighbours,
  'consolidationMaxFailures' => strings.adminSettingConsolidationMaxFailures,
  _ => key,
};

/// Live overrides for how recordings are split, matched and written up. The
/// server validates every value and the relations between them; the defaults
/// come from its configuration until a value is saved here.
class AdminProcessingSection extends StatelessWidget {
  const AdminProcessingSection({
    super.key,
    required this.controller,
    required this.client,
  });

  final NeoRecallController controller;
  final AdminClient client;

  @override
  Widget build(BuildContext context) {
    return AdminLoader<Map<String, Object>>(
      controller: controller,
      load: client.processingSettings,
      builder: (context, settings, reload) => _ProcessingForm(
        controller: controller,
        client: client,
        settings: settings,
      ),
    );
  }
}

class _ProcessingForm extends StatefulWidget {
  const _ProcessingForm({
    required this.controller,
    required this.client,
    required this.settings,
  });

  final NeoRecallController controller;
  final AdminClient client;
  final Map<String, Object> settings;

  @override
  State<_ProcessingForm> createState() => _ProcessingFormState();
}

class _ProcessingFormState extends State<_ProcessingForm> {
  late Map<String, Object> _saved = widget.settings;
  final Map<String, TextEditingController> _numbers =
      <String, TextEditingController>{};
  final Map<String, bool> _switches = <String, bool>{};
  Map<String, String> _fieldErrors = const <String, String>{};
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _adopt(widget.settings);
  }

  @override
  void dispose() {
    for (final field in _numbers.values) {
      field.dispose();
    }
    super.dispose();
  }

  void _adopt(Map<String, Object> settings) {
    _saved = settings;
    for (final entry in settings.entries) {
      final value = entry.value;
      if (value is bool) {
        _switches[entry.key] = value;
      } else {
        (_numbers[entry.key] ??= TextEditingController()).text = '$value';
      }
    }
  }

  /// Only what changed: saving every value would pin the server's current
  /// defaults as overrides, and a later change to its configuration would no
  /// longer reach them.
  Map<String, Object>? _changes(AppL10n strings) {
    final changes = <String, Object>{};
    final problems = <String, String>{};
    for (final entry in _switches.entries) {
      if (_saved[entry.key] != entry.value) changes[entry.key] = entry.value;
    }
    for (final entry in _numbers.entries) {
      final text = entry.value.text.trim();
      final original = _saved[entry.key];
      final num? value = original is int
          ? int.tryParse(text) ?? num.tryParse(text)
          : num.tryParse(text);
      if (value == null) {
        problems[entry.key] = strings.adminSettingNotANumber;
      } else if (value != original) {
        changes[entry.key] = value;
      }
    }
    setState(() => _fieldErrors = problems);
    return problems.isEmpty ? changes : null;
  }

  Future<void> _save() async {
    final strings = AppL10n.of(context);
    final changes = _changes(strings);
    if (changes == null) return;
    if (changes.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.adminSettingsUnchanged)));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.client.saveProcessingSettings(changes);
      if (!mounted) return;
      setState(() => _adopt(saved));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.adminSettingsSaved(changes.length))),
      );
    } catch (error) {
      noteAdminFailure(widget.controller, error);
      if (!mounted) return;
      setState(() {
        _error = adminErrorText(error);
        _fieldErrors = _serverFieldErrors(error);
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The validator's per-field messages, when the server sent them.
  Map<String, String> _serverFieldErrors(Object error) {
    final details = error is ApiException ? error.details : null;
    final fields = details is Map ? details['fieldErrors'] : null;
    if (fields is! Map) return const <String, String>{};
    return <String, String>{
      for (final entry in fields.entries)
        if (entry.value is List && (entry.value as List).isNotEmpty)
          entry.key.toString(): (entry.value as List).first.toString(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    final grouped = <_SettingGroup, List<String>>{};
    for (final key in _saved.keys) {
      grouped.putIfAbsent(_groupOf(key), () => <String>[]).add(key);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InlineMessage(
          icon: Icons.tune_rounded,
          message: strings.adminProcessingDescription,
        ),
        for (final group in _SettingGroup.values)
          if (grouped[group] != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm + 2),
            AdminCard(
              id: 'processing.${group.name}',
              eyebrow: _groupLabel(strings, group),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final key in grouped[group]!)
                    if (_switches.containsKey(key))
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _switches[key]!,
                        onChanged: (value) =>
                            setState(() => _switches[key] = value),
                        title: Text(_settingLabel(strings, key)),
                        subtitle: _fieldErrors[key] == null
                            ? null
                            : Text(
                                _fieldErrors[key]!,
                                style: TextStyle(color: palette.danger),
                              ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: TextField(
                          controller: _numbers[key],
                          keyboardType: const TextInputType.numberWithOptions(
                            signed: true,
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: _settingLabel(strings, key),
                            errorText: _fieldErrors[key],
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ],
        if (_error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          InlineMessage(message: _error!, error: true),
        ],
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: Text(strings.adminSaveProcessing),
          ),
        ),
      ],
    );
  }
}
