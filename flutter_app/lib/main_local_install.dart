import 'dart:async';

import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_theme.dart';
import 'src/install/local_backend_installer.dart';

enum _LocalInstallPhase { choose, installing, done, failed }

/// Installs a NeoRecall server on this computer without a terminal, then points
/// the app at it. Mirrors what `install.sh` does on the command line.
class LocalInstallView extends StatefulWidget {
  const LocalInstallView({
    super.key,
    required this.controller,
    required this.onBack,
    required this.onInstalled,
  });

  final NeoRecallController controller;
  final VoidCallback onBack;
  final VoidCallback onInstalled;

  @override
  State<LocalInstallView> createState() => _LocalInstallViewState();
}

class _LocalInstallViewState extends State<LocalInstallView> {
  _LocalInstallPhase _phase = _LocalInstallPhase.choose;
  LocalBackendChannel _channel = LocalBackendChannel.stable;
  late final LocalBackendInstaller _installer;
  late final TextEditingController _directory;
  StreamSubscription<LocalBackendInstallEvent>? _subscription;
  final List<LocalBackendInstallEvent> _events = <LocalBackendInstallEvent>[];
  LocalBackendInstallEvent? _current;
  LocalBackendInstallResult? _result;
  List<LocalBackendRequirement> _missing = const <LocalBackendRequirement>[];
  String? _errorMessage;
  String? _errorRemedy;
  bool _showDetails = false;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _installer = LocalBackendInstaller();
    _directory = TextEditingController(
      text: _installer.defaultInstallDirectory,
    );
    _subscription = _installer.events.listen((event) {
      if (!mounted) return;
      setState(() {
        _current = event;
        _events.add(event);
      });
    });
    unawaited(_refreshRequirements());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _installer.dispose();
    _directory.dispose();
    super.dispose();
  }

  Future<void> _refreshRequirements() async {
    final missing = await _installer.missingRequirements();
    if (!mounted) return;
    setState(() => _missing = missing);
  }

  Future<void> _install() async {
    setState(() {
      _phase = _LocalInstallPhase.installing;
      _events.clear();
      _current = null;
      _errorMessage = null;
      _errorRemedy = null;
    });
    try {
      final result = await _installer.install(
        channel: _channel,
        installDirectory: _directory.text,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _phase = _LocalInstallPhase.done;
      });
    } on LocalBackendInstallerException catch (error) {
      if (!mounted) return;
      await _refreshRequirements();
      if (!mounted) return;
      setState(() {
        _errorMessage = '${error.message} (${error.code})';
        _errorRemedy = error.remedy;
        _phase = _LocalInstallPhase.failed;
      });
    }
  }

  Future<void> _connect() async {
    final result = _result;
    if (result == null) return;
    setState(() => _connecting = true);
    final saved = await widget.controller.setBackendUrl(result.backendUrl);
    if (!mounted) return;
    setState(() => _connecting = false);
    if (saved) widget.onInstalled();
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final compact = MediaQuery.sizeOf(context).width < 760;
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      body: AppBackdrop(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: AppPanel(
                  radius: 34,
                  padding: EdgeInsets.fromLTRB(
                    compact ? 24 : 34,
                    compact ? 24 : 28,
                    compact ? 24 : 34,
                    compact ? 24 : 30,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _phase == _LocalInstallPhase.installing
                              ? null
                              : widget.onBack,
                          icon: const Icon(Icons.arrow_back, size: 16),
                          label: const Text('Back'),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: BrandLockup(logoSize: 60),
                      ),
                      const SizedBox(height: 22),
                      Text('LOCAL SETUP', style: sectionEyebrowStyle(palette)),
                      const SizedBox(height: 8),
                      Text(
                        'Set up NeoRecall on this computer',
                        style: displayTitleStyle(palette, size: 28),
                      ),
                      const SizedBox(height: 18),
                      _buildContent(palette),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(NeoRecallPalette palette) {
    switch (_phase) {
      case _LocalInstallPhase.choose:
        return _buildChoose(palette);
      case _LocalInstallPhase.installing:
        return _buildInstalling(palette);
      case _LocalInstallPhase.done:
        return _buildDone(palette);
      case _LocalInstallPhase.failed:
        return _buildFailed(palette);
    }
  }

  Widget _buildChoose(NeoRecallPalette palette) {
    final blocked = _missing.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'NeoRecall will be downloaded from GitHub, installed as a background '
          'service, and connected to this app. Both channels can be switched '
          'later.',
          style: TextStyle(color: palette.textSecondary, height: 1.55),
        ),
        const SizedBox(height: 18),
        _ChannelCard(
          selected: _channel == LocalBackendChannel.stable,
          icon: Icons.verified_rounded,
          title: 'Stable',
          description: 'Released versions only. Recommended for daily use.',
          badge: 'Recommended',
          onTap: () => setState(() => _channel = LocalBackendChannel.stable),
        ),
        const SizedBox(height: 10),
        _ChannelCard(
          selected: _channel == LocalBackendChannel.beta,
          icon: Icons.science_rounded,
          title: 'Beta',
          description:
              'New features first, with the rough edges that come with them.',
          onTap: () => setState(() => _channel = LocalBackendChannel.beta),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _directory,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Install directory',
            prefixIcon: Icon(Icons.folder_outlined),
          ),
        ),
        if (blocked) ...<Widget>[
          const SizedBox(height: 16),
          InlineMessage(
            message:
                'Install ${_missing.map((item) => item.label).join(', ')} on '
                'this computer first, then check again.',
            error: true,
            action: TextButton(
              onPressed: _refreshRequirements,
              child: const Text('Check again'),
            ),
          ),
          const SizedBox(height: 8),
          for (final requirement in _missing)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${requirement.label} — ${requirement.downloadUrl}',
                style: TextStyle(color: palette.textMuted, fontSize: 12),
              ),
            ),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: blocked ? null : _install,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
          ),
          icon: const Icon(Icons.auto_awesome_rounded),
          label: Text('Install the ${_channel.cliName} channel'),
        ),
      ],
    );
  }

  Widget _buildInstalling(NeoRecallPalette palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(_current?.message ?? 'Preparing NeoRecall…'),
            ),
            TextButton(
              onPressed: () {
                _installer.cancel();
                setState(() => _phase = _LocalInstallPhase.choose);
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        LinearProgressIndicator(
          value: _current?.progress,
          minHeight: 7,
          borderRadius: BorderRadius.circular(999),
        ),
        const SizedBox(height: 6),
        Text(
          'The first install downloads about 165 MB of local models, so this '
          'can take a few minutes.',
          style: TextStyle(color: palette.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        _buildDetails(palette),
      ],
    );
  }

  Widget _buildDetails(NeoRecallPalette palette) {
    return ExpansionTile(
      initiallyExpanded: _showDetails,
      onExpansionChanged: (value) => setState(() => _showDetails = value),
      tilePadding: EdgeInsets.zero,
      title: const Text('Setup details'),
      children: <Widget>[
        for (final event in _events.reversed.take(40).toList().reversed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  event.isCompleted
                      ? Icons.check_circle_outline
                      : event.isFailure
                      ? Icons.error_outline
                      : event.isWarning
                      ? Icons.warning_amber_rounded
                      : Icons.circle_outlined,
                  size: 16,
                  color: event.isFailure
                      ? palette.danger
                      : event.isCompleted
                      ? palette.success
                      : event.isWarning
                      ? palette.warning
                      : palette.textMuted,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    event.errorCode == null
                        ? event.message
                        : '${event.message} (${event.errorCode})',
                    style: TextStyle(
                      color: palette.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDone(NeoRecallPalette palette) {
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.check_circle_outline, color: palette.success),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'NeoRecall is installed and running'
                '${result == null ? '' : ' (${result.serverVersion})'}.',
              ),
            ),
          ],
        ),
        if (result != null) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            '${result.backendUrl} · ${result.sourceDirectory}',
            style: TextStyle(color: palette.textMuted, fontSize: 12),
          ),
          if (!result.cliLinked) ...<Widget>[
            const SizedBox(height: 12),
            InlineMessage(
              message:
                  'The neorecall terminal command was not linked. NeoRecall '
                  'runs anyway; run "npm link" in ${result.sourceDirectory} if '
                  'you want the command.',
              icon: Icons.info_outline,
            ),
          ],
        ],
        if (widget.controller.error != null) ...<Widget>[
          const SizedBox(height: 12),
          InlineMessage(message: widget.controller.error!, error: true),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _connecting ? null : _connect,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
          ),
          icon: _connecting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.arrow_forward_rounded),
          label: const Text('Create your account'),
        ),
        const SizedBox(height: 8),
        _buildDetails(palette),
      ],
    );
  }

  Widget _buildFailed(NeoRecallPalette palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        InlineMessage(
          message: _errorMessage ?? 'NeoRecall setup could not finish.',
          error: true,
        ),
        if (_errorRemedy != null) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            _errorRemedy!,
            style: TextStyle(color: palette.textSecondary, fontSize: 12),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _install,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: () =>
                  setState(() => _phase = _LocalInstallPhase.choose),
              child: const Text('Change options'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildDetails(palette),
      ],
    );
  }
}

class _ChannelCard extends StatelessWidget {
  const _ChannelCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.badge,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '$title. $description',
      child: Material(
        color: selected
            ? palette.accent.withValues(alpha: 0.08)
            : palette.bgSecondary.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? palette.accent : palette.borderLight,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  icon,
                  color: selected ? palette.accent : palette.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (badge != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: palette.accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                badge!,
                                style: TextStyle(
                                  color: palette.accent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        description,
                        style: TextStyle(
                          color: palette.textSecondary,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: selected ? palette.accent : palette.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
