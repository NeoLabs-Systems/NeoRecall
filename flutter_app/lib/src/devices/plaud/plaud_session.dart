class PlaudEmbeddedSession {
  const PlaudEmbeddedSession({
    required this.accessToken,
    required this.customDomain,
    required this.userId,
    required this.expiresAt,
  });

  final String accessToken;
  final String customDomain;
  final String userId;
  final DateTime expiresAt;

  bool get isFresh => DateTime.now().isBefore(expiresAt);
}

typedef PlaudSessionFetcher = Future<PlaudEmbeddedSession?> Function();
