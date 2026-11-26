import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neolabs_flutter/neolabs_flutter.dart'
    show NeoAuthClient, NeoAuthQrPlate;
import 'package:neorecall/l10n/gen/app_l10n.dart';
import 'package:neorecall/main_auth.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/api_client.dart';
import 'package:neorecall/src/auth/auth_transport.dart';
import 'package:neorecall/src/auth/qr_login.dart';
import 'package:neorecall/src/auth/qr_sign_in_panel.dart';
import 'package:neorecall/src/settings/qr_approval_card.dart';

/// A server answering by path, remembering every request it was sent.
class _Server {
  _Server(this.answers);

  /// Path to the response body, or to an [http.Response] for a failure.
  final Map<String, Object> answers;
  final List<(String, Map<String, dynamic>)> requests = [];

  late final NeoRecallApiClient api = NeoRecallApiClient(
    baseUrl: 'http://localhost:4500',
    client: MockClient((request) async {
      requests.add((
        request.url.path,
        request.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(request.body) as Map<String, dynamic>,
      ));
      final answer = answers[request.url.path];
      if (answer is http.Response) return answer;
      return http.Response(jsonEncode(answer ?? <String, dynamic>{}), 200);
    }),
  );

  List<String> get paths => requests.map((request) => request.$1).toList();
}

const _challenge = <String, dynamic>{
  'challengeId': 'c1',
  'pollToken': 'poll',
  'qrPayload': 'neorecall://qr-login?v=1&backend=x&challenge=c1&secret=s',
  'status': 'pending',
};
const _status = '/api/v1/auth/qr-login/challenge/c1/status';

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: AppL10n.localizationsDelegates,
  supportedLocales: AppL10n.supportedLocales,
  theme: buildNeoRecallTheme(Brightness.light),
  home: home,
);

void main() {
  test('shared auth calls use the v1 paths and carry the 2FA code', () async {
    final server = _Server({});
    await NeoAuthClient(
      neoAuthPost(server.api, extra: {'twoFactorCode': '123456'}),
    ).login(server.api.baseUrl, 'neo', 'secret');

    expect(server.paths.single, '/api/v1/auth/login');
    expect(server.requests.single.$2, {
      'username': 'neo',
      'password': 'secret',
      'twoFactorCode': '123456',
    });
  });

  test('only NeoRecall sign-in codes are accepted', () {
    final payload = QrLoginScanPayload.tryParse(
      'neorecall://qr-login?v=1&backend=https%3A%2F%2Fa&challenge=c1&secret=s',
    )!;
    expect(payload.challengeId, 'c1');
    expect(payload.secret, 's');
    for (final other in <String>[
      'neoagent://qr-login?v=1&challenge=c1&secret=s',
      'neorecall://qr-login?v=2&challenge=c1&secret=s',
      'neorecall://qr-login?v=1&challenge=c1',
      'https://example.test',
    ]) {
      expect(QrLoginScanPayload.tryParse(other), isNull, reason: other);
    }
  });

  test('a server time without a zone is UTC', () {
    expect(
      parseServerTime('2026-11-26 10:00:00')!.toUtc(),
      DateTime.utc(2026, 11, 26, 10),
    );
  });

  testWidgets('the code waits for a phone and cancelling asks for a new one', (
    tester,
  ) async {
    final server = _Server({
      '/api/v1/auth/qr-login/challenge': _challenge,
      _status: {
        'status': 'scanned',
        'scannedBy': {'label': 'Neo phone'},
      },
    });
    final controller = NeoRecallController(api: server.api);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(Scaffold(body: QrSignInPanel(controller: controller))),
    );
    await tester.pump();
    expect(
      tester.widget<NeoAuthQrPlate>(find.byType(NeoAuthQrPlate)).payload,
      _challenge['qrPayload'],
    );

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('Approve the sign-in on Neo phone.'), findsOneWidget);
    expect(server.requests.last.$2, {
      'token': 'poll',
      'knownStatus': 'pending',
    });

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump();
    expect(server.paths, contains('/api/v1/auth/qr-login/challenge/c1/cancel'));
    expect(find.byType(NeoAuthQrPlate), findsOneWidget);

    // Leaving the screen stops the polling.
    await tester.pumpWidget(_app(const SizedBox()));
    final sent = server.requests.length;
    await tester.pump(const Duration(minutes: 1));
    expect(server.requests, hasLength(sent));
  });

  testWidgets('a password reset is offered only when the server can send one', (
    tester,
  ) async {
    for (final available in <bool>[false, true]) {
      final server = _Server({
        '/api/v1/auth/options': {
          'passwordReset': available,
          'registration': false,
        },
      });
      final controller = NeoRecallController(api: server.api);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _app(
          ListenableBuilder(
            key: ValueKey(available),
            listenable: controller,
            builder: (_, _) => NeoRecallAuthScreen(
              key: ValueKey(available),
              controller: controller,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Need a new account? Register'), findsNothing);
      expect(
        find.text('Forgot password?'),
        available ? findsOneWidget : findsNothing,
      );
      if (!available) continue;

      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Username or email'),
        'neo',
      );
      await tester.tap(find.text('Send link'));
      await tester.pumpAndSettle();
      expect(server.requests.last.$1, '/api/v1/auth/password/forgot');
      expect(server.requests.last.$2, {'account': 'neo'});
      expect(find.byType(AlertDialog), findsNothing);
    }
  });

  for (final approve in <bool>[true, false]) {
    testWidgets('a scanned code is ${approve ? 'approved' : 'declined'}', (
      tester,
    ) async {
      final server = _Server({
        '/api/v1/account/qr-login/resolve': {
          'requestedDevice': {'label': 'macOS · Chrome'},
          'requestLocation': {'label': 'Home', 'ipAddress': '10.0.0.2'},
        },
      });
      final controller = NeoRecallController(api: server.api);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: QrApprovalCard(
              controller: controller,
              scan: (_) async =>
                  const QrLoginScanPayload(challengeId: 'c1', secret: 's'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Scan QR code'));
      await tester.pumpAndSettle();
      expect(find.text('macOS · Chrome'), findsOneWidget);
      expect(find.text('Home · 10.0.0.2'), findsOneWidget);

      await tester.tap(find.text(approve ? 'Approve' : 'Decline'));
      await tester.pumpAndSettle();
      expect(
        server.requests.last.$1,
        '/api/v1/account/qr-login/${approve ? 'approve' : 'decline'}',
      );
      expect(server.requests.last.$2['secret'], 's');
    });
  }
}
