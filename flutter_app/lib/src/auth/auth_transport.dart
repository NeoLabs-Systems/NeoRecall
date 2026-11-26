import 'package:neolabs_flutter/neolabs_flutter.dart' show NeoAuthPost;

import '../api_client.dart';

/// A held status request outlasts the server's 25 second long poll.
const Duration _longPollTimeout = Duration(seconds: 45);

/// Runs the shared NeoLabs auth endpoints over the app's own HTTP client.
///
/// The shared client names `/api/...`; NeoRecall serves `/api/v1/...`. [extra]
/// adds fields the shared calls do not carry, such as the two-factor code.
NeoAuthPost neoAuthPost(
  NeoRecallApiClient api, {
  Map<String, dynamic> extra = const <String, dynamic>{},
}) => (baseUrl, path, body, {allowUnauthorized = false}) async {
  final response = await api.request(
    'POST',
    path.replaceFirst('/api/', '/api/v1/'),
    body: <String, dynamic>{...body, ...extra},
    timeout: body.containsKey('knownStatus') ? _longPollTimeout : null,
  );
  return Map<String, dynamic>.from(response as Map);
};
