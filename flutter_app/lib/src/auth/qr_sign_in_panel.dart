import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:neolabs_flutter/neolabs_flutter.dart'
    show NeoAuthQrPlate, NeoQrSignInCard;

import '../../l10n/gen/app_l10n.dart';
import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';

/// Screens without a camera to scan with offer a code instead.
bool get qrSignInSupported =>
    kIsWeb ||
    const <TargetPlatform>{
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }.contains(defaultTargetPlatform);

/// The sign-in code above the password form. It asks for a code and polls only
/// while the code is on screen and the window is visible.
class QrSignInPanel extends StatefulWidget {
  const QrSignInPanel({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<QrSignInPanel> createState() => _QrSignInPanelState();
}

class _QrSignInPanelState extends State<QrSignInPanel> {
  late final AppLifecycleListener _lifecycle;
  late final Timer _countdown;
  bool _inline = false;
  bool _dialogOpen = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onShow: () {
        _foreground = true;
        _applyVisibility();
      },
      onHide: () {
        _foreground = false;
        widget.controller.hideQrLogin();
      },
    );
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.controller.qrLoginChallenge != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _countdown.cancel();
    _lifecycle.dispose();
    widget.controller.hideQrLogin();
    super.dispose();
  }

  void _applyVisibility() {
    if (!mounted) return;
    if ((_inline || _dialogOpen) && _foreground) {
      unawaited(widget.controller.showQrLogin());
    } else {
      widget.controller.hideQrLogin();
    }
  }

  /// The card reports this during layout, when preparing a code is too early.
  void _setInline(bool inline) {
    if (_inline == inline) return;
    _inline = inline;
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyVisibility());
  }

  Future<void> _openCode() async {
    _dialogOpen = true;
    _applyVisibility();
    final strings = AppL10n.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.qrScanOnPhoneTitle),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(strings.qrScanOnPhoneInstructions),
              const SizedBox(height: AppSpacing.md),
              ListenableBuilder(
                listenable: widget.controller,
                builder: (_, _) => NeoAuthQrPlate(
                  size: 260,
                  payload: widget.controller.qrLoginChallenge?.qrPayload,
                  preparing: widget.controller.isPreparingQrLogin,
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.actionClose),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    _applyVisibility();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final strings = AppL10n.of(context);
      final palette = neoRecallPaletteOf(context);
      final scannedBy = controller.qrLoginScannedBy;
      final challenge = controller.qrLoginChallenge;
      final usable = challenge != null && !challenge.isExpired;
      if (scannedBy != null) {
        return Column(
          children: <Widget>[
            Text(
              strings.qrSignInWaiting(scannedBy),
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.textSecondary, height: 1.45),
            ),
            TextButton(
              onPressed: () => unawaited(controller.cancelQrLoginScan()),
              child: Text(strings.actionCancel),
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          NeoQrSignInCard(
            palette: palette,
            payload: usable ? challenge.qrPayload : null,
            preparing: controller.isPreparingQrLogin,
            title: strings.qrScanOnPhoneTitle,
            instructions: strings.qrScanOnPhoneInstructions,
            status: usable && challenge.secondsRemaining > 0
                ? strings.qrRefreshesIn(challenge.secondsRemaining)
                : strings.qrWaitingForCode,
            refreshLabel: strings.qrSignInNewCode,
            openLabel: strings.qrShowCode,
            onRefresh: () => unawaited(controller.prepareQrLogin(force: true)),
            onOpen: () => unawaited(_openCode()),
            onLayout: _setInline,
          ),
          if (controller.qrLoginError != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            InlineMessage(message: controller.qrLoginError!, error: true),
          ],
        ],
      );
    },
  );
}
