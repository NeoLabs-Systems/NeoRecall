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

  bool get _canConfigureServer =>
      widget.controller.allowsBackendUrlConfiguration;

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
      final ok = await widget.controller.completeTwoFactor(
        _twoFactor.text.trim(),
      );
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
    final compact = MediaQuery.sizeOf(context).width < 760;

    final card = GlassSurface(
      radius: serverSetup && _canConfigureServer ? 34 : 32,
      padding: serverSetup && _canConfigureServer
          ? EdgeInsets.fromLTRB(
              compact ? 24 : 34,
              compact ? 24 : 32,
              compact ? 24 : 34,
              compact ? 24 : 30,
            )
          : EdgeInsets.fromLTRB(
              compact ? 18 : 34,
              compact ? 20 : 30,
              compact ? 18 : 34,
              compact ? 20 : 30,
            ),
      child: serverSetup && _canConfigureServer
          ? _serverCard(palette)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Center(child: BrandLockup(logoSize: 56)),
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
                      : 'Sign in',
                  style: displayTitleStyle(palette, size: 30),
                ),
                const SizedBox(height: 8),
                Text(
                  awaitingTwoFactor
                      ? 'Open your authenticator app and enter the current NeoRecall code.'
                      : registerMode
                      ? 'Your first account becomes the NeoRecall administrator for this server.'
                      : 'Enter your NeoRecall account details.',
                  style: TextStyle(color: palette.textSecondary, height: 1.5),
                ),
                const SizedBox(height: 20),
                if (controller.error != null) ...<Widget>[
                  InlineMessage(message: controller.error!, error: true),
                  const SizedBox(height: 16),
                ],
                if (controller.initializationError != null) ...<Widget>[
                  OutlinedButton.icon(
                    onPressed: controller.initializing
                        ? null
                        : controller.initialize,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry local startup'),
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: awaitingTwoFactor ? _twoFactor : _username,
                  decoration: InputDecoration(
                    labelText: awaitingTwoFactor
                        ? '2FA or recovery code'
                        : 'Username',
                  ),
                ),
                if (registerMode && !awaitingTwoFactor) ...<Widget>[
                  const SizedBox(height: 14),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email (optional)',
                    ),
                  ),
                ],
                if (!awaitingTwoFactor) ...<Widget>[
                  const SizedBox(height: 14),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                  ),
                  if (registerMode) ...<Widget>[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _confirm,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Confirm password',
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
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  runSpacing: 4,
                  children: <Widget>[
                    TextButton(
                      onPressed: () => setState(() {
                        registerMode = !registerMode;
                        awaitingTwoFactor = false;
                      }),
                      child: Text(
                        registerMode
                            ? 'Already have an account? Sign in'
                            : 'Need a new account? Register',
                      ),
                    ),
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

    return Material(
      type: MaterialType.transparency,
      child: AmbientBackdrop(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - 48).clamp(
                    0,
                    double.infinity,
                  ),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: serverSetup && _canConfigureServer ? 680 : 468,
                    ),
                    child: card,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _serverCard(NeoRecallPalette palette) {
    final controller = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Align(
          alignment: Alignment.centerLeft,
          child: BrandLockup(logoSize: 60),
        ),
        const SizedBox(height: 22),
        Text('WELCOME TO NEORECALL', style: sectionEyebrowStyle(palette)),
        const SizedBox(height: 8),
        Text('Connect NeoRecall', style: displayTitleStyle(palette, size: 34)),
        const SizedBox(height: 8),
        Text(
          'Enter the address of the NeoRecall server this device should use.',
          style: TextStyle(color: palette.textSecondary, height: 1.5),
        ),
        if (controller.error != null) ...<Widget>[
          const SizedBox(height: 18),
          InlineMessage(message: controller.error!, error: true),
        ],
        const SizedBox(height: 20),
        TextField(
          controller: _server,
          enabled: !controller.loading && !controller.initializing,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          onSubmitted: (_) => _saveServer(),
          decoration: const InputDecoration(
            labelText: 'NeoRecall server address',
            prefixIcon: Icon(Icons.dns_outlined),
            hintText: 'http://192.168.1.20:4500',
          ),
        ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: controller.loading || controller.initializing
              ? null
              : _saveServer,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(58)),
          child: controller.loading || controller.initializing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Connect to this server'),
        ),
        if (controller.initializationError != null) ...<Widget>[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: controller.initializing ? null : controller.initialize,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry local startup'),
          ),
        ],
        if (!controller.requiresBackendUrlSetup) ...<Widget>[
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() => serverSetup = false),
            child: const Text('Back to sign in'),
          ),
        ],
      ],
    );
  }

  Future<void> _saveServer() async {
    final saved = await widget.controller.setBackendUrl(_server.text);
    if (!saved || !mounted) return;
    if (widget.controller.initializationError != null) {
      await widget.controller.initialize();
    }
    if (mounted && widget.controller.initializationError == null) {
      setState(() => serverSetup = false);
    }
  }
}
