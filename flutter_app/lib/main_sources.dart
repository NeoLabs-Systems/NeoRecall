import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
  // Set while the live sign-in view replaces the provider list.
  Map<String, dynamic>? _liveSignIn;

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
      setState(() => _status = Map<String, dynamic>.from(result as Map));
    } catch (error) {
      if (mounted) setState(() => _error = _friendly(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Server error messages are already written for people, not just logs, so
  /// they are shown as-is; only the generic "couldn't reach the server" case
  /// gets a friendlier wrapper here.
  String _friendly(Object error) {
    final text = '$error';
    if (text.contains('SocketException') || text.contains('Connection') || text.contains('TimeoutException')) {
      return "Couldn't reach NeoRecall. Check your connection and try again.";
    }
    return text.replaceFirst(RegExp(r'^Exception:\s*'), '');
  }

  Future<void> _load() => _call(() => widget.controller.api.request('GET', '/api/v1/sources/meeting/account'));

  Future<void> _signOut() => _call(() => widget.controller.api.request('DELETE', '/api/v1/sources/meeting/account'));

  Future<void> _signIn(String provider) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.controller.api
          .request('POST', '/api/v1/sources/meeting/account/sign-in', body: {'provider': provider});
      if (!mounted) return;
      setState(() => _liveSignIn = Map<String, dynamic>.from(result as Map));
    } catch (error) {
      if (mounted) setState(() => _error = _friendly(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onSignInFinished(Map<String, dynamic>? status, String? note) {
    if (!mounted) return;
    setState(() {
      _liveSignIn = null;
      if (status != null) _status = status;
      _error = note;
    });
  }

  String _blockedMessage(String reason) => switch (reason) {
        'unavailable' =>
          'Connecting an account isn’t available on this NeoRecall installation right now. The bot can still join meetings as a guest.',
        _ => 'Connecting an account isn’t available right now.',
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final status = _status;
    final liveSignIn = _liveSignIn;

    if (status == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: _error == null
            ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
            : Text(_error!, style: TextStyle(fontSize: 12, color: colors.error)),
      );
    }

    final providers = (status['providers'] as List<dynamic>? ?? <dynamic>[]).cast<Map<String, dynamic>>();
    final available = status['available'] == true;
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
              const Expanded(child: Text('Connect an account', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
              if (_busy) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 6),
          if (liveSignIn == null)
            Text(
              'Some meetings only let signed-in people in, and turn the notetaker away otherwise. Connect your account once and it will join as a real guest instead. Your password goes straight to Google, Microsoft, or Zoom — NeoRecall never sees it.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          if (emails.isNotEmpty && liveSignIn == null) ...[
            const SizedBox(height: 6),
            Text('Connected as $emails', style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
          ],
          const SizedBox(height: 10),
          if (liveSignIn != null)
            _RemoteSignInView(
              controller: widget.controller,
              session: liveSignIn,
              onFinished: _onSignInFinished,
            )
          else if (!available)
            Text(_blockedMessage('${status['blockedReason']}'), style: TextStyle(fontSize: 12, color: colors.error))
          else
            ...providers.map((provider) => _providerRow(provider, colors)),
          if (status['warning'] != null && liveSignIn == null) ...[
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
            child: Text(connected ? 'Disconnect' : 'Connect', style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// A private, one-time sign-in session shown live inside the app.
///
/// The page the user is signing in to renders on the server, in a browser
/// session that belongs only to them, and is streamed here frame by frame; taps
/// and typing are sent back the same way. Nothing about the machine running
/// NeoRecall is ever shown — this view IS the sign-in window, from the user's
/// own device, for their account alone.
class _RemoteSignInView extends StatefulWidget {
  const _RemoteSignInView({required this.controller, required this.session, required this.onFinished});

  final NeoRecallController controller;
  final Map<String, dynamic> session;
  final void Function(Map<String, dynamic>? status, String? note) onFinished;

  @override
  State<_RemoteSignInView> createState() => _RemoteSignInViewState();
}

class _RemoteSignInViewState extends State<_RemoteSignInView> {
  // Matches the fixed CDP viewport signin_session.js starts the screencast
  // with; taps are rescaled from on-screen pixels into this space.
  static const double _viewportWidth = 1024;
  static const double _viewportHeight = 768;
  static final Map<LogicalKeyboardKey, String> _namedKeys = {
    LogicalKeyboardKey.backspace: 'Backspace',
    LogicalKeyboardKey.enter: 'Enter',
    LogicalKeyboardKey.numpadEnter: 'Enter',
    LogicalKeyboardKey.tab: 'Tab',
    LogicalKeyboardKey.escape: 'Escape',
    LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
    LogicalKeyboardKey.arrowRight: 'ArrowRight',
    LogicalKeyboardKey.arrowUp: 'ArrowUp',
    LogicalKeyboardKey.arrowDown: 'ArrowDown',
    LogicalKeyboardKey.delete: 'Delete',
  };

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Uint8List? _frame;
  bool _connecting = true;
  bool _closed = false;
  Offset _lastPoint = Offset.zero;
  final _typeCapture = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _connect();
  }

  void _connect() {
    final Uri uri;
    try {
      uri = _relayUri();
    } catch (error) {
      _finish(status: null, note: "Couldn't start the sign-in session. Please try again.");
      return;
    }
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    _subscription = channel.stream.listen(_onMessage, onError: (_) => _onDisconnected(), onDone: _onDisconnected);
  }

  Uri _relayUri() {
    final ticket = '${widget.session['ticket']}';
    final path = '${widget.session['path']}';
    var base = widget.controller.api.baseUrl.trim();
    if (base.isEmpty) {
      // Same-origin (the web build): derive the server's address from the
      // page's own location, since a relative WebSocket URL isn't valid.
      final origin = Uri.base;
      base = '${origin.scheme}://${origin.host}${origin.hasPort ? ':${origin.port}' : ''}';
    }
    final httpUri = Uri.parse(base);
    return Uri(
      scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
      host: httpUri.host,
      port: httpUri.hasPort ? httpUri.port : null,
      path: path,
      queryParameters: {'ticket': ticket},
    );
  }

  void _onMessage(dynamic raw) {
    if (_closed) return;
    Map<String, dynamic> message;
    try {
      message = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (error) {
      return; // not a message we understand — ignore rather than crash the view
    }
    switch (message['type']) {
      case 'frame':
        final data = message['data'];
        if (data is String) {
          setState(() {
            _connecting = false;
            _frame = base64Decode(data);
          });
        }
      case 'result':
        _finish(
          status: message['status'] is Map ? Map<String, dynamic>.from(message['status'] as Map) : null,
          note: message['message'] as String?,
        );
      case 'error':
        _finish(status: null, note: message['message'] as String? ?? "Something went wrong. Please try again.");
    }
  }

  void _onDisconnected() {
    if (_closed) return;
    _finish(status: null, note: "The sign-in session closed. If you finished signing in, try again to confirm it connected.");
  }

  void _finish({required Map<String, dynamic>? status, required String? note}) {
    if (_closed) return;
    _closed = true;
    _subscription?.cancel();
    try {
      _channel?.sink.close();
    } catch (error) {
      // already gone
    }
    widget.onFinished(status, note);
  }

  void _sendInput(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null || _closed) return;
    channel.sink.add(jsonEncode({'type': 'input', ...payload}));
  }

  void _sendFinish() {
    final channel = _channel;
    if (channel == null || _closed) return;
    channel.sink.add(jsonEncode({'type': 'finish'}));
  }

  Offset _toViewport(Offset local, Size widgetSize) {
    if (widgetSize.width == 0 || widgetSize.height == 0) return Offset.zero;
    return Offset(
      local.dx * _viewportWidth / widgetSize.width,
      local.dy * _viewportHeight / widgetSize.height,
    );
  }

  // The hidden field exists only to capture the OS/IME keyboard (and, on
  // mobile, to bring up the on-screen keyboard). What it accumulates is
  // forwarded and then cleared immediately, so it never holds real text —
  // what the user is typing only ever appears on the streamed page itself.
  void _onTypedTextChanged(String value) {
    if (value.isEmpty) return;
    _sendInput({'kind': 'insertText', 'text': value});
    _typeCapture.clear();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = _namedKeys[event.logicalKey];
    if (key == null) return KeyEventResult.ignored;
    _sendInput({'kind': 'key', 'key': key});
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _closed = true;
    _subscription?.cancel();
    try {
      _channel?.sink.close();
    } catch (error) {
      // already gone
    }
    _typeCapture.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Sign in to ${widget.session['label']} below.',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        AspectRatio(
          aspectRatio: _viewportWidth / _viewportHeight,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: colors.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_frame != null) Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.fill),
                if (_connecting)
                  const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final size = Size(constraints.maxWidth, constraints.maxHeight);
                    return Focus(
                      focusNode: _focusNode,
                      onKeyEvent: _onKeyEvent,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (details) {
                          _focusNode.requestFocus();
                          _lastPoint = _toViewport(details.localPosition, size);
                          _sendInput({'kind': 'mouseMove', 'x': _lastPoint.dx, 'y': _lastPoint.dy});
                          _sendInput({'kind': 'mouseDown', 'x': _lastPoint.dx, 'y': _lastPoint.dy, 'button': 'left'});
                        },
                        onTapUp: (details) {
                          _lastPoint = _toViewport(details.localPosition, size);
                          _sendInput({'kind': 'mouseUp', 'x': _lastPoint.dx, 'y': _lastPoint.dy, 'button': 'left'});
                        },
                        // A cancelled tap (e.g. a scroll took over mid-press) still
                        // has the mouse logically down remotely; release it at the
                        // last known point rather than leaving it stuck.
                        onTapCancel: () => _sendInput({'kind': 'mouseUp', 'x': _lastPoint.dx, 'y': _lastPoint.dy, 'button': 'left'}),
                        child: SizedBox.expand(
                          child: Opacity(
                            opacity: 0,
                            child: TextField(
                              controller: _typeCapture,
                              onChanged: _onTypedTextChanged,
                              decoration: const InputDecoration(border: InputBorder.none),
                              style: const TextStyle(fontSize: 1, height: 0.01),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Tap the box above, then sign in as you normally would. When you’re done, press Finish.',
          style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(onPressed: _sendFinish, child: const Text('Finish')),
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
