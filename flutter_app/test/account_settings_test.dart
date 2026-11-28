import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neolabs_flutter/neolabs_flutter.dart';
import 'package:neorecall/src/api_client.dart';
import 'package:neorecall/src/settings/account_transport.dart';

/// Records each request and answers from [answer].
({NeoAccountApi api, List<http.Request> sent}) _account(
  http.Response Function(http.Request request) answer,
) {
  final sent = <http.Request>[];
  final client = NeoRecallApiClient(
    baseUrl: 'https://recall.example',
    token: 'nrs_test',
    client: MockClient((request) async {
      sent.add(request);
      return answer(request);
    }),
  );
  return (
    api: NeoAccountApi(
      RecallAccountTransport(client),
      routes: recallAccountRoutes,
      fields: recallAccountFields,
    ),
    sent: sent,
  );
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

const _identity = NeoIdentity(password: 'secret', code: '123456');

void main() {
  test('the export is a POST that re-authenticates and saves a zip', () async {
    final a = _account(
      (_) => http.Response.bytes(
        <int>[80, 75, 3, 4],
        200,
        headers: <String, String>{
          'content-type': 'application/zip',
          'content-disposition':
              'attachment; filename="neorecall-ada-2026-11-28.zip"',
        },
      ),
    );
    final file = await a.api.exportData(_identity);
    final request = a.sent.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/api/v1/auth/account/export');
    expect(request.headers['Authorization'], 'Bearer nrs_test');
    expect(jsonDecode(request.body), <String, dynamic>{
      'password': 'secret',
      'twoFactorCode': '123456',
    });
    expect(file.filename, 'neorecall-ada-2026-11-28.zip');
    expect(file.mimeType, 'application/zip');
    expect(file.bytes, <int>[80, 75, 3, 4]);
  });

  test('a refused export surfaces the server code', () async {
    final a = _account(
      (_) => _json(<String, dynamic>{
        'error': <String, dynamic>{
          'code': 'INVALID_PASSWORD',
          'message': 'Current password is incorrect.',
        },
      }, 401),
    );
    await expectLater(
      a.api.exportData(_identity),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'INVALID_PASSWORD'),
      ),
    );
  });

  test('deleting the account sends the password and code', () async {
    final a = _account((_) => http.Response('', 204));
    await a.api.deleteAccount(
      const NeoIdentity(
        password: 'secret',
        code: '123456',
        confirmation: 'ada',
      ),
    );
    final request = a.sent.single;
    expect(request.method, 'DELETE');
    expect(request.url.path, '/api/v1/auth/account');
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(body['password'], 'secret');
    expect(body['twoFactorCode'], '123456');
  });

  test(
    'changing the email re-authenticates and reports the pending address',
    () async {
      final a = _account(
        (_) => _json(<String, dynamic>{
          'email': 'ada@example.com',
          'emailVerified': true,
          'pendingEmail': 'ada@new.example',
          'canConfirm': true,
        }),
      );
      final out = await a.api.changeEmail(' ada@new.example ', _identity);
      final request = a.sent.single;
      expect(request.method, 'PUT');
      expect(request.url.path, '/api/v1/auth/email');
      expect(jsonDecode(request.body), <String, dynamic>{
        'email': 'ada@new.example',
        'password': 'secret',
        'twoFactorCode': '123456',
      });
      expect(out['pendingEmail'], 'ada@new.example');
    },
  );

  test(
    'sessions are listed, revoked one by one, and ended everywhere',
    () async {
      final a = _account((request) {
        if (request.method == 'GET') {
          return _json(<String, dynamic>{
            'sessions': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'abc',
                'current': true,
                'userAgent': 'Phone',
                'createdAt': '2026-11-28T10:00:00Z',
              },
              <String, dynamic>{'id': 'd/e', 'current': false},
            ],
          });
        }
        if (request.method == 'DELETE') {
          return _json(<String, dynamic>{
            'success': true,
            'sessions': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'abc', 'current': true},
            ],
          });
        }
        return http.Response('', 204);
      });
      final list = await a.api.sessions();
      expect(a.sent.last.url.path, '/api/v1/auth/sessions');
      expect(list.map((s) => s.id), <String>['abc', 'd/e']);
      expect(list.first.current, isTrue);
      expect(list.first.createdAt, DateTime.utc(2026, 11, 28, 10));

      final left = await a.api.revokeSession('d/e');
      expect(a.sent.last.method, 'DELETE');
      expect(
        a.sent.last.url.toString(),
        'https://recall.example/api/v1/auth/sessions/d%2Fe',
      );
      expect(left!.single.id, 'abc');

      expect(await a.api.signOutEverywhere(), isNull);
      expect(a.sent.last.method, 'POST');
      expect(a.sent.last.url.path, '/api/v1/auth/logout-all');
    },
  );
}
