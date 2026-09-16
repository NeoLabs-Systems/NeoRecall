import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../l10n/gen/app_l10n.dart';

class DiscordSetupDialog extends StatefulWidget {
  const DiscordSetupDialog({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<DiscordSetupDialog> createState() => _DiscordSetupDialogState();
}

class _DiscordSetupDialogState extends State<DiscordSetupDialog> {
  final _nameController = TextEditingController();
  final _usersController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _saving = false;
  bool _prefilled = false;

  // The suggested name is a translated string, so it cannot be a field
  // initializer; it is filled in once, the first time translations are in
  // reach, and never again — overwriting what somebody typed would be worse
  // than showing no suggestion at all.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefilled) return;
    _prefilled = true;
    _nameController.text = AppL10n.of(context).discordDefaultName;
  }

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
            content: Text(AppL10n.of(context).discordError(error.toString())),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppL10n.of(context).discordTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AppL10n.of(context).discordDescription,
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: AppL10n.of(context).speakersDisplayNameLabel,
              ),
              enabled: !_saving,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usersController,
              decoration: InputDecoration(
                labelText: AppL10n.of(context).discordUsersLabel,
                helperText: AppL10n.of(context).discordUsersHelper,
              ),
              enabled: !_saving,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: AppL10n.of(context).discordTokenLabel,
                helperText: AppL10n.of(context).discordTokenHelper,
              ),
              enabled: !_saving,
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                AppL10n.of(context).discordHowTo,
                style: const TextStyle(fontSize: 13),
              ),
              children: [
                Text(
                  AppL10n.of(context).discordSteps,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(AppL10n.of(context).actionCancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppL10n.of(context).discordConnect),
        ),
      ],
    );
  }
}
