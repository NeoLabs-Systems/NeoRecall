import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_theme.dart';

class NeoRecallAuthScreen extends StatefulWidget {
  const NeoRecallAuthScreen({super.key, required this.controller});
  final NeoRecallController controller;
  @override
  State<NeoRecallAuthScreen> createState() => _NeoRecallAuthScreenState();
}

class _NeoRecallAuthScreenState extends State<NeoRecallAuthScreen> {
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _server = TextEditingController();
  final _twoFactor = TextEditingController();
  bool registerMode = false;
  bool serverSetup = false;
  bool awaitingTwoFactor = false;

  bool get _canConfigureServer => widget.controller.allowsBackendUrlConfiguration;

  @override
  void initState() {
    super.initState();
    _server.text = widget.controller.backendUrl;
    serverSetup = widget.controller.requiresBackendUrlSetup;
  }

  @override
  void dispose() {
    for (final value in <TextEditingController>[
      _username,
      _email,
      _password,
      _confirm,
      _server,
      _twoFactor,
    ]) {
      value.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (awaitingTwoFactor) {
      final ok = await widget.controller.completeTwoFactor(_twoFactor.text.trim());
      if (ok && mounted) setState(() => awaitingTwoFactor = false);
      return;
    }
    if (registerMode) {
      if (_password.text != _confirm.text) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Passwords do not match.')),
        );
        return;
      }
      await widget.controller.register(
        _username.text.trim(),
        _email.text.trim(),
        _password.text,
      );
      return;
    }
    final ok = await widget.controller.login(
      _username.text.trim(),
      _password.text,
    );
    if (!ok &&
        widget.controller.error?.toLowerCase().contains('two-factor') == true &&
        mounted) {
      setState(() => awaitingTwoFactor = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final controller = widget.controller;
    final wide = MediaQuery.sizeOf(context).width >= 980;

    final card = GlassSurface(
      padding: const EdgeInsets.all(30),
      child: serverSetup && _canConfigureServer
          ? _serverCard(palette)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const BrandLockup(logoSize: 56),
                const SizedBox(height: 26),
                Text(
                  awaitingTwoFactor
                      ? 'VERIFICATION'
                      : (registerMode ? 'CREATE ACCOUNT' : 'SIGN IN'),
                  style: sectionEyebrowStyle(palette),
                ),
                const SizedBox(height: 8),
                Text(
                  awaitingTwoFactor
                      ? 'Enter 2FA code'
                      : registerMode
                          ? 'Create your NeoRecall account'
                          : 'Welcome back',
                  style: displayTitleStyle(palette, size: 30),
                ),
                const SizedBox(height: 8),
                Text(
                  awaitingTwoFactor
                      ? 'Open your authenticator app and enter the current NeoRecall code.'
                      : registerMode
                          ? 'Your first account becomes the NeoRecall administrator for this server.'
                          : 'Sign in to your private NeoRecall control surface.',
                  style: TextStyle(color: palette.textSecondary, height: 1.5),
                ),
                const SizedBox(height: 20),
                if (controller.error != null) ...<Widget>[
                  InlineMessage(message: controller.error!, error: true),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: awaitingTwoFactor ? _twoFactor : _username,
                  decoration: InputDecoration(
                    labelText: awaitingTwoFactor ? '2FA or recovery code' : 'Username',
                    prefixIcon: Icon(
                      awaitingTwoFactor
                          ? Icons.verified_user_outlined
                          : Icons.person_outline,
                    ),
                  ),
                ),
                if (registerMode && !awaitingTwoFactor) ...<Widget>[
                  const SizedBox(height: 14),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email (optional)',
                      prefixIcon: Icon(Icons.alternate_email),
                    ),
                  ),
                ],
                if (!awaitingTwoFactor) ...<Widget>[
                  const SizedBox(height: 14),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  if (registerMode) ...<Widget>[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _confirm,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Confirm password',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: controller.loading ? null : _submit,
                  child: controller.loading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          awaitingTwoFactor
                              ? 'Verify'
                              : registerMode
                                  ? 'Create account'
                                  : 'Sign in',
                        ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    TextButton(
                      onPressed: () => setState(() {
                        registerMode = !registerMode;
                        awaitingTwoFactor = false;
                      }),
                      child: Text(
                        registerMode
                            ? 'Already have an account?'
                            : 'Create account',
                      ),
                    ),
                    const Spacer(),
                    if (_canConfigureServer)
                      TextButton(
                        onPressed: () => setState(() => serverSetup = true),
                        child: const Text('Server'),
                      ),
                  ],
                ),
              ],
            ),
    );

    return AmbientBackdrop(
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 1080 : 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: wide
                ? Row(
                    children: <Widget>[
                      Expanded(child: _heroPanel(palette)),
                      const SizedBox(width: 28),
                      SizedBox(width: 440, child: card),
                    ],
                  )
                : card,
          ),
        ),
      ),
    );
  }

  Widget _heroPanel(NeoRecallPalette palette) {
    return GlassSurface(
      padding: const EdgeInsets.all(34),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('CONTROL SURFACE', style: sectionEyebrowStyle(palette)),
          const SizedBox(height: 14),
          Text(
            'Private audio memory that stays under your control.',
            style: displayTitleStyle(palette, size: 40),
          ),
          const SizedBox(height: 16),
          Text(
            'Record anywhere, transcribe locally, and recall the day without keeping server-side audio after processing.',
            style: TextStyle(color: palette.textSecondary, height: 1.55, fontSize: 16),
          ),
          const SizedBox(height: 28),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: const <Widget>[
              MetaPill(icon: Icons.mic_none_rounded, label: 'Local capture', active: true),
              MetaPill(icon: Icons.lock_outline, label: 'Receipt-gated release'),
              MetaPill(icon: Icons.auto_awesome_outlined, label: 'Hybrid recall'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _serverCard(NeoRecallPalette palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const BrandLockup(logoSize: 48),
        const SizedBox(height: 22),
        Text('SERVER', style: sectionEyebrowStyle(palette)),
        const SizedBox(height: 8),
        Text('Connect this client', style: displayTitleStyle(palette, size: 28)),
        const SizedBox(height: 8),
        Text(
          'Desktop and mobile builds can point at any NeoRecall server. Web builds always use the host that serves /app.',
          style: TextStyle(color: palette.textSecondary, height: 1.5),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _server,
          decoration: const InputDecoration(
            labelText: 'NeoRecall server URL',
            prefixIcon: Icon(Icons.dns_outlined),
            hintText: 'http://192.168.1.20:4500',
          ),
        ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: widget.controller.loading
              ? null
              : () async {
                  await widget.controller.setBackendUrl(_server.text);
                  if (mounted) setState(() => serverSetup = false);
                },
          child: const Text('Save server'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => setState(() => serverSetup = false),
          child: const Text('Back to sign in'),
        ),
      ],
    );
  }
}
