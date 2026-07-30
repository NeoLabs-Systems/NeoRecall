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
      'id': 'zoom',
      'name': 'Zoom',
      'icon': Icons.videocam,
      'description': 'Automatically transcribe and record your Zoom meetings.',
      'comingSoon': true,
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
    if (typeId != 'discord') return;

    final result = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DiscordSetupDialog(controller: widget.controller),
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
                            Text(
                              integration['name'],
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (isConnected) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: Colors.green.withValues(alpha: 0.5)),
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
                          activeColor: palette.accent,
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
  final _nameController = TextEditingController(text: 'My Discord Account');
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
      final response = await widget.controller.api.request('POST', '/api/v1/sources/discord/pairing', body: {
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
        final response = await widget.controller.api.request('GET', '/api/v1/sources/discord/pairing/$_pairingToken/status') as Map;
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
  let t;
  try {
    var req = webpackChunkdiscord_app.push([[Math.random()], {}, e => e]);
    for (let c in req.c) {
      let m = req.c[c].exports;
      if (m && m.default && m.default.getToken) { t = m.default.getToken(); break; }
      if (m && m.getToken) { t = m.getToken(); break; }
    }
  } catch(e) { console.error("Error extracting token", e); }
  if (!t) return alert("Failed to automatically find Discord token. Discord may have updated their web app.");
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
                  Text('Waiting for you to connect...', style: TextStyle(color: palette.textSecondary)),
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
      title: Text('Connect Discord Account', style: TextStyle(color: palette.textPrimary)),
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
                      'WARNING: Automating voice channels violates Discord Terms of Service and could lead to a ban. Use at your own risk.',
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
                labelText: 'Account Name',
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
                labelText: 'Record these users (comma separated IDs)',
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
              : const Text('Connect Account', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
