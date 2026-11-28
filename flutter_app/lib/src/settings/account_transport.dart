import 'package:neolabs_flutter/neolabs_flutter.dart';

import '../api_client.dart';

/// NeoRecall's account routes for the shared account settings.
const recallAccountRoutes = NeoAccountRoutes(
  export: NeoAccountRoute('POST', '/api/v1/auth/account/export'),
  delete: NeoAccountRoute('DELETE', '/api/v1/auth/account'),
  email: NeoAccountRoute('PUT', '/api/v1/auth/email'),
  sessions: NeoAccountRoute('GET', '/api/v1/auth/sessions'),
  revokeSession: NeoAccountRoute('DELETE', '/api/v1/auth/sessions/{id}'),
  signOutEverywhere: NeoAccountRoute('POST', '/api/v1/auth/logout-all'),
);

/// The body names NeoRecall's account routes read.
const recallAccountFields = NeoAccountFields(
  password: 'password',
  code: 'twoFactorCode',
);

/// The shared account calls over NeoRecall's API client and its session.
class RecallAccountTransport implements NeoAccountTransport {
  const RecallAccountTransport(this.api);

  final NeoRecallApiClient api;

  @override
  Future<Map<String, dynamic>> json(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final out = await api.request(method, path, body: body);
    return out is Map ? Map<String, dynamic>.from(out) : <String, dynamic>{};
  }

  @override
  Future<NeoDownload> download(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) => api.download(method, path, body: body);
}
