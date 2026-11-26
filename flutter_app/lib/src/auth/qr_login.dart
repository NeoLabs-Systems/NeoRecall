/// The values exchanged while a signed-in phone approves another screen.
library;

/// The code a signed-out screen shows, with the token it polls with.
class QrLoginChallenge {
  const QrLoginChallenge({
    required this.challengeId,
    required this.pollToken,
    required this.qrPayload,
    required this.expiresAt,
  });

  factory QrLoginChallenge.fromJson(Map<String, dynamic> json) =>
      QrLoginChallenge(
        challengeId: json['challengeId'] as String? ?? '',
        pollToken: json['pollToken'] as String? ?? '',
        qrPayload: json['qrPayload'] as String? ?? '',
        expiresAt: parseServerTime(json['expiresAt']),
      );

  final String challengeId;
  final String pollToken;
  final String qrPayload;
  final DateTime? expiresAt;

  bool get isUsable =>
      challengeId.isNotEmpty && pollToken.isNotEmpty && qrPayload.isNotEmpty;

  bool get isExpired => expiresAt?.isBefore(DateTime.now()) ?? false;

  /// Whole seconds until the code is replaced; zero when unknown or past.
  int get secondsRemaining {
    final left = expiresAt?.difference(DateTime.now()).inSeconds ?? 0;
    return left > 0 ? left : 0;
  }
}

/// What a scanned `neorecall://qr-login` code names.
///
/// The code also carries the asking screen's server address. It is ignored: the
/// phone only ever talks to the server it is already signed in to.
class QrLoginScanPayload {
  const QrLoginScanPayload({required this.challengeId, required this.secret});

  static QrLoginScanPayload? tryParse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'neorecall' || uri.host != 'qr-login') {
      return null;
    }
    final challengeId = uri.queryParameters['challenge'] ?? '';
    final secret = uri.queryParameters['secret'] ?? '';
    if (uri.queryParameters['v'] != '1' ||
        challengeId.isEmpty ||
        secret.isEmpty) {
      return null;
    }
    return QrLoginScanPayload(challengeId: challengeId, secret: secret);
  }

  final String challengeId;
  final String secret;
}

/// What the phone is shown before it approves.
class QrLoginApprovalPreview {
  const QrLoginApprovalPreview({
    required this.deviceLabel,
    required this.locationLabel,
    required this.ipAddress,
    required this.requestedAt,
  });

  factory QrLoginApprovalPreview.fromJson(Map<String, dynamic> json) {
    final device = json['requestedDevice'] as Map? ?? const {};
    final location = json['requestLocation'] as Map? ?? const {};
    return QrLoginApprovalPreview(
      deviceLabel: device['label'] as String? ?? '',
      locationLabel: location['label'] as String? ?? '',
      ipAddress: location['ipAddress'] as String?,
      requestedAt: parseServerTime(json['requestedAt']),
    );
  }

  final String deviceLabel;
  final String locationLabel;
  final String? ipAddress;
  final DateTime? requestedAt;
}

/// Reads a server timestamp as local time. SQLite's `YYYY-MM-DD HH:MM:SS` form
/// carries no zone and means UTC.
DateTime? parseServerTime(Object? value) {
  if (value is! String || value.isEmpty) return null;
  final iso = value.contains('T') ? value : '${value.replaceFirst(' ', 'T')}Z';
  return DateTime.tryParse(iso)?.toLocal();
}
