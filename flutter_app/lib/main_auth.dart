import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:neolabs_flutter/neolabs_flutter.dart'
    show
        NeoAuthBackdrop,
        NeoCredentialField,
        NeoCredentialFields,
        NeoForgotPasswordDialog;

import 'main_controller.dart';
import 'main_local_install.dart';
import 'main_shared.dart';
import 'main_theme.dart';
import 'src/auth/qr_sign_in_panel.dart';
import 'src/install/local_backend_installer.dart';
import 'l10n/gen/app_l10n.dart';

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
  final _usernameFocus = FocusNode();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();
  bool _obscurePassword = true;
  bool registerMode = false;
  bool serverSetup = false;
  bool localInstall = false;

  bool get _canConfigureServer =>
      widget.controller.allowsBackendUrlConfiguration;

  /// Only desktop hosts can run a NeoRecall server; the web client is already
  /// served by one, and phones cannot host it. `defaultTargetPlatform` decides
  /// this rather than `Platform`, so a desktop test host still renders the
  /// mobile screen when it drives a mobile target.
  bool get _canInstallLocally =>
      _canConfigureServer &&
      !kIsWeb &&
      supportsLocalBackendInstall &&
      const <TargetPlatform>{
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      }.contains(defaultTargetPlatform);

  @override
  void initState() {
    super.initState();
    _server.text = widget.controller.backendUrl;
    serverSetup = widget.controller.requiresBackendUrlSetup;
    if (!serverSetup) unawaited(widget.controller.loadAuthOptions());
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
    for (final node in <FocusNode>[
      _usernameFocus,
      _emailFocus,
      _passwordFocus,
      _confirmFocus,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _showForgotPassword() async {
    final strings = AppL10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final palette = neoRecallPaletteOf(context);
    await showDialog<void>(
      context: context,
      builder: (context) => NeoForgotPasswordDialog(
        initialAccount: _username.text.trim(),
        title: strings.authResetTitle,
        description: strings.authResetDescription,
        accountLabel: strings.authResetAccountLabel,
        emptyError: strings.authResetAccountMissing,
        cancelLabel: strings.actionCancel,
        submitLabel: strings.authResetSubmit,
        onSubmit: (account) async {
          final sent = await widget.controller.requestPasswordReset(account);
          // A failure closes nothing; say why above the open dialog's barrier.
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                sent ? strings.authResetSent : widget.controller.error ?? '',
              ),
            ),
          );
          return sent;
        },
        errorBuilder: (message) => InlineMessage(message: message, error: true),
        backgroundColor: palette.bgCard,
        textColor: palette.textSecondary,
      ),
    );
  }

  Future<void> _signInWithSecurityKey() async {
    final account = _username.text.trim();
    final ok = await widget.controller.signInWithSecurityKey(
      account: account.isEmpty ? null : account,
    );
    if (!ok && mounted) setState(() {});
  }

  Future<void> _submit() async {
    if (widget.controller.needsTwoFactor) {
      final ok = await widget.controller.completeTwoFactor(
        _twoFactor.text.trim(),
      );
      if (ok && mounted) setState(() {});
      return;
    }
    if (registerMode) {
      if (_password.text != _confirm.text) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).authPasswordsDoNotMatch)),
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
    if (!ok && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    if (localInstall) {
      return LocalInstallView(
        controller: widget.controller,
        onBack: () => setState(() => localInstall = false),
        onInstalled: () => setState(() {
          localInstall = false;
          serverSetup = false;
          registerMode = true;
          widget.controller.openProvidersAfterSignIn();
          unawaited(widget.controller.loadAuthOptions());
        }),
      );
    }
    final awaitingTwoFactor = widget.controller.needsTwoFactor;
    final palette = neoRecallPaletteOf(context);
    final controller = widget.controller;
    final compact = MediaQuery.sizeOf(context).width < 760;

    final card = AppPanel(
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
                // No eyebrow: it only ever restated the title underneath it.
                Text(
                  awaitingTwoFactor
                      ? strings.authTwoFactorTitle
                      : registerMode
                      ? strings.authRegisterTitle
                      : strings.authSignInTitle,
                  style: displayTitleStyle(palette, size: 30),
                ),
                const SizedBox(height: 8),
                Text(
                  awaitingTwoFactor
                      ? strings.authTwoFactorSubtitle
                      : registerMode
                      ? strings.authRegisterSubtitle
                      : strings.authSignInSubtitle,
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
                    label: Text(strings.authRetryLocalStartup),
                  ),
                  const SizedBox(height: 16),
                ],
                AutofillGroup(
                  child: awaitingTwoFactor
                      ? TextField(
                          controller: _twoFactor,
                          keyboardType: TextInputType.visiblePassword,
                          autofillHints: const <String>[
                            AutofillHints.oneTimeCode,
                          ],
                          decoration: InputDecoration(
                            labelText: strings.authTwoFactorFieldLabel,
                          ),
                        )
                      : NeoCredentialFields(
                          register: registerMode,
                          username: _username,
                          email: _email,
                          password: _password,
                          confirmPassword: _confirm,
                          usernameFocus: _usernameFocus,
                          emailFocus: _emailFocus,
                          passwordFocus: _passwordFocus,
                          confirmPasswordFocus: _confirmFocus,
                          obscurePassword: _obscurePassword,
                          onChanged: (_) {},
                          onSubmit: () => _submit(),
                          decoration: (field, suffix) => InputDecoration(
                            labelText: switch (field) {
                              NeoCredentialField.username =>
                                strings.authUsernameLabel,
                              NeoCredentialField.email =>
                                strings.authEmailLabel,
                              NeoCredentialField.password =>
                                strings.authPasswordLabel,
                              NeoCredentialField.confirmPassword =>
                                strings.authConfirmPasswordLabel,
                            },
                            suffixIcon: suffix,
                          ),
                          labeledField: (label, child, trailing) =>
                              trailing == null
                              ? child
                              : Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: <Widget>[child, trailing],
                                ),
                          usernameLabel: strings.authUsernameLabel,
                          usernameOrEmailLabel: strings.authUsernameLabel,
                          emailLabel: strings.authEmailLabel,
                          passwordLabel: strings.authPasswordLabel,
                          confirmPasswordLabel:
                              strings.authConfirmPasswordLabel,
                          forgotPassword: controller.passwordResetAvailable
                              ? Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: controller.loading
                                        ? null
                                        : _showForgotPassword,
                                    child: Text(strings.authForgotPassword),
                                  ),
                                )
                              : null,
                          passwordToggle: IconButton(
                            onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                ),
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
                              ? strings.authVerify
                              : registerMode
                              ? strings.authCreateAccount
                              : strings.authSignInTitle,
                        ),
                ),
                if (!registerMode &&
                    !awaitingTwoFactor &&
                    controller.supportsSecurityKeys) ...<Widget>[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: controller.loading
                        ? null
                        : _signInWithSecurityKey,
                    icon: const Icon(Icons.key_rounded),
                    label: Text(strings.authSecurityKeySignIn),
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  runSpacing: 4,
                  children: <Widget>[
                    if (awaitingTwoFactor ||
                        registerMode ||
                        controller.registrationOpen)
                      TextButton(
                        onPressed: awaitingTwoFactor
                            ? widget.controller.cancelTwoFactor
                            : () => setState(() {
                                registerMode = !registerMode;
                              }),
                        child: Text(
                          awaitingTwoFactor
                              ? strings.authSwitchToSignIn
                              : registerMode
                              ? strings.authSwitchToSignIn
                              : strings.authSwitchToRegister,
                        ),
                      ),
                    if (_canConfigureServer)
                      TextButton(
                        onPressed: () => setState(() => serverSetup = true),
                        child: Text(strings.authServerButton),
                      ),
                  ],
                ),
                if (!registerMode &&
                    !awaitingTwoFactor &&
                    qrSignInSupported) ...<Widget>[
                  const SizedBox(height: 12),
                  QrSignInPanel(controller: controller),
                ],
              ],
            ),
    );

    return Scaffold(
      // Opaque, for the same reason the local-setup screen is: a transparent
      // scaffold shows the native window's own background.
      backgroundColor: palette.bgPrimary,
      resizeToAvoidBottomInset: true,
      body: NeoAuthBackdrop(
        palette: palette,
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
    final strings = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Align(
          alignment: Alignment.centerLeft,
          child: BrandLockup(logoSize: 60),
        ),
        const SizedBox(height: 22),
        Text(strings.authWelcomeEyebrow, style: sectionEyebrowStyle(palette)),
        const SizedBox(height: 8),
        Text(
          _canInstallLocally ? strings.authSetUpOrConnect : strings.authConnect,
          style: displayTitleStyle(palette, size: 34),
        ),
        const SizedBox(height: 8),
        Text(
          _canInstallLocally
              ? strings.authSetUpOrConnectBody
              : strings.authConnectBody,
          style: TextStyle(color: palette.textSecondary, height: 1.5),
        ),
        if (_canInstallLocally) ...<Widget>[
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => setState(() => localInstall = true),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(58),
            ),
            icon: const Icon(Icons.auto_awesome_rounded),
            label: Text(strings.authInstallLocally),
          ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              Expanded(child: Divider(color: palette.borderLight)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  strings.authOrConnectRunning,
                  style: TextStyle(color: palette.textMuted, fontSize: 12),
                ),
              ),
              Expanded(child: Divider(color: palette.borderLight)),
            ],
          ),
        ],
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
          decoration: InputDecoration(
            labelText: strings.authServerAddressLabel,
            prefixIcon: const Icon(Icons.dns_outlined),
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
              : Text(strings.authConnectToServer),
        ),
        if (controller.initializationError != null) ...<Widget>[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: controller.initializing ? null : controller.initialize,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(strings.authRetryLocalStartup),
          ),
        ],
        if (!controller.requiresBackendUrlSetup) ...<Widget>[
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              setState(() => serverSetup = false);
              unawaited(widget.controller.loadAuthOptions());
            },
            child: Text(strings.authBackToSignIn),
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
      unawaited(widget.controller.loadAuthOptions());
    }
  }
}
