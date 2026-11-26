import 'package:flutter/material.dart';

import '../../l10n/gen/app_l10n.dart';
import '../../main_controller.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import '../auth/qr_login.dart';
import '../auth/qr_scanner_page.dart';

/// Signs another screen in: scan its code, see what is asking, decide.
class QrApprovalCard extends StatefulWidget {
  const QrApprovalCard({
    super.key,
    required this.controller,
    this.scan = scanQrLoginCode,
  });

  final NeoRecallController controller;
  final Future<QrLoginScanPayload?> Function(BuildContext context) scan;

  @override
  State<QrApprovalCard> createState() => _QrApprovalCardState();
}

class _QrApprovalCardState extends State<QrApprovalCard> {
  bool _busy = false;

  Future<void> _scanAndDecide() async {
    final payload = await widget.scan(context);
    if (payload == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final preview = await widget.controller.resolveQrApproval(payload);
      if (!mounted) return;
      if (preview == null) {
        _say(widget.controller.error);
        return;
      }
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => _QrApprovalDialog(preview: preview),
      );
      if (approved != true) {
        await widget.controller.declineQrLogin(payload);
        return;
      }
      final sent = await widget.controller.approveQrLogin(payload);
      if (!mounted) return;
      _say(sent ? AppL10n.of(context).qrApproveDone : widget.controller.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String? message) {
    if (message == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final palette = neoRecallPaletteOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          strings.qrApproveCardTitle,
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          strings.qrApproveCardDescription,
          style: TextStyle(color: palette.textSecondary, height: 1.45),
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton.icon(
          onPressed: _busy ? null : _scanAndDecide,
          icon: const Icon(Icons.qr_code_scanner_rounded),
          label: Text(strings.qrApproveScanAction),
        ),
      ],
    );
  }
}

class _QrApprovalDialog extends StatelessWidget {
  const _QrApprovalDialog({required this.preview});

  final QrLoginApprovalPreview preview;

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final requestedAt = preview.requestedAt;
    final location = <String>[
      preview.locationLabel,
      preview.ipAddress ?? '',
    ].where((part) => part.isNotEmpty).join(' · ');
    return AlertDialog(
      title: Text(strings.qrApproveDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            preview.deviceLabel,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (location.isNotEmpty) Text(location),
          if (requestedAt != null)
            Text(
              strings.qrApproveRequestedAt(
                MaterialLocalizations.of(
                  context,
                ).formatTimeOfDay(TimeOfDay.fromDateTime(requestedAt)),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          Text(strings.qrApproveWarning),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(strings.qrApproveDecline),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(strings.qrApproveAction),
        ),
      ],
    );
  }
}
