part of '../../main_controller.dart';

/// What the sign-in screen offers besides the password form (password reset and
/// QR sign-in), and the signed-in phone's side of approving a QR sign-in.
mixin SignInController on ChangeNotifier, AuthController {
  // Provided by NeoRecallController.
  String get _platform;
  String get _deviceName;

  bool passwordResetAvailable = false;
  bool registrationOpen = true;

  QrLoginChallenge? qrLoginChallenge;

  /// The label of the phone that scanned the code and is deciding.
  String? qrLoginScannedBy;
  String? qrLoginError;
  bool isPreparingQrLogin = false;

  bool _qrVisible = false;
  bool _qrServerHoldsPolls = false;
  bool _signInDisposed = false;
  String? _qrPollingId;

  late final NeoQrPolling _qrPolling = NeoQrPolling(
    poll: _pollQrLogin,
    serverHoldsPolls: () => _qrServerHoldsPolls,
    canPoll: () => qrLoginChallenge != null && !authenticated,
  );

  void _notifySignIn() {
    if (!_signInDisposed) notifyListeners();
  }

  Future<void> loadAuthOptions() async {
    try {
      final options = await api.request('GET', '/api/v1/auth/options') as Map;
      passwordResetAvailable = options['passwordReset'] == true;
      registrationOpen = options['registration'] != false;
    } on ApiException {
      // Without an answer, offer no reset and leave registration reachable; the
      // server still refuses what it does not allow.
      passwordResetAvailable = false;
      registrationOpen = true;
    }
    _notifySignIn();
  }

  Future<bool> requestPasswordReset(String account) => _run(() async {
    await _auth.forgotPassword(api.baseUrl, account);
  });

  Map<String, dynamic> get _qrClientMetadata => <String, dynamic>{
    // A browser is better described by the server from its user agent.
    if (!kIsWeb) 'deviceLabel': _deviceName,
    if (!kIsWeb)
      'deviceClass':
          defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS
          ? 'mobile'
          : 'desktop',
    'platform': _platform,
    'appMode': kIsWeb ? 'web' : 'app',
  };

  /// The QR code came on screen.
  Future<void> showQrLogin() {
    _qrVisible = true;
    return prepareQrLogin();
  }

  /// The QR code left the screen; polling stops until it is back.
  void hideQrLogin() {
    _qrVisible = false;
    _qrPolling.pause();
  }

  /// Forgets the current code, for instance when the server changes.
  void _resetQrLogin() {
    _qrPolling.pause();
    qrLoginChallenge = null;
    qrLoginScannedBy = null;
    qrLoginError = null;
    isPreparingQrLogin = false;
  }

  /// Keeps the current code while it is valid, unless [force] asks for another.
  Future<void> prepareQrLogin({bool force = false}) async {
    if (authenticated || isPreparingQrLogin) return;
    final current = qrLoginChallenge;
    if (!force && current != null && !current.isExpired) {
      if (_qrVisible) _qrPolling.start();
      return;
    }
    _resetQrLogin();
    isPreparingQrLogin = true;
    _notifySignIn();
    final server = api.baseUrl;
    try {
      final challenge = QrLoginChallenge.fromJson(
        await _auth.createQrChallenge(server, _qrClientMetadata),
      );
      if (server != api.baseUrl) return;
      if (!challenge.isUsable) {
        qrLoginError = strings.qrSignInUnavailable;
      } else {
        qrLoginChallenge = challenge;
        if (_qrVisible && !_signInDisposed) _qrPolling.start(fresh: true);
      }
    } on ApiException catch (exception) {
      qrLoginError = exception.message;
    } finally {
      isPreparingQrLogin = false;
      _notifySignIn();
    }
  }

  Future<Map<String, dynamic>> _qrAction(
    QrLoginChallenge challenge,
    QrChallengeAction action, {
    String? knownStatus,
  }) => _auth.qrChallengeAction(
    api.baseUrl,
    challenge.challengeId,
    challenge.pollToken,
    action,
    knownStatus: knownStatus,
  );

  /// Null when this check was skipped or its code was replaced while it waited.
  Future<bool?> _pollQrLogin() async {
    final challenge = qrLoginChallenge;
    // A held request can outlive a pause; never run two for one code, or both
    // would claim the same approval.
    if (challenge == null || _qrPollingId == challenge.challengeId) return null;
    _qrPollingId = challenge.challengeId;
    try {
      final status = await _qrAction(
        challenge,
        QrChallengeAction.status,
        knownStatus: qrLoginScannedBy == null ? 'pending' : 'scanned',
      );
      if (qrLoginChallenge != challenge) return null;
      _qrServerHoldsPolls = status['longPoll'] == true;
      if (qrLoginError != null) {
        qrLoginError = null;
        _notifySignIn();
      }
      switch (status['status']) {
        case 'approved':
          await _claimQrLogin(challenge);
        case 'scanned':
          if (qrLoginScannedBy == null) {
            final scanner = status['scannedBy'] as Map?;
            qrLoginScannedBy = scanner?['label'] as String? ?? '';
            _notifySignIn();
          }
        case 'declined':
          await prepareQrLogin(force: true);
          qrLoginError = strings.qrSignInDeclined;
          _notifySignIn();
        case 'expired' || 'claimed':
          await prepareQrLogin(force: true);
      }
      return true;
    } on ApiException catch (exception) {
      if (qrLoginChallenge != challenge) return null;
      qrLoginError = exception.message;
      _notifySignIn();
      return false;
    } finally {
      if (_qrPollingId == challenge.challengeId) _qrPollingId = null;
    }
  }

  Future<void> _claimQrLogin(QrLoginChallenge challenge) async {
    final signedIn = await _run(() async {
      final payload = await _qrAction(challenge, QrChallengeAction.claim);
      _resetQrLogin();
      await _acceptSession(payload);
      await refreshAll(silent: true);
    });
    // An approval can be claimed once; a failed claim needs a new code.
    if (!signedIn && !authenticated) await prepareQrLogin(force: true);
  }

  /// Gives up on a scanned code, so a late approval cannot sign this screen in.
  Future<void> cancelQrLoginScan() async {
    final challenge = qrLoginChallenge;
    if (challenge != null) {
      try {
        await _qrAction(challenge, QrChallengeAction.cancel);
      } on ApiException {
        // A fresh code replaces it either way; the old one expires.
      }
    }
    await prepareQrLogin(force: true);
  }

  /// What is asking to sign in, or null with [error] set.
  Future<QrLoginApprovalPreview?> resolveQrApproval(
    QrLoginScanPayload payload,
  ) async {
    QrLoginApprovalPreview? preview;
    await _run(() async {
      preview = QrLoginApprovalPreview.fromJson(
        await _auth.resolveQr(
          api.baseUrl,
          payload.challengeId,
          payload.secret,
          _qrClientMetadata,
        ),
      );
    });
    return preview;
  }

  Future<bool> approveQrLogin(QrLoginScanPayload payload) => _run(() async {
    await _auth.approveQr(
      api.baseUrl,
      payload.challengeId,
      payload.secret,
      _qrClientMetadata,
    );
  });

  /// Tells the waiting screen this phone said no.
  Future<void> declineQrLogin(QrLoginScanPayload payload) async {
    try {
      await _auth.declineQr(api.baseUrl, payload.challengeId, payload.secret);
    } on ApiException {
      // The request expires on its own and the waiting screen moves on.
    }
  }

  void disposeSignIn() {
    _signInDisposed = true;
    _qrPolling.dispose();
  }
}
