import 'dart:convert';

import 'package:flutter/material.dart';

import 'main_shared.dart';
import 'main_theme.dart';
import 'src/admin/admin_provider_client.dart';
import 'src/api_client.dart';
import 'l10n/gen/app_l10n.dart';

/// Configures the transcription and language-model services a NeoRecall server
/// uses. Lives on Admin › Providers, where the first admin lands straight after
/// this app installs a server.
class ProviderSetupPanel extends StatefulWidget {
  const ProviderSetupPanel({
    super.key,
    required this.client,
    this.onAccessRevoked,
  });

  final AdminProviderClient client;

  /// Called when the server answers that this account is no longer an admin.
  final VoidCallback? onAccessRevoked;

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
    } on ApiException catch (error) {
      if (!mounted) return;
      _noteAccess(error);
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  void _noteAccess(ApiException error) {
    if (error.code == 'ADMIN_REQUIRED') widget.onAccessRevoked?.call();
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
    } on ApiException catch (error) {
      if (!mounted) return;
      _noteAccess(error);
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
    // Removing the saved key is fine when the server's own configuration has
    // one to fall back to.
    if (entry.apiKeyRequired &&
        form.apiKey.text.trim().isEmpty &&
        (!form.apiKeyAlreadyStored ||
            (form.clearApiKey && !form.environmentApiKeyConfigured))) {
      return strings.providerNeedsApiKey(entry.label);
    }
    final language = form.language.text.trim();
    if (form.isTranscription && language.isNotEmpty && language.length < 2) {
      return strings.providerLanguageInvalid;
    }
    if (!entry.modelOptional &&
        form.model.text.trim().isEmpty &&
        (entry.defaultModel ?? '').isEmpty) {
      return strings.providerNeedsModel(entry.label);
    }
    if (!form.isTranscription && form.extraBodyProblem(strings) != null) {
      return form.extraBodyProblem(strings);
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
    } on ApiException catch (error) {
      if (!mounted) return false;
      _noteAccess(error);
      setState(() {
        _error = error.message;
        _saving = false;
      });
      return false;
    }
  }

  /// Drops everything saved from the app, so the server's `.env` applies again.
  Future<void> _reset() async {
    final strings = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.providerResetTitle),
        content: Text(strings.providerResetBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(strings.providerResetConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
      _saved = null;
      _report = null;
    });
    try {
      final snapshot = await widget.client.reset();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _transcription.adopt(
          snapshot.transcription,
          snapshot.transcriptionCatalog,
        );
        _llm.adopt(snapshot.llm, snapshot.llmCatalog);
        _saving = false;
        _saved = AppL10n.of(context).providerResetDone;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      _noteAccess(error);
      setState(() {
        _error = error.message;
        _saving = false;
      });
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
    } on ApiException catch (error) {
      if (!mounted) return;
      _noteAccess(error);
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
        if (snapshot.transcription.hasOverrides ||
            snapshot.llm.hasOverrides) ...<Widget>[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: busy ? null : _reset,
              icon: const Icon(Icons.settings_backup_restore_rounded, size: 18),
              label: Text(strings.providerReset),
            ),
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
            _baseUrlField(strings, form),
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
          if (form.apiKeySource != 'none') ...<Widget>[
            const SizedBox(height: 8),
            Text(
              form.apiKeySource == 'admin'
                  ? strings.providerKeySourceSaved
                  : strings.providerKeySourceServer,
              style: TextStyle(color: palette.textMuted, fontSize: 11),
            ),
          ],
          _advanced(palette, strings, form, entry),
        ],
      ),
    );
  }

  Widget _baseUrlField(AppL10n strings, _WorkloadFormState form) => TextField(
    controller: form.baseUrl,
    autocorrect: false,
    keyboardType: TextInputType.url,
    decoration: InputDecoration(
      labelText: form.isTranscription
          ? strings.providerTranscriptionEndpointLabel
          : strings.providerBaseUrlLabel,
      hintText: 'https://example.com/v1',
    ),
  );

  /// The values most setups never touch: an endpoint for a provider that has a
  /// default one, the request details a particular model needs, and removing a
  /// key saved from the app.
  Widget _advanced(
    NeoRecallPalette palette,
    AppL10n strings,
    _WorkloadFormState form,
    ProviderCatalogEntry? entry,
  ) {
    return Theme(
      // An ExpansionTile draws dividers above and below itself by default,
      // which doubled the card's border.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        title: Text(
          strings.providerAdvanced,
          style: TextStyle(color: palette.textSecondary, fontSize: 13),
        ),
        children: <Widget>[
          if (entry != null && !entry.baseUrlRequired) ...<Widget>[
            _baseUrlField(strings, form),
            const SizedBox(height: 12),
          ],
          if (form.isTranscription) ...<Widget>[
            TextField(
              controller: form.language,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: strings.providerLanguageLabel,
                helperText: strings.providerLanguageHelp,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: form.responseFormat,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: strings.providerResponseFormatLabel,
              ),
            ),
          ] else ...<Widget>[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: form.skipThinking,
              onChanged: (value) => setState(() => form.setSkipThinking(value)),
              title: Text(strings.providerSkipThinking),
              subtitle: Text(strings.providerSkipThinkingHelp),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: form.extraBody,
              autocorrect: false,
              enableSuggestions: false,
              minLines: 2,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              onChanged: (_) => setState(form.syncSkipThinking),
              decoration: InputDecoration(
                labelText: strings.providerExtraBodyLabel,
                helperText: strings.providerExtraBodyHelp,
                helperMaxLines: 3,
                hintText: '{"top_p": 0.9}',
                errorText: form.extraBodyProblem(strings),
              ),
            ),
          ],
          if (form.apiKeySource == 'admin')
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: form.clearApiKey,
              onChanged: (value) =>
                  setState(() => form.clearApiKey = value ?? false),
              title: Text(strings.providerClearKey),
            ),
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

/// What skipping a model's thinking step adds to every request.
const String _thinkingKwargs = 'chat_template_kwargs';
const String _enableThinking = 'enable_thinking';

class _WorkloadFormState {
  _WorkloadFormState({required this.workload});

  final String workload;
  final TextEditingController model = TextEditingController();
  final TextEditingController baseUrl = TextEditingController();
  final TextEditingController apiKey = TextEditingController();
  final TextEditingController language = TextEditingController();
  final TextEditingController responseFormat = TextEditingController();
  final TextEditingController extraBody = TextEditingController();
  List<ProviderCatalogEntry> catalog = const <ProviderCatalogEntry>[];
  List<String> models = const <String>[];
  String? provider;
  bool apiKeyAlreadyStored = false;
  String apiKeySource = 'none';
  bool environmentApiKeyConfigured = false;
  bool clearApiKey = false;

  /// Where each loaded value came from, and the values themselves, so a value
  /// from the server's configuration is only sent once someone changes it.
  Map<String, String> sources = const <String, String>{};
  String _loadedLanguage = '';
  String _loadedResponseFormat = '';
  String _loadedExtraBody = '';
  bool skipThinking = false;
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
    apiKey.clear();
    apiKeyAlreadyStored = settings.apiKeyConfigured;
    apiKeySource = settings.apiKeySource;
    environmentApiKeyConfigured = settings.environmentApiKeyConfigured;
    clearApiKey = false;
    models = const <String>[];
    _adoptDetails(settings);
  }

  void adoptSaved(ProviderWorkloadSettings settings) {
    apiKeyAlreadyStored = settings.apiKeyConfigured;
    apiKeySource = settings.apiKeySource;
    environmentApiKeyConfigured = settings.environmentApiKeyConfigured;
    clearApiKey = false;
    // A saved key is stored server-side; keeping it in the field would only
    // re-send the same secret on the next save.
    apiKey.clear();
    model.text = settings.model ?? model.text;
    baseUrl.text = settings.baseUrl ?? baseUrl.text;
    _adoptDetails(settings);
  }

  void _adoptDetails(ProviderWorkloadSettings settings) {
    sources = settings.sources;
    language.text = settings.language ?? '';
    responseFormat.text = settings.responseFormat ?? '';
    final body = settings.extraBody;
    extraBody.text = body == null || body.isEmpty
        ? ''
        : const JsonEncoder.withIndent('  ').convert(body);
    _loadedLanguage = language.text;
    _loadedResponseFormat = responseFormat.text;
    _loadedExtraBody = extraBody.text;
    syncSkipThinking();
  }

  /// Sent when it is an override already, or when someone changed it here.
  bool _sends(String field, String loaded, String current) =>
      sources[field] == 'admin' || current.trim() != loaded.trim();

  /// The extra request JSON as typed, or null when the field is empty.
  /// Throws [FormatException] when it is not a JSON object.
  Map<String, dynamic>? _parsedExtraBody() {
    final raw = extraBody.text.trim();
    if (raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('not an object');
    return Map<String, dynamic>.from(decoded);
  }

  String? extraBodyProblem(AppL10n l10n) {
    try {
      _parsedExtraBody();
      return null;
    } on FormatException {
      return l10n.providerExtraBodyInvalid;
    }
  }

  /// Keeps the switch in step with JSON typed by hand.
  void syncSkipThinking() {
    try {
      final kwargs = _parsedExtraBody()?[_thinkingKwargs];
      skipThinking = kwargs is Map && kwargs[_enableThinking] == false;
    } on FormatException {
      // Leave the switch as it was until the JSON parses again.
    }
  }

  /// Writes the switch into the JSON, or takes it back out, leaving every
  /// other field as it was.
  void setSkipThinking(bool value) {
    Map<String, dynamic> body;
    try {
      body = _parsedExtraBody() ?? <String, dynamic>{};
    } on FormatException {
      return;
    }
    final kwargs = Map<String, dynamic>.from(
      body[_thinkingKwargs] as Map? ?? const <String, dynamic>{},
    );
    if (value) {
      kwargs[_enableThinking] = false;
    } else {
      kwargs.remove(_enableThinking);
    }
    if (kwargs.isEmpty) {
      body.remove(_thinkingKwargs);
    } else {
      body[_thinkingKwargs] = kwargs;
    }
    skipThinking = value;
    extraBody.text = body.isEmpty
        ? ''
        : const JsonEncoder.withIndent('  ').convert(body);
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
    apiKeySource = 'none';
    // Unknown for a provider the server was not pointed at; the server looks
    // up its keys again on save.
    environmentApiKeyConfigured = false;
    clearApiKey = false;
    if (isTranscription) {
      responseFormat.text = entry?.defaultResponseFormat ?? '';
    }
  }

  /// Every value the workload has, so saving never resets one the form did
  /// not show. Only called once [extraBodyProblem] is null.
  ProviderSelection selection() => ProviderSelection(
    provider: provider!,
    model: model.text.trim(),
    baseUrl: baseUrl.text.trim(),
    apiKey: apiKey.text.trim(),
    clearApiKey: clearApiKey,
    language: _sends('language', _loadedLanguage, language.text)
        ? language.text.trim()
        : null,
    responseFormat:
        _sends('responseFormat', _loadedResponseFormat, responseFormat.text)
        ? responseFormat.text.trim()
        : null,
    extraBody:
        isTranscription ||
            !_sends('extraBody', _loadedExtraBody, extraBody.text)
        ? null
        : _parsedExtraBody(),
  );

  void dispose() {
    model.dispose();
    baseUrl.dispose();
    apiKey.dispose();
    language.dispose();
    responseFormat.dispose();
    extraBody.dispose();
  }
}
