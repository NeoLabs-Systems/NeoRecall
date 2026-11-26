import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/gen/app_l10n.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import 'qr_login.dart';

/// Only the phone apps scan codes with a camera.
bool get qrScannerSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Opens the camera until it reads a sign-in code. Null when the user backs out.
Future<QrLoginScanPayload?> scanQrLoginCode(BuildContext context) =>
    Navigator.of(context).push<QrLoginScanPayload>(
      MaterialPageRoute<QrLoginScanPayload>(
        fullscreenDialog: true,
        builder: (_) => const _QrScannerPage(),
      ),
    );

enum _ScanState { priming, scanning, denied, failed }

class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage();

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  final MobileScannerController _camera = MobileScannerController(
    autoStart: false,
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
  );
  _ScanState _state = _ScanState.priming;
  bool _wrongCode = false;
  Timer? _wrongCodeTimer;
  bool _done = false;

  @override
  void dispose() {
    _wrongCodeTimer?.cancel();
    unawaited(_camera.dispose());
    super.dispose();
  }

  /// Starting the camera triggers the system prompt, so it only happens after
  /// the user read why it is needed.
  Future<void> _start() async {
    setState(() => _state = _ScanState.scanning);
    try {
      await _camera.start();
    } on MobileScannerException catch (error) {
      if (!mounted) return;
      setState(
        () =>
            _state = error.errorCode == MobileScannerErrorCode.permissionDenied
            ? _ScanState.denied
            : _ScanState.failed,
      );
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done || capture.barcodes.isEmpty) return;
    for (final barcode in capture.barcodes) {
      final payload = QrLoginScanPayload.tryParse(barcode.rawValue ?? '');
      if (payload != null) {
        _done = true;
        unawaited(_camera.stop());
        Navigator.of(context).pop(payload);
        return;
      }
    }
    _wrongCodeTimer?.cancel();
    setState(() => _wrongCode = true);
    _wrongCodeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _wrongCode = false);
    });
  }

  Widget _message(String title, String body, {Widget? action}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(body, textAlign: TextAlign.center),
          if (action != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            action,
          ],
        ],
      ),
    ),
  );

  Widget _body(AppL10n strings) {
    final retry = FilledButton(
      onPressed: () => unawaited(_start()),
      child: Text(strings.actionRetry),
    );
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    return switch (_state) {
      _ScanState.priming => _message(
        strings.qrScanPrimeTitle,
        strings.qrScanPrimeBody,
        action: FilledButton(
          onPressed: () => unawaited(_start()),
          child: Text(strings.qrScanPrimeAllow),
        ),
      ),
      // iOS can link to the app's settings page; Android cannot, so the text
      // says where to go.
      _ScanState.denied => _message(
        strings.qrScanDeniedTitle,
        ios ? strings.qrScanDeniedBodyIos : strings.qrScanDeniedBodyAndroid,
        action: ios
            ? FilledButton(
                onPressed: () =>
                    unawaited(launchUrl(Uri.parse('app-settings:'))),
                child: Text(strings.qrScanOpenSettings),
              )
            : retry,
      ),
      _ScanState.failed => _message(
        strings.qrScanFailedTitle,
        strings.qrScanFailedBody,
        action: retry,
      ),
      _ScanState.scanning => Stack(
        fit: StackFit.expand,
        children: <Widget>[
          MobileScanner(
            controller: _camera,
            onDetect: _onDetect,
            errorBuilder: (context, error) =>
                _message(strings.qrScanFailedTitle, strings.qrScanFailedBody),
          ),
          Positioned(
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            bottom: AppSpacing.xxl,
            child: Text(
              _wrongCode ? strings.qrScanWrongCode : strings.qrScanHint,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    // The camera is a dark surface in either theme.
    return Theme(
      data: buildNeoRecallTheme(Brightness.dark),
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: darkPalette.bgPrimary,
          appBar: AppBar(title: Text(strings.qrScanTitle)),
          body: SafeArea(child: _body(strings)),
        ),
      ),
    );
  }
}
