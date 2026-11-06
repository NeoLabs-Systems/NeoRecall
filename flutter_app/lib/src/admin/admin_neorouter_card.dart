import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/gen/app_l10n.dart';
import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_theme.dart';
import 'admin_neorouter_client.dart';
import 'admin_widgets.dart';

/// "Connect NeoRouter": one approval in NeoRouter and the server can use every
/// model the router offers for summaries and chat, speech to text and search.
/// Each kind of work can be switched off again; it then returns to the service
/// the server's own configuration names.
class AdminNeoRouterCard extends StatefulWidget {
  const AdminNeoRouterCard({
    super.key,
    required this.controller,
    required this.client,
    this.onChanged,
    this.pollInterval = const Duration(seconds: 2),
    this.openUrl = _launch,
  });

  final NeoRecallController controller;
  final AdminNeoRouterClient client;

  /// Called after the connection or a switch changed what the providers below
  /// are pointed at, so they can reload.
  final VoidCallback? onChanged;
  final Duration pollInterval;

  /// Opens NeoRouter's approval page in the browser.
  final Future<void> Function(Uri url) openUrl;

  static Future<void> _launch(Uri url) async {
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @override
  State<AdminNeoRouterCard> createState() => _AdminNeoRouterCardState();
}

class _AdminNeoRouterCardState extends State<AdminNeoRouterCard> {
  NeoRouterState? _state;
  Object? _loadError;
  NeoRouterSignIn? _pending;
  String? _problem;
  bool _busy = false;

  /// Bumped by every start and cancel, so a cancelled sign-in that is still
  /// polling can never touch a newer one.
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _attempt++;
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final state = await widget.client.load();
      if (!mounted) return;
      setState(() {
        _state = state;
        _loadError = null;
      });
    } catch (error) {
      noteAdminFailure(widget.controller, error);
      if (mounted) setState(() => _loadError = error);
    }
  }

  Future<void> _connect() async {
    final signIn = await showDialog<NeoRouterSignIn>(
      context: context,
      builder: (_) => _ConnectDialog(client: widget.client),
    );
    if (signIn == null || !mounted) return;
    final attempt = ++_attempt;
    bool current() => mounted && attempt == _attempt;
    setState(() {
      _pending = signIn;
      _problem = null;
    });
    unawaited(_open(signIn.url));
    final strings = AppL10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      while (current() && DateTime.now().isBefore(deadline)) {
        final result = await widget.client.poll(signIn.id);
        if (!current()) return;
        if (result.status == 'completed') {
          messenger.showSnackBar(
            SnackBar(content: Text(strings.neoRouterConnected)),
          );
          widget.onChanged?.call();
          await _load();
          return;
        }
        if (result.status == 'failed') {
          setState(
            () => _problem = strings.neoRouterSignInFailed(
              result.error ?? strings.neoRouterSignInTimedOut,
            ),
          );
          return;
        }
        await Future<void>.delayed(widget.pollInterval);
      }
      if (current()) {
        setState(() => _problem = strings.neoRouterSignInTimedOut);
      }
    } catch (error) {
      noteAdminFailure(widget.controller, error);
      if (current()) {
        setState(
          () => _problem = strings.neoRouterSignInFailed(adminErrorText(error)),
        );
      }
    } finally {
      if (current()) setState(() => _pending = null);
    }
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await widget.openUrl(uri);
    } catch (error) {
      // The sign-in keeps waiting; "Open NeoRouter again" tries once more.
      if (mounted) {
        setState(
          () => _problem = AppL10n.of(
            context,
          ).neoRouterSignInFailed(adminErrorText(error)),
        );
      }
    }
  }

  void _cancel() => setState(() {
    _attempt++;
    _pending = null;
  });

  Future<void> _setRole(String role, bool on) async {
    final state = _state;
    if (state == null) return;
    final next = <String>{...state.activeRoles};
    on ? next.add(role) : next.remove(role);
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await widget.client.setRoles(next);
      widget.onChanged?.call();
      await _load();
    } catch (error) {
      noteAdminFailure(widget.controller, error);
      if (mounted) setState(() => _problem = adminErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final strings = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.neoRouterDisconnectTitle),
        content: Text(strings.neoRouterDisconnectBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.neoRouterDisconnect),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await widget.client.disconnect();
      widget.onChanged?.call();
      await _load();
    } catch (error) {
      noteAdminFailure(widget.controller, error);
      if (mounted) setState(() => _problem = adminErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _roleLabel(AppL10n strings, String role) => switch (role) {
    'llm' => strings.neoRouterRoleLlm,
    'transcription' => strings.neoRouterRoleTranscription,
    'embeddings' => strings.neoRouterRoleEmbeddings,
    _ => role,
  };

  String _availability(AppL10n strings, NeoRouterOffer? offer) {
    if (offer == null) return '';
    if (offer.error != null) return strings.neoRouterRoleFailed(offer.error!);
    if (offer.empty) {
      return offer.notAllowed > 0
          ? strings.neoRouterNotAllowed(offer.notAllowed)
          : strings.neoRouterNoModels;
    }
    final count = strings.neoRouterModelCount(offer.models, offer.auto);
    return offer.notAllowed > 0
        ? '$count · ${strings.neoRouterNotAllowed(offer.notAllowed)}'
        : count;
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    final state = _state;
    final children = <Widget>[];
    if (_pending != null) {
      children.add(
        Row(
          children: <Widget>[
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                strings.neoRouterWaiting(_pending!.userCode),
                style: TextStyle(color: palette.textSecondary, height: 1.4),
              ),
            ),
          ],
        ),
      );
      children.add(
        Wrap(
          spacing: 8,
          children: <Widget>[
            TextButton(
              onPressed: () => _open(_pending!.url),
              child: Text(strings.neoRouterOpenAgain),
            ),
            TextButton(onPressed: _cancel, child: Text(strings.actionCancel)),
          ],
        ),
      );
    } else if (state == null) {
      children.add(
        _loadError == null
            ? const Center(child: CircularProgressIndicator())
            : AdminFailure(error: _loadError, onRetry: _load),
      );
    } else if (!state.connected) {
      children.add(
        Text(
          strings.neoRouterIntro,
          style: TextStyle(color: palette.textSecondary, height: 1.5),
        ),
      );
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _busy ? null : _connect,
            icon: const Icon(Icons.link_rounded),
            label: Text(strings.neoRouterConnect),
          ),
        ),
      );
    } else {
      children.add(
        Row(
          children: <Widget>[
            StatusDot(
              color: state.reachable ? palette.success : palette.warning,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                state.reachable
                    ? strings.neoRouterConnectedTo(state.address ?? '')
                    : strings.neoRouterUnreachable(state.address ?? ''),
                style: TextStyle(color: palette.textPrimary, height: 1.4),
              ),
            ),
            TextButton(
              onPressed: _busy ? null : _disconnect,
              child: Text(strings.neoRouterDisconnect),
            ),
          ],
        ),
      );
      for (final role in state.roles) {
        children.add(
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_roleLabel(strings, role)),
            subtitle: state.reachable
                ? Text(
                    role == 'embeddings'
                        ? '${_availability(strings, state.offers[role])}\n${strings.neoRouterEmbeddingsNote}'
                        : _availability(strings, state.offers[role]),
                    style: TextStyle(color: palette.textSecondary),
                  )
                : null,
            value: state.activeRoles.contains(role),
            onChanged: _busy ? null : (value) => _setRole(role, value),
          ),
        );
      }
    }
    if (_problem != null) {
      children.add(InlineMessage(message: _problem!, error: true));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var index = 0; index < children.length; index++) ...<Widget>[
          if (index > 0) const SizedBox(height: 10),
          children[index],
        ],
      ],
    );
  }
}

/// Asks for the NeoRouter address and starts its sign-in. Pops with the started
/// sign-in once NeoRouter has answered.
class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog({required this.client});

  final AdminNeoRouterClient client;

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  final TextEditingController _address = TextEditingController();
  bool _starting = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final address = _address.text.trim();
    if (address.isEmpty || _starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final signIn = await widget.client.begin(address);
      if (mounted) Navigator.of(context).pop(signIn);
    } catch (error) {
      if (mounted) setState(() => _error = adminErrorText(error));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    return AlertDialog(
      title: Text(strings.neoRouterConnect),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              strings.neoRouterConnectBody,
              style: TextStyle(color: palette.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _address,
              autofocus: true,
              autocorrect: false,
              enabled: !_starting,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: strings.neoRouterAddressLabel,
                hintText: 'https://router.example.com',
              ),
              onSubmitted: (_) => _start(),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: palette.danger)),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _starting ? null : () => Navigator.of(context).pop(),
          child: Text(strings.actionCancel),
        ),
        FilledButton(
          onPressed: _starting ? null : _start,
          child: _starting
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(strings.neoRouterContinue),
        ),
      ],
    );
  }
}
