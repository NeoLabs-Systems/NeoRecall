import 'dart:async';
import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_theme.dart';

class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  bool loading = true;
  List<dynamic> activeSources = [];

  final List<Map<String, dynamic>> availableIntegrations = [
    {
      'id': 'discord',
      'name': 'Discord',
      'icon': Icons.discord,
      'description': 'Automatically record specific users in voice channels you join.',
      'comingSoon': false,
    },
    {
      'id': 'meeting',
      'name': 'Meeting Link',
      'icon': Icons.link,
      'description': 'Paste a URL to automatically record Google Meet, Zoom, or Teams.',
      'comingSoon': false,
    },
  ];

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    setState(() => loading = true);
    try {
      final response = await widget.controller.api.request('GET', '/api/v1/sources') as Map;
      setState(() {
        activeSources = response['sources'] as List<dynamic>;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load sources: $error')));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _setupSource(String typeId) async {
    if (typeId != 'discord' && typeId != 'meeting') return;

    final result = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => typeId == 'discord' 
        ? _DiscordSetupDialog(controller: widget.controller)
        : _MeetingSetupDialog(controller: widget.controller),
    );
    if (result == true) {
      _loadSources();
    }
  }

  Future<void> _toggleSource(Map<String, dynamic> source, bool enabled) async {
    try {
      await widget.controller.api.request('PATCH', '/api/v1/sources/${source['id']}', body: {'enabled': enabled});
      _loadSources();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update: $error')));
      }
    }
  }

  Future<void> _deleteSource(Map<String, dynamic> source) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: neoRecallPaletteOf(context).bgCard,
        title: Text('Disconnect Account', style: TextStyle(color: neoRecallPaletteOf(context).textPrimary)),
        content: Text('Are you sure you want to disconnect this source?', style: TextStyle(color: neoRecallPaletteOf(context).textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text('Cancel', style: TextStyle(color: neoRecallPaletteOf(context).textSecondary))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text('Disconnect', style: TextStyle(color: neoRecallPaletteOf(context).danger))),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await widget.controller.api.request('DELETE', '/api/v1/sources/${source['id']}');
      _loadSources();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to disconnect: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);

    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text('External Sources', style: TextStyle(color: palette.textPrimary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: availableIntegrations.length,
        itemBuilder: (context, index) {
          final integration = availableIntegrations[index];
          final typeId = integration['id'] as String;
          final isComingSoon = integration['comingSoon'] as bool;
          
          final activeSourceIndex = activeSources.indexWhere((s) => s['type'] == typeId);
          final activeSource = activeSourceIndex >= 0 ? activeSources[activeSourceIndex] : null;
          final isConnected = activeSource != null;

          return Card(
            color: palette.bgCard,
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: palette.bgSecondary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(integration['icon'] as IconData, color: isComingSoon ? palette.textMuted : palette.accent, size: 28),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                integration['name'],
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.textPrimary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (isConnected) ...[
                              const SizedBox(width: 8),
                              if (activeSource['config'] != null && activeSource['config']['error'] != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.red.withValues(alpha:0.1),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: Colors.red.withValues(alpha:0.5)),
                                  ),
                                  child: const Text(
                                    'Error',
                                    style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.bold),
                                  ),
                                )
                              else
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withValues(alpha:0.1),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: Colors.green.withValues(alpha:0.5)),
                                  ),
                                  child: const Text(
                                    'Connected',
                                    style: TextStyle(color: Colors.green, fontSize: 10, fontWeight: FontWeight.bold),
                                  ),
                                ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          integration['description'],
                          style: TextStyle(color: palette.textSecondary, fontSize: 13),
                        ),
                        if (isConnected && activeSource['config'] != null && activeSource['config']['error'] != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            activeSource['config']['error'],
                            style: TextStyle(color: Colors.red.shade400, fontSize: 12),
                          ),
                        ]
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  if (isComingSoon)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: palette.bgTertiary,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text('Coming Soon', style: TextStyle(color: palette.textMuted, fontSize: 12)),
                    )
                  else if (isConnected)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: activeSource['enabled'],
                          onChanged: (val) => _toggleSource(activeSource, val),
                          activeThumbColor: palette.accent,
                        ),
                        IconButton(
                          icon: Icon(Icons.link_off, color: palette.danger),
                          tooltip: 'Disconnect Account',
                          onPressed: () => _deleteSource(activeSource),
                        ),
                      ],
                    )
                  else
                    ElevatedButton(
                      onPressed: () => _setupSource(typeId),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: palette.accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                      child: const Text('Setup'),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DiscordSetupDialog extends StatefulWidget {
  const _DiscordSetupDialog({required this.controller});

  final NeoRecallController controller;

  @override
  State<_DiscordSetupDialog> createState() => _DiscordSetupDialogState();
}

class _DiscordSetupDialogState extends State<_DiscordSetupDialog> {
  final _nameController = TextEditingController(text: 'My Discord Bot');
  final _usersController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _usersController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final users = _usersController.text.trim();
    final token = _tokenController.text.trim();

    if (name.isEmpty || users.isEmpty || token.isEmpty) return;

    setState(() => _saving = true);
    try {
      await widget.controller.api.request('POST', '/api/v1/sources', body: {
        'type': 'discord',
        'name': name,
        'config': {
          'token': token,
          'triggerUsernames': users,
        },
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $error'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connect Discord Bot'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha:0.08),
                border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha:0.3)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Theme.of(context).colorScheme.primary, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Uses a Discord bot you create and invite to your server. When a trigger user joins a voice channel, the bot joins and records everyone in that channel, then leaves when they leave.',
                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Team Standup Bot',
              ),
              enabled: !_saving,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _usersController,
              decoration: const InputDecoration(
                labelText: 'Trigger Username(s)',
                hintText: 'e.g. frank, bob',
                helperText: 'Bot joins when one of these users joins a voice channel, and records everyone there',
              ),
              enabled: !_saving,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(
                labelText: 'Bot Token',
                hintText: 'From your Discord application\'s Bot page',
                helperText: 'Keep this secret — do not share it with anyone',
              ),
              enabled: !_saving,
              obscureText: true,
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              title: const Text('How to create the bot', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              tilePadding: EdgeInsets.zero,
              children: [
                const Text(
                  '1. Go to discord.com/developers/applications and click "New Application".\n'
                  '2. Open the "Bot" tab, then "Reset Token" and copy the token into the field above.\n'
                  '3. In "OAuth2 → URL Generator", tick the "bot" scope and the '
                  '"View Channels", "Connect", and "Speak" permissions.\n'
                  '4. Open the generated URL and invite the bot to your server.\n'
                  '\n'
                  'No privileged intents are required. The bot only listens — it never speaks.',
                  style: TextStyle(fontSize: 13, height: 1.5),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Connect Account'),
        ),
      ],
    );
  }
}

class _MeetingSetupDialog extends StatefulWidget {
  const _MeetingSetupDialog({required this.controller});

  final NeoRecallController controller;

  @override
  State<_MeetingSetupDialog> createState() => _MeetingSetupDialogState();
}

class _MeetingSetupDialogState extends State<_MeetingSetupDialog> {
  final _urlController = TextEditingController();
  final _nameController = TextEditingController(text: 'NeoRecall Notetaker');
  bool _saving = false;

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _urlController.text.trim();
    final name = _nameController.text.trim();

    if (url.isEmpty) return;

    setState(() => _saving = true);
    try {
      await widget.controller.api.request('POST', '/api/v1/sources', body: {
        'type': 'meeting',
        'name': name.isNotEmpty ? name : 'NeoRecall Notetaker',
        'config': {
          'url': url,
        },
        'enabled': true, // Auto-start the bot immediately
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $error'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join Meeting'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Paste a Google Meet, Zoom, or Microsoft Teams meeting link below. Our bot will automatically join as a guest and record the audio.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Meeting URL',
                hintText: 'https://meet.google.com/...',
              ),
              enabled: !_saving,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Bot Name',
                hintText: 'e.g. NeoRecall Notetaker',
                helperText: 'This name will be shown to other participants',
              ),
              enabled: !_saving,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Join & Record'),
        ),
      ],
    );
  }
}
