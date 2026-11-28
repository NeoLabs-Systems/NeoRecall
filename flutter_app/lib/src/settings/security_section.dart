import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:neolabs_flutter/neolabs_flutter.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_theme.dart';
import '../auth/qr_scanner_page.dart';
import 'account_email_card.dart';
import 'account_export_save.dart';
import 'outcome_list.dart';
import 'qr_approval_card.dart';
import 'settings_section_list.dart';
import '../../l10n/gen/app_l10n.dart';

/// The security area of settings: two-factor, security keys, the account's
/// email and signed-in devices, a copy of its data, and account deletion.
///
/// Its own widget rather than ten more methods on the settings screen — it owns
/// a self-contained set of flows (enrol a key, enable 2FA, regenerate recovery
/// codes) that share nothing with the recording or memory sections beyond the
/// controller.
class SecuritySection extends StatefulWidget {
  const SecuritySection({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends State<SecuritySection> {
  late final NeoSessionsController sessions;

  @override
  void initState() {
    super.initState();
    final api = widget.controller.accountApi;
    sessions = NeoSessionsController(
      load: api.sessions,
      revoke: api.revokeSession,
      // The route ends this device's session too, so the app signs out.
      signOutEverywhere: () async {
        await api.signOutEverywhere();
        await widget.controller.logout();
        return const <NeoAccountSession>[];
      },
    );
  }

  @override
  void dispose() {
    sessions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => _securitySettings(),
  );

  Widget _securitySettings() {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    final ctrl = widget.controller;
    final tfStatus = ctrl.accountTwoFactor;
    final isEnabled = tfStatus['enabled'] == true;
    final recoveryCodesRemaining =
        tfStatus['recoveryCodesRemaining'] as int? ?? 0;

    return SettingsSectionList(
      controller: widget.controller,
      children: <Widget>[
        SettingsCard(
          eyebrow: strings.securitySectionEyebrow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                strings.securityTwoFactorTitle,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                strings.securityTwoFactorDescription,
                style: TextStyle(color: palette.textSecondary, height: 1.45),
              ),
              const SizedBox(height: 16),
              if (ctrl.isConfiguringTwoFactor)
                const Center(child: CircularProgressIndicator())
              else if (isEnabled) ...<Widget>[
                Row(
                  children: [
                    Icon(Icons.check_circle, color: palette.accent, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      strings.securityTwoFactorEnabled(recoveryCodesRemaining),
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: () => _disableTwoFactor(ctrl),
                      child: Text(strings.securityDisableTwoFactor),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => _regenerateRecoveryCodes(ctrl),
                      child: Text(strings.securityRegenerateCodes),
                    ),
                  ],
                ),
              ] else ...<Widget>[
                Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.amber,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      strings.securityTwoFactorDisabled,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => _setupTwoFactor(ctrl),
                  child: Text(strings.securityEnableTwoFactor),
                ),
              ],
            ],
          ),
        ),
        SettingsCard(
          eyebrow: strings.securityKeysEyebrow,
          child: _securityKeysCard(palette, ctrl),
        ),
        if (qrScannerSupported)
          SettingsCard(
            eyebrow: strings.qrApproveEyebrow,
            child: QrApprovalCard(controller: ctrl),
          ),
        SettingsCard(
          eyebrow: strings.securityEmailEyebrow,
          child: AccountEmailCard(controller: ctrl),
        ),
        _sessionsGroup(palette, ctrl),
        _accountDataGroup(palette, ctrl),
        // The only sign-out on a phone; on desktop it replaces the icon that
        // sat next to the Settings button in the rail.
        SettingsCard(
          eyebrow: strings.shellSignOut,
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  strings.settingsSignOutDescription,
                  style: TextStyle(color: palette.textSecondary, height: 1.45),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () async => ctrl.logout(),
                icon: const Icon(Icons.logout, size: 18),
                label: Text(strings.shellSignOut),
              ),
            ],
          ),
        ),
        _dangerZone(ctrl),
      ],
    );
  }

  Widget _securityKeysCard(NeoRecallPalette palette, NeoRecallController ctrl) {
    final keys = ctrl.securityKeys;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          AppL10n.of(context).securityKeysTitle,
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          AppL10n.of(context).securityKeysDescription,
          style: TextStyle(color: palette.textSecondary, height: 1.45),
        ),
        const SizedBox(height: 16),
        if (keys.isEmpty)
          Text(
            AppL10n.of(context).securityKeysNone,
            style: TextStyle(color: palette.textSecondary),
          )
        else
          ...keys.map((key) => _securityKeyRow(palette, ctrl, key)),
        const SizedBox(height: 16),
        // Keys registered elsewhere stay manageable here; only adding one needs
        // an authenticator this device can actually talk to.
        if (ctrl.supportsSecurityKeys)
          FilledButton.icon(
            onPressed: ctrl.loading ? null : () => _addSecurityKey(ctrl),
            icon: const Icon(Icons.key_rounded),
            label: Text(AppL10n.of(context).securityKeysAdd),
          )
        else
          Text(
            AppL10n.of(context).securityKeysUnsupported,
            style: TextStyle(color: palette.textSecondary, height: 1.45),
          ),
      ],
    );
  }

  Widget _securityKeyRow(
    NeoRecallPalette palette,
    NeoRecallController ctrl,
    Map<String, dynamic> key,
  ) {
    final lastUsedAt = key['lastUsedAt'] as String?;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          Icon(Icons.key_rounded, size: 20, color: palette.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  key['label'] as String? ??
                      AppL10n.of(context).securityKeyFallbackName,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  lastUsedAt == null
                      ? AppL10n.of(context).securityKeyNeverUsed
                      : AppL10n.of(
                          context,
                        ).securityKeyLastUsed(lastUsedAt.split('T').first),
                  style: TextStyle(color: palette.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            enabled: !ctrl.loading,
            icon: Icon(Icons.more_horiz_rounded, color: palette.textSecondary),
            onSelected: (action) => action == 'rename'
                ? _renameSecurityKey(ctrl, key)
                : ctrl.removeSecurityKey(key['id'] as int),
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'rename',
                child: Text(AppL10n.of(context).actionRename),
              ),
              PopupMenuItem<String>(
                value: 'remove',
                child: Text(AppL10n.of(context).actionRemove),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sessionsGroup(NeoRecallPalette palette, NeoRecallController ctrl) {
    final strings = AppL10n.of(context);
    return NeoSessionsGroup(
      palette: palette,
      controller: sessions,
      texts: NeoSessionsTexts(
        title: strings.securitySessionsEyebrow,
        description: strings.securitySessionsDescription,
        currentTag: strings.securitySessionsCurrent,
        revoke: strings.securitySessionsRevoke,
        signOutEverywhere: strings.securitySessionsSignOutEverywhere,
        empty: strings.securitySessionsEmpty,
      ),
      label: (s) => s.userAgent ?? strings.securitySessionsUnknownDevice,
      description: (s) => <String>[
        ?s.ipAddress,
        if (s.createdAt != null)
          strings.securitySessionsSince(
            MaterialLocalizations.of(
              context,
            ).formatMediumDate(s.createdAt!.toLocal()),
          ),
      ].join(' · '),
      describeError: ctrl.describeAccountError,
      confirmSignOutEverywhere: () async =>
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(strings.securitySessionsConfirmTitle),
              content: Text(strings.securitySessionsConfirmBody),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(strings.actionCancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(strings.securitySessionsSignOutEverywhere),
                ),
              ],
            ),
          ) ??
          false,
    );
  }

  /// The export and account deletion, each behind the account's password and,
  /// when it is on, a 2FA code.
  Widget _accountDataGroup(NeoRecallPalette palette, NeoRecallController ctrl) {
    final strings = AppL10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    return NeoAccountDataGroup(
      palette: palette,
      api: ctrl.accountApi,
      texts: NeoAccountDataTexts(
        title: strings.securityExportEyebrow,
        exportLabel: strings.securityExportTitle,
        exportDescription: strings.securityExportDescription,
        exportButton: strings.securityExportAction,
        exportTitle: strings.securityExportConfirmTitle,
        deleteLabel: strings.securityDeleteAccountTitle,
        deleteDescription: strings.securityDeleteCardDescription,
        deleteButton: strings.securityDeleteConfirm,
        deleteTitle: strings.securityDeleteAccountTitle,
        deleteMessage: strings.securityDeleteAccountIntro,
        passwordLabel: strings.destructiveYourPassword,
        codeLabel: strings.securityAuthenticatorCodeLabel,
        confirmLabel: strings.destructiveTypeToConfirm,
        cancel: strings.actionCancel,
      ),
      username: ctrl.username ?? strings.securityYourUsername,
      twoFactor: ctrl.accountTwoFactor['enabled'] == true,
      save: (file) async {
        final saved = await saveAccountExport(file.bytes, file.filename);
        if (saved != null) {
          messenger.showSnackBar(
            SnackBar(content: Text(strings.securityExportSaved(saved))),
          );
        }
      },
      // An admin deleting themselves could leave nobody able to run the
      // server, so the server refuses it; admin is revoked first.
      deleteBlocked: ctrl.isAdmin ? strings.securityDeleteAdminBlocked : null,
      deleteDetails: OutcomeList(
        erased: <String>[
          strings.securityDeleteItem1,
          strings.securityEraseItem3,
          strings.securityDeleteItem2,
          strings.securityDeleteItem3,
          strings.securityDeleteItem4,
        ],
      ),
      onDeleted: () async {
        await ctrl.forgetDeletedAccount();
        messenger.showSnackBar(
          SnackBar(content: Text(strings.securityDeletedNotice)),
        );
      },
      describeError: ctrl.describeAccountError,
    );
  }

  /// Empties the library but keeps the account: the last thing in the last
  /// section, behind the password, a 2FA code when it is on, and the
  /// username typed out.
  Future<void> _eraseContent(NeoRecallController ctrl) async {
    final strings = AppL10n.of(context);
    final username = ctrl.username ?? strings.securityYourUsername;
    final erased = await NeoConfirmIdentityDialog.show(
      context,
      NeoConfirmIdentityDialog(
        title: strings.securityEraseTitle,
        message: strings.securityEraseIntro,
        details: OutcomeList(
          erased: <String>[
            strings.securityEraseItem1,
            strings.securityEraseItem2,
            strings.securityEraseItem3,
            strings.securityEraseItem4,
          ],
          kept: <String>[strings.securityKeptItem1, strings.securityKeptItem2],
        ),
        cancelLabel: strings.actionCancel,
        submitLabel: strings.securityEraseConfirm,
        destructive: true,
        passwordLabel: strings.destructiveYourPassword,
        askCode: ctrl.accountTwoFactor['enabled'] == true,
        codeLabel: strings.securityAuthenticatorCodeLabel,
        confirmPhrase: username,
        confirmLabel: strings.destructiveTypeToConfirm(username),
        onSubmit: (identity) => ctrl.eraseContent(
          password: identity.password,
          twoFactorCode: identity.code.isEmpty ? null : identity.code,
        ),
      ),
    );
    if (!erased || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.securityErasedNotice)));
  }

  Widget _dangerZone(NeoRecallController ctrl) {
    final strings = AppL10n.of(context);
    return SettingsCard(
      eyebrow: strings.securityDangerZone,
      child: _DangerAction(
        title: strings.securityEraseTitle,
        description: strings.securityEraseCardDescription,
        actionLabel: strings.securityEraseCardAction,
        icon: Icons.delete_sweep_outlined,
        onPressed: ctrl.loading ? null : () => _eraseContent(ctrl),
      ),
    );
  }

  Future<void> _addSecurityKey(NeoRecallController ctrl) async {
    final strings = AppL10n.of(context);
    final label = await _promptDialog(
      strings.securityNameKeyTitle,
      strings.securityNameKeyMessage,
    );
    if (label == null) return;
    final name = label.trim().isEmpty
        ? strings.securityKeyDefaultName(ctrl.securityKeys.length + 1)
        : label.trim();
    await ctrl.registerSecurityKey(name);
    if (ctrl.error != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ctrl.error!)));
    }
  }

  Future<void> _renameSecurityKey(
    NeoRecallController ctrl,
    Map<String, dynamic> key,
  ) async {
    final label = await _promptDialog(
      AppL10n.of(context).securityRenameKeyTitle,
      AppL10n.of(context).securityRenameKeyMessage('${key['label']}'),
    );
    if (label == null || label.trim().isEmpty) return;
    await ctrl.renameSecurityKey(key['id'] as int, label.trim());
    if (ctrl.error != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ctrl.error!)));
    }
  }

  Future<void> _disableTwoFactor(NeoRecallController ctrl) async {
    final password = await _promptDialog(
      AppL10n.of(context).securityEnterPassword,
      AppL10n.of(context).securityPasswordForDisable,
      obscure: true,
    );
    if (password == null || password.isEmpty || !mounted) return;
    final code = await _promptDialog(
      AppL10n.of(context).securityEnterTwoFactorCode,
      AppL10n.of(context).securityEnterAuthenticatorCode,
    );
    if (code == null || code.isEmpty) return;
    await ctrl.disableTwoFactor(password: password, code: code);
    if (ctrl.error != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ctrl.error!)));
    }
  }

  Future<void> _regenerateRecoveryCodes(NeoRecallController ctrl) async {
    final password = await _promptDialog(
      AppL10n.of(context).securityEnterPassword,
      AppL10n.of(context).securityPasswordRequired,
      obscure: true,
    );
    if (password == null || password.isEmpty || !mounted) return;
    final code = await _promptDialog(
      AppL10n.of(context).securityEnterTwoFactorCode,
      AppL10n.of(context).securityEnterAuthenticatorCode,
    );
    if (code == null || code.isEmpty) return;
    final codes = await ctrl.regenerateTwoFactorCodes(
      password: password,
      code: code,
    );
    if (ctrl.error != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ctrl.error!)));
      return;
    }
    if (codes.isNotEmpty && mounted) {
      _showRecoveryCodesDialog(codes);
    }
  }

  Future<void> _setupTwoFactor(NeoRecallController ctrl) async {
    final setup = await ctrl.beginTwoFactorSetup();
    if (setup == null || !mounted) return;
    final code = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _TwoFactorSetupDialog(setup: setup),
    );
    if (code == null || code.isEmpty) return;
    final codes = await ctrl.enableTwoFactor(code.trim());
    if (ctrl.error != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ctrl.error!)));
      return;
    }
    if (codes.isNotEmpty && mounted) {
      _showRecoveryCodesDialog(codes);
    }
  }

  void _showRecoveryCodesDialog(List<String> codes) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppL10n.of(context).securityRecoveryCodesTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppL10n.of(context).securityRecoveryCodesBody),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: codes
                  .map(
                    (c) => Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey.withAlpha(25),
                      ),
                      child: Text(
                        c,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppL10n.of(context).actionDone),
          ),
        ],
      ),
    );
  }

  Future<String?> _promptDialog(
    String title,
    String message, {
    bool obscure = false,
  }) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: obscure,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppL10n.of(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(AppL10n.of(context).actionOk),
          ),
        ],
      ),
    );
  }
}

String groupedTotpSecret(String secret) {
  final compact = secret.replaceAll(RegExp(r'[\s-]+'), '').toUpperCase();
  if (compact.isEmpty) return '';
  final chunks = <String>[];
  for (var i = 0; i < compact.length; i += 4) {
    final end = i + 4 > compact.length ? compact.length : i + 4;
    chunks.add(compact.substring(i, end));
  }
  return chunks.join(' ');
}

class _TwoFactorSetupDialog extends StatefulWidget {
  const _TwoFactorSetupDialog({required this.setup});

  final Map<String, dynamic> setup;

  @override
  State<_TwoFactorSetupDialog> createState() => _TwoFactorSetupDialogState();
}

class _TwoFactorSetupDialogState extends State<_TwoFactorSetupDialog> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final setup = widget.setup;
    final qr = setup['qrDataUrl'] as String?;
    final secret = groupedTotpSecret(
      setup['manualKey'] as String? ?? setup['secret'] as String? ?? '',
    );
    return AlertDialog(
      title: Text(AppL10n.of(context).securityEnableTwoFactor),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(AppL10n.of(context).securityScanQr),
          const SizedBox(height: 16),
          if (qr != null)
            Image.memory(
              base64Decode(qr.split(',').last),
              width: 200,
              height: 200,
            ),
          const SizedBox(height: 8),
          SelectableText(
            secret,
            style: const TextStyle(
              fontFamily: 'IBM Plex Mono',
              fontSize: 13,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            decoration: InputDecoration(
              labelText: AppL10n.of(context).securityAuthenticatorCodeLabel,
            ),
            keyboardType: TextInputType.number,
            autofillHints: const <String>[AutofillHints.oneTimeCode],
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            autofocus: true,
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppL10n.of(context).actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _code.text),
          child: Text(AppL10n.of(context).actionVerify),
        ),
      ],
    );
  }
}

/// One irreversible action: what it does, and the button that starts it.
class _DangerAction extends StatelessWidget {
  const _DangerAction({
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.icon,
    required this.onPressed,
  });

  final String title;
  final String description;
  final String actionLabel;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          description,
          style: TextStyle(
            color: palette.textSecondary,
            fontSize: 12.5,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            style: OutlinedButton.styleFrom(
              foregroundColor: palette.danger,
              side: BorderSide(color: palette.danger.withValues(alpha: 0.55)),
            ),
            label: Text(actionLabel),
          ),
        ),
      ],
    );
  }
}
