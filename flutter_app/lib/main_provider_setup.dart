import 'package:flutter/material.dart';

import 'main_shared.dart';
import 'main_theme.dart';
import 'src/install/admin_provider_client.dart';
import 'l10n/gen/app_l10n.dart';

/// Configures the transcription and language-model services a NeoRecall server
/// uses, without the admin web dashboard. Used both at the end of a local
/// install and from Settings afterwards.
class ProviderSetupPanel extends StatefulWidget {
  const ProviderSetupPanel({
    super.key,
    required this.client,
    this.onFinished,
    this.finishLabel,
    this.showSkip = false,
    this.onSkip,
  });

  final AdminProviderClient client;

  /// Called once both services are saved (and, when the person asked for it,
  /// tested).
  final VoidCallback? onFinished;
  final String? finishLabel;
  final bool showSkip;
  final VoidCallback? onSkip;

  @override
  State<ProviderSetupPanel> createState() => _ProviderSetupPanelState();
}

class _ProviderSetupPanelState extends State<ProviderSetupPanel> {
  ProviderSettingsSnapshot? _snapshot;
  late final _WorkloadFormState _transcription = _WorkloadFormState(
    workload: 'transcription',
  );
  late final _WorkloadFormState _llm = _WorkloadFormState(workload: 'llm');
  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  String? _error;
  String? _saved;
  ProviderTestReport? _report;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _transcription.dispose();
    _llm.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await widget.client.load();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _transcription.adopt(
          snapshot.transcription,
          snapshot.transcriptionCatalog,
        );
        _llm.adopt(snapshot.llm, snapshot.llmCatalog);
        _loading = false;
      });
    } on AdminProviderException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _discover(_WorkloadFormState form) async {
    setState(() {
      form.discovering = true;
      form.discoveryError = null;
    });
    try {
      final models = await widget.client.discoverModels(
        workload: form.workload,
        provider: form.provider!,
        baseUrl: form.baseUrl.text.trim(),
        apiKey: form.apiKey.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        form.models = models;
        form.discovering = false;
        if (models.isNotEmpty && !models.contains(form.model.text.trim())) {
          form.model.text = models.first;
        }
      });
    } on AdminProviderException catch (error) {
      if (!mounted) return;
      setState(() {
        form.discoveryError = error.message;
        form.discovering = false;
      });
    }
  }

  String? _validate(_WorkloadFormState form) {
    final strings = AppL10n.of(context);
    final entry = form.selectedEntry;
    if (entry == null) {
      return strings.providerChoose(form.title(strings).toLowerCase());
    }
    if (entry.baseUrlRequired && form.baseUrl.text.trim().isEmpty) {
      return strings.providerNeedsBaseUrl(entry.label);
    }
    if (entry.apiKeyRequired &&
        form.apiKey.text.trim().isEmpty &&
        !form.apiKeyAlreadyStored) {
      return '${entry.label} needs an API key.';
    }
    if (!entry.modelOptional &&
        form.model.text.trim().isEmpty &&
        (entry.defaultModel ?? '').isEmpty) {
      return '${entry.label} needs a model.';
    }
    return null;
  }

  Future<bool> _save() async {
    for (final form in <_WorkloadFormState>[_transcription, _llm]) {
      final problem = _validate(form);
      if (problem != null) {
        setState(() {
          _error = problem;
          _saved = null;
        });
        return false;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
      _saved = null;
      _report = null;
    });
    try {
      final snapshot = await widget.client.save(
        transcription: _transcription.selection(),
        llm: _llm.selection(),
      );
      if (!mounted) return false;
      setState(() {
        _snapshot = snapshot;
        _transcription.adoptSaved(snapshot.transcription);
        _llm.adoptSaved(snapshot.llm);
        _saving = false;
        _saved = AppL10n.of(context).providerSaved;
      });
      return true;
    } on AdminProviderException catch (error) {
      if (!mounted) return false;
      setState(() {
        _error = error.message;
        _saving = false;
      });
      return false;
    }
  }

  Future<void> _saveAndTest() async {
    if (!await _save()) return;
    setState(() => _testing = true);
    try {
      final report = await widget.client.test();
      if (!mounted) return;
      setState(() {
        _report = report;
        _testing = false;
      });
    } on AdminProviderException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _testing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final snapshot = _snapshot;
    if (snapshot == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InlineMessage(
            message: _error ?? strings.providerLoadFailed,
            error: true,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(strings.providerTryAgain),
          ),
        ],
      );
    }
    final busy = _saving || _testing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          strings.providerIntro,
          style: TextStyle(color: palette.textSecondary, height: 1.5),
        ),
        const SizedBox(height: 18),
        _workloadCard(palette, _transcription),
        const SizedBox(height: 14),
        _workloadCard(palette, _llm),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 14),
          InlineMessage(message: _error!, error: true),
        ],
        if (_saved != null && _error == null) ...<Widget>[
          const SizedBox(height: 14),
          InlineMessage(message: _saved!, icon: Icons.check_circle_outline),
        ],
        if (_report != null) ...<Widget>[
          const SizedBox(height: 14),
          _testReport(palette, _report!),
        ],
        const SizedBox(height: 18),
        Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : _saveAndTest,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                icon: busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_circle_outline),
                label: Text(
                  _testing
                      ? strings.providerTesting
                      : _saving
                      ? strings.providerSaving
                      : strings.providerSaveAndTest,
                ),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              onPressed: busy ? null : _save,
              // A height-only minimum would ask for infinite width inside a Row.
              style: OutlinedButton.styleFrom(minimumSize: const Size(120, 52)),
              child: Text(strings.providerSaveOnly),
            ),
          ],
        ),
        if (widget.onFinished != null) ...<Widget>[
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: busy ? null : widget.onFinished,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(widget.finishLabel ?? strings.providerContinue),
          ),
        ],
        if (widget.showSkip) ...<Widget>[
          const SizedBox(height: 4),
          TextButton(
            onPressed: busy ? null : widget.onSkip,
            child: Text(strings.providerSetUpLater),
          ),
        ],
      ],
    );
  }

  Widget _workloadCard(NeoRecallPalette palette, _WorkloadFormState form) {
    final strings = AppL10n.of(context);
    final entry = form.selectedEntry;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.bgSecondary.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(form.icon, size: 18, color: palette.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  form.title(strings),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (form.apiKeyAlreadyStored)
                Text(
                  strings.providerKeyStored,
                  style: TextStyle(color: palette.textMuted, fontSize: 11),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            form.subtitle(strings),
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: form.provider,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: strings.providerServiceLabel,
            ),
            items: <DropdownMenuItem<String>>[
              for (final item in form.catalog)
                DropdownMenuItem<String>(
                  value: item.id,
                  child: Text(item.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => form.selectProvider(value));
            },
          ),
          if (entry != null && entry.baseUrlRequired) ...<Widget>[
            const SizedBox(height: 12),
            TextField(
              controller: form.baseUrl,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: strings.providerBaseUrlLabel,
                hintText: 'https://example.com/v1',
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: form.apiKey,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: form.apiKeyAlreadyStored
                  ? strings.providerApiKeyStoredLabel
                  : strings.providerApiKeyLabel,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: form.models.isEmpty
                    ? TextField(
                        controller: form.model,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: entry?.modelOptional == true
                              ? strings.providerModelOptionalLabel
                              : strings.providerModelLabel,
                        ),
                      )
                    : DropdownButtonFormField<String>(
                        initialValue: form.models.contains(form.model.text)
                            ? form.model.text
                            : null,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: strings.providerModelLabel,
                        ),
                        items: <DropdownMenuItem<String>>[
                          for (final id in form.models)
                            DropdownMenuItem<String>(
                              value: id,
                              child: Text(id, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (value) => setState(
                          () => form.model.text = value ?? form.model.text,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: form.discovering ? null : () => _discover(form),
                child: form.discovering
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(strings.providerFindModels),
              ),
            ],
          ),
          if (form.discoveryError != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              form.discoveryError!,
              style: TextStyle(color: palette.warning, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _testReport(NeoRecallPalette palette, ProviderTestReport report) {
    final strings = AppL10n.of(context);
    Widget leg(String label, ProviderTestLeg value) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            value.ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: value.ok ? palette.success : palette.danger,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$label: ${value.detail}',
              style: TextStyle(color: palette.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.bgTertiary.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          leg(strings.providerLegTranscription, report.transcription),
          leg(strings.providerLegSpeakerIdentity, report.speakerIdentity),
          leg(strings.providerLegMemoryWriting, report.llm),
        ],
      ),
    );
  }
}

class _WorkloadFormState {
  _WorkloadFormState({required this.workload});

  final String workload;
  final TextEditingController model = TextEditingController();
  final TextEditingController baseUrl = TextEditingController();
  final TextEditingController apiKey = TextEditingController();
  List<ProviderCatalogEntry> catalog = const <ProviderCatalogEntry>[];
  List<String> models = const <String>[];
  String? provider;
  bool apiKeyAlreadyStored = false;
  bool discovering = false;
  String? discoveryError;

  bool get isTranscription => workload == 'transcription';

  String title(AppL10n l10n) => isTranscription
      ? l10n.providerLegTranscription
      : l10n.providerLegMemoryWriting;

  String subtitle(AppL10n l10n) => isTranscription
      ? l10n.providerTranscriptionSubtitle
      : l10n.providerMemorySubtitle;

  IconData get icon =>
      isTranscription ? Icons.graphic_eq_rounded : Icons.auto_stories_rounded;

  ProviderCatalogEntry? get selectedEntry {
    for (final entry in catalog) {
      if (entry.id == provider) return entry;
    }
    return null;
  }

  void adopt(
    ProviderWorkloadSettings settings,
    List<ProviderCatalogEntry> entries,
  ) {
    catalog = entries;
    provider = entries.any((entry) => entry.id == settings.provider)
        ? settings.provider
        : (entries.isEmpty ? null : entries.first.id);
    model.text = settings.model ?? '';
    baseUrl.text = settings.baseUrl ?? '';
    apiKeyAlreadyStored = settings.apiKeyConfigured;
  }

  void adoptSaved(ProviderWorkloadSettings settings) {
    apiKeyAlreadyStored = settings.apiKeyConfigured;
    // A saved key is stored server-side; keeping it in the field would only
    // re-send the same secret on the next save.
    apiKey.clear();
    model.text = settings.model ?? model.text;
    baseUrl.text = settings.baseUrl ?? baseUrl.text;
  }

  void selectProvider(String value) {
    provider = value;
    models = const <String>[];
    discoveryError = null;
    final entry = selectedEntry;
    model.text = entry?.defaultModel ?? '';
    baseUrl.text = entry?.defaultBaseUrl ?? '';
    apiKey.clear();
    apiKeyAlreadyStored = false;
  }

  ProviderSelection selection() => ProviderSelection(
    provider: provider!,
    model: model.text.trim(),
    baseUrl: baseUrl.text.trim(),
    apiKey: apiKey.text.trim(),
  );

  void dispose() {
    model.dispose();
    baseUrl.dispose();
    apiKey.dispose();
  }
}
