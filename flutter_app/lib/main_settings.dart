import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_devices.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_theme.dart';

enum SettingsSection { general, recording, memory, speakers, devices }

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
  late SettingsSection selectedSection = widget.initialSection;

  @override
  void initState() {
    super.initState();
    widget.controller.loadSettings().then((value) {
      if (!mounted) return;
      timezone.text = value['timezone'] as String? ?? 'UTC';
      setState(() => settings = value);
    });
  }

  @override
  void dispose() {
    timezone.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final current = settings;
    if (current == null) return;
    await widget.controller.updateSettings(<String, dynamic>{
      'consolidationIntervalMs': current['consolidationIntervalMs'],
      'timezone': current['timezone'],
      'recurringSpeakerMatching': current['recurringSpeakerMatching'],
      'diarizationEnabled': current['diarizationEnabled'],
      'chunkTargetMs': current['chunkTargetMs'],
      'chunkOverlapMs': current['chunkOverlapMs'],
    });
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Settings saved.')));
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
                      settings == null ||
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
                      _SettingsNavigation(
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
                        child: _SettingsNavigation(
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
    if (widget.controller.notice != null) ...<Widget>[
      InlineMessage(message: widget.controller.notice!),
      const SizedBox(height: 14),
    ],
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
    ]);
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
    return _sectionList(<Widget>[
      SectionCard(
        eyebrow: 'SPEAKERS',
        child: Column(
          children: <Widget>[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: current['diarizationEnabled'] as bool? ?? true,
              onChanged: (value) =>
                  setState(() => current['diarizationEnabled'] = value),
              title: const Text('Speaker diarization'),
              subtitle: const Text(
                'Separate overlapping speakers during transcription.',
              ),
            ),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: current['recurringSpeakerMatching'] as bool? ?? true,
              onChanged: (value) =>
                  setState(() => current['recurringSpeakerMatching'] = value),
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

class _SettingsNavigation extends StatelessWidget {
  const _SettingsNavigation({
    required this.selected,
    required this.compact,
    required this.onSelected,
  });

  final SettingsSection selected;
  final bool compact;
  final ValueChanged<SettingsSection> onSelected;

  static const items = <_SettingsNavigationItem>[
    _SettingsNavigationItem(
      section: SettingsSection.general,
      icon: Icons.tune,
      label: 'General',
      description: 'Time and locale',
    ),
    _SettingsNavigationItem(
      section: SettingsSection.recording,
      icon: Icons.graphic_eq_outlined,
      label: 'Recording',
      description: 'Chunks and overlap',
    ),
    _SettingsNavigationItem(
      section: SettingsSection.memory,
      icon: Icons.auto_awesome_outlined,
      label: 'Memory',
      description: 'Consolidation timing',
    ),
    _SettingsNavigationItem(
      section: SettingsSection.speakers,
      icon: Icons.record_voice_over_outlined,
      label: 'Speakers',
      description: 'Diarization and matching',
    ),
    _SettingsNavigationItem(
      section: SettingsSection.devices,
      icon: Icons.devices_other_outlined,
      label: 'Devices',
      description: 'Capture endpoints',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return DropdownButtonFormField<SettingsSection>(
        key: ValueKey<SettingsSection>(selected),
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Settings area',
          prefixIcon: Icon(Icons.settings_outlined),
        ),
        items: items
            .map(
              (item) => DropdownMenuItem<SettingsSection>(
                value: item.section,
                child: Text(item.label),
              ),
            )
            .toList(),
        onChanged: (section) {
          if (section != null) onSelected(section);
        },
      );
    }

    final palette = neoRecallPaletteOf(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.bgSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
            child: Text(
              'Settings areas',
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          for (final item in items)
            _SettingsNavigationButton(
              item: item,
              selected: item.section == selected,
              onTap: () => onSelected(item.section),
            ),
        ],
      ),
    );
  }
}

class _SettingsNavigationButton extends StatelessWidget {
  const _SettingsNavigationButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _SettingsNavigationItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected
            ? palette.accent.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  item.icon,
                  size: 20,
                  color: selected ? palette.accent : palette.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.label,
                        style: TextStyle(
                          color: selected
                              ? palette.accent
                              : palette.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.description,
                        style: TextStyle(
                          color: palette.textSecondary,
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsNavigationItem {
  const _SettingsNavigationItem({
    required this.section,
    required this.icon,
    required this.label,
    required this.description,
  });

  final SettingsSection section;
  final IconData icon;
  final String label;
  final String description;
}
