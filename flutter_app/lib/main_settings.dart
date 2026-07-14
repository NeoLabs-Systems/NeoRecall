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
  @override
  void initState() {
    super.initState();
    server.text = widget.controller.backendUrl;
    widget.controller.loadSettings().then((value) {
      if (mounted) {
        timezone.text = value['timezone'] as String;
        setState(() => settings = value);
      }
    });
  }

  @override
  void dispose() {
    server.dispose();
    timezone.dispose();
    super.dispose();
  }

  Future<void> save() async {
    await widget.controller.setBackendUrl(server.text);
    if (settings != null) {
      await widget.controller.updateSettings(<String, dynamic>{
        'consolidationIntervalMs': settings!['consolidationIntervalMs'],
        'timezone': settings!['timezone'],
        'recurringSpeakerMatching': settings!['recurringSpeakerMatching'],
        'diarizationEnabled': settings!['diarizationEnabled'],
        'chunkTargetMs': settings!['chunkTargetMs'],
        'chunkOverlapMs': settings!['chunkOverlapMs'],
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return ListView(
      padding: const EdgeInsets.all(28),
      children: <Widget>[
        const ScreenHeader(
          eyebrow: 'SETTINGS',
          title: 'Recall on your terms',
          description:
              'Server floors always win over user-selected processing intervals. Capture settings apply to the next recording.',
        ),
        const SizedBox(height: 24),
        GlassSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('CONNECTION', style: sectionEyebrowStyle(palette)),
              const SizedBox(height: 14),
              TextField(
                controller: server,
                decoration: const InputDecoration(
                  labelText: 'NeoRecall server URL',
                  prefixIcon: Icon(Icons.cloud_outlined),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        GlassSurface(
          child: settings == null
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('CAPTURE', style: sectionEyebrowStyle(palette)),
                    const SizedBox(height: 14),
                    Text(
                      'Chunk duration: ${((settings!['chunkTargetMs'] as int) / 1000).round()} seconds',
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
        GlassSurface(
          child: settings == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'MEMORY CONSOLIDATION',
                      style: sectionEyebrowStyle(palette),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Interval: ${((settings!['consolidationIntervalMs'] as int) / 3600000).toStringAsFixed(1)} hours',
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
                    TextField(
                      controller: timezone,
                      decoration: const InputDecoration(
                        labelText: 'IANA timezone',
                      ),
                      onChanged: (value) => settings!['timezone'] = value,
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 14),
        GlassSurface(
          child: settings == null
              ? const SizedBox.shrink()
              : Column(
                  children: <Widget>[
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings!['diarizationEnabled'] as bool,
                      onChanged: (value) => setState(
                        () => settings!['diarizationEnabled'] = value,
                      ),
                      title: const Text('Speaker diarization'),
                      subtitle: const Text(
                        'Separate anonymous speakers locally.',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings!['recurringSpeakerMatching'] as bool,
                      onChanged: (value) => setState(
                        () => settings!['recurringSpeakerMatching'] = value,
                      ),
                      title: const Text('Recurring speaker matching'),
                      subtitle: const Text(
                        'Store voiceprint centroids to recognize the same voice across recordings.',
                      ),
                    ),
                  ],
                ),
        ),
        if (!kIsWeb) ...<Widget>[
          const SizedBox(height: 14),
          GlassSurface(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: widget.controller.autostartEnabled,
              onChanged: (value) async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await widget.controller.setAutostart(value);
                } catch (error) {
                  if (mounted) {
                    messenger.showSnackBar(
                      SnackBar(content: Text(error.toString())),
                    );
                  }
                }
              },
              title: const Text('Start NeoRecall when I sign in'),
              subtitle: const Text(
                'Opt in to desktop autostart. Recording never starts automatically.',
              ),
            ),
          ),
        ],
        const SizedBox(height: 14),
        GlassSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('OFFLINE & PRIVACY', style: sectionEyebrowStyle(palette)),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.storage_outlined),
                title: Text(
                  '${(widget.controller.pendingAudioBytes / 1048576).toStringAsFixed(1)} MB awaiting durable receipts',
                ),
                subtitle: const Text(
                  'Unacknowledged audio is never removed to satisfy a storage target.',
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.visibility_outlined),
                title: const Text('Visible recording and informed consent'),
                subtitle: Text(
                  widget.controller.consentAccepted
                      ? 'Consent notice acknowledged on this device.'
                      : 'The consent notice must be acknowledged before recording.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save settings'),
          ),
        ),
      ],
    );
  }
}
