import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';

void main() {
  testWidgets('informational header notices expire automatically', (
    tester,
  ) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);

    controller.notice = 'Phone recording started from the home-screen widget.';
    expect(controller.notice, isNotNull);

    await tester.pump(const Duration(seconds: 4));
    expect(controller.notice, isNotNull);

    await tester.pump(const Duration(seconds: 2));
    expect(controller.notice, isNull);
  });

  testWidgets('a newer notice is not cleared by an older timer', (
    tester,
  ) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);

    controller.notice = 'First';
    await tester.pump(const Duration(seconds: 3));
    controller.notice = 'Second';
    await tester.pump(const Duration(seconds: 3));
    expect(controller.notice, 'Second');

    await tester.pump(const Duration(seconds: 3));
    expect(controller.notice, isNull);
  });
}
