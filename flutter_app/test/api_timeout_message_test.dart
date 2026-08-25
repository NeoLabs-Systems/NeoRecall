import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neorecall/src/api_client.dart';

/// A server that never answers in time. Dart words that as "Future not
/// completed", which every screen would otherwise print verbatim.
NeoRecallApiClient _clientThatOutlivesItsDeadline() => NeoRecallApiClient(
  baseUrl: 'http://127.0.0.1:9999',
  token: 'test-token',
  requestTimeout: const Duration(milliseconds: 20),
  client: MockClient((request) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return http.Response('{}', 200);
  }),
);

void main() {
  test(
    'a request that runs out of time reads as a server that went quiet',
    () async {
      final api = _clientThatOutlivesItsDeadline();
      final error = await api
          .request('GET', '/api/v1/memories')
          .then<Object?>((_) => null, onError: (Object error) => error);

      expect(error, isA<ApiException>());
      final failure = error! as ApiException;
      expect(failure.code, 'REQUEST_TIMEOUT');
      // What a snackbar would show.
      expect('$failure', isNot(contains('Future not completed')));
      expect('$failure', isNot(contains('TimeoutException')));
      expect('$failure', contains('did not respond in time'));
    },
  );

  test('a speaker preview that runs out of time reads the same way', () async {
    final api = _clientThatOutlivesItsDeadline();
    final error = await api
        .speakerPreview('speaker-1')
        .then<Object?>((_) => null, onError: (Object error) => error);

    expect(error, isA<ApiException>());
    expect('$error', isNot(contains('Future not completed')));
    expect('$error', contains('did not respond in time'));
  });
}
