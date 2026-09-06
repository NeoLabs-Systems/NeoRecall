import 'package:flutter/material.dart';

import '../../main_controller.dart';

class DiscordSetupDialog extends StatefulWidget {
  const DiscordSetupDialog({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<DiscordSetupDialog> createState() => _DiscordSetupDialogState();
}

class _DiscordSetupDialogState extends State<DiscordSetupDialog> {
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
      await widget.controller.api.request(
        'POST',
        '/api/v1/sources',
        body: {
          'type': 'discord',
          'name': name,
          'config': {'token': token, 'triggerUsernames': users},
          'enabled': true,
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $error'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connect Discord'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'NeoRecall joins voice channels as a bot and records the people you list. Create a bot in the Discord Developer Portal, invite it to your server, then paste its token here.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Display name'),
              enabled: !_saving,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usersController,
              decoration: const InputDecoration(
                labelText: 'Users to record',
                helperText: 'Comma-separated Discord usernames',
              ),
              enabled: !_saving,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Bot token',
                helperText: 'Stored only on your NeoRecall server',
              ),
              enabled: !_saving,
            ),
            const SizedBox(height: 16),
            const ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                'How to create the bot',
                style: TextStyle(fontSize: 13),
              ),
              children: [
                Text(
                  '1. Open the Discord Developer Portal and create an application.\n'
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
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Connect Account'),
        ),
      ],
    );
  }
}
