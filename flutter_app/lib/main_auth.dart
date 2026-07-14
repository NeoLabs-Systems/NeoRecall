import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
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
  @override
  void initState() {
    super.initState();
    _server.text = widget.controller.backendUrl;
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
    } else {
      final ok = await widget.controller.login(
        _username.text.trim(),
        _password.text,
      );
      if (!ok &&
          widget.controller.error?.toLowerCase().contains('two-factor') ==
              true &&
          mounted) {
        setState(() => awaitingTwoFactor = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final controller = widget.controller;
    final card = GlassSurface(
      padding: const EdgeInsets.all(30),
      child: serverSetup
          ? _serverCard(palette)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const BrandLockup(logoSize: 58),
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
                  style: displayTitleStyle(palette, size: 28),
                ),
                const SizedBox(height: 8),
                Text(
                  awaitingTwoFactor
                      ? 'Open your authenticator app and enter the current NeoRecall code.'
                      : registerMode
                      ? 'Your first account becomes the NeoRecall administrator for this server.'
                      : 'Sign in to your private NeoRecall workspace.',
                  style: TextStyle(color: palette.textSoft, height: 1.5),
                ),
                const SizedBox(height: 20),
                if (controller.error != null) ...<Widget>[
                  InlineMessage(message: controller.error!, error: true),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: awaitingTwoFactor ? _twoFactor : _username,
                  decoration: InputDecoration(
                    labelText: awaitingTwoFactor
                        ? '2FA or recovery code'
                        : 'Username',
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
                        labelText: 'Confirm Password',
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
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    TextButton(
                      onPressed: () =>
                          setState(() => registerMode = !registerMode),
                      child: Text(
                        registerMode
                            ? 'Already have an account?'
                            : 'Create account',
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() => serverSetup = true),
                      child: const Text('Server settings'),
                    ),
                  ],
                ),
              ],
            ),
    );
    return AmbientBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(
                      constraints.maxWidth < AppBreakpoints.mobile ? 14 : 24,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 468),
                      child: card,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _serverCard(NeoRecallPalette palette) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      const BrandLockup(logoSize: 58),
      const SizedBox(height: 24),
      Text('FIRST-RUN SETUP', style: sectionEyebrowStyle(palette)),
      const SizedBox(height: 8),
      Text(
        'Connect this build to your NeoRecall backend',
        style: displayTitleStyle(palette, size: 26),
      ),
      const SizedBox(height: 12),
      Text(
        'Enter your self-hosted server URL once. NeoRecall stores it locally on this device.',
        style: TextStyle(color: palette.textSoft, height: 1.5),
      ),
      const SizedBox(height: 22),
      TextField(
        controller: _server,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          labelText: 'Backend URL',
          hintText: 'Enter your NeoRecall server URL',
          prefixIcon: Icon(Icons.cloud_outlined),
        ),
      ),
      const SizedBox(height: 18),
      FilledButton(
        onPressed: () async {
          try {
            await widget.controller.setBackendUrl(_server.text);
            if (mounted) setState(() => serverSetup = false);
          } catch (error) {
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(error.toString())));
            }
          }
        },
        child: const Text('Connect backend'),
      ),
      TextButton(
        onPressed: () => setState(() => serverSetup = false),
        child: const Text('Back'),
      ),
    ],
  );
}
