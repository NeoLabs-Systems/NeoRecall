import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/settings/security_section.dart';

void main() {
  test('manual TOTP keys are shown in groups of four', () {
    expect(groupedTotpSecret('abcd efghijkl'), 'ABCD EFGH IJKL');
    expect(groupedTotpSecret(''), '');
  });
}
