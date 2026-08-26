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

  test(
    'a proxy outage with a plain-text body reports server availability',
    () async {
      final api = NeoRecallApiClient(
        baseUrl: 'https://recall.example',
        client: MockClient(
          (request) async => http.Response('proxy tunnel unavailable', 530),
        ),
      );

      final error = await api
          .request('GET', '/health')
          .then<Object?>((_) => null, onError: (Object error) => error);

      expect(error, isA<ApiException>());
      final failure = error! as ApiException;
      expect(failure.status, 530);
      expect(failure.code, 'HTTP_ERROR');
      expect(failure.message, contains('server is unavailable'));
      expect(failure.message, contains('HTTP 530'));
      expect(failure.message, isNot(contains('Request failed')));
    },
  );

  test('a transport failure reports that the server is unreachable', () async {
    final api = NeoRecallApiClient(
      baseUrl: 'https://recall.example',
      client: MockClient((request) async {
        throw http.ClientException('Connection failed', request.url);
      }),
    );

    final error = await api
        .request('POST', '/api/v1/auth/login', body: <String, String>{})
        .then<Object?>((_) => null, onError: (Object error) => error);

    expect(error, isA<ApiException>());
    final failure = error! as ApiException;
    expect(failure.status, 0);
    expect(failure.code, 'SERVER_UNREACHABLE');
    expect(failure.message, contains('could not connect'));
    expect(failure.message, isNot(contains('ClientException')));
  });

  test('a malformed successful response is identified as invalid', () async {
    final api = NeoRecallApiClient(
      baseUrl: 'https://recall.example',
      client: MockClient(
        (request) async => http.Response('<html></html>', 200),
      ),
    );

    final error = await api
        .request('GET', '/health')
        .then<Object?>((_) => null, onError: (Object error) => error);

    expect(error, isA<ApiException>());
    final failure = error! as ApiException;
    expect(failure.code, 'INVALID_SERVER_RESPONSE');
    expect(failure.message, contains('HTTP 200'));
  });
}
