import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main_theme.dart';

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
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({
    super.key,
    required this.username,
    required this.twoFactorEnabled,
    required this.onConfirm,
  });

  final String username;
  final bool twoFactorEnabled;

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
  }) async {
    final deleted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => DeleteAccountDialog(
        username: username,
        twoFactorEnabled: twoFactorEnabled,
        onConfirm: onConfirm,
      ),
    );
    return deleted ?? false;
  }

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
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
      title: const Text('Delete your account'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'This removes everything, permanently. There is no undo and no '
                'backup you can ask us to restore from.',
                style: TextStyle(color: palette.textSecondary, height: 1.45),
              ),
              const SizedBox(height: 16),
              _ErasedList(palette: palette),
              const SizedBox(height: 20),
              TextField(
                controller: _password,
                enabled: !_working,
                obscureText: true,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Your password',
                ),
              ),
              if (widget.twoFactorEnabled) ...<Widget>[
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  enabled: !_working,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Authenticator code',
                    helperText: 'A current code, or one of your recovery codes.',
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
                  labelText: 'Type ${widget.username} to confirm',
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
                            style: TextStyle(color: palette.danger, height: 1.4),
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
          child: const Text('Keep my account'),
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
              : const Text('Delete permanently'),
        ),
      ],
    );
  }
}

/// Named consequences, not a summary. "All your data" is easy to agree to
/// without picturing what it contains.
class _ErasedList extends StatelessWidget {
  const _ErasedList({required this.palette});

  final NeoRecallPalette palette;

  static const _items = <String>[
    'Every transcript, conversation and memory',
    'Named speakers and their voice profiles',
    'Recordings still waiting to upload on this device',
    'Connected devices, security keys and sign-in history',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _items
          .map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: palette.danger,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item,
                      style: TextStyle(
                        color: palette.textPrimary,
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
