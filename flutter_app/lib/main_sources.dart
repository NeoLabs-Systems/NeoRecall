import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main_controller.dart';
import 'main_theme.dart';
import 'main_shared.dart';

class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  bool loading = true;
  List<dynamic> sources = [];

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    setState(() => loading = true);
    try {
      final response = await widget.controller.api.request('GET', '/sources') as Map;
      setState(() {
        sources = response['sources'] as List<dynamic>;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load sources: $error')));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _addSource() async {
    final result = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _AddSourceDialog(controller: widget.controller),
    );
    if (result == true) {
      _loadSources();
    }
  }

  Future<void> _toggleSource(Map<String, dynamic> source, bool enabled) async {
    try {
      await widget.controller.api.request('PATCH', '/sources/${source['id']}', body: {'enabled': enabled});
      _loadSources();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update source: $error')));
      }
    }
  }

  Future<void> _deleteSource(Map<String, dynamic> source) async {
    try {
      await widget.controller.api.request('DELETE', '/sources/${source['id']}');
      _loadSources();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete source: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);

    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (sources.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.input_rounded, size: 64, color: palette.textMuted),
              const SizedBox(height: 16),
              Text(
                'No Sources Configured',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Add external sources like Discord bots here to feed audio into NeoRecall.',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textSecondary),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _addSource,
                icon: const Icon(Icons.add),
                label: const Text('Add Source'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: palette.accent,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        onPressed: _addSource,
        backgroundColor: palette.accent,
        foregroundColor: Colors.white,
        child: const Icon(Icons.add),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: sources.length,
        itemBuilder: (context, index) {
          final source = sources[index];
          final typeName = source['type'] == 'discord' ? 'Discord Selfbot' : source['type'];
          return Card(
            color: palette.bgCard,
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: Icon(
                source['type'] == 'discord' ? Icons.discord : Icons.input_rounded,
                color: palette.accent,
              ),
              title: Text(source['name'], style: TextStyle(color: palette.textPrimary, fontWeight: FontWeight.w600)),
              subtitle: Text(typeName, style: TextStyle(color: palette.textSecondary)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: source['enabled'],
                    onChanged: (val) => _toggleSource(source, val),
                    activeColor: palette.accent,
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: palette.danger),
                    onPressed: () => _deleteSource(source),
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

class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog({required this.controller});

  final NeoRecallController controller;

  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final _nameController = TextEditingController();
  final _usersController = TextEditingController();
  
  bool _saving = false;
  String? _pairingToken;
  Timer? _pollingTimer;

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _nameController.dispose();
    _usersController.dispose();
    super.dispose();
  }

  Future<void> _generateSetup() async {
    final name = _nameController.text.trim();
    final users = _usersController.text.trim();

    if (name.isEmpty || users.isEmpty) return;

    setState(() => _saving = true);
    try {
      final response = await widget.controller.api.request('POST', '/sources/discord/pairing', body: {
        'name': name,
        'targetUsers': users,
      }) as Map;
      
      setState(() {
        _pairingToken = response['pairingToken'] as String;
      });
      
      _startPolling();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
  
  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted || _pairingToken == null) {
        timer.cancel();
        return;
      }
      try {
        final response = await widget.controller.api.request('GET', '/sources/discord/pairing/$_pairingToken/status') as Map;
        if (response['status'] == 'success') {
          timer.cancel();
          if (mounted) Navigator.of(context).pop(true);
        } else if (response['status'] == 'expired') {
          timer.cancel();
          if (mounted) {
            setState(() {
               _pairingToken = null;
            });
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Setup session expired.')));
          }
        }
      } catch (_) {}
    });
  }

  String get _backendUrl {
    final url = widget.controller.api.baseUrl;
    if (url.isNotEmpty) return url;
    return Uri.base.origin; // Fallback for web
  }

  String get _jsSnippet {
    return '''(function() {
  var t=(webpackChunkdiscord_app.push([[''],{},e=>{m=[];for(let c in e.c)m.push(e.c[c])}]),m).find(m=>m?.exports?.default?.getToken!==void 0).exports.default.getToken();
  if (!t) return alert("Failed to find Discord token.");
  fetch('$_backendUrl/api/v1/sources/discord/pair', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ pairingToken: '$_pairingToken', discordToken: t })
  }).then(r => r.ok ? alert('Successfully linked to NeoRecall!') : alert('Pairing failed.'));
})();''';
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);

    if (_pairingToken != null) {
      return AlertDialog(
        backgroundColor: palette.bgCard,
        title: Text('Complete Setup in Discord', style: TextStyle(color: palette.textPrimary)),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('1. Open the Discord Web App in your browser.', style: TextStyle(color: palette.textSecondary)),
              const SizedBox(height: 8),
              Text('2. Open the Developer Tools (Ctrl+Shift+I or Cmd+Option+I) and go to the Console tab.', style: TextStyle(color: palette.textSecondary)),
              const SizedBox(height: 8),
              Text('3. Paste the following code and press Enter:', style: TextStyle(color: palette.textSecondary)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: palette.bgSecondary,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.border),
                ),
                child: SelectableText(
                  _jsSnippet,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: palette.textPrimary),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _jsSnippet));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy Code'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: palette.bgTertiary,
                    foregroundColor: palette.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Text('Waiting for pairing...', style: TextStyle(color: palette.textSecondary)),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: palette.textSecondary)),
          ),
        ],
      );
    }

    return AlertDialog(
      backgroundColor: palette.bgCard,
      title: Text('Add Discord Source', style: TextStyle(color: palette.textPrimary)),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.danger.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: palette.danger),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, color: palette.danger),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'WARNING: Using a user token to automate joining and recording voice channels is a violation of Discord Terms of Service. This can lead to your account being permanently banned.',
                      style: TextStyle(color: palette.danger, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Source Name',
                labelStyle: TextStyle(color: palette.textSecondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: palette.border)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: palette.accent)),
              ),
              style: TextStyle(color: palette.textPrimary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usersController,
              decoration: InputDecoration(
                labelText: 'Target User IDs (comma separated)',
                labelStyle: TextStyle(color: palette.textSecondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: palette.border)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: palette.accent)),
              ),
              style: TextStyle(color: palette.textPrimary),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: palette.textSecondary)),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _generateSetup,
          style: ElevatedButton.styleFrom(backgroundColor: palette.accent),
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Generate Setup Script', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
