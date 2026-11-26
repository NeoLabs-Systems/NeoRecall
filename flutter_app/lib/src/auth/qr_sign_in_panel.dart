import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:neolabs_flutter/neolabs_flutter.dart' show NeoAuthQrPlate;

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

/// The sign-in code. It asks for a code and polls only while it is on screen
/// and the window is visible.
class QrSignInPanel extends StatefulWidget {
  const QrSignInPanel({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<QrSignInPanel> createState() => _QrSignInPanelState();
}

class _QrSignInPanelState extends State<QrSignInPanel> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onShow: () => unawaited(widget.controller.showQrLogin()),
      onHide: widget.controller.hideQrLogin,
    );
    // Preparing notifies listeners, which is not allowed during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.showQrLogin());
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.controller.hideQrLogin();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final strings = AppL10n.of(context);
      final palette = neoRecallPaletteOf(context);
      final scannedBy = controller.qrLoginScannedBy;
      final secondary = TextStyle(color: palette.textSecondary, height: 1.45);
      return Column(
        children: <Widget>[
          Divider(color: palette.borderLight),
          const SizedBox(height: AppSpacing.sm),
          if (scannedBy == null) ...<Widget>[
            NeoAuthQrPlate(
              size: 180,
              payload: controller.qrLoginChallenge?.qrPayload,
              preparing: controller.isPreparingQrLogin,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              strings.qrSignInHint,
              textAlign: TextAlign.center,
              style: secondary,
            ),
          ] else ...<Widget>[
            Text(
              strings.qrSignInWaiting(scannedBy),
              textAlign: TextAlign.center,
              style: secondary,
            ),
            TextButton(
              onPressed: () => unawaited(controller.cancelQrLoginScan()),
              child: Text(strings.actionCancel),
            ),
          ],
          if (controller.qrLoginError != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            InlineMessage(message: controller.qrLoginError!, error: true),
          ],
          if (scannedBy == null &&
              !controller.isPreparingQrLogin &&
              (controller.qrLoginChallenge == null ||
                  controller.qrLoginError != null))
            TextButton(
              onPressed: () =>
                  unawaited(controller.prepareQrLogin(force: true)),
              child: Text(strings.qrSignInNewCode),
            ),
        ],
      );
    },
  );
}
