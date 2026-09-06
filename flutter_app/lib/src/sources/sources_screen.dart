import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import 'discord_setup_dialog.dart';
import 'platform_copy.dart';
import 'source_platform_card.dart';

class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  List<Map<String, dynamic>> _sources = <Map<String, dynamic>>[];
  final Set<String> _busyTypes = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
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

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final response =
          await widget.controller.api.request('GET', '/api/v1/sources') as Map;
      if (!mounted) return;
      setState(() {
        _sources = (response['sources'] as List<dynamic>? ?? <dynamic>[])
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load sources: $error')));
    }
  }

  Map<String, dynamic>? _sourceFor(String type) {
    for (final source in _sources) {
      if (source['type'] == type) return source;
    }
    return null;
  }

  Future<void> _setupManual(String typeId) async {
    final Widget? dialog = switch (typeId) {
      'discord' => DiscordSetupDialog(controller: widget.controller),
      _ => null,
    };
    if (dialog == null) return;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => dialog,
    );
    if (result == true) {
      await _load();
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to update: $error')));
      }
    }
  }


  Future<void> _deleteSource(Map<String, dynamic> source) async {
    final palette = neoRecallPaletteOf(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.bgCard,
        title: Text('Disconnect', style: TextStyle(color: palette.textPrimary)),
        content: Text(
          'Stop this source? Existing transcripts stay in NeoRecall.',
          style: TextStyle(color: palette.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: palette.textSecondary),
            ),
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
      await widget.controller.api.request(
        'DELETE',
        '/api/v1/sources/${source['id']}',
      );
      await _load(silent: true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to disconnect: $error')));
      }
    }
  }

  List<_CardModel> _buildCards(SourceCategory category) {
    final cards = <_CardModel>[];
    for (final copy in kStaticIntegrations.where(
      (c) => c.category == category,
    )) {
      final source = _sourceFor(copy.id);
      cards.add(
        _CardModel(
          copy: copy,
          available: true,
          source: source,
          accountEmail: source?['config'] is Map
              ? (source!['config'] as Map)['accountEmail'] as String?
              : null,
          lastSyncAt: source?['config'] is Map
              ? (source!['config'] as Map)['lastSyncAt'] as String?
              : null,
          error: source?['config'] is Map
              ? (source!['config'] as Map)['error'] as String?
              : null,
          prerequisites: copy.prerequisites,
        ),
      );
    }
    return cards;
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final gutter = compact ? AppSpacing.lg - 4 : AppSpacing.lg;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final live = _buildCards(SourceCategory.liveCapture);

    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 20 : 28, gutter, 40),
        children: <Widget>[
          ScreenHeader(
            title: 'Sources',
            description:
                'Services that can feed NeoRecall audio. Wearables and a '
                'NeoRecall Desk are set up from Record.',
            trailing: IconButton(
              tooltip: 'Refresh',
              onPressed: () => _load(),
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
          ),
          const SectionLabel(label: 'Live capture'),
          const SizedBox(height: 6),
          if (live.isEmpty)
            const EmptyState(
              icon: Icons.hub_outlined,
              title: 'Nothing to connect yet',
              message:
                  'Live sources appear here as they become available for your '
                  'account.',
            )
          else
            for (final card in live)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: SourcePlatformCard(
                  copy: card.copy,
                  available: card.available,
                  source: card.source,
                  accountEmail: card.accountEmail,
                  lastSyncAt: card.lastSyncAt,
                  error: card.error,
                  prerequisites: card.prerequisites,
                  busy: _busyTypes.contains(card.copy.id),
                  onConnect: () => _setupManual(card.copy.id),
                  onToggle: card.source == null
                      ? null
                      : (value) => _toggleSource(card.source!, value),
                  onSync: null,
                  onDisconnect: card.source == null
                      ? null
                      : () => _deleteSource(card.source!),
                ),
              ),
        ],
      ),
    );
  }
}

class _CardModel {
  const _CardModel({
    required this.copy,
    required this.available,
    this.source,
    this.accountEmail,
    this.lastSyncAt,
    this.error,
    this.prerequisites = const <String>[],
  });

  final SourcePlatformCopy copy;
  final bool available;
  final Map<String, dynamic>? source;
  final String? accountEmail;
  final String? lastSyncAt;
  final String? error;
  final List<String> prerequisites;
}
