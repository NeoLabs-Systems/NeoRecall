import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';

/// Confirmation flow for permanent account deletion.
///
/// Three deliberate pieces of friction, in increasing order of cost to the user:
/// the exact consequences are spelled out rather than summarised as "all data";
/// the account password (and a current authenticator code, when one is set) must
/// be entered; and the username must be typed out, so the destructive button
/// cannot be reached by muscle memory from the dialog that preceded it.
///
/// Errors render inside the dialog. A snackbar would appear behind the barrier,
/// leaving a wrong password looking like a button that simply did nothing.
/// The confirmation gate in front of an irreversible erasure.
///
/// Both danger-zone actions use it: password, second factor where one is
/// enabled, and the account name typed out. The copy is passed in because the
/// two differ in exactly one respect that matters — whether the account itself
/// survives — and a reader has to be able to tell which one they are agreeing
/// to without reading the button twice.
class DestructiveConfirmDialog extends StatefulWidget {
  const DestructiveConfirmDialog({
    super.key,
    required this.username,
    required this.twoFactorEnabled,
    required this.onConfirm,
    required this.title,
    required this.intro,
    required this.erased,
    required this.confirmLabel,
    this.kept = const <String>[],
  });

  final String username;
  final bool twoFactorEnabled;
  final String title;
  final String intro;

  /// What this action destroys, and — when the account survives — what it
  /// deliberately leaves behind.
  final List<String> erased;
  final List<String> kept;
  final String confirmLabel;

  /// Returns null when the account was deleted, or a message to display.
  final Future<String?> Function({
    required String password,
    String? twoFactorCode,
  })
  onConfirm;

  static Future<bool> show(
    BuildContext context, {
    required String username,
    required bool twoFactorEnabled,
    required Future<String?> Function({
      required String password,
      String? twoFactorCode,
    })
    onConfirm,
    required String title,
    required String intro,
    required List<String> erased,
    required String confirmLabel,
    List<String> kept = const <String>[],
  }) async {
    final done = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => DestructiveConfirmDialog(
        username: username,
        twoFactorEnabled: twoFactorEnabled,
        onConfirm: onConfirm,
        title: title,
        intro: intro,
        erased: erased,
        kept: kept,
        confirmLabel: confirmLabel,
      ),
    );
    return done ?? false;
  }

  @override
  State<DestructiveConfirmDialog> createState() =>
      _DestructiveConfirmDialogState();
}

class _DestructiveConfirmDialogState extends State<DestructiveConfirmDialog> {
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _confirmation = TextEditingController();
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  bool get _confirmed =>
      _confirmation.text.trim().toLowerCase() ==
      widget.username.trim().toLowerCase();

  bool get _canDelete =>
      !_working &&
      _confirmed &&
      _password.text.isNotEmpty &&
      (!widget.twoFactorEnabled || _code.text.trim().isNotEmpty);

  Future<void> _submit() async {
    if (!_canDelete) return;
    setState(() {
      _working = true;
      _error = null;
    });
    final failure = await widget.onConfirm(
      password: _password.text,
      twoFactorCode: widget.twoFactorEnabled ? _code.text.trim() : null,
    );
    if (!mounted) return;
    if (failure != null) {
      setState(() {
        _working = false;
        _error = failure;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: palette.danger, size: 32),
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                widget.intro,
                style: TextStyle(color: palette.textSecondary, height: 1.45),
              ),
              const SizedBox(height: 16),
              _OutcomeList(
                palette: palette,
                items: widget.erased,
                removed: true,
              ),
              if (widget.kept.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                _OutcomeList(
                  palette: palette,
                  items: widget.kept,
                  removed: false,
                ),
              ],
              const SizedBox(height: 20),
              TextField(
                controller: _password,
                enabled: !_working,
                obscureText: true,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: AppL10n.of(context).destructiveYourPassword,
                ),
              ),
              if (widget.twoFactorEnabled) ...<Widget>[
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  enabled: !_working,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: AppL10n.of(
                      context,
                    ).securityAuthenticatorCodeLabel,
                    helperText: AppL10n.of(context).destructiveCodeHelper,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _confirmation,
                enabled: !_working,
                autocorrect: false,
                enableSuggestions: false,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.deny(RegExp(r'\s')),
                ],
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: AppL10n.of(
                    context,
                  ).destructiveTypeToConfirm(widget.username),
                  suffixIcon: _confirmed
                      ? Icon(Icons.check_rounded, color: palette.textSecondary)
                      : null,
                ),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 16),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: palette.danger.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(
                          Icons.error_outline_rounded,
                          size: 18,
                          color: palette.danger,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: palette.danger,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _working ? null : () => Navigator.of(context).pop(false),
          child: Text(AppL10n.of(context).actionCancel),
        ),
        FilledButton(
          onPressed: _canDelete ? _submit : null,
          style: FilledButton.styleFrom(
            backgroundColor: palette.danger,
            disabledBackgroundColor: palette.danger.withValues(alpha: 0.35),
          ),
          child: _working
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Named consequences, not a summary. "All your data" is easy to agree to
/// without picturing what it contains.
/// What goes and what stays, marked so the two cannot be misread for each other.
class _OutcomeList extends StatelessWidget {
  const _OutcomeList({
    required this.palette,
    required this.items,
    required this.removed,
  });

  final NeoRecallPalette palette;
  final List<String> items;
  final bool removed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items
          .map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      removed ? Icons.close_rounded : Icons.check_rounded,
                      size: 16,
                      color: removed ? palette.danger : palette.success,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item,
                      style: TextStyle(
                        color: removed
                            ? palette.textPrimary
                            : palette.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}
