import 'package:flutter/material.dart';
import 'package:neolabs_flutter/neolabs_flutter.dart'
    show NeoConfirmIdentityDialog;

import '../../l10n/gen/app_l10n.dart';
import '../../main_controller.dart';
import '../../main_theme.dart';

/// The account's email address: which one it is, whether it is confirmed, and
/// changing it. With service email on, a new address takes effect when the
/// link mailed to it is opened.
class AccountEmailCard extends StatefulWidget {
  const AccountEmailCard({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<AccountEmailCard> createState() => _AccountEmailCardState();
}

class _AccountEmailCardState extends State<AccountEmailCard> {
  Map<String, dynamic> state = const <String, dynamic>{};
  bool busy = false;
  String? error;

  NeoRecallController get ctrl => widget.controller;

  @override
  void initState() {
    super.initState();
    _run(() => ctrl.api.request('GET', '/api/v1/auth/email'));
  }

  Future<void> _run(Future<dynamic> Function() work) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final out = await work();
      if (out is Map) state = Map<String, dynamic>.from(out);
    } catch (e) {
      error = ctrl.describeAccountError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _notify(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _change() async {
    final strings = AppL10n.of(context);
    final email = await _askAddress(strings);
    if (email == null || email.isEmpty || !mounted) return;
    final changed = await NeoConfirmIdentityDialog.show(
      context,
      NeoConfirmIdentityDialog(
        title: strings.securityEmailChange,
        message: strings.securityEmailConfirmMessage(email),
        cancelLabel: strings.actionCancel,
        submitLabel: strings.securityEmailChange,
        passwordLabel: strings.destructiveYourPassword,
        askCode: ctrl.accountTwoFactor['enabled'] == true,
        codeLabel: strings.securityAuthenticatorCodeLabel,
        onSubmit: (identity) async {
          try {
            state = await ctrl.accountApi.changeEmail(email, identity);
            return null;
          } catch (e) {
            return ctrl.describeAccountError(e);
          }
        },
      ),
    );
    if (!changed || !mounted) return;
    setState(() {});
    final pending = state['pendingEmail'] as String?;
    _notify(
      pending != null
          ? strings.securityEmailSent(pending)
          : strings.securityEmailChanged('${state['email'] ?? email}'),
    );
  }

  Future<String?> _askAddress(AppL10n strings) {
    final field = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.securityEmailNewTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (state['canConfirm'] == true)
              Text(strings.securityEmailNewMessage),
            TextField(
              controller: field,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const <String>[AutofillHints.email],
              onSubmitted: (v) => Navigator.pop(context, v.trim()),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(strings.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text.trim()),
            child: Text(strings.actionOk),
          ),
        ],
      ),
    );
  }

  Future<void> _resend() async {
    final strings = AppL10n.of(context);
    await _run(() => ctrl.api.request('POST', '/api/v1/auth/email/resend'));
    if (error == null && mounted) {
      _notify(
        strings.securityEmailSent(
          '${state['pendingEmail'] ?? state['email'] ?? ''}',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    final email = state['email'] as String?;
    final pending = state['pendingEmail'] as String?;
    final unconfirmed = email != null && state['emailVerified'] == false;
    final canResend =
        state['canConfirm'] == true && (pending != null || unconfirmed);
    final status = pending != null
        ? strings.securityEmailPending(pending)
        : unconfirmed
        ? strings.securityEmailUnconfirmed
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          email ?? strings.securityEmailNone,
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (status != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(status, style: TextStyle(color: palette.textSecondary)),
        ],
        if (error != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(error!, style: TextStyle(color: palette.danger)),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            OutlinedButton(
              onPressed: busy ? null : _change,
              child: Text(strings.securityEmailChange),
            ),
            if (canResend)
              TextButton(
                onPressed: busy ? null : _resend,
                child: Text(strings.securityEmailResend),
              ),
          ],
        ),
      ],
    );
  }
}
