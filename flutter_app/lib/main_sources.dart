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
      'id': 'plaud',
      'name': 'PLAUD',
      'icon': Icons.cloud_sync_outlined,
      'description': 'Import recordings from your PLAUD wearable via your PLAUD account.',
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

  /// Setup dialog per source type. Adding an integration means adding one entry
  /// here, not another branch in a growing if-chain.
  Widget? _setupDialogFor(String typeId) => switch (typeId) {
    'discord' => _DiscordSetupDialog(controller: widget.controller),
    'meeting' => _MeetingSetupDialog(controller: widget.controller),
    'plaud' => _PlaudSetupDialog(controller: widget.controller),
    _ => null,
  };

  Future<void> _setupSource(String typeId) async {
    final dialog = _setupDialogFor(typeId);
    if (dialog == null) return;

    final result = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => dialog,
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

/// Connects the meeting bots to a real account, without any per-service API key.
///
/// Most meetings refuse anonymous guests outright, so a bot that joins as one is
/// simply denied at the door. Instead the user signs in once, by hand, in an
/// ordinary Chrome window that the server opens on its own machine; the bot then
/// reuses that browser profile. The password goes into the provider's own page —
/// NeoRecall never sees it and stores no credentials.
class _MeetingAccountPanel extends StatefulWidget {
  const _MeetingAccountPanel({required this.controller});

  final NeoRecallController controller;

  @override
  State<_MeetingAccountPanel> createState() => _MeetingAccountPanelState();
}

class _MeetingAccountPanelState extends State<_MeetingAccountPanel> {
  Map<String, dynamic>? _status;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _call(Future<dynamic> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await action();
      if (!mounted) return;
      setState(() => _status = _statusOf(result));
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// sign-in returns `{provider, label, status}`; the others return the status
  /// object itself.
  Map<String, dynamic>? _statusOf(dynamic result) {
    if (result is! Map) return _status;
    final nested = result['status'];
    return Map<String, dynamic>.from(nested is Map ? nested : result);
  }

  Future<void> _load() => _call(() => widget.controller.api.request('GET', '/api/v1/sources/meeting/account'));

  Future<void> _signIn(String provider) => _call(() => widget.controller.api
      .request('POST', '/api/v1/sources/meeting/account/sign-in', body: {'provider': provider}));

  Future<void> _complete() =>
      _call(() => widget.controller.api.request('POST', '/api/v1/sources/meeting/account/complete'));

  Future<void> _signOut() => _call(() => widget.controller.api.request('DELETE', '/api/v1/sources/meeting/account'));

  String _blockedMessage(String reason) => switch (reason) {
        'no-chrome' =>
          'Google Chrome was not found on the machine running NeoRecall. Install Chrome there, then reopen this dialog.',
        'no-display' =>
          'The machine running NeoRecall has no screen, so the sign-in window cannot be shown. Run the server on a machine with a display, or sign in there and copy the meeting_profiles directory across.',
        'no-browser-support' =>
          'This NeoRecall build cannot drive a browser, so meeting accounts are unavailable. Install the Playwright dependency on the server and restart it.',
        _ => 'Signing in is not available on the machine running NeoRecall.',
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final status = _status;

    if (status == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: _error == null
            ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
            : Text(_error!, style: TextStyle(fontSize: 12, color: colors.error)),
      );
    }

    final providers = (status['providers'] as List<dynamic>? ?? <dynamic>[]).cast<Map<String, dynamic>>();
    final pending = status['signInPending'] as Map<String, dynamic>?;
    final canSignIn = status['canSignIn'] == true;
    final emails = (status['accountEmails'] as List<dynamic>? ?? <dynamic>[]).join(', ');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.account_circle_outlined, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              const Expanded(child: Text('Meeting account', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
              if (_busy) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Meetings that do not accept guests will turn the bot away. Sign in once and it joins as a real participant instead. No API keys, and your password is typed into the provider’s own page — never into NeoRecall.',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          if (emails.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Signed in as $emails', style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
          ],
          const SizedBox(height: 10),
          if (pending != null)
            _PendingSignIn(
              provider: '${pending['provider']}',
              busy: _busy,
              onDone: _complete,
            )
          else if (!canSignIn)
            Text(_blockedMessage('${status['blockedReason']}'), style: TextStyle(fontSize: 12, color: colors.error))
          else
            ...providers.map((provider) => _providerRow(provider, colors)),
          if (status['warning'] != null) ...[
            const SizedBox(height: 8),
            Text('${status['warning']}', style: TextStyle(fontSize: 11, color: colors.error)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(fontSize: 12, color: colors.error)),
          ],
        ],
      ),
    );
  }

  Widget _providerRow(Map<String, dynamic> provider, ColorScheme colors) {
    final connected = provider['connected'] == true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            connected ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 16,
            color: connected ? Colors.green : colors.outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${provider['label']} · ${provider['platforms']}',
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: _busy ? null : () => connected ? _signOut() : _signIn('${provider['id']}'),
            child: Text(connected ? 'Sign out' : 'Sign in', style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// Shown while the Chrome window is open on the server. The user finishes there,
/// then tells NeoRecall to close it and re-check what the profile holds.
class _PendingSignIn extends StatelessWidget {
  const _PendingSignIn({required this.provider, required this.busy, required this.onDone});

  final String provider;
  final bool busy;
  final Future<void> Function() onDone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'A Chrome window is open on the machine running NeoRecall. Sign in to $provider there, then come back and press Done.',
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: busy ? null : () => onDone(),
          child: const Text("Done — I've signed in"),
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
              'Paste a Google Meet, Zoom, or Microsoft Teams meeting link below. The bot joins the call and records the audio.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            _MeetingAccountPanel(controller: widget.controller),
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
                helperText: 'Shown to other participants when joining as a guest',
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

/// Connects a user's PLAUD account so their wearable's recordings are imported.
///
/// PLAUD's own app owns the device link — current wearable firmware speaks a
/// closed BLE protocol — so recordings are pulled from the PLAUD account they
/// already sync to. The token is verified before the source is stored, so a bad
/// paste fails here instead of silently never importing anything.
class _PlaudSetupDialog extends StatefulWidget {
  const _PlaudSetupDialog({required this.controller});

  final NeoRecallController controller;

  @override
  State<_PlaudSetupDialog> createState() => _PlaudSetupDialogState();
}

class _PlaudSetupDialogState extends State<_PlaudSetupDialog> {
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
      // Fail fast on a bad token rather than storing a source that can never sync.
      final check =
          await widget.controller.api.request(
                'POST',
                '/api/v1/sources/verify',
                body: <String, Object?>{'type': 'plaud', 'config': config},
              )
              as Map;
      if (check['ok'] != true) {
        throw StateError(check['error']?.toString() ?? 'PLAUD rejected the token.');
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
                helperText: 'Stored only on your NeoRecall server, never shown again.',
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
                DropdownMenuItem<int>(value: 15, child: Text('Every 15 minutes')),
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
