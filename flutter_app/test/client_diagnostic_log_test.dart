import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/diagnostics/client_diagnostic_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('client diagnostics are account-scoped and redact credentials', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final log = ClientDiagnosticLog.instance;
    await log.bindAccount('account-a');
    log.record(
      'network',
      'failed',
      details: <String, Object?>{
        'authorization': 'Bearer secret-token',
        'password': 'not-for-export',
        'error': 'Authorization: Bearer another-secret',
      },
    );
    await Future<void>.delayed(Duration.zero);

    final first = jsonEncode(log.clientSummary());
    expect(first, contains('[redacted]'));
    expect(first, isNot(contains('secret-token')));
    expect(first, isNot(contains('not-for-export')));
    expect(first, isNot(contains('another-secret')));

    await log.bindAccount('account-b');
    expect(log.snapshot(), isEmpty);
    await log.bindAccount('account-a');
    expect(log.snapshot(), hasLength(1));
    await log.clear();
  });
}
