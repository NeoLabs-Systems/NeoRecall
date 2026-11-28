import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_settings.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/api_client.dart';

Future<_SecurityController> _open(
  WidgetTester tester, {
  bool admin = false,
}) async {
  tester.view.physicalSize = const Size(1400, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = _SecurityController(admin: admin);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      theme: buildNeoRecallTheme(Brightness.light),
      home: Scaffold(
        body: SettingsScreen(
          controller: controller,
          initialSection: SettingsSection.security,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('security shows the email, signed-in devices and your data', (
    tester,
  ) async {
    await _open(tester);
    expect(find.text('ada@example.com'), findsOneWidget);
    expect(
      find.text('Waiting for confirmation: ada@new.example'),
      findsOneWidget,
    );
    expect(find.text('Send the link again'), findsOneWidget);
    expect(find.text('Phone'), findsOneWidget);
    expect(find.text('THIS DEVICE'), findsOneWidget);
    expect(find.text('Laptop'), findsOneWidget);
    expect(find.text('Sign out everywhere'), findsOneWidget);
    expect(find.text('Download my data'), findsOneWidget);
    expect(find.text('Delete permanently'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ending another session asks the server to revoke it', (
    tester,
  ) async {
    final c = await _open(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(
      c.sent.any(
        (r) =>
            r.method == 'DELETE' &&
            r.url.path == '/api/v1/auth/sessions/laptop',
      ),
      isTrue,
    );
    expect(find.text('Laptop'), findsNothing);
  });

  testWidgets('deleting the account asks for the password and the username', (
    tester,
  ) async {
    final c = await _open(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete permanently'));
    await tester.pumpAndSettle();
    final submit = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, 'Delete permanently'),
    );
    bool enabled() => tester.widget<FilledButton>(submit).onPressed != null;
    expect(enabled(), isFalse);
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), 'secret');
    await tester.pump();
    expect(enabled(), isFalse);
    await tester.enterText(fields.at(1), 'ADA');
    await tester.pump();
    expect(enabled(), isTrue);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    final delete = c.sent.lastWhere(
      (r) => r.url.path == '/api/v1/auth/account',
    );
    expect(delete.method, 'DELETE');
    expect(jsonDecode(delete.body), <String, dynamic>{
      'password': 'secret',
      'confirmUsername': 'ADA',
    });
    expect(c.forgotten, isTrue);
  });

  testWidgets('an admin cannot start deleting their own account', (
    tester,
  ) async {
    await _open(tester, admin: true);
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Delete permanently'),
    );
    expect(button.onPressed, isNull);
  });
}

class _SecurityController extends NeoRecallController {
  _SecurityController({required bool admin}) : this._(<http.Request>[], admin);

  _SecurityController._(this.sent, bool admin)
    : super(
        api: NeoRecallApiClient(
          baseUrl: 'https://recall.example.test',
          token: 'nrs_test',
          client: MockClient((request) async {
            sent.add(request);
            return _answer(request);
          }),
        ),
      ) {
    username = 'ada';
    isAdmin = admin;
  }

  final List<http.Request> sent;
  bool forgotten = false;

  static http.Response _answer(http.Request request) {
    Map<String, dynamic> session(String id, String agent, bool current) =>
        <String, dynamic>{'id': id, 'current': current, 'userAgent': agent};
    final body = switch ((request.method, request.url.path)) {
      ('GET', '/api/v1/auth/email') => <String, dynamic>{
        'email': 'ada@example.com',
        'emailVerified': true,
        'pendingEmail': 'ada@new.example',
        'canConfirm': true,
      },
      ('GET', '/api/v1/auth/sessions') => <String, dynamic>{
        'sessions': <Object>[
          session('phone', 'Phone', true),
          session('laptop', 'Laptop', false),
        ],
      },
      ('DELETE', '/api/v1/auth/sessions/laptop') => <String, dynamic>{
        'success': true,
        'sessions': <Object>[session('phone', 'Phone', true)],
      },
      _ => null,
    };
    return body == null
        ? http.Response('', 204)
        : http.Response(
            jsonEncode(body),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
  }

  @override
  Future<void> forgetDeletedAccount() async => forgotten = true;

  @override
  Future<Map<String, dynamic>> loadSettings() async => <String, dynamic>{
    'timezone': 'UTC',
  };

  @override
  Future<void> fetchTwoFactorStatus() async {}

  @override
  Future<void> fetchSecurityKeys() async {}

  @override
  Future<void> loadIntegrations() async {}

  @override
  Future<void> loadCloudStatus() async {}
}
