import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/src/admin/admin_neorouter_card.dart';
import 'package:neorecall/src/admin/admin_neorouter_client.dart';
import 'package:neorecall/src/api_client.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, dynamic> _state({
  bool connected = true,
  bool reachable = true,
  List<String> active = const <String>['llm', 'transcription', 'embeddings'],
}) => <String, dynamic>{
  'allRoles': <String>['llm', 'transcription', 'embeddings'],
  'connected': connected,
  'address': connected ? 'https://router.example.com' : null,
  'roles': connected ? active : <String>[],
  'reachable': reachable,
  'unreachableReason': reachable ? null : 'Could not reach NeoRouter.',
  'offer': reachable && connected
      ? <String, dynamic>{
          'roles': <String, dynamic>{
            'llm': <String, dynamic>{'models': 12, 'auto': 4},
            'transcription': <String, dynamic>{'models': 0, 'auto': 0},
            'embeddings': <String, dynamic>{'models': 1, 'auto': 1},
          },
          'notAllowed': <String, dynamic>{
            'llm': 0,
            'transcription': 3,
            'embeddings': 0,
          },
        }
      : null,
};

Future<void> _pump(
  WidgetTester tester,
  MockClient mock, {
  Future<void> Function(Uri)? openUrl,
}) async {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: AdminNeoRouterCard(
            controller: NeoRecallController(),
            client: AdminNeoRouterClient(
              NeoRecallApiClient(
                baseUrl: 'http://server.test',
                token: 'session-token',
                client: mock,
              ),
            ),
            pollInterval: const Duration(milliseconds: 10),
            openUrl: openUrl ?? (_) async {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('connecting opens NeoRouter, shows the code and ends connected', (
    tester,
  ) async {
    var connected = false;
    var polls = 0;
    final opened = <Uri>[];
    final mock = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path == '/api/v1/admin/neorouter') {
        return _json(_state(connected: connected));
      }
      if (request.method == 'POST' && path.endsWith('/connect')) {
        expect(jsonDecode(request.body)['address'], 'router.example.com');
        return _json(<String, dynamic>{
          'id': 'abc',
          'url': 'https://router.example.com/app/?connect=req1',
          'userCode': 'ABCD-EFGH',
        });
      }
      if (path.endsWith('/connect/abc')) {
        polls += 1;
        if (polls >= 2) connected = true;
        return _json(<String, dynamic>{
          'status': polls >= 2 ? 'completed' : 'pending',
          'error': null,
        });
      }
      return http.Response('{}', 404);
    });
    await _pump(tester, mock, openUrl: (url) async => opened.add(url));

    expect(find.text('Connect NeoRouter'), findsOneWidget);
    await tester.tap(find.text('Connect NeoRouter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'router.example.com');
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5));
    expect(opened.single.toString(), contains('connect=req1'));
    expect(find.textContaining('ABCD-EFGH'), findsOneWidget);

    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(
      find.text('Connected to https://router.example.com'),
      findsOneWidget,
    );
    expect(find.text('Summaries and chat'), findsOneWidget);
    expect(find.textContaining('12 models and 4 auto models'), findsOneWidget);
    // Nothing offered for speech: the reason is the models the key may not use.
    expect(
      find.textContaining('3 more models are not allowed for this key'),
      findsOneWidget,
    );
    expect(find.textContaining('rebuilds the search index'), findsOneWidget);
  });

  testWidgets('each kind of work can be switched off and the server is told', (
    tester,
  ) async {
    Map<String, dynamic>? put;
    var active = <String>['llm', 'transcription', 'embeddings'];
    final mock = MockClient((request) async {
      if (request.method == 'PUT') {
        put = jsonDecode(request.body) as Map<String, dynamic>;
        active = (put!['roles'] as List).cast<String>();
        return _json(<String, dynamic>{'roles': active});
      }
      return _json(_state(active: active));
    });
    await _pump(tester, mock);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(put!['roles'], <String>['transcription', 'embeddings']);
    expect(
      tester.widget<Switch>(find.byType(Switch).first).value,
      isFalse,
      reason: 'the switch follows what the server reports',
    );
  });

  testWidgets('an unreachable router is said plainly', (tester) async {
    await _pump(
      tester,
      MockClient((request) async => _json(_state(reachable: false))),
    );
    expect(
      find.textContaining(
        'NeoRouter at https://router.example.com cannot be reached',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('keeps answering from keywords'),
      findsOneWidget,
    );
  });

  testWidgets('a declined connection shows why', (tester) async {
    final mock = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v1/admin/neorouter') {
        return _json(_state(connected: false));
      }
      if (path.endsWith('/connect')) {
        return _json(<String, dynamic>{
          'id': 'x',
          'url': 'https://r/',
          'userCode': 'AAAA-BBBB',
        });
      }
      return _json(<String, dynamic>{
        'status': 'failed',
        'error': 'The connection was declined in NeoRouter.',
      });
    });
    await _pump(tester, mock);
    await tester.tap(find.text('Connect NeoRouter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'r');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.textContaining('declined in NeoRouter'), findsOneWidget);
  });
}
