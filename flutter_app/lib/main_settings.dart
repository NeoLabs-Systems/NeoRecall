import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});
  final NeoRecallController controller;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? settings;
  final server = TextEditingController();
  final timezone = TextEditingController();

  bool get _canConfigureServer =>
      widget.controller.allowsBackendUrlConfiguration;

  @override
  void initState() {
    super.initState();
    server.text = widget.controller.backendUrl;
    widget.controller.loadSettings().then((value) {
      if (!mounted) return;
      timezone.text = value['timezone'] as String? ?? 'UTC';
      setState(() => settings = value);
    });
  }

  @override
  void dispose() {
    server.dispose();
    timezone.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (_canConfigureServer) {
      await widget.controller.setBackendUrl(server.text);
    }
    if (settings == null) return;
    await widget.controller.updateSettings(<String, dynamic>{
      'consolidationIntervalMs': settings!['consolidationIntervalMs'],
      'timezone': settings!['timezone'],
      'recurringSpeakerMatching': settings!['recurringSpeakerMatching'],
      'diarizationEnabled': settings!['diarizationEnabled'],
      'chunkTargetMs': settings!['chunkTargetMs'],
      'chunkOverlapMs': settings!['chunkOverlapMs'],
    });
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Settings saved.')));
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final platformLabel = kIsWeb ? 'Web' : defaultTargetPlatform.name;

    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 48),
      children: <Widget>[
        ScreenHeader(
          eyebrow: 'SETTINGS',
          title: 'Control surface',
          description:
              'Tune capture and consolidation for this account. Server floors always win over user-selected processing intervals.',
          trailing: FilledButton.icon(
            onPressed: widget.controller.loading ? null : save,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save'),
          ),
        ),
        if (widget.controller.notice != null) ...<Widget>[
          InlineMessage(message: widget.controller.notice!),
          const SizedBox(height: 14),
        ],
        if (widget.controller.error != null) ...<Widget>[
          InlineMessage(message: widget.controller.error!, error: true),
          const SizedBox(height: 14),
        ],
        if (_canConfigureServer) ...<Widget>[
          SectionCard(
            eyebrow: 'CONNECTION',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TextField(
                  controller: server,
                  decoration: const InputDecoration(
                    labelText: 'NeoRecall server URL',
                    prefixIcon: Icon(Icons.cloud_outlined),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Only native clients can change this. Web always uses the host that serves /app.',
                  style: TextStyle(color: palette.textMuted, height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ] else ...<Widget>[
          SectionCard(
            eyebrow: 'CONNECTION',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                MetaPill(
                  icon: Icons.link_rounded,
                  label: widget.controller.backendUrl.isEmpty
                      ? 'Same-origin web host'
                      : widget.controller.backendUrl,
                  active: true,
                ),
                const SizedBox(height: 10),
                Text(
                  'This web client is bound to the NeoRecall host that served it.',
                  style: TextStyle(color: palette.textMuted, height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        SectionCard(
          eyebrow: 'CAPTURE',
          child: settings == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Chunk duration: ${((settings!['chunkTargetMs'] as int) / 1000).round()} seconds',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Slider(
                      min: (settings!['chunkMinMs'] as int) / 1000,
                      max: (settings!['chunkMaxMs'] as int) / 1000,
                      value: ((settings!['chunkTargetMs'] as int) / 1000)
                          .clamp(
                            (settings!['chunkMinMs'] as int) / 1000,
                            (settings!['chunkMaxMs'] as int) / 1000,
                          )
                          .toDouble(),
                      onChanged: (value) => setState(
                        () => settings!['chunkTargetMs'] = value.round() * 1000,
                      ),
                    ),
                    Text(
                      'Boundary overlap: ${((settings!['chunkOverlapMs'] as int) / 1000).toStringAsFixed(1)} seconds',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Slider(
                      min: 0,
                      max: 5,
                      divisions: 10,
                      value: ((settings!['chunkOverlapMs'] as int) / 1000)
                          .clamp(0, 5)
                          .toDouble(),
                      onChanged: (value) => setState(
                        () => settings!['chunkOverlapMs'] = (value * 1000)
                            .round(),
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 14),
        SectionCard(
          eyebrow: 'MEMORY CONSOLIDATION',
          child: settings == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Interval: ${((settings!['consolidationIntervalMs'] as int) / 3600000).toStringAsFixed(1)} hours',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Slider(
                      min:
                          (settings!['effectiveConsolidationIntervalMs'] as int)
                              .toDouble(),
                      max: 24 * 3600000,
                      divisions: 23,
                      value: (settings!['consolidationIntervalMs'] as int)
                          .clamp(
                            settings!['effectiveConsolidationIntervalMs']
                                as int,
                            24 * 3600000,
                          )
                          .toDouble(),
                      onChanged: (value) => setState(
                        () => settings!['consolidationIntervalMs'] = value
                            .round(),
                      ),
                    ),
                    const SizedBox(height: 8),
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
        const SizedBox(height: 14),
        SectionCard(
          eyebrow: 'SPEAKERS',
          child: settings == null
              ? const SizedBox.shrink()
              : Column(
                  children: <Widget>[
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings!['diarizationEnabled'] as bool? ?? true,
                      onChanged: (value) => setState(
                        () => settings!['diarizationEnabled'] = value,
                      ),
                      title: const Text('Speaker diarization'),
                      subtitle: const Text(
                        'Separate overlapping speakers during transcription.',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value:
                          settings!['recurringSpeakerMatching'] as bool? ??
                          true,
                      onChanged: (value) => setState(
                        () => settings!['recurringSpeakerMatching'] = value,
                      ),
                      title: const Text('Recurring speaker matching'),
                      subtitle: const Text(
                        'Match known voiceprints across recordings.',
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 14),
        SectionCard(
          eyebrow: 'CLIENT',
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              MetaPill(
                icon: Icons.devices_outlined,
                label: platformLabel,
                active: true,
              ),
              MetaPill(
                icon: widget.controller.online
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
                label: widget.controller.online ? 'Online' : 'Offline',
                active: widget.controller.online,
              ),
              if (widget.controller.username != null)
                MetaPill(
                  icon: Icons.person_outline,
                  label: widget.controller.username!,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
