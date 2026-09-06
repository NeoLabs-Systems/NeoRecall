part of '../../main_controller.dart';

/// Signing in and proving who you are: password login, security keys,
/// two-factor enrolment, session acceptance, and account deletion.
///
/// A part of the controller's library rather than a separate one, because these
/// flows share the controller's private plumbing (`_run`, `_preferences`,
/// `_webAuthn`) and its published state. Splitting the file is what was needed;
/// splitting the privacy boundary was not.
mixin AuthController on ChangeNotifier {
  // Provided by NeoRecallController.
  NeoRecallApiClient get api;
  WebAuthnClient get _webAuthn;
  SyncCoordinator get sync;
  RecallRecorder get recorder;
  bool get authenticated;
  bool get loading;
  set loading(bool value);
  String? get error;
  set error(String? value);
  String? get notice;
  set notice(String? value);
  Future<bool> _run(
    Future<void> Function() operation, {
    void Function()? onTwoFactor,
  });
  Future<void> refreshAll({bool silent});

  /// Adopts a freshly issued session across the whole app (token, cached
  /// settings, device bindings, sync). Lives on the controller because it
  /// touches far more than authentication.
  Future<void> _acceptSession(Map payload);

  String? accountId;
  String? username;
  bool isConfiguringTwoFactor = false;
  Map<String, dynamic> accountTwoFactor = const <String, dynamic>{};
  List<Map<String, dynamic>> securityKeys = const <Map<String, dynamic>>[];
  String? _pendingAccount;
  String? _pendingPassword;
  bool _pendingSecurityKeyLogin = false;
  bool _securityKeyDismissed = false;

  Future<bool> login(
    String account,
    String password, {
    String? twoFactorCode,
  }) async {
    return _run(
      () async {
        final payload =
            await api.request(
                  'POST',
                  '/api/v1/auth/login',
                  body: <String, dynamic>{
                    'account': account,
                    'password': password,
                    'twoFactorCode': ?twoFactorCode,
                  },
                )
                as Map;
        await _acceptSession(payload);
        _pendingAccount = null;
        _pendingPassword = null;
        await refreshAll(silent: true);
      },
      onTwoFactor: () {
        _pendingAccount = account;
        _pendingPassword = password;
        _pendingSecurityKeyLogin = false;
      },
    );
  }

  bool get supportsSecurityKeys => _webAuthn.isSupported;

  /// Signs in with a security key. A key that verifies the user with a PIN or a
  /// fingerprint covers the second factor too, so no code is asked for; a
  /// presence-only key falls back to the two-factor step.
  Future<bool> signInWithSecurityKey({
    String? account,
    String? twoFactorCode,
  }) async {
    final signedIn = await _run(
      () async {
        final start =
            await api.request(
                  'POST',
                  '/api/v1/auth/webauthn/options',
                  body: <String, dynamic>{'account': ?account},
                )
                as Map;
        final assertion = await _webAuthn.getAssertion(
          Map<String, dynamic>.from(start['options'] as Map),
        );
        final payload =
            await api.request(
                  'POST',
                  '/api/v1/auth/webauthn/verify',
                  body: <String, dynamic>{
                    'challengeId': start['challengeId'],
                    'response': assertion,
                    'twoFactorCode': ?twoFactorCode,
                  },
                )
                as Map;
        await _acceptSession(payload);
        _pendingAccount = null;
        _pendingSecurityKeyLogin = false;
        await refreshAll(silent: true);
      },
      onTwoFactor: () {
        _pendingAccount = account;
        _pendingPassword = null;
        _pendingSecurityKeyLogin = true;
      },
    );
    // Dismissing the browser prompt is a deliberate choice, not a failure worth
    // reporting back on the sign-in card.
    if (!signedIn && _securityKeyDismissed) {
      _securityKeyDismissed = false;
      error = null;
      notifyListeners();
    }
    return signedIn;
  }

  Future<void> fetchSecurityKeys() async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      final response =
          await api.request('GET', '/api/v1/settings/security-keys') as Map;
      securityKeys = _securityKeyList(response);
    } catch (_) {
    } finally {
      isConfiguringTwoFactor = false;
      notifyListeners();
    }
  }

  Future<bool> registerSecurityKey(String label) async {
    final registered = await _run(() async {
      final start =
          await api.request('POST', '/api/v1/settings/security-keys/options')
              as Map;
      final attestation = await _webAuthn.createCredential(
        Map<String, dynamic>.from(start['options'] as Map),
      );
      final response =
          await api.request(
                'POST',
                '/api/v1/settings/security-keys',
                body: <String, dynamic>{
                  'challengeId': start['challengeId'],
                  'response': attestation,
                  'label': label,
                },
              )
              as Map;
      securityKeys = _securityKeyList(response);
      notice = 'Security key added.';
    });
    if (!registered && _securityKeyDismissed) {
      _securityKeyDismissed = false;
      error = null;
      notifyListeners();
    }
    return registered;
  }

  Future<bool> renameSecurityKey(String id, String label) => _run(() async {
    final response =
        await api.request(
              'PUT',
              '/api/v1/settings/security-keys/$id',
              body: <String, dynamic>{'label': label},
            )
            as Map;
    securityKeys = _securityKeyList(response);
  });

  Future<bool> removeSecurityKey(String id) => _run(() async {
    final response =
        await api.request('DELETE', '/api/v1/settings/security-keys/$id')
            as Map;
    securityKeys = _securityKeyList(response);
  });

  List<Map<String, dynamic>> _securityKeyList(Map response) {
    final rows = response['credentials'];
    if (rows is! List) return const <Map<String, dynamic>>[];
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<bool> completeTwoFactor(String code) => _pendingSecurityKeyLogin
      ? signInWithSecurityKey(account: _pendingAccount, twoFactorCode: code)
      : login(
          _pendingAccount ?? '',
          _pendingPassword ?? '',
          twoFactorCode: code,
        );
  Future<bool> register(String usernameValue, String? email, String password) =>
      _run(() async {
        final payload =
            await api.request(
                  'POST',
                  '/api/v1/auth/register',
                  body: <String, dynamic>{
                    'username': usernameValue,
                    if (email?.isNotEmpty ?? false) 'email': email,
                    'password': password,
                  },
                )
                as Map;
        await _acceptSession(payload);
        await refreshAll(silent: true);
      });
  String _readableError(Object error) {
    final text = error.toString();
    if (text.contains('INVALID_PASSWORD')) {
      return 'That password is not correct.';
    }
    if (text.contains('INVALID_TWO_FACTOR')) {
      return 'That authentication code is not valid. Codes expire quickly — try the current one.';
    }
    if (text.contains('TWO_FACTOR_REQUIRED')) {
      return 'This account needs an authenticator code to confirm.';
    }
    return 'The account could not be deleted: $text';
  }

  Future<void> fetchTwoFactorStatus() async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      final response = await api.request('GET', '/api/v1/settings/2fa');
      accountTwoFactor = Map<String, dynamic>.from(response as Map);
    } catch (_) {
    } finally {
      isConfiguringTwoFactor = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> beginTwoFactorSetup() async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      final response = await api.request('POST', '/api/v1/settings/2fa/setup');
      return Map<String, dynamic>.from(response as Map);
    } catch (e) {
      error = e.toString();
      return null;
    } finally {
      isConfiguringTwoFactor = false;
      notifyListeners();
    }
  }

  Future<List<String>> enableTwoFactor(String code) async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      final response = await api.request(
        'POST',
        '/api/v1/settings/2fa/enable',
        body: {'code': code},
      );
      await fetchTwoFactorStatus();
      final map = response as Map;
      if (map['recoveryCodes'] is List) {
        return (map['recoveryCodes'] as List).cast<String>();
      }
      return [];
    } catch (e) {
      error = e.toString();
      return [];
    } finally {
      isConfiguringTwoFactor = false;
      notifyListeners();
    }
  }

  Future<void> disableTwoFactor({
    required String password,
    String? code,
  }) async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      await api.request(
        'DELETE',
        '/api/v1/settings/2fa',
        body: {'password': password, 'code': ?code},
      );
      await fetchTwoFactorStatus();
    } catch (e) {
      error = e.toString();
    } finally {
      isConfiguringTwoFactor = false;
      notifyListeners();
    }
  }

  Future<List<String>> regenerateTwoFactorCodes({
    required String password,
    required String code,
  }) async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      final response = await api.request(
        'POST',
        '/api/v1/settings/2fa/recovery-codes',
        body: {'password': password, 'code': code},
      );
      await fetchTwoFactorStatus();
      final map = response as Map;
      if (map['recoveryCodes'] is List) {
        return (map['recoveryCodes'] as List).cast<String>();
      }
      return [];
    } catch (e) {
      error = e.toString();
      return [];
    } finally {
      isConfiguringTwoFactor = false;
      notifyListeners();
    }
  }
}
