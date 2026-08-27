import 'dart:convert';

import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_theme.dart';
import 'delete_account_dialog.dart';
import 'settings_section_list.dart';

/// The security area of settings: password, two-factor, security keys, and
/// account deletion.
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
  @override
  Widget build(BuildContext context) => _securitySettings();

  Widget _securitySettings() {
    final palette = neoRecallPaletteOf(context);
    final ctrl = widget.controller;
    final tfStatus = ctrl.accountTwoFactor;
    final isEnabled = tfStatus['enabled'] == true;
    final recoveryCodesRemaining =
        tfStatus['recoveryCodesRemaining'] as int? ?? 0;

    return SettingsSectionList(
      controller: widget.controller,
      children: <Widget>[
        SectionCard(
          eyebrow: 'SECURITY',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Two-factor authentication',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Protect your account with an authenticator app.',
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
                      '2FA is enabled ($recoveryCodesRemaining recovery codes remaining)',
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
                      child: const Text('Disable 2FA'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => _regenerateRecoveryCodes(ctrl),
                      child: const Text('Regenerate codes'),
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
                      '2FA is not enabled',
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
                  child: const Text('Enable 2FA'),
                ),
              ],
            ],
          ),
        ),
        SectionCard(
          eyebrow: 'SECURITY KEYS',
          child: _securityKeysCard(palette, ctrl),
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
          'Security keys',
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Sign in with a hardware key or passkey instead of your password. A key that asks for a PIN or a fingerprint also replaces your two-factor code.',
          style: TextStyle(color: palette.textSecondary, height: 1.45),
        ),
        const SizedBox(height: 16),
        if (keys.isEmpty)
          Text(
            'No security keys registered.',
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
            label: const Text('Add security key'),
          )
        else
          Text(
            'This device cannot register security keys. Open NeoRecall in a browser over HTTPS to add one.',
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
                  key['label'] as String? ?? 'Security key',
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  lastUsedAt == null
                      ? 'Never used'
                      : 'Last used ${lastUsedAt.split('T').first}',
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
                : ctrl.removeSecurityKey(key['id'] as String),
            itemBuilder: (context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'rename', child: Text('Rename')),
              PopupMenuItem<String>(value: 'remove', child: Text('Remove')),
            ],
          ),
        ],
      ),
    );
  }

  /// The only irreversible action in the app, so it is deliberately the last
  /// thing in the last section rather than a menu item next to "Rename".
  Future<void> _deleteAccount(NeoRecallController ctrl) async {
    final deleted = await DeleteAccountDialog.show(
      context,
      username: ctrl.username ?? 'your username',
      twoFactorEnabled: ctrl.accountTwoFactor['enabled'] == true,
      onConfirm: ctrl.deleteAccount,
    );
    if (!deleted || !mounted) return;
    // logout() has already cleared the session, so the app is back at sign-in.
    // Confirm what happened rather than dropping the user somewhere silently.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Your account and all its data were deleted.'),
      ),
    );
  }

  Widget _dangerZone(NeoRecallController ctrl) {
    final palette = neoRecallPaletteOf(context);
    return SectionCard(
      eyebrow: 'DANGER ZONE',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Delete account',
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Permanently erases your transcripts, memories, named speakers and '
            'voice profiles from the server, along with anything still queued '
            'on this device. This cannot be undone.',
            style: TextStyle(color: palette.textSecondary, height: 1.45),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: ctrl.loading ? null : () => _deleteAccount(ctrl),
              icon: const Icon(Icons.delete_forever_outlined, size: 18),
              style: OutlinedButton.styleFrom(
                foregroundColor: palette.danger,
                side: BorderSide(color: palette.danger.withValues(alpha: 0.55)),
              ),
              label: const Text('Delete account…'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addSecurityKey(NeoRecallController ctrl) async {
    final label = await _promptDialog(
      'Name this key',
      'Give the key a name you will recognise, for example "YubiKey".',
    );
    if (label == null) return;
    final name = label.trim().isEmpty
        ? 'Security key ${ctrl.securityKeys.length + 1}'
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
      'Rename security key',
      'Enter a new name for "${key['label']}".',
    );
    if (label == null || label.trim().isEmpty) return;
    await ctrl.renameSecurityKey(key['id'] as String, label.trim());
    if (ctrl.error != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ctrl.error!)));
    }
  }

  Future<void> _disableTwoFactor(NeoRecallController ctrl) async {
    final password = await _promptDialog(
      'Enter password',
      'Your current password is required to disable 2FA',
      obscure: true,
    );
    if (password == null || password.isEmpty) return;
    await ctrl.disableTwoFactor(password: password);
    if (ctrl.error != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ctrl.error!)));
    }
  }

  Future<void> _regenerateRecoveryCodes(NeoRecallController ctrl) async {
    final password = await _promptDialog(
      'Enter password',
      'Your current password is required.',
      obscure: true,
    );
    if (password == null || password.isEmpty) return;
    final code = await _promptDialog(
      'Enter 2FA code',
      'Enter your current authenticator code.',
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
      builder: (context) {
        final codeController = TextEditingController();
        return AlertDialog(
          title: const Text('Enable 2FA'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Scan this QR code in your authenticator app.'),
              const SizedBox(height: 16),
              if (setup['qrDataUrl'] != null)
                Image.memory(
                  base64Decode((setup['qrDataUrl'] as String).split(',').last),
                  width: 200,
                  height: 200,
                ),
              const SizedBox(height: 8),
              SelectableText(setup['manualKey'] as String? ?? ''),
              const SizedBox(height: 16),
              TextField(
                controller: codeController,
                decoration: const InputDecoration(
                  labelText: 'Authenticator code',
                ),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, codeController.text),
              child: const Text('Verify'),
            ),
          ],
        );
      },
    );
    if (code == null || code.isEmpty) return;
    final codes = await ctrl.enableTwoFactor(code);
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
        title: const Text('Recovery Codes'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Save these codes in a secure place. They are shown only once.',
            ),
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
            child: const Text('Done'),
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
