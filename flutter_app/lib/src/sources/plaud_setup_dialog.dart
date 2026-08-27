import 'package:flutter/material.dart';

import '../../main_controller.dart';

class PlaudSetupDialog extends StatefulWidget {
  const PlaudSetupDialog({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<PlaudSetupDialog> createState() => _PlaudSetupDialogState();
}

class _PlaudSetupDialogState extends State<PlaudSetupDialog> {
  final _tokenController = TextEditingController();
  final _nameController = TextEditingController(text: 'PLAUD');
  int _pollMinutes = 15;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _tokenController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _error = 'Paste your PLAUD access token.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final config = <String, Object?>{
        'accessToken': token,
        'pollMinutes': _pollMinutes,
      };
      final check =
          await widget.controller.api.request(
                'POST',
                '/api/v1/sources/verify',
                body: <String, Object?>{'type': 'plaud', 'config': config},
              )
              as Map;
      if (check['ok'] != true) {
        throw StateError(
          check['error']?.toString() ?? 'PLAUD rejected the token.',
        );
      }
      final name = _nameController.text.trim();
      await widget.controller.api.request(
        'POST',
        '/api/v1/sources',
        body: <String, Object?>{
          'type': 'plaud',
          'name': name.isNotEmpty ? name : 'PLAUD',
          'config': config,
          'enabled': true,
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connect PLAUD'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Your PLAUD wearable syncs its recordings to your PLAUD account. '
              'NeoRecall imports them from there and transcribes them like any '
              'other recording.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 10),
            const Text(
              'Get an access token by signing in with the PLAUD CLI '
              '(npx -y @plaud-ai/mcp@latest install), then paste it here.',
              style: TextStyle(fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tokenController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'PLAUD access token',
                helperText:
                    'Stored only on your NeoRecall server, never shown again.',
              ),
              enabled: !_saving,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Display name'),
              enabled: !_saving,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              initialValue: _pollMinutes,
              decoration: const InputDecoration(
                labelText: 'Check for new recordings',
              ),
              items: const <DropdownMenuItem<int>>[
                DropdownMenuItem<int>(value: 5, child: Text('Every 5 minutes')),
                DropdownMenuItem<int>(
                  value: 15,
                  child: Text('Every 15 minutes'),
                ),
                DropdownMenuItem<int>(value: 60, child: Text('Hourly')),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _pollMinutes = value ?? 15),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12.5,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
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
              : const Text('Connect'),
        ),
      ],
    );
  }
}
