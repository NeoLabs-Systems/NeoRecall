import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_theme.dart';
import 'discord_setup_dialog.dart';
import 'oauth_connect_flow.dart';
import 'platform_copy.dart';
import 'plaud_setup_dialog.dart';
import 'source_platform_card.dart';

class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> with WidgetsBindingObserver {
  bool _loading = true;
  List<Map<String, dynamic>> _sources = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _catalogPlatforms = <Map<String, dynamic>>[];
  final Set<String> _busyTypes = <String>{};
  String? _banner;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _consumeOauthReturnQuery();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load(silent: true);
    }
  }

  /// When OAuth redirects back to /app/?sources_oauth=… on web, show a toast.
  void _consumeOauthReturnQuery() {
    if (!kIsWeb) return;
    final params = Uri.base.queryParameters;
    final status = params['sources_oauth'];
    if (status == null) return;
    final provider = params['provider'];
    final message = params['message'];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (status == 'success') {
        final label = copyFor(provider ?? '')?.name ?? provider ?? 'account';
        setState(() => _banner = '$label connected. Cloud recordings will import automatically.');
      } else if (status == 'error') {
        setState(() => _banner = message ?? 'Sign-in failed. Try again.');
      }
      _load(silent: true);
    });
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final results = await Future.wait<dynamic>([
        widget.controller.api.request('GET', '/api/v1/sources'),
        widget.controller.api.request('GET', '/api/v1/sources/catalog').catchError((_) => <String, dynamic>{'platforms': <dynamic>[]}),
      ]);
      final sourcesResponse = results[0] as Map;
      final catalogResponse = results[1] as Map;
      if (!mounted) return;
      setState(() {
        _sources = (sourcesResponse['sources'] as List<dynamic>? ?? <dynamic>[])
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
        _catalogPlatforms = (catalogResponse['platforms'] as List<dynamic>? ?? <dynamic>[])
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load sources: $error')),
      );
    }
  }

  Map<String, dynamic>? _sourceFor(String type) {
    for (final source in _sources) {
      if (source['type'] == type) return source;
    }
    return null;
  }

  Map<String, dynamic>? _catalogFor(String type) {
    for (final platform in _catalogPlatforms) {
      if (platform['type'] == type) return platform;
    }
    return null;
  }

  Future<void> _setupManual(String typeId) async {
    final Widget? dialog = switch (typeId) {
      'discord' => DiscordSetupDialog(controller: widget.controller),
      'plaud' => PlaudSetupDialog(controller: widget.controller),
      _ => null,
    };
    if (dialog == null) return;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => dialog,
    );
    if (result == true) await _load();
  }

  Future<void> _connectOauth(String typeId) async {
    setState(() {
      _busyTypes.add(typeId);
      _banner = null;
    });
    try {
      final connected = await OauthConnectFlow(widget.controller).connect(context, typeId);
      if (!mounted) return;
      if (connected) {
        final label = copyFor(typeId)?.name ?? typeId;
        setState(() => _banner = '$label connected. Cloud recordings will import automatically.');
        await _load(silent: true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Still waiting for sign-in. If you finished in the browser, pull to refresh or reopen Sources.'),
          ),
        );
        await _load(silent: true);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start sign-in: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyTypes.remove(typeId));
    }
  }

  Future<void> _toggleSource(Map<String, dynamic> source, bool enabled) async {
    try {
      await widget.controller.api.request(
        'PATCH',
        '/api/v1/sources/${source['id']}',
        body: {'enabled': enabled},
      );
      await _load(silent: true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update: $error')));
      }
    }
  }

  Future<void> _syncSource(Map<String, dynamic> source) async {
    final type = source['type'] as String? ?? '';
    setState(() => _busyTypes.add(type));
    try {
      final result = await widget.controller.api.request(
        'POST',
        '/api/v1/sources/${source['id']}/sync',
      ) as Map;
      if (mounted) {
        final imported = result['imported'];
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              imported is num && imported > 0
                  ? 'Imported $imported new recording${imported == 1 ? '' : 's'}.'
                  : 'Sync complete. No new recordings.',
            ),
          ),
        );
      }
      await _load(silent: true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sync failed: $error')));
      }
      await _load(silent: true);
    } finally {
      if (mounted) setState(() => _busyTypes.remove(type));
    }
  }

  Future<void> _deleteSource(Map<String, dynamic> source) async {
    final palette = neoRecallPaletteOf(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.bgCard,
        title: Text('Disconnect account', style: TextStyle(color: palette.textPrimary)),
        content: Text(
          'Stop importing from this source? Existing transcripts stay in NeoRecall.',
          style: TextStyle(color: palette.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel', style: TextStyle(color: palette.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Disconnect', style: TextStyle(color: palette.danger)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await widget.controller.api.request('DELETE', '/api/v1/sources/${source['id']}');
      await _load(silent: true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to disconnect: $error')));
      }
    }
  }

  List<_CardModel> _buildCards() {
    final cards = <_CardModel>[];

    for (final copy in kStaticIntegrations) {
      if (copy.auth == 'oauth') {
        final catalog = _catalogFor(copy.id);
        final source = _sourceFor(copy.id);
        final available = catalog == null ? false : catalog['available'] == true;
        final prerequisites = <String>[
          ...copy.prerequisites,
          if (catalog?['prerequisites'] is List)
            for (final item in catalog!['prerequisites'] as List)
              if (item is String && !copy.prerequisites.contains(item)) item,
        ];
        cards.add(_CardModel(
          copy: copy,
          available: available || source != null,
          unavailableReason: catalog?['unavailableReason'] as String? ??
              (catalog == null
                  ? 'Could not load platform status from the server.'
                  : null),
          source: source,
          accountEmail: (catalog?['accountEmail'] as String?) ??
              (source?['config'] is Map ? (source!['config'] as Map)['accountEmail'] as String? : null),
          lastSyncAt: source?['config'] is Map ? (source!['config'] as Map)['lastSyncAt'] as String? : null,
          error: source?['config'] is Map ? (source!['config'] as Map)['error'] as String? : null,
          prerequisites: prerequisites,
        ));
      } else {
        final source = _sourceFor(copy.id);
        cards.add(_CardModel(
          copy: copy,
          available: true,
          source: source,
          accountEmail: source?['config'] is Map ? (source!['config'] as Map)['accountEmail'] as String? : null,
          lastSyncAt: source?['config'] is Map ? (source!['config'] as Map)['lastSyncAt'] as String? : null,
          error: source?['config'] is Map ? (source!['config'] as Map)['error'] as String? : null,
          prerequisites: copy.prerequisites,
        ));
      }
    }
    return cards;
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final cards = _buildCards();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(
          'External Sources',
          style: TextStyle(color: palette.textPrimary, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _load(),
            icon: Icon(Icons.refresh, color: palette.textSecondary),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Connect accounts once. NeoRecall imports recordings automatically and runs them through the same transcription pipeline as live capture.',
              style: TextStyle(color: palette.textSecondary, fontSize: 13.5, height: 1.4),
            ),
            if (_banner != null) ...[
              const SizedBox(height: 12),
              Material(
                color: palette.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline, size: 18, color: palette.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_banner!, style: TextStyle(color: palette.textPrimary, fontSize: 13)),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(() => _banner = null),
                        icon: Icon(Icons.close, size: 16, color: palette.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Meetings',
              style: TextStyle(
                color: palette.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            for (final card in cards.where((c) => c.copy.auth == 'oauth'))
              SourcePlatformCard(
                copy: card.copy,
                available: card.available,
                unavailableReason: card.unavailableReason,
                source: card.source,
                accountEmail: card.accountEmail,
                lastSyncAt: card.lastSyncAt,
                error: card.error,
                prerequisites: card.prerequisites,
                busy: _busyTypes.contains(card.copy.id),
                onConnect: () => _connectOauth(card.copy.id),
                onReconnect: () => _connectOauth(card.copy.id),
                onToggle: card.source == null ? null : (value) => _toggleSource(card.source!, value),
                onSync: card.source == null ? null : () => _syncSource(card.source!),
                onDisconnect: card.source == null ? null : () => _deleteSource(card.source!),
              ),
            const SizedBox(height: 8),
            Text(
              'Other',
              style: TextStyle(
                color: palette.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            for (final card in cards.where((c) => c.copy.auth != 'oauth'))
              SourcePlatformCard(
                copy: card.copy,
                available: card.available,
                unavailableReason: card.unavailableReason,
                source: card.source,
                accountEmail: card.accountEmail,
                lastSyncAt: card.lastSyncAt,
                error: card.error,
                prerequisites: card.prerequisites,
                busy: _busyTypes.contains(card.copy.id),
                onConnect: () => _setupManual(card.copy.id),
                onToggle: card.source == null ? null : (value) => _toggleSource(card.source!, value),
                onSync: card.copy.id == 'plaud' && card.source != null
                    ? () => _syncSource(card.source!)
                    : null,
                onDisconnect: card.source == null ? null : () => _deleteSource(card.source!),
              ),
          ],
        ),
      ),
    );
  }
}

class _CardModel {
  const _CardModel({
    required this.copy,
    required this.available,
    this.unavailableReason,
    this.source,
    this.accountEmail,
    this.lastSyncAt,
    this.error,
    this.prerequisites = const <String>[],
  });

  final SourcePlatformCopy copy;
  final bool available;
  final String? unavailableReason;
  final Map<String, dynamic>? source;
  final String? accountEmail;
  final String? lastSyncAt;
  final String? error;
  final List<String> prerequisites;
}
